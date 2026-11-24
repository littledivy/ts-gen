// Runs the routes node can serve. The wasm modules load as
// WebAssembly.Module, as workerd's do.
import { registerHooks } from 'node:module';

registerHooks({
  load(url, context, next) {
    if (url.endsWith('.wasm')) {
      return { format: 'module', shortCircuit: true, source:
        `export default new WebAssembly.Module((await import("node:fs")).readFileSync(new URL(${JSON.stringify(url)})));` };
    }
    return next(url, context);
  },
});

const { default: worker } = await import(new URL('./loader.js', import.meta.url));
const ctx = { waitUntil() {}, passThroughOnException() {} };
const env = { GREETING: 'Hello from Zig on node' };
const tour = [
  ['GET /', '/'],
  ['POST /echo', '/echo', { method: 'POST', headers: { 'x-zig': 'hi' }, body: 'Hello!' }],
  ['GET /url?tag=a&tag=b&q=zig', '/url?tag=a&tag=b&q=zig'],
  ['POST /json', '/json', { method: 'POST', body: '{"item":"tea","quantity":2,"tags":["hot","green"]}' }],
  ['POST /json (not an order)', '/json', { method: 'POST', body: '{"item":"tea"}' }],
  ['GET /errors', '/errors'],
];
for (const [label, path, init] of tour) {
  let reply;
  try {
    const res = await worker.fetch(new Request(`http://127.0.0.1${path}`, init), env, ctx);
    reply = await res.text();
  } catch (e) {
    reply = `rejected: ${e.name}: ${e.message}\n`;
  }
  process.stdout.write(`\n== ${label}\n${reply}${reply.endsWith('\n') ? '' : '\n'}`);
}
