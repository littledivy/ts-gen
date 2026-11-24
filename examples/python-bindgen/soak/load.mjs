#!/usr/bin/env node
// Load test: oha for each route at each concurrency against a running Worker,
// one after another, and one line per run with rps, p50 and p99.
//
//   node soak/load.mjs <base-url> [--c 50,200] [--z 15s] [--label name]
//        [--routes "/,/kv,POST /items"] [--body '{...}'] [--json out.json]
//
// A route is "[METHOD ]path"; a method other than GET sends --body as JSON.
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";

const argv = process.argv.slice(2);
const base = argv[0];
const opt = (name, dflt) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : dflt;
};
const concs = opt("--c", "50,200").split(",");
const z = opt("--z", "15s");
const label = opt("--label", base);
const routes = opt("--routes", "/,/kv").split(",");
const body = opt("--body", undefined);
const jsonOut = opt("--json", undefined);

const results = [];
for (const route of routes) {
  const [method, path] = route.includes(" ") ? route.split(" ") : ["GET", route];
  for (const c of concs) {
    const args = ["-z", z, "-c", c, "--no-tui", "--output-format", "json", "-m", method];
    if (method !== "GET") args.push("-d", body ?? "", "-H", "content-type: application/json");
    const r = JSON.parse(execFileSync("oha", [...args, base + path], { maxBuffer: 1 << 28 }).toString());
    const ms = (s) => (s * 1000).toFixed(2);
    const codes = r.statusCodeDistribution ?? {};
    const res = {
      label,
      route,
      c: Number(c),
      rps: Math.round(r.summary.requestsPerSec),
      p50: ms(r.latencyPercentiles.p50),
      p99: ms(r.latencyPercentiles.p99),
      codes,
      errors: r.errorDistribution ?? {},
    };
    results.push(res);
    console.log(`${label.padEnd(14)} ${route.padEnd(18)} c=${String(c).padEnd(4)} ${String(res.rps).padStart(6)} rps  p50 ${res.p50.padStart(7)} ms  p99 ${res.p99.padStart(7)} ms  ${JSON.stringify(codes)}${Object.keys(res.errors).length ? " errors " + JSON.stringify(res.errors) : ""}`);
  }
}
if (jsonOut) writeFileSync(jsonOut, JSON.stringify(results, null, 1));
