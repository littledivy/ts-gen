#!/usr/bin/env node
// Runs workerd's own Python Workers tests (upstream/, from workerd's
// src/pyodide/tests) against the WASI Python Worker:
//
//   node compat-tests/run.mjs [test-name...]
//
// Each test's Python files run unchanged. Its .wd-test config is translated:
// every Python worker's modules become the packaged Worker (entry.mjs, the
// runtime bundled by esbuild, app.wasm and bridge.wasm, built by ../build.sh with APP set
// to a copy of the test's directory and MAIN to its first Python module), and
// `%PYTHON_FEATURE_FLAGS` is dropped. The config is then run with
// `workerd test`, as Bazel's wd_test does, at the compatibility date the
// test's BUILD rule uses.
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const upstream = join(here, "upstream");
const work = join(here, "work");
const platform = { darwin: "darwin", linux: "linux" }[process.platform] + "-" + { arm64: "arm64", x64: "64" }[process.arch];
const workerd = process.env.WORKERD ?? join(root, `node_modules/@cloudflare/workerd-${platform}/bin/workerd`);
const esbuild = join(root, "node_modules/.bin/esbuild");
// A workerd checkout (github.com/cloudflare/workerd), for the few files
// tests embed from outside their own directory.
const WORKERD_SRC = process.env.WORKERD_SRC ?? join(process.env.HOME, "workerd");

// Every test target in upstream/BUILD.bazel, in order. `na` is a test that
// checks a Pyodide internal with no counterpart here, with the reason.
// `edits` are the smallest changes made to a test's own files, each with
// the reason. `packages` are packages/ recipes the build links in, as the
// test's vendored packages, and `env` sets other build.sh variables.
const TESTS = [
  { name: "hello" },
  { name: "top-level-tests", src: "top-level-tests/env.wd-test" },
  { name: "env-param", src: "env-param/env.wd-test" },
  { name: "asgi" },
  { name: "asgi-sse" },
  { name: "top-level-entropy" },
  { name: "top-level-entropy-baseline", dir: "top-level-entropy" },
  { name: "subdirectory" },
  { name: "subdirectory-keep-import-caches", src: "subdirectory/subdirectory-keep-import-caches.wd-test" },
  { name: "sdk", compatDate: "2026-01-01" },
  { name: "undefined-handler" },
  { name: "vendor_dir" },
  { name: "durable-object" },
  { name: "durable-object-websocket" },
  { name: "worker-entrypoint" },
  { name: "jspi" },
  { name: "python-rpc" },
  { name: "stack-switching-state" },
  { name: "stack-switching-gc" },
  { name: "workflow-entrypoint", src: "workflow-entrypoint/workflow-entrypoint.wd-test" },
  { name: "workflow-entrypoint-old", src: "workflow-entrypoint/workflow-entrypoint-old.wd-test" },
  { name: "vendor_dir_compat_flag" },
  { name: "default-class-with-legacy-global-handlers" },
  { name: "python-compat-flag" },
  { name: "nodejs-compat" },
  { name: "pth-file" },
  { name: "metadata-read-overflow" },
  { name: "stdlib-zip" },
  { name: "sockets", sidecar: socketServer },
  {
    name: "python-abort-isolate-on-fatal",
    // A shell test (Bazel's sh_test): it runs workerd itself, given the
    // binary, the config and Pyodide's bundle (unused here).
    sh: "python-abort-isolate-on-fatal/python-abort-isolate-on-fatal.sh",
  },
  // vendor_pkg_tests: vendored_py_wd_test()'s, for Python 3.14: each
  // template's %PYTHON_VENDORED_MODULES% becomes the files of the package's
  // vendored archive (as generate_modules.py makes it), under
  // python_modules/. The fastapi and scipy ones are for older Pythons, and
  // existing_dedicated_* restore Pyodide's own snapshots.
  vendored("beautifulsoup4", "beautifulsoup4", "5aa09c5f549443969dda260a70e58e3ac8537bd3d29155b307a3d98b36eb70fd"),
  vendored("python-workers-runtime-sdk", "python-workers-runtime-sdk", "fc4fb50f73973c257277155b3cb113aa2cf68e9da8ef424ecb049b41bc463183", {
    flags: ["enable_python_external_sdk"],
  }),
  vendored("python-workers-runtime-sdk-override", "python-workers-runtime-sdk", "fc4fb50f73973c257277155b3cb113aa2cf68e9da8ef424ecb049b41bc463183", {
    flags: ["disable_python_external_sdk"],
    template: "python-workers-runtime-sdk",
  }),
  // The rest vendor native packages: their archives hold Emscripten side
  // modules (.so), which nothing here loads, and native modules are linked
  // in from packages/ recipes instead. A recipe at the archive's version
  // runs the test with the archive's Python files.
  {
    ...vendored("numpy", "numpy-314", "28bea03aa0a18bbc1884ea4cebe8d93a9004455c497417e172c221f0a245b439", { packages: "numpy" }),
    na: "the archive is numpy 2.4.3 and packages/recipes/numpy.sh builds 2.5.5, whose native modules don't match the archive's Python files",
  },
  { name: "vendor_pkg_tests/shapely", na: "native (GEOS); no packages/ recipe" },
  { name: "vendor_pkg_tests/Pillow", na: "native; no packages/ recipe" },
  { name: "vendor_pkg_tests/pywavelets", na: "native; no packages/ recipe" },
  { name: "pytest-asyncio", dir: "pytest", src: "pytest/pytest.wd-test", packages: "pytest pytest-asyncio" },
];

