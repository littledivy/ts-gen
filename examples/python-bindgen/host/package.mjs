#!/usr/bin/env node
// Packages a module bound through a ts-gen bridge as a Worker:
//
//   node host/package.mjs <app.wasm> <out-dir> --bridge <dir> [--max-instances N] [--debug-stats]
//
// <dir> holds the bridge ts-gen-bridge generated with --factory (bridge.js
// and bridge.wasm). The module, the bridge and the host runtime (tsgen.js,
// wasi-p1.js and the modules bridge.js imports) are copied into <out-dir>,
// with an entry.js exporting the classes the module's `workers.classes`
// sections declare (see tsgenClass in tsgen.js).
//
// The module's custom sections shape the Worker:
// - `workers.js-modules` lists the JS modules the module imports, one JSON
//   object per line: { name, source? }. A module with a source is written
//   next to entry.js; one without is a specifier the platform provides,
//   such as "cloudflare:sockets". entry.js imports each statically.
// - `workers.reentrant`: one instance serves every call at once.
// - `workers.init`: the first instance is created, and its "$init" run, in
//   the global scope.
// --max-instances caps the instance pool, and --debug-stats installs
// globalThis.__wasmWorkersStats (see tsgen.js).

import { copyFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { jsonFragments, mergeClasses } from "./classes.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const [moduleArg, outArg] = args;
const opt = (name) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined);
const bridgeDir = opt("--bridge");
const maxArg = opt("--max-instances");
const maxInstances = maxArg === undefined ? undefined : Number(maxArg);
const debugStats = args.includes("--debug-stats");
if (!moduleArg || !outArg || !bridgeDir) {
  console.error("usage: package.mjs <app.wasm> <out-dir> --bridge <dir> [--max-instances N] [--debug-stats]");
  process.exit(2);
}
if (maxInstances !== undefined && !(Number.isInteger(maxInstances) && maxInstances >= 1)) {
  console.error("--max-instances takes a whole number of at least 1");
  process.exit(2);
}
const modulePath = resolve(moduleArg);
const outDir = resolve(outArg);

// Fails early, with the module's own error, on anything V8 can't compile.
const module = new WebAssembly.Module(readFileSync(modulePath));
const sections = (name) => WebAssembly.Module.customSections(module, name);

const src = readFileSync(join(bridgeDir, "bridge.js"), "utf8");
if (!src.includes("export function createBridge()")) throw new Error("bridge.js: generate it with ts-gen-bridge --factory");
mkdirSync(outDir, { recursive: true });
writeFileSync(join(outDir, "app.wasm"), readFileSync(modulePath));
copyFileSync(join(bridgeDir, "bridge.wasm"), join(outDir, "bridge.wasm"));
writeFileSync(join(outDir, "bridge.js"), src);
const runtimeDir = join(outDir, "runtime");
rmSync(runtimeDir, { recursive: true, force: true });
mkdirSync(runtimeDir);
const fromBridge = [...src.matchAll(/from "\.\/runtime\/([\w.-]+\.js)"/g)].map((m) => m[1]);
for (const f of new Set(["tsgen.js", "wasi-p1.js", ...fromBridge])) copyFileSync(join(here, f), join(runtimeDir, f));
// tsgen.js only calls wasiP1 for a module that imports WASI.
if (!WebAssembly.Module.imports(module).some((i) => i.module === "wasi_snapshot_preview1")) {
  writeFileSync(join(runtimeDir, "wasi-p1.js"), `export function wasiP1() {\n  throw new Error("this module doesn't import WASI");\n}\n`);
}

const classSections = sections("workers.classes");
if (!classSections.length) throw new Error(`${modulePath} has no workers.classes section`);
const classes = mergeClasses(classSections.map((b) => new TextDecoder().decode(b)));
const moduleImports = jsModuleImports();
const init = sections("workers.init").length > 0;
const cfgFields = [
  "module",
  "bridge",
  "createBridge",
  ...(maxInstances === undefined ? [] : [`maxInstances: ${maxInstances}`]),
  ...(debugStats ? ["debugStats: true"] : []),
  'bases: { entrypoint: WorkerEntrypoint, "durable-object": DurableObject, workflow: WorkflowEntrypoint }',
  ...(sections("workers.reentrant").length ? ["reentrant: true"] : []),
  ...(init ? ["init: true", "env"] : []),
  ...(moduleImports.length ? [`modules: { ${moduleImports.map((m) => `${JSON.stringify(m.name)}: ${m.ident}`).join(", ")} }`] : []),
];
const ident = /^[A-Za-z_$][A-Za-z0-9_$]*$/;
const imports = [
  `import { DurableObject, WorkerEntrypoint, WorkflowEntrypoint${init ? ", env" : ""} } from "cloudflare:workers";`,
  `import { tsgenClass${init ? ", tsgenPrewarm" : ""} } from "./runtime/tsgen.js";`,
  ...moduleImports.map((m) => m.line),
];
const lines = [
  ...(init ? ["await tsgenPrewarm(cfg);"] : []),
  ...(!("default" in classes) ? ["export default {};"] : []),
  ...Object.entries(classes).map(([name, info]) => {
    if (name !== "default" && !ident.test(name)) throw new Error(`workers.classes: ${name} is not a JS identifier`);
    const cls = `tsgenClass(cfg, ${JSON.stringify(name)}, ${JSON.stringify(info)})`;
    return name === "default" ? `export default ${cls};` : `export const ${name} = ${cls};`;
  }),
];
writeFileSync(
  join(outDir, "entry.js"),
  `// Generated by host/package.mjs. Do not edit.
${imports.join("\n")}
import { createBridge } from "./bridge.js";
import module from "./app.wasm";
import bridge from "./bridge.wasm";

const cfg = { ${cfgFields.join(", ")} };
${lines.join("\n")}
`,
);
const summary = `classes: ${Object.keys(classes).join(", ")}${moduleImports.length ? `; JS modules: ${moduleImports.length}` : ""}${init ? ", init at startup" : ""}`;
console.log(`packaged ${modulePath} -> ${join(outDir, "entry.js")} (${summary})`);

// The modules the module's `workers.js-modules` sections list, written next
// to entry.js (those with a source) and imported by it.
function jsModuleImports() {
  const jsModules = {};
  for (const bytes of sections("workers.js-modules")) {
    for (const m of jsonFragments(new TextDecoder().decode(bytes))) {
      if (typeof m?.name !== "string") throw new Error(`workers.js-modules: entry without a name: ${JSON.stringify(m)}`);
      if (Object.hasOwn(jsModules, m.name) && jsModules[m.name].source !== m.source) {
        throw new Error(`workers.js-modules: ${m.name} is listed twice with different sources`);
      }
      jsModules[m.name] = m;
    }
  }
  rmSync(join(outDir, "js-modules"), { recursive: true, force: true });
  return Object.values(jsModules).map((m, i) => {
    let from = m.name;
    if (m.source !== undefined) {
      const file = `js-modules/${createHash("sha256").update(m.name).digest("hex").slice(0, 16)}.js`;
      mkdirSync(join(outDir, "js-modules"), { recursive: true });
      writeFileSync(join(outDir, file), m.source);
      from = "./" + file;
    }
    return { ident: `jsModule${i}`, name: m.name, line: `import * as jsModule${i} from ${JSON.stringify(from)};` };
  });
}
