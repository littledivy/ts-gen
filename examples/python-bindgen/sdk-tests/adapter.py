"""A pytest plugin that runs workers-py's runtime-sdk tests against the WASI
Python Worker instead of Pyodide (run.sh loads it with `-p adapter`).

The suite runs unchanged. Where it would call pywrangler or workerd's Python
support, this plugin substitutes:

- `pywrangler sync`: the project's dependencies are vendored into
  python_modules/ as pywrangler does. The SDK and testlib come from the
  workers-py checkout, as in upstream's runs. Packages with native code come
  from ../packages recipes instead, linked into the Worker.
- `pywrangler dev`: ../build.sh builds the project (its main module's
  directory, plus python_modules/) into a directory outside it, and
  `wrangler dev` serves the built entry.js with the project's bindings.
- `workerd test` on a .wd-test (test_in_workerd.py): each Python worker's
  modules become the built Worker (entry.mjs, app.wasm and bridge.wasm), as in
  ../compat-tests, and the config runs once; there is no Pyodide snapshot to
  save and load.

COMPAT_CONFIGS is narrowed to its Python 3.14 entry, the only Python here.
EDITS lists the changes made to the suite's own files, with the reasons;
NA lists what can't run here.
"""

import contextlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest


def _port(host):
    """A free port: from SDK_TESTS_PORTS ("first-last") if set, else any."""
    span = os.environ.get("SDK_TESTS_PORTS")
    if not span:
        return host.get_free_port()
    import socket

    first, last = (int(p) for p in span.split("-"))
    for port in range(first, last + 1):
        with socket.socket() as sock:
            try:
                sock.bind(("127.0.0.1", port))
            except OSError:
                continue
        return port
    raise RuntimeError(f"no free port in {span}")

HERE = Path(__file__).resolve().parent
PYDIR = HERE.parent  # examples/python-bindgen
sys.path.insert(0, str(PYDIR / "packages"))
WORKERS_PY = Path(os.environ.get("WORKERS_PY", HERE / "work/workers-py"))
WORK = Path(os.environ.get("SDK_TESTS_WORK", HERE / "work"))
_PLATFORM = {"darwin": "darwin", "linux": "linux"}.get(sys.platform, sys.platform)
_ARCH = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "64"}.get(os.uname().machine, "64")
WORKERD = Path(os.environ.get("WORKERD", PYDIR / f"node_modules/@cloudflare/workerd-{_PLATFORM}-{_ARCH}/bin/workerd"))
WRANGLER = PYDIR / "node_modules/.bin/wrangler"
ESBUILD = PYDIR / "node_modules/.bin/esbuild"

# The local sources a project's [tool.uv.sources] points at, and their own
# dependencies.
LOCAL = {
    "testlib": ["pytest", "pyodide-tblib>=3.2.3"],
    "workers-runtime-sdk": [],
}

# Native distributions with no recipe that projects list only for the
# Hyperdrive tests, which need local database services and are skipped
# without them: they are left out of python_modules/. psycopg falls back to
# its pure-Python implementation without psycopg-binary.
UNAVAILABLE = {"asyncpg", "psycopg-binary"}

# Linear memory caps (MAX_MEMORY_MIB) above build.sh's default, by project,
# with the reason.
MAX_MEMORY_MIB = {
    # Its worker imports every package the SDK patches (numpy, pydantic,
    # cryptography, aiohttp, tiktoken, botocore, langchain, litestar, ...)
    # and vendors 64 MB of pure-Python packages, which /app holds in memory:
    # the snapshot starts at 147.5 MiB. That is past the isolate's 128 MB, as
    # the app is past the 10 MiB upload limit, so it only runs with this cap.
    "entropy-patches": 160,
}

# Changes to the suite's files: (project-relative path, from, to, why).
EDITS: list[tuple[str, str, str, str]] = []

# Projects or suites that can't run here, with the reason; their tests are
# skipped with it.
NA: dict[str, str] = {}


# ---- sync ----


def sync(project):
    """Vendors `project`'s dependencies into python_modules/ with
    ../packages/sync.py, as build.sh does for a pyproject.toml, and records
    the recipes its native dependencies need in .cf-packages."""
    import sync as pkgsync

    vendor = project / "python_modules"
    recipes, local = pkgsync.sync(project, vendor, local=LOCAL, unavailable=UNAVAILABLE)
    for name in ("testlib", "workers"):
        shutil.rmtree(vendor / name, ignore_errors=True)
    if "testlib" in local:
        shutil.copytree(WORKERS_PY / "packages/testlib/testlib", vendor / "testlib")
    # pywrangler sync vendors the SDK into every project, listed or not (its
    # MANAGED_SDK_PACKAGE), and from 2026-04-21 (python_external_sdk) Python
    # Workers run that copy rather than the runtime's own.
    src = WORKERS_PY / "packages/runtime-sdk/src"
    for p in src.iterdir():
        if p.suffix == ".pyi":
            continue
        dest = vendor / p.name
        if dest.is_dir():
            shutil.rmtree(dest)
        (shutil.copytree if p.is_dir() else shutil.copy2)(p, dest)
    for p in vendor.rglob("__pycache__"):
        shutil.rmtree(p, ignore_errors=True)
    (project / ".cf-packages").write_text(" ".join(recipes))
    for rel, old, new, why in EDITS:
        f = project / rel
        if f.exists():
            text = f.read_text()
            if old not in text:
                raise RuntimeError(f"edit no longer applies to {rel}: {why}")
            f.write_text(text.replace(old, new))