// A vendor_pkg_tests test: `name`'s template and main module, with the
// vendored archive `archive` (its sha256 checked) and `flags` added to its
// feature flags.
function vendored(name, archive, sha256, { flags = [], template = name, packages } = {}) {
  return {
    name: `vendor_pkg_tests/${name}`,
    dir: "vendor_pkg_tests",
    src: `vendor_pkg_tests/${template}_vendor.wd-test`,
    vendor: { archive, sha256, flags },
    packages,
  };
}

// The vendored archive's files, extracted into `testDir`/vendored, as
// capnp module entries for %PYTHON_VENDORED_MODULES%.
function vendoredModules(testDir, { archive, sha256 }) {
  const cache = join(root, "deps", "vendor-tests");
  const zip = join(cache, `${archive}.zip`);
  if (!existsSync(zip)) {
    mkdirSync(cache, { recursive: true });
    execFileSync("curl", ["-sSfL", "-o", `${zip}.tmp`, `https://pub-25a5b2f2f1b84655b185a505c7a3ad23.r2.dev/${archive}-vendored-for-ew-testing.zip`]);
    execFileSync("mv", [`${zip}.tmp`, zip]);
  }
  const sum = execFileSync("shasum", ["-a", "256", zip], { encoding: "utf8" }).split(" ")[0];
  if (sum !== sha256) throw new Error(`${zip}: sha256 ${sum}, expected ${sha256}`);
  const out = join(testDir, "vendored");
  execFileSync("unzip", ["-q", "-o", zip, "-d", out]);
  const files = execFileSync("find", [".", "-type", "f"], { cwd: out, encoding: "utf8" }).split("\n").filter(Boolean).sort();
  return files
    .map((f) => {
      const rel = f.replace(/^\.\//, "");
      const kind = rel.endsWith(".py") ? "pythonModule" : "data";
      return `(name = "python_modules/${rel}", ${kind} = embed "vendored/${rel}"),`;
    })
    .join("\n");
}

// The sockets test's sidecar: socket-server.js prints NAME=port lines, which
// become the environment workerd reads the port bindings from (as Bazel's
// sidecar supervisor does).
async function socketServer(testDir) {
  const names = ["PYTHON_SOCKET_SERVER_PORT", "PYTHON_HOSTNAME_SOCKET_SERVER_PORT", "PYTHON_STARTTLS_SOCKET_SERVER_PORT", "PYTHON_TLS_SOCKET_SERVER_PORT"];
  const env = { SIDECAR_HOSTNAME: "127.0.0.1" };
  const child = spawn("node", [join(testDir, "socket-server.js")], { env: { ...process.env, ...env }, stdio: ["ignore", "pipe", "inherit"] });
  let buf = "";
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("socket server didn't start")), 10000);
    child.stdout.on("data", (d) => {
      buf += d;
      for (const m of buf.matchAll(/^(\w+)=(\d+)$/gm)) env[m[1]] = m[2];
      if (names.every((n) => env[n])) {
        clearTimeout(timer);
        resolve();
      }
    });
  });
  return { env, stop: () => child.kill() };
}

