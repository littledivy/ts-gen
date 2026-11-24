#!/usr/bin/env node
// Soaks a built Python Worker under `wrangler dev` and samples the runtime's
// debug stats as it goes, to show whether anything grows with requests:
//
//   node soak/soak.mjs [--out out] [--config wrangler.toml] [--port 8990]
//        [--routes /,/kv,/do/a] [--total 100000] [--samples 20] [-c 16]
//        [--what gc] [--body '{...}'] [--json result.json]
//
// The build's app-tw.wasm is packaged again with --debug-stats into
// <out>-stats/, behind stats.js, which serves /__stats from
// __wasmWorkersStats(what) (host/tsgen.js) and hands every other request
// to the packaged Worker. `what` goes to each instance's dispatch("$stats"):
// "gc" collects first, "tracemalloc" starts tracing. Routes take turns,
// `total / samples` requests between two samples, with oha at -c. A route
// is "[METHOD ]path"; a method other than GET sends --body as JSON, and a
// path starting with "~" is a regex oha draws a random URL from for each
// request (e.g. "~/do/[a-z]{3}").
import { execFileSync, spawn } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const py = resolve(here, "..");
const argv = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : dflt;
};
const out = resolve(py, opt("--out", "out"));
const config = resolve(py, opt("--config", "wrangler.toml"));
const port = Number(opt("--port", "8990"));
const routes = opt("--routes", "/,/kv,/do/a").split(",");
const total = Number(opt("--total", "100000"));
const samples = Number(opt("--samples", "20"));
const conc = opt("-c", "16");
const what = opt("--what", "gc");
const body = opt("--body", undefined);
const jsonOut = opt("--json", undefined);

const statsDir = `${out}-stats`;
execFileSync(process.execPath, [join(py, "host/package.mjs"), join(out, "app-tw.wasm"), statsDir, "--bridge", join(out, "gen/bridge"), "--debug-stats"], {
  stdio: ["ignore", "ignore", "inherit"],
});
writeFileSync(
  join(statsDir, "stats.js"),
  `import Inner from "./entry.js";
import { WorkerEntrypoint } from "cloudflare:workers";
export * from "./entry.js";
export default class extends WorkerEntrypoint {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/__stats") return Response.json(await globalThis.__wasmWorkersStats(url.searchParams.get("what") ?? ""));
    return new Inner(this.ctx, this.env).fetch(request);
  }
}
`,
);
const toml = readFileSync(config, "utf8").replace(/^main = .*$/m, 'main = "stats.js"');
writeFileSync(join(statsDir, "wrangler.toml"), toml);

const base = `http://127.0.0.1:${port}`;
try {
  execFileSync("lsof", ["-nP", "-t", `-iTCP:${port}`, "-sTCP:LISTEN"]);
  throw new Error(`port ${port} is in use`);
} catch (e) {
  if (e.message.includes("in use")) throw e;
}
const wrangler = spawn("npx", ["wrangler", "dev", "-c", join(statsDir, "wrangler.toml"), "--port", String(port), "--ip", "127.0.0.1"], {
  cwd: statsDir,
  env: { ...process.env, WRANGLER_SEND_METRICS: "false" },
  stdio: ["ignore", "pipe", "pipe"],
  detached: true,
});
let log = "";
wrangler.stdout.on("data", (d) => (log += d));
wrangler.stderr.on("data", (d) => (log += d));
// workerd can outlive wrangler's process group, so whatever still listens
// on the port goes too.
const stop = () => {
  try {
    process.kill(-wrangler.pid, "SIGTERM");
  } catch {}
  try {
    for (const pid of execFileSync("lsof", ["-nP", "-t", `-iTCP:${port}`, "-sTCP:LISTEN"]).toString().split(/\s+/).filter(Boolean)) process.kill(Number(pid), "SIGTERM");
  } catch {}
};
process.on("exit", stop);
process.on("SIGINT", () => process.exit(130));

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function ready() {
  for (let i = 0; i < 120; i++) {
    try {
      const r = await fetch(`${base}/__stats`);
      if (r.ok) return;
    } catch {}
    await sleep(500);
  }
  console.error(log);
  throw new Error("wrangler dev didn't start");
}
const stats = async () => (await fetch(`${base}/__stats?what=${what}`)).json();

const parse = (route) => {
  const [m, p] = route.includes(" ") ? route.split(" ") : ["GET", route];
  return { method: m, path: p, init: m === "GET" ? { method: m } : { method: m, body, headers: { "content-type": "application/json" } } };
};

function oha(route, n) {
  const { method, path } = parse(route);
  const args = ["-n", String(n), "-c", conc, "--no-tui", "--output-format", "json", "-m", method];
  if (method !== "GET") args.push("-d", body ?? "", "-H", "content-type: application/json");
  if (path.startsWith("~")) args.push("--rand-regex-url", base + path.slice(1));
  else args.push(base + path);
  const r = JSON.parse(execFileSync("oha", args, { maxBuffer: 1 << 26 }).toString());
  return r.statusCodeDistribution ?? {};
}

const fmt = (b) => (b / 2 ** 20).toFixed(1);
const rows = [];
function row(done, s, codes) {
  const r = { requests: done, instances: s.instances, created: s.created, discarded: s.discarded, codes, per: s.list.map((e) => ({ owner: e.owner, ...e.guest, memoryBytes: e.memoryBytes })) };
  rows.push(r);
  const cells = r.per.map(
    (e) =>
      `${e.owner}: mem ${fmt(e.memoryBytes)} MiB, objs ${e.gc_objects}, slots ${e.slots_live}, cb ${e.callbacks}/${e.internal_callbacks}, py ${e.pyproxies}, tasks ${e.tasks}/${e.all_tasks}, idle ${e.idle}, wakers ${e.wakers}` +
      (e.traced_bytes !== undefined ? `, traced ${fmt(e.traced_bytes)} MiB` : ""),
  );
  console.log(`${String(done).padStart(7)} req | inst ${s.instances} (+${s.created} -${s.discarded}) | ${cells.join(" | ")} | ${JSON.stringify(codes)}`);
}

await ready();
// Warm every route before the first sample.
for (const r of routes) {
  const { path, init } = parse(r);
  if (!path.startsWith("~")) await (await fetch(base + path, init)).arrayBuffer();
}
row(0, await stats(), {});
const per = Math.max(1, Math.round(total / samples / routes.length));
let done = 0;
for (let i = 0; i < samples; i++) {
  const codes = {};
  for (const p of routes) {
    for (const [k, v] of Object.entries(oha(p, per))) codes[k] = (codes[k] ?? 0) + v;
    done += per;
  }
  row(done, await stats(), codes);
}
if (jsonOut) writeFileSync(jsonOut, JSON.stringify({ out, routes, conc, what, rows }, null, 1));
const errors = log.split("\n").filter((l) => /Error|Traceback|trap/i.test(l));
if (errors.length) console.log(`wrangler log: ${errors.length} error lines, first: ${errors.slice(0, 5).join("\n")}`);
stop();
process.exit(0);