def _pywrangler_sync(cwd, env):
    try:
        sync(Path(cwd))
    except Exception as e:  # noqa: BLE001  (sync.SyncError names what's missing)
        pytest.fail(f"sync failed in {cwd}: {e}")


# ---- build ----


def build(app, main, out, packages):
    """Builds `app` (its main module `main`) into `out` with ../build.sh."""
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    log = out.parent / f"{out.name}-build.log"
    env = os.environ | {
        "APP": str(app),
        "MAIN": main,
        "OUTDIR": str(out),
        "PACKAGES": packages,
        # pytest imports stdlib modules (unittest, doctest, pdb...) as it runs.
        "RUNTIME_IMPORTS": "all",
    }
    if app.name in MAX_MEMORY_MIB:
        env["MAX_MEMORY_MIB"] = str(MAX_MEMORY_MIB[app.name])
    with log.open("w") as fh:
        r = subprocess.run(["./build.sh"], cwd=PYDIR, env=env, stdout=fh, stderr=subprocess.STDOUT)
    if r.returncode != 0:
        tail = log.read_text(errors="replace").strip().splitlines()[-15:]
        pytest.fail(f"build.sh failed for {app} (log {log}):\n" + "\n".join(tail))


def _strip_jsonc(text):
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i : j + 1])
            i = j + 1
        elif text.startswith("//", i):
            i = text.find("\n", i)
            i = n if i < 0 else i
        elif text.startswith("/*", i):
            i = text.find("*/", i) + 2
        else:
            out.append(c)
            i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


def _stage(target):
    """The app build.sh builds for a wrangler project: its main module's
    directory with python_modules/ beside the main module, as wrangler
    uploads it. Returns (app dir, main module, wrangler config)."""
    config = json.loads(_strip_jsonc((target / "wrangler.jsonc").read_text()))
    main = Path(config["main"])
    app = target.parent / f"{target.name}-app"
    shutil.rmtree(app, ignore_errors=True)
    shutil.copytree(target / main.parent, app)
    shutil.copytree(target / "python_modules", app / "python_modules")
    return app, main.name, config


@contextlib.contextmanager
def _run_dev_server(target, tmp_path, env, *, startup_timeout):
    from testlib import host

    target = Path(target)
    app, main, config = _stage(target)
    out = target.parent / f"{target.name}-out"
    build(app, main, out, (target / ".cf-packages").read_text())
    config["main"] = str(out / "entry.js")
    # python_workers (and its dated python_workers_* variants) would make
    # wrangler run the Worker on Pyodide; other python_* flags, such as
    # python_workflows_implicit_dependencies, are what the SDK reads through
    # _cloudflare_compat_flags, so they stay.
    flags = [
        f for f in config.get("compatibility_flags", [])
        if f != "python_workers" and not f.startswith("python_workers_")
    ]
    config["compatibility_flags"] = [*flags, "nodejs_compat"]
    config.pop("rules", None)
    if "assets" in config:
        config["assets"]["directory"] = str((target / config["assets"]["directory"]).resolve())
    cfg = out / "wrangler.json"
    cfg.write_text(json.dumps(config, indent=2))
    port = _port(host)
    base_url = f"http://127.0.0.1:{port}"
    log_path = Path(tmp_path) / f"{target.name}-dev.log"
    with log_path.open("w") as log_file:
        process = subprocess.Popen(
            [str(WRANGLER), "dev", "--config", str(cfg), "--port", str(port), "--ip", "127.0.0.1",
             "--persist-to", str(Path(tmp_path) / "state")],
            cwd=out,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            env=env | {"WRANGLER_SEND_METRICS": "false"},
            start_new_session=True,
        )
        try:
            host.wait_for_ready(process, base_url, log_path, timeout=startup_timeout)
            yield base_url, log_path
        finally:
            host._terminate(process, host.TEARDOWN_TIMEOUT)


# ---- workerd test (.wd-test) ----


def _match_bracket(s, start):
    pairs = {"(": ")", "[": "]"}
    stack, in_str, i = [], False, start
    while i < len(s):
        c = s[i]
        if in_str:
            if c == "\\":
                i += 1
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "#":
            i = s.find("\n", i)
        elif c in pairs:
            stack.append(pairs[c])
        elif c in ")]":
            if stack.pop() != c:
                raise ValueError(f"unbalanced {c} at {i}")
            if not stack:
                return i + 1
        i += 1
    raise ValueError("unbalanced brackets")