// ---- capnp text helpers ----

// The index just past the bracket matching the one at `open`.
function matchBracket(s, open) {
  const pairs = { "(": ")", "[": "]" };
  const stack = [];
  let inStr = false;
  for (let i = open; i < s.length; i++) {
    const c = s[i];
    if (inStr) {
      if (c === "\\") i++;
      else if (c === '"') inStr = false;
      continue;
    }
    if (c === '"') inStr = true;
    else if (c === "#") i = s.indexOf("\n", i);
    else if (pairs[c]) stack.push(pairs[c]);
    else if (c === ")" || c === "]") {
      if (stack.pop() !== c) throw new Error(`unbalanced ${c} at ${i}`);
      if (stack.length === 0) return i + 1;
    }
  }
  throw new Error("unbalanced brackets");
}

// The top-level entries of a capnp list "[ (...), (...) ]".
function listEntries(list) {
  const out = [];
  for (let i = 1; i < list.length - 1; i++) {
    if (list[i] === "#") i = list.indexOf("\n", i);
    else if (list[i] === "(") {
      const end = matchBracket(list, i);
      out.push(list.slice(i, end));
      i = end;
    }
  }
  return out;
}

// The start of the struct enclosing index `at` (its "(").
function enclosing(s, at) {
  let depth = 0;
  for (let i = at - 1; i >= 0; i--) {
    const c = s[i];
    if (c === ")" || c === "]") depth++;
    else if (c === "(" || c === "[") {
      if (depth === 0 && c === "(") return i;
      depth--;
    }
  }
  return 0;
}

// The strings of a capnp list "[ "a", "b" ]", without %PLACEHOLDERS.
const strings = (list) => [...list.matchAll(/"([^"]*)"/g)].map((m) => m[1]);

// A module entry's name, and its file contents as { embed } or { text }.
function moduleFile(entry) {
  const name = /name\s*=\s*"([^"]+)"/.exec(entry)[1];
  const m = /(pythonModule|data|text|json)\s*=\s*(embed\s+)?"((?:[^"\\]|\\.)*)"/.exec(entry);
  if (!m) return { name };
  return m[2] ? { name, embed: m[3] } : { name, text: JSON.parse(`"${m[3]}"`) };
}

// Translates one .wd-test. Returns { config, workers: [{ main, files, flags }] }.
function translate(text, testName) {
  const workers = [];
  let out = "";
  let i = 0;
  for (;;) {
    const m = /modules\s*=\s*\[/g;
    m.lastIndex = i;
    const hit = m.exec(text);
    if (!hit) break;
    const open = hit.index + hit[0].length - 1;
    const close = matchBracket(text, open);
    const list = text.slice(open, close);
    if (!list.includes("pythonModule")) {
      out += text.slice(i, close);
      i = close;
      continue;
    }
    const entries = listEntries(list);
    const py = entries.filter((e) => /pythonModule\s*=/.test(e));
    const rest = entries.filter((e) => !/python(Module|Requirement)\s*=/.test(e));
    const main = /name\s*=\s*"([^"]+)"/.exec(py[0])[1];
    const k = workers.length;
    // The worker's compatibilityFlags, which the build decides some things
    // by (as Pyodide's snapshot does).
    const start = enclosing(text, hit.index);
    const struct = text.slice(start, matchBracket(text, start));
    const fm = /compatibilityFlags\s*=\s*\[/.exec(struct);
    const flags = fm ? strings(struct.slice(fm.index + fm[0].length - 1, matchBracket(struct, fm.index + fm[0].length - 1))) : [];
    // Pyodide sees every module as a file under /session/metadata.
    workers.push({ main, files: entries.map(moduleFile).filter((f) => f.embed !== undefined || f.text !== undefined), flags });
    const mods = [
      `(name = "entry.mjs", esModule = embed "build-${k}/entry.mjs")`,
      `(name = "app.wasm", wasm = embed "build-${k}/app.wasm")`,
      `(name = "bridge.wasm", wasm = embed "build-${k}/bridge.wasm")`,
      ...rest,
    ];
    out += text.slice(i, open) + "[\n    " + mods.join(",\n    ") + "\n  ]";
    i = close;
  }
  out += text.slice(i);
  out = out.replace(/%PYTHON_FEATURE_FLAGS\s*,?\s*/g, "");
  return { config: out, workers };
}

