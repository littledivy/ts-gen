"""Installs a Python Worker project's dependencies as `pywrangler sync` does,
for the WASI Python Worker.

    python sync.py <project dir> <vendor dir>

reads [project].dependencies from <project dir>/pyproject.toml, resolves
them for CPython 3.14 and fills <vendor dir> (the app's python_modules/)
with the pure-Python wheels. Distributions with native code come from the
recipes in recipes/, which build.sh links into the Worker; it prints their
names. A native distribution with no recipe is an error that names it.

- Versions: each recipe's version is a constraint, so the resolution picks
  the versions the recipes build.
- Environment markers are evaluated for the Worker (Python 3.14 on WASI),
  not for the Python running pip.
- A recipe's own pure-Python wheels (WHEELS) and DEPENDS are what it
  provides, so they are left out of <vendor dir>.
- A vendor dir synced from the same dependencies and recipes isn't synced
  again (.cf-sync holds what it was synced from).

sdk-tests/adapter.py imports this module for its `pywrangler sync`.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tomllib
import zipfile
from pathlib import Path

from pip._vendor.packaging.markers import Marker
from pip._vendor.packaging.requirements import Requirement

HERE = Path(__file__).resolve().parent
RECIPES = HERE / "recipes"
DEPS = HERE.parent / "deps"
PIP = [sys.executable, "-m", "pip"]

# The Worker's interpreter, for environment markers.
ENV = {
    "python_version": "3.14",
    "python_full_version": "3.14.10",
    "implementation_name": "cpython",
    "implementation_version": "3.14.10",
    "platform_python_implementation": "CPython",
    "sys_platform": "wasi",
    "platform_system": "wasi",
    "platform_machine": "wasm32",
    "platform_release": "",
    "platform_version": "",
    "os_name": "posix",
    "extra": "",
}


class SyncError(Exception):
    pass


def norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def _log(msg):
    print(f"sync: {msg}", file=sys.stderr, flush=True)


def recipe_vars(name):
    """The variables recipes/<name>.sh sets that sync needs."""
    out = subprocess.run(
        ["bash", "-c", '. "$1" >/dev/null; printf "%s\\n" "$KIND" "$VERSION" "$SDIST" "$WHEELS" "$DEPENDS"',
         "-", str(RECIPES / f"{name}.sh")],
        capture_output=True, text=True, check=True,
        env={"PATH": os.environ.get("PATH", "/usr/bin:/bin")},
    ).stdout.split("\n")
    kind, version, sdist, wheels, depends = out[:5]
    return {"kind": kind, "version": version, "sdist": sdist, "wheels": wheels.split(), "depends": depends.split()}


def recipes():
    """{distribution: (recipe, version, distributions it provides)} for every
    recipe that builds a distribution: its sdist's, or its own name."""
    raw = {p.stem: recipe_vars(p.stem) for p in sorted(RECIPES.glob("*.sh"))}

    def provides(name, seen):
        if name in seen:
            return set()
        seen.add(name)
        r = raw[name]
        dist = norm(re.split(r"[<>=!~ ]", r["sdist"] or name, maxsplit=1)[0])
        out = {dist} | {norm(re.split(r"[<>=!~;\[ ]", w, maxsplit=1)[0]) for w in r["wheels"]}
        for d in r["depends"]:
            out |= provides(d, seen)
        return out

    table = {}
    for name, r in raw.items():
        if r["kind"] == "pure" and not r["sdist"]:
            # A bundle of wheels (fastapi, pytest): the resolver finds those.
            if name not in {norm(re.split(r"[<>=!~ ]", w, maxsplit=1)[0]) for w in r["wheels"]}:
                continue
        dist = norm(re.split(r"[<>=!~ ]", r["sdist"] or name, maxsplit=1)[0])
        table[dist] = (name, r["version"], provides(name, set()))
    return table


def dependencies(project):
    meta = tomllib.loads((project / "pyproject.toml").read_text()).get("project", {})
    return list(meta.get("dependencies", []))


