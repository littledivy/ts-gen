import { assert } from "./harness.mjs";

class Api {
  constructor() {
    this.resolvers = [];
  }
  later() {
    return new Promise((r) => this.resolvers.push(r));
  }
}
globalThis.Api = Api;

const { instantiate, app } = await import("./bridge.js");
const fs = await import("node:fs");
const compile = (f) => new WebAssembly.Module(fs.readFileSync(f));
const instance = instantiate(compile("lang.wasm"), compile("bridge.wasm"));
const wakes = instance.exports["test:wakes"];
const tick = () => new Promise((r) => setTimeout(r, 0));

// The export runs up to its first wait, then returns a promise.
const api = new Api();
const p = app.run(api);
assert.ok(p instanceof Promise);
assert.equal(api.resolvers.length, 2);

// `b` settles first: no wait holds waker 9, so it's a plain wake.
api.resolvers[1](5);
await tick();
assert.equal(wakes(), 1);

// `a` settling resumes the suspended export.
api.resolvers[0](3);
assert.equal(await p, 8);
assert.equal(wakes(), 1);

// Two suspended calls can't wait on one waker.
const api2 = new Api();
const first = app.run(api2);
const second = app.run(new Api());
await assert.rejects(second, (e) => e instanceof TypeError && /already waited on/.test(e.message));
api2.resolvers[0](1);
api2.resolvers[1](2);
assert.equal(await first, 3);

console.log("ok");