// ---- running ----

function build(testDir, k, w, t) {
  const outDir = join(testDir, `build-${k}`);
  const pkgOut = join(testDir, `.pkg-${k}`);
  rmSync(outDir, { recursive: true, force: true });
  const log = join(testDir, `build-${k}.log`);
  const env = {
    APP: join(testDir, `app-${k}`),
    MAIN: w.main,
    OUTDIR: pkgOut,
    PACKAGES: t.packages ?? "",
    COMPAT_DATE: t.compatDate ?? "2000-01-01",
    COMPAT_FLAGS: w.flags.join(" "),
    ...t.env,
  };
  const r = spawnSync("./build.sh", [], {
    cwd: resolve(here, ".."),
    env: { ...process.env, ...env },
    encoding: "utf8",
    maxBuffer: 64 << 20,
  });
  writeFileSync(log, (r.stdout ?? "") + (r.stderr ?? ""));
  if (r.status !== 0) return { ok: false, why: `build failed (see ${log}): ${tail(r.stderr ?? "", 6)}` };
  mkdirSync(outDir, { recursive: true });
  cpSync(join(pkgOut, "app.wasm"), join(outDir, "app.wasm"));
  cpSync(join(pkgOut, "bridge.wasm"), join(outDir, "bridge.wasm"));
  execFileSync(esbuild, [
    join(pkgOut, "entry.js"),
    "--bundle",
    "--format=esm",
    "--external:cloudflare:*",
    "--external:node:*",
    "--external:./app.wasm",
    "--external:./bridge.wasm",
    `--outfile=${join(outDir, "entry.mjs")}`,
    "--log-level=error",
  ]);
  return { ok: true, log: r.stderr };
}

const tail = (s, n) => s.trim().split("\n").slice(-n).join(" | ");

// An embedded file's contents: relative to the config (`srcDir`), or to the
// tests' directory as Bazel's generated configs are, or else from workerd's
// tree.
function embedded(srcDir, dir, rel, testDir) {
  for (const base of [join(upstream, srcDir), upstream]) {
    const p = join(base, rel);
    if (p.startsWith(upstream + "/") && existsSync(p)) return readFileSync(p);
  }
  // Files the runner put next to the config (vendored archives).
  if (existsSync(join(testDir, rel))) return readFileSync(join(testDir, rel));
  const repoPath = join("src/pyodide/tests", dir, rel).replace(/\\/g, "/");
  return execFileSync("git", ["-C", WORKERD_SRC, "show", `origin/main:${repoPath}`]);
}