def _resolve_once(reqs, constraints, scratch):
    report = scratch / "resolve.json"
    cfile = scratch / "constraints.txt"
    cfile.write_text("".join(f"{c}\n" for c in constraints))
    cmd = [
        *PIP, "install", "-q", "--dry-run", "--ignore-installed", "--report", str(report),
        "--python-version", "3.14", "--only-binary=:all:", "--target", str(scratch / "unused"),
        "--platform", "macosx_14_0_arm64", "--platform", "any", "--disable-pip-version-check",
        "-c", str(cfile), *reqs,
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SyncError("resolving the dependencies failed:\n" + (r.stderr or r.stdout).strip())
    out = {}
    for item in json.loads(report.read_text())["install"]:
        meta = item["metadata"]
        out[norm(meta["name"])] = {
            "name": meta["name"],
            "version": meta["version"],
            "url": item["download_info"]["url"],
            "requires": meta.get("requires_dist", []),
        }
    return out


def _wanted(req, extras=("",)):
    """Whether the Worker needs `req`, given the extras of what requires it."""
    return req.marker is None or any(req.marker.evaluate(ENV | {"extra": e}) for e in extras)


def _unmarked(req):
    req = Requirement(str(req))
    req.marker = None
    return str(req)


def resolve(reqs, constraints, scratch):
    """Resolves `reqs` for the Worker: {name: info}. pip evaluates markers for
    the Python running it, so the result is walked again with the Worker's,
    and resolved again with whatever only the Worker needs."""
    top = [r for r in map(Requirement, reqs) if _wanted(r)]
    more = []
    for _ in range(4):
        resolved = _resolve_once([_unmarked(r) for r in top] + more, constraints, scratch)
        keep, missing = {}, []
        queue = list(top)
        while queue:
            req = queue.pop()
            name = norm(req.name)
            info = resolved.get(name)
            if info is None:
                missing.append(_unmarked(req).split(";")[0])
                continue
            done = keep.get(name, (info, None))[1]
            if done is not None and not set(req.extras) - done:
                continue
            done = (done or set()) | set(req.extras)
            keep[name] = (info, done)
            for d in info["requires"]:
                dr = Requirement(d)
                if _wanted(dr, ("", *sorted(done))):
                    queue.append(dr)
        if not missing:
            return {n: i for n, (i, _) in keep.items()}
        more = sorted(set(more) | set(missing))
    raise SyncError(f"could not resolve {', '.join(missing)} for Python 3.14")


def _download(name, version, cache):
    cache.mkdir(parents=True, exist_ok=True)
    pat = re.compile(re.escape(name.replace("-", "_")) + r"-" + re.escape(version) + r"-.*-none-any\.whl$", re.I)
    found = [p for p in cache.iterdir() if pat.match(p.name)]
    if found:
        return found[0]
    subprocess.run(
        [*PIP, "download", "-q", "--no-deps", "--only-binary=:all:", "--python-version", "3.14",
         "--platform", "any", "--implementation", "py", "-d", str(cache), f"{name}=={version}",
         "--disable-pip-version-check"],
        check=True,
    )
    found = [p for p in cache.iterdir() if pat.match(p.name)]
    if not found:
        raise SyncError(f"pip downloaded no pure wheel for {name}=={version}")
    return found[0]


def sync(project, vendor, *, local=None, extra_reqs=(), unavailable=()):
    """Fills `vendor` with `project`'s pure-Python dependencies and returns the
    recipes its native ones need.

    `local` maps distribution names that come from elsewhere (local path
    sources) to the requirements they bring instead. Native distributions
    named in `unavailable` are left out instead of being an error."""
    local = local or {}
    reqs, local_found = [], []
    for d in [*dependencies(project), *extra_reqs]:
        r = Requirement(d)
        if norm(r.name) in local:
            if _wanted(r):
                local_found.append(norm(r.name))
                reqs += local[norm(r.name)]
        else:
            reqs.append(d)
    table = recipes()
    stamp = hashlib.sha256(json.dumps(
        [reqs, sorted(unavailable), sorted((k, v[1]) for k, v in table.items()),
         [(p.name, p.read_bytes().hex()) for p in sorted(RECIPES.glob("*.sh"))]]).encode()).hexdigest()
    stamp_file = vendor / ".cf-sync"
    if stamp_file.exists():
        prev = json.loads(stamp_file.read_text())
        if prev.get("stamp") == stamp:
            return prev["recipes"], local_found
    scratch = DEPS / "sync-scratch" / hashlib.sha256(str(vendor).encode()).hexdigest()[:12]
    shutil.rmtree(scratch, ignore_errors=True)
    scratch.mkdir(parents=True)
    constraints = [f"{dist}=={version}" for dist, (_, version, _) in table.items() if version]
    resolved = resolve(reqs, constraints, scratch) if reqs else {}
    chosen, provided, missing = [], set(), []
    for name, info in sorted(resolved.items()):
        if info["url"].endswith("-none-any.whl"):
            continue
        if name in table:
            chosen.append(table[name][0])
            provided |= table[name][2]
        elif name in unavailable:
            _log(f"leaving out {info['name']}=={info['version']}: native, no recipe")
            provided.add(name)
        else:
            missing.append(f"{info['name']}=={info['version']}")
    if missing:
        raise SyncError(
            "these dependencies have native code and no recipe in packages/recipes/: "
            + ", ".join(missing) + " (see packages/README.md, Adding a package)"
        )
    shutil.rmtree(vendor, ignore_errors=True)
    vendor.mkdir(parents=True)
    for name, info in sorted(resolved.items()):
        if name in provided:
            continue
        whl = _download(info["name"], info["version"], DEPS / "wheels")
        with zipfile.ZipFile(whl) as z:
            z.extractall(vendor)
    for p in vendor.rglob("__pycache__"):
        shutil.rmtree(p, ignore_errors=True)
    shutil.rmtree(scratch, ignore_errors=True)
    chosen = list(dict.fromkeys(chosen))
    stamp_file.write_text(json.dumps({"stamp": stamp, "recipes": chosen}))
    return chosen, local_found


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    project, vendor = Path(argv[1]).resolve(), Path(argv[2]).resolve()
    try:
        chosen, _ = sync(project, vendor)
    except SyncError as e:
        print(f"{project / 'pyproject.toml'}: {e}", file=sys.stderr)
        return 1
    print(" ".join(chosen))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
