// Runs the Zig module as a worker. A request that waits on a future
// suspends its instance's whole stack (JSPI), so an instance serves one
// request at a time: the default export takes one from a small pool, and
// each Durable Object keeps its own and queues its calls. bridge.js is
// generated with --factory, so every instance has its own bridge.
import { createBridge } from './bridge.js';
import language from './worker.wasm';
import bridgeModule from './bridge.wasm';

class Instance {
  constructor() {
    this.bridge = createBridge();
    this.bridge.instantiate(language, bridgeModule, {});
  }
}

const MAX_INSTANCES = 4;
const idle = [];
const waiting = [];
let size = 0;

// Runs fn(instance) on a pooled instance; a trap discards it.
async function pooled(fn) {
  let inst = idle.pop();
  if (!inst && size < MAX_INSTANCES) {
    size++;
    inst = new Instance();
  }
  if (!inst) inst = await new Promise((resolve) => waiting.push(resolve));
  let dead = false;
  try {
    return await fn(inst);
  } catch (e) {
    dead = e instanceof WebAssembly.RuntimeError;
    throw e;
  } finally {
    if (dead) {
      size--;
      inst = null;
    }
    const next = waiting.shift();
    if (next) next(inst ?? (size++, new Instance()));
    else if (inst) idle.push(inst);
  }
}

export default {
  fetch: (request, env, ctx) => pooled((i) => i.bridge.default.fetch(request, env, ctx)),
};

// The module's Counter, on an instance of the object's own.
export class Counter {
  #inst = new Instance();
  #counter;
  #queue = Promise.resolve();
  constructor(ctx, env) {
    this.#counter = new this.#inst.bridge.Counter(ctx, env);
  }
  fetch(request) {
    const call = this.#queue.then(() => this.#counter.fetch(request));
    this.#queue = call.catch(() => {});
    return call;
  }
}