async function runTest(t) {
  if (t.na) return { status: "N/A", why: t.na };
  const dir = t.dir ?? (t.src ? dirname(t.src) : t.name);
  const src = t.src ?? `${dir}/${dir}.wd-test`;
  const testDir = join(work, t.name);
  rmSync(testDir, { recursive: true, force: true });
  mkdirSync(testDir, { recursive: true });
  let text = readFileSync(join(upstream, src), "utf8");
  if (t.vendor) {
    text = text.replace("%PYTHON_VENDORED_MODULES%", vendoredModules(testDir, t.vendor));
    text = text.replace("%PYTHON_FEATURE_FLAGS", ["%PYTHON_FEATURE_FLAGS", ...t.vendor.flags.map((f) => `"${f}"`)].join(", "));
  }
  const { config, workers } = translate(text, t.name);
  for (const [k, w] of workers.entries()) {
    // The app is the worker's modules, each at its name.
    const app = join(testDir, `app-${k}`);
    for (const f of w.files) {
      const out = join(app, f.name);
      mkdirSync(dirname(out), { recursive: true });
      writeFileSync(out, f.text ?? embedded(dirname(src), dir, f.embed, testDir));
    }
    for (const e of t.edits ?? []) {
      const f = join(app, e.file);
      const text = readFileSync(f, "utf8");
      if (!text.includes(e.from)) return { status: "FAIL", why: `edit no longer applies to ${e.file}` };
      writeFileSync(f, text.replace(e.from, e.to));
    }
    const b = build(testDir, k, w, t);
    if (!b.ok) return { status: "FAIL", why: b.why };
  }
  // Non-Python files the config embeds sit next to it.
  cpSync(join(upstream, dir), testDir, { recursive: true });
  // Files embedded from elsewhere in workerd's tree are fetched next to it.
  const fixed = config.replace(/embed "(\.\.\/[^"]+)"/g, (_, rel) => {
    const repoPath = join("src/pyodide/tests", dir, rel).replace(/\\/g, "/");
    const name = basename(rel);
    writeFileSync(join(testDir, name), execFileSync("git", ["-C", WORKERD_SRC, "show", `origin/main:${repoPath}`]));
    return `embed "${name}"`;
  });
  const cfg = join(testDir, basename(src));
  writeFileSync(cfg, fixed);
  mkdirSync(join(testDir, "tmp"), { recursive: true });
  const args = [
    "test",
    cfg,
    `--compat-date=${t.compatDate ?? "2000-01-01"}`,
    "--experimental",
    `--directory-path=TEST_TMPDIR=${join(testDir, "tmp")}`,
  ];
  if (t.sh) {
    const r = spawnSync("bash", [join(upstream, t.sh), workerd, cfg, join(testDir, "pyodide.capnp.bin")], {
      cwd: testDir,
      encoding: "utf8",
      timeout: 120000,
      env: { ...process.env, TEST_TMPDIR: join(testDir, "tmp") },
    });
    const output = (r.stdout ?? "") + (r.stderr ?? "");
    writeFileSync(join(testDir, "workerd.log"), output);
    if (r.status === 0) return { status: "PASS", output };
    return { status: "FAIL", why: output.split("\n").filter((l) => /FAIL|rror/.test(l)).slice(0, 4).join(" | ") || `exit ${r.status}`, output };
  }
  const sidecar = t.sidecar ? await t.sidecar(testDir) : undefined;
  try {
    const r = spawnSync(workerd, args, { cwd: testDir, encoding: "utf8", timeout: 120000, env: { ...process.env, ...sidecar?.env } });
    const output = (r.stdout ?? "") + (r.stderr ?? "");
    writeFileSync(join(testDir, "workerd.log"), output);
    if (r.status === 0) return { status: "PASS", why: t.edits?.map((e) => `edited ${e.file}: ${e.why}`).join("; "), output };
    const fail = output.split("\n").filter((l) => /error|Error|FAIL|assert/i.test(l)).slice(0, 4).join(" | ");
    return { status: "FAIL", why: fail || tail(output, 4) || `exit ${r.status}`, output };
  } finally {
    sidecar?.stop();
  }
}

const only = process.argv.slice(2);
mkdirSync(work, { recursive: true });
const results = [];
for (const t of TESTS) {
  if (only.length && !only.includes(t.name)) continue;
  process.stdout.write(`${t.name} ... `);
  let r;
  try {
    r = await runTest(t);
  } catch (e) {
    r = { status: "FAIL", why: String(e.stack ?? e).split("\n").slice(0, 3).join(" | ") };
  }
  console.log(r.status + (r.why ? `  ${r.why}` : ""));
  results.push({ name: t.name, ...r });
}
const count = (s) => results.filter((r) => r.status === s).length;
console.log(`\n${count("PASS")} passed, ${count("FAIL")} failed, ${count("N/A")} N/A of ${results.length}`);
writeFileSync(join(work, "results.json"), JSON.stringify(results.map(({ output, ...r }) => r), null, 2));
process.exit(count("FAIL") ? 1 : 0);
