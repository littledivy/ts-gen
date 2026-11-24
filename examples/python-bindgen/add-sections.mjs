#!/usr/bin/env node
// Appends the custom sections the runtime layer reads to a core module:
//   node add-sections.mjs <core.wasm> <meta-dir>
// <meta-dir>/classes.json becomes `workers.classes`, and <meta-dir>/init, if
// present, `workers.init` (see host/tsgen.js). `workers.reentrant` is always
// added, since all requests share one interpreter and event loop, as in
// Pyodide.
//   node add-sections.mjs <core.wasm> <meta-dir> <app-dir>
// The .js and .mjs files under <app-dir>/python_modules/workers/ (the SDK's
// own JS helpers, such as workflows.js) become `workers.js-modules` entries
// named by their path in the app, as wrangler registers them as ES modules
// for Pyodide's doAnImport.
import { appendFileSync, existsSync, readdirSync, readFileSync } from "node:fs";
import { join, relative, sep } from "node:path";

const [wasm, meta, app] = process.argv.slice(2);
const leb = (n) => {
  const out = [];
  do {
    let b = n & 0x7f;
    n >>>= 7;
    if (n) b |= 0x80;
    out.push(b);
  } while (n);
  return out;
};
function section(name, payload) {
  const nm = Buffer.from(name);
  const body = Buffer.concat([Buffer.from(leb(nm.length)), nm, payload]);
  return Buffer.concat([Buffer.from([0]), Buffer.from(leb(body.length)), body]);
}
const classes = join(meta, "classes.json");
if (!existsSync(classes)) {
  console.error(`${classes} is missing: pre-initialization didn't record the app's classes`);
  process.exit(1);
}
appendFileSync(wasm, section("workers.classes", readFileSync(classes)));
appendFileSync(wasm, section("workers.reentrant", Buffer.from([1])));
const sdkJs = app ? join(app, "python_modules", "workers") : null;
if (sdkJs && existsSync(sdkJs)) {
  const entries = readdirSync(sdkJs, { recursive: true, withFileTypes: true })
    .filter((e) => e.isFile() && /\.m?js$/.test(e.name))
    .map((e) => join(e.parentPath, e.name))
    .sort()
    .map((f) => JSON.stringify({ name: relative(app, f).split(sep).join("/"), source: readFileSync(f, "utf8") }));
  if (entries.length) appendFileSync(wasm, section("workers.js-modules", Buffer.from(entries.join("\n") + "\n")));
}
if (existsSync(join(meta, "init"))) appendFileSync(wasm, section("workers.init", Buffer.from([1])));
console.log(`classes: ${readFileSync(classes, "utf8")}${existsSync(join(meta, "init")) ? " (imported at startup)" : ""}`);
