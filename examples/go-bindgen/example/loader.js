// Instantiates the Go module through the bridge and publishes its
// exports: the default export and the Durable Object. The host gives the
// module WASI (wasi.js) and WebAssembly.JSTag, which its shim catches JS
// exceptions with; the bridge supplies every tw import.
//
// The module starts on the first request: Go's runtime seeds itself with
// random_get as it initializes, which workerd allows only in a handler.
import { instantiate, default as handler, Counter as GoCounter } from './bridge.js';
import { wasi } from './wasi.js';
import language from './worker.wasm';
import bridge from './bridge.wasm';

let started = false;
function start() {
  if (started) return;
  started = true;
  let memory;
  const instance = instantiate(language, bridge, {
    wasi_snapshot_preview1: wasi(() => memory),
    'tsgen:js': { tag: WebAssembly.JSTag },
  });
  memory = instance.exports.memory;
  instance.exports._initialize();
}

export default {
  fetch(request, env, ctx) {
    start();
    return handler.fetch(request, env, ctx);
  },
};

export class Counter extends GoCounter {
  constructor(state, env) {
    start();
    super(state, env);
  }
}
