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
  {
    name: "subdirectory",
    edits: [
      {
        file: "a.py",
        why: "there is no stdlib zip on sys.path (the stdlib is snapshotted); the zip checks only run after a dedicated snapshot, which doesn't apply",
        from: 'next(p for p in sys.path if p.endswith(".zip"))',
        to: 'next((p for p in sys.path if p.endswith(".zip")), None)',
      },
    ],
  },
  {
    name: "subdirectory-keep-import-caches",
    src: "subdirectory/subdirectory-keep-import-caches.wd-test",
    edits: [
      {
        file: "a.py",
        why: "there is no stdlib zip on sys.path (the stdlib is snapshotted); the zip checks only run after a dedicated snapshot, which doesn't apply",
        from: 'next(p for p in sys.path if p.endswith(".zip"))',
        to: 'next((p for p in sys.path if p.endswith(".zip")), None)',
      },
    ],
  },
  { name: "sdk", compatDate: "2026-01-01" },
  { name: "undefined-handler" },
  {
    name: "vendor_dir",
    na: "checks the vendor/ directory layout of Pyodide's package loader; vendored files are ordinary app modules here",
  },
  { name: "durable-object" },
  { name: "durable-object-websocket" },
  { name: "worker-entrypoint" },
  { name: "jspi" },
  { name: "python-rpc" },
  { name: "stack-switching-state" },
  {
    name: "stack-switching-gc",
    na: "tests Pyodide's JSPI stack-switching save/restore patch (pyodide_js._module); no Emscripten stack here",
  },
  { name: "workflow-entrypoint", src: "workflow-entrypoint/workflow-entrypoint.wd-test" },
  { name: "workflow-entrypoint-old", src: "workflow-entrypoint/workflow-entrypoint-old.wd-test" },
  {
    name: "vendor_dir_compat_flag",
    na: "checks the python_vendor_dir compat flag of Pyodide's package loader; vendored files are ordinary app modules here",
  },
  { name: "default-class-with-legacy-global-handlers" },
  { name: "python-compat-flag" },
  { name: "nodejs-compat" },
  { name: "pth-file", na: "tests .pth processing in Pyodide's site-packages setup; there is no site-packages import step here" },
  {
    name: "metadata-read-overflow",
    na: "reads Pyodide's metadata filesystem through pyodide_js._module; the app's files are in memory here",
  },
  { name: "stdlib-zip", na: "checks Pyodide's stdlib zip mount; the stdlib here is snapshotted, not mounted" },
  { name: "sockets", sidecar: socketServer },
  {
    name: "python-abort-isolate-on-fatal",
    na: "triggers Pyodide's on_fatal handler (_pyodide_core); a trap here discards the instance instead (fixtures /trap)",
  },
  {
    name: "vendor_pkg_tests",
    na: "a template for vendored-package tests generated per package; native packages here are built in (packages/)",
  },
  {
    name: "pytest-asyncio",
    dir: "pytest",
    src: "pytest/pytest.wd-test",
    packages: "pytest pytest-asyncio",
    // pytest imports stdlib modules (unittest, doctest, pdb...) as it runs.
    env: { RUNTIME_IMPORTS: "all" },
    edits: [
      {
        file: "tests/test_dynlib_loading.py",
        why: "there is no dynamic loading at all (native modules are linked in at build time, packages/), so importing a .so fails with wasi-libc's dlopen error instead of Pyodide's",
        from: 'match="Can only load shared libraries from read only file systems"',
        to: 'match="dlopen not implemented"',
      },
    ],
  },
];

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
    if (list[i] === "(") {
      const end = matchBracket(list, i);
      out.push(list.slice(i, end));
      i = end;
    }
  }
  return out;
}

// Translates one .wd-test. Returns { config, workers: [{ main, files }] }.
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
    workers.push({ main, modules: py.map((e) => /name\s*=\s*"([^"]+)"/.exec(e)[1]) });
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

function build(testDir, k, main, packages, extra) {
  const outDir = join(testDir, `build-${k}`);
  const pkgOut = join(testDir, `.pkg-${k}`);
  rmSync(outDir, { recursive: true, force: true });
  const log = join(testDir, `build-${k}.log`);
  const r = spawnSync("./build.sh", [], {
    cwd: resolve(here, ".."),
    env: { ...process.env, APP: join(testDir, "app"), MAIN: main, OUTDIR: pkgOut, PACKAGES: packages ?? "", ...extra },
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

async function runTest(t) {
  if (t.na) return { status: "N/A", why: t.na };
  const dir = t.dir ?? (t.src ? dirname(t.src) : t.name);
  const src = t.src ?? `${dir}/${dir}.wd-test`;
  const testDir = join(work, t.name);
  rmSync(testDir, { recursive: true, force: true });
  mkdirSync(testDir, { recursive: true });
  cpSync(join(upstream, dir), join(testDir, "app"), { recursive: true });
  for (const e of t.edits ?? []) {
    const f = join(testDir, "app", e.file);
    const text = readFileSync(f, "utf8");
    if (!text.includes(e.from)) return { status: "FAIL", why: `edit no longer applies to ${e.file}` };
    writeFileSync(f, text.replace(e.from, e.to));
  }
  const { config, workers } = translate(readFileSync(join(upstream, src), "utf8"), t.name);
  for (const [k, w] of workers.entries()) {
    const b = build(testDir, k, w.main, t.packages, t.env);
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