def _entries(lst):
    out, i = [], 1
    while i < len(lst) - 1:
        if lst[i] == "(":
            end = _match_bracket(lst, i)
            out.append(lst[i:end])
            i = end
        else:
            i += 1
    return out


def translate(text):
    """Each modules list with Python modules becomes the built Worker plus the
    list's other modules (the SDK's ES modules among them). Returns the
    config and each worker's main module."""
    mains, out, i = [], [], 0
    pat = re.compile(r"modules\s*=\s*\[")
    while m := pat.search(text, i):
        start = m.end() - 1
        end = _match_bracket(text, start)
        lst = text[start:end]
        if "pythonModule" not in lst:
            out.append(text[i:end])
            i = end
            continue
        entries = _entries(lst)
        name = lambda e: re.search(r'name\s*=\s*"([^"]+)"', e).group(1)  # noqa: E731
        py = [e for e in entries if re.search(r"pythonModule\s*=", e)]
        rest = [
            e for e in entries
            if not re.search(r"python(Module|Requirement)\s*=|\bdata\s*=", e) and not name(e).startswith("tests/")
        ]
        k = len(mains)
        mains.append(name(py[0]))
        mods = [f'(name = "entry.mjs", esModule = embed "build-{k}/entry.mjs")',
                f'(name = "app.wasm", wasm = embed "build-{k}/app.wasm")',
                f'(name = "bridge.wasm", wasm = embed "build-{k}/bridge.wasm")', *rest]
        out.append(text[i:start] + "[\n    " + ",\n    ".join(mods) + "\n  ]")
        i = end
    out.append(text[i:])
    return "".join(out), mains


def run_wd_test(cmd, cwd):
    cwd = Path(cwd)
    wd_file = cmd[2]
    tmpdir_arg = next(a for a in cmd if a.startswith("-dTEST_TMPDIR="))
    config, mains = translate((cwd / wd_file).read_text())
    packages = (cwd / ".cf-packages").read_text()
    for k, main in enumerate(mains):
        out = cwd.parent / f"{cwd.name}-out-{k}"
        build(cwd, main, out, packages)
        dest = cwd / f"build-{k}"
        dest.mkdir(exist_ok=True)
        shutil.copy2(out / "app.wasm", dest / "app.wasm")
        shutil.copy2(out / "bridge.wasm", dest / "bridge.wasm")
        subprocess.run(
            [str(ESBUILD), str(out / "entry.js"), "--bundle", "--format=esm", "--external:cloudflare:*",
             "--external:node:*", "--external:./app.wasm", "--external:./bridge.wasm", f"--outfile={dest / 'entry.mjs'}", "--log-level=error"],
            check=True,
        )
    translated = cwd / f"cf-{wd_file}"
    translated.write_text(config)
    return subprocess.run(
        [str(WORKERD), "test", translated.name, "--experimental", tmpdir_arg],
        cwd=cwd,
        check=True,
    )


class _Subprocess:
    """test_in_workerd's `subprocess`: workerd's Pyodide snapshot runs become
    one run of the translated config."""

    def __getattr__(self, name):
        return getattr(subprocess, name)

    def run(self, cmd, *args, cwd=None, **kwargs):
        cmd = [str(c) for c in cmd]
        if "--python-save-snapshot" in cmd:
            return run_wd_test(cmd, cwd)
        if "--python-load-snapshot" in cmd:
            return subprocess.CompletedProcess(cmd, 0)
        return subprocess.run(cmd, *args, cwd=cwd, **kwargs)


# ---- pytest hooks ----


def _patch_testlib():
    # Runs as the plugin loads, before conftest.py reads COMPAT_CONFIGS.
    import gzip

    import requests
    from testlib import host

    # A suite's results can arrive gzip-compressed twice: the FastAPI
    # project's GZipMiddleware compresses them once they pass its 1 KB
    # minimum (when tests fail, with tracebacks), and wrangler dev's path to
    # the host compresses that body again for the Content-Encoding header it
    # carries; requests decodes one layer. The host reads past the second.
    # (Open question: whether Pyodide's runs see the same.)
    def get(*args, **kwargs):
        resp = requests.get(*args, **kwargs)
        while resp.content[:2] == b"\x1f\x8b":
            resp._content = gzip.decompress(resp.content)
        return resp

    host.requests = type("requests", (), {"get": staticmethod(get), "RequestException": requests.RequestException})

    host.COMPAT_CONFIGS[:] = [c for c in host.COMPAT_CONFIGS if c.python_version == "3.14"]
    host.pywrangler_sync = _pywrangler_sync
    host.run_dev_server = _run_dev_server
    os.environ["WORKERD_PATH"] = str(WORKERD)


_patch_testlib()


def pytest_collection_modifyitems(config, items):
    for item in items:
        for name, why in NA.items():
            if name in item.nodeid:
                item.add_marker(pytest.mark.skip(reason=f"N/A: {name}: {why}"))
        mod = getattr(item, "module", None)
        if mod is not None and mod.__name__ == "test_in_workerd":
            mod.subprocess = _Subprocess()
            mod.pywrangler_sync = _pywrangler_sync
