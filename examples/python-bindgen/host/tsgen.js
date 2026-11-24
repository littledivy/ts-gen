// Runs a module whose imports and exports follow the ts-gen `tw` ABI as a
// Worker. The bridge ts-gen generated for it (bridge.js, generated with
// --factory, and bridge.wasm) does all the value conversion, and under the
// profile's `jspi = on` runs the exports that return a future on their own
// stack and lets the module wait on its futures. This adds what the bridge
// leaves to the host:
//
// - a pool of instances, each with its own bridge, serving one request at a
//   time, since a request suspended in I/O owns the instance's stack and
//   heap;
// - WASI preview1 (wasi-p1.js) for modules that import it;
// - WebAssembly.JSTag, as ("tsgen:js", "tag"), for modules that catch JS
//   exceptions with it but can't name it themselves;
// - Durable Object classes, each object constructing the module's exported
//   class on the instance that serves it.
//
//   export default tsgenWorker(cfg);
//   export const Counter = tsgenDurableObject(cfg, "Counter", ["fetch"], DurableObject);
//
// cfg is { module, bridge: bridge.wasm's module, createBridge, maxInstances }.
//
// A module that receives every call through one export,
// `dispatch(cls, method, this, args, cx)` (generic.ir), declares its
// classes in a `workers.classes` custom section instead (see classes.mjs),
// and gets one JS class for each:
//
//   export default tsgenClass(cfg, "default", { kind: "entrypoint", methods: ["fetch"] });
//
// cx is { env, ctx, modules, dispatch, memory }: the call's env and ctx, the modules
// the packager bundled (cfg.modules), the instance's dispatch, for
// calling it back, and its memory. These cfg fields apply:
//
// - bases: { entrypoint, "durable-object", workflow }, the classes from
//   cloudflare:workers each kind extends;
// - reentrant (a `workers.reentrant` section): one instance serves every
//   call at once, so calls nest on it (the module orders them). cx.release(id)
//   then hands the ids of callbacks whose functions JS collected
//   (generic.js) back as dispatch("$release", "id,id,...");
// - init (a `workers.init` section) and env: each new instance gets
//   dispatch("$init", "", null, [], cx) first, with cx.env = cfg.env; tsgenPrewarm creates the
//   first one in the global scope.
// - debugStats (package.mjs --debug-stats): globalThis.__wasmWorkersStats(what)
//   reports every live instance (see installStats).

import { wasiP1 } from "./wasi-p1.js";

const DEFAULT_MAX_INSTANCES = 4;

// With cfg.debugStats, every instance, for __wasmWorkersStats. Weak, so that
// counting them doesn't keep a Durable Object's instance alive.
const live = new Set();
const counts = { created: 0, discarded: 0 };
function installStats() {
  globalThis.__wasmWorkersStats ??= async (what = "") => {
    const out = { ...counts, instances: 0, memoryBytes: 0, list: [] };
    for (const ref of live) {
      const inst = ref.deref();
      if (!inst || inst.dead) {
        live.delete(ref);
        continue;
      }
      out.instances++;
      out.memoryBytes += inst.memory.buffer.byteLength;
      const entry = { owner: inst.owner, memoryBytes: inst.memory.buffer.byteLength };
      // A module that answers dispatch("$stats", what) adds its own counts
      // (JSON); others reject it.
      if (inst.dispatch) {
        try {
          const r = await inst.dispatch("$stats", what, null, [], { dispatch: inst.dispatch });
          if (typeof r === "string") entry.guest = JSON.parse(r);
        } catch {}
      }
      out.list.push(entry);
    }
    return out;
  };
}

// For a reentrant instance: collects the ids a burst of
// FinalizationRegistry cleanups delivers and hands them over in one
// dispatch(cls, "id,id,..."). A reentrant module takes a call at any time,
// even while others are suspended in it.
function releaser(inst, cls) {
  let ids = [];
  return (id) => {
    if (inst.dead) return;
    if (ids.push(id) > 1) return;
    queueMicrotask(() => {
      const batch = ids.join(",");
      ids = [];
      if (inst.dead) return;
      const { dispatch } = inst;
      dispatch(cls, batch, null, [], { dispatch, release: inst.release }).catch(() => {});
    });
  };
}

// Marks a reentrant instance dead after a trap, and fails the calls still
// in it (see Shared).
function discard(inst, cause) {
  if (inst.dead) return;
  inst.dead = true;
  counts.discarded++;
  for (const call of inst.calls) call.abort(new Error("this call's Wasm instance trapped in another call and was discarded", { cause }));
  inst.calls.clear();
}

// cx.dispatch for a reentrant instance, which JS calls back through: it
// refuses calls into a dead instance, and a trap in one discards it as a
// trap in a handler does.
function guarded(inst) {
  const { dispatch } = inst.bridge;
  return (...a) => {
    if (inst.dead) return Promise.reject(new Error("this callback's Wasm instance trapped and was discarded"));
    return dispatch(...a).catch((e) => {
      if (e instanceof WebAssembly.RuntimeError) inst.onTrap?.(e);
      throw e;
    });
  };
}

class Instance {
  constructor(cfg) {
    let memory;
    const modules = new Set(WebAssembly.Module.imports(cfg.module).map((i) => i.module));
    const usesWasi = modules.has("wasi_snapshot_preview1");
    const imports = {};
    if (modules.has("tsgen:js")) imports["tsgen:js"] = { tag: WebAssembly.JSTag };
    if (usesWasi) {
      this.wasi = wasiP1(() => memory, { log: console, suspend: true });
      imports.wasi_snapshot_preview1 = this.wasi.wasi_snapshot_preview1;
    }
    this.bridge = cfg.createBridge();
    const instance = this.bridge.instantiate(cfg.module, cfg.bridge, imports);
    memory = instance.exports.memory;
    instance.exports._initialize?.();
    this.objects = new WeakMap();
    this.memory = memory;
    if (cfg.debugStats) {
      installStats();
      counts.created++;
      live.add(new WeakRef(this));
    }
  }
}

// A new instance, after the module's "$init" if it has one.
function create(cfg, owner = "default") {
  const inst = new Instance(cfg);
  inst.owner = owner;
  inst.dispatch = inst.bridge.dispatch;
  if (cfg.reentrant) {
    inst.release = releaser(inst, "$release");
    inst.dropObject = releaser(inst, "$drop-objects");
    inst.calls = new Set();
    inst.dispatch = guarded(inst);
  }
  if (!cfg.init) return inst;
  const cx = { env: cfg.env, ctx: undefined, modules: cfg.modules, dispatch: inst.dispatch, release: inst.release, memory: inst.memory };
  return Promise.resolve(inst.dispatch("$init", "", null, [], cx)).then(() => inst);
}

class Pool {
  #cfg;
  #max;
  #idle = [];
  #size = 0;
  #busy = 0;
  #waiting = [];
  constructor(cfg, max) {
    this.#cfg = cfg;
    this.#max = max;
  }
  async #acquire() {
    const inst = this.#idle.pop();
    if (inst) return inst;
    if (this.#size < this.#max) {
      this.#size++;
      try {
        return await create(this.#cfg);
      } catch (e) {
        this.#size--;
        throw e;
      }
    }
    return new Promise((resolve) => this.#waiting.push(resolve));
  }
  #release(inst) {
    if (inst.dead) {
      counts.discarded++;
      this.#size--;
      const next = this.#waiting.shift();
      if (next) Promise.resolve().then(() => next(this.#acquire()));
      return;
    }
    const next = this.#waiting.shift();
    if (next) return next(inst);
    this.#idle.push(inst);
    if (this.#busy === 0) {
      while (this.#idle.length > 1) (this.#idle.shift().dead = true), this.#size--;
    }
  }
  // Runs fn(instance); a trap in the module discards the instance.
  async run(fn) {
    const inst = await this.#acquire();
    this.#busy++;
    try {
      return await fn(inst);
    } catch (e) {
      if (e instanceof WebAssembly.RuntimeError) inst.dead = true;
      throw e;
    } finally {
      this.#busy--;
      inst.wasi?.flush();
      this.#release(inst);
    }
  }
}

/// The Worker's default export: the module's `default` namespace (its
/// handlers), each call on a pooled instance.
export function tsgenWorker(cfg) {
  const pool = new Pool(cfg, cfg.maxInstances ?? DEFAULT_MAX_INSTANCES);
  const probe = new Set(WebAssembly.Module.exports(cfg.module).map((e) => e.name));
  const worker = {};
  for (const k of probe) {
    const m = /^default\.([A-Za-z_$][\w$]*)\(/.exec(k);
    if (m && !worker[m[1]]) worker[m[1]] = (...args) => pool.run((inst) => inst.bridge.default[m[1]](...args));
  }
  return worker;
}

/// A Durable Object class over the module's exported class `name`: every
/// object has its own instance (a pool of one), on which it constructs
/// `name` with (ctx, env) before its first call.
export function tsgenDurableObject(cfg, name, methods, Base) {
  const cls = class extends Base {
    #pool = new Pool(cfg, cfg.durableObjectMaxInstances ?? 1);
    $call(method, args) {
      return this.#pool.run((inst) => {
        let obj = inst.objects.get(this);
        if (!obj) inst.objects.set(this, (obj = new inst.bridge[name](this.ctx, this.env)));
        return obj[method](...args);
      });
    }
  };
  for (const m of methods) {
    cls.prototype[m] = function (...args) {
      return this.$call(m, args);
    };
  }
  Object.defineProperty(cls, "name", { value: name });
  return cls;
}

// The one instance of a `workers.reentrant` module, serving every call at
// once. A trap in any call into it (a handler, or JS calling one of its
// callbacks) discards it: the next call gets a new instance, and the calls
// still suspended in the old one fail now. They couldn't finish: the trap
// left the module's own state (its shadow stack, the interpreter) in the
// middle of a call, and a call below the one that trapped resumes only once
// that one has returned, which it never will.
class Shared {
  #cfg;
  #ready;
  #owner;
  // The instance, once created, for calls that can't wait for one.
  current;
  constructor(cfg, owner) {
    this.#cfg = cfg;
    this.#owner = owner;
  }
  instance() {
    if (!this.#ready) {
      const ready = (this.#ready = Promise.resolve()
        .then(() => create(this.#cfg, this.#owner))
        .then((inst) => {
          inst.onTrap = (e) => {
            if (this.#ready === ready) this.#ready = undefined;
            if (this.current === inst) this.current = undefined;
            discard(inst, e);
          };
          return (this.current = inst);
        }));
      ready.catch(() => {
        if (this.#ready === ready) this.#ready = undefined;
      });
    }
    return this.#ready;
  }
  async run(fn) {
    const inst = await this.instance();
    const call = {};
    const aborted = new Promise((_, reject) => (call.abort = reject));
    inst.calls.add(call);
    try {
      return await Promise.race([fn(inst), aborted]);
    } catch (e) {
      if (e instanceof WebAssembly.RuntimeError) inst.onTrap(e);
      throw e;
    } finally {
      inst.calls.delete(call);
      inst.wasi?.flush();
    }
  }
}

const pools = new WeakMap();
const poolOf = (cfg, max, owner) => (cfg.reentrant ? new Shared(cfg, owner) : new Pool(cfg, max));
// Entry points share one pool, so they see the same instances.
function entryPool(cfg) {
  let pool = pools.get(cfg);
  if (!pool) pools.set(cfg, (pool = poolOf(cfg, cfg.maxInstances ?? DEFAULT_MAX_INSTANCES)));
  return pool;
}

/// Creates the entry points' first instance now, running its "$init".
export async function tsgenPrewarm(cfg) {
  const pool = entryPool(cfg);
  if (pool instanceof Shared) await pool.instance();
  else await pool.run(() => {});
}

// Names that are the instance's own state, never the module's methods.
const PASS_THROUGH = new Set(["constructor", "env", "ctx", "then", "toJSON"]);

// Durable Objects on a reentrant module's one instance: each gets a key,
// `$cfObject` ("Class#n"), that the module keeps its state for the object
// under, and once JS collects the object the module hears
// dispatch("$drop-objects", "key,key,...") (with FinalizationRegistry).
let nextObject = 0;
const objects = typeof FinalizationRegistry === "function" ? new FinalizationRegistry(({ key, pool }) => pool.current?.dropObject(key)) : undefined;

/// A class for `name` from the module's `workers.classes` section: every
/// method, handler or RPC call on an instance becomes the module's
/// dispatch(name, method, this, args, cx). A reentrant module serves every
/// class, Durable Objects included, from its one instance, as Python Workers
/// share one interpreter; otherwise each Durable Object has its own pool.
export function tsgenClass(cfg, name, info) {
  if (cfg.debugStats) installStats();
  const Base = cfg.bases[info.kind];
  if (!Base) throw new TypeError(`workers.classes: ${name} has unknown kind ${info.kind}`);
  const isObject = info.kind === "durable-object";
  const shared = isObject && !cfg.reentrant ? undefined : entryPool(cfg);
  const Wrapper = class extends Base {
    constructor(ctx, env) {
      super(ctx, env);
      const pool = shared ?? poolOf(cfg, cfg.durableObjectMaxInstances ?? 1, name);
      const target = this;
      if (isObject && shared) {
        const key = `${name}#${++nextObject}`;
        Object.defineProperty(this, "$cfObject", { value: key });
        objects?.register(this, { key, pool });
      }
      return new Proxy(this, {
        get(obj, prop, receiver) {
          if (typeof prop !== "string" || PASS_THROUGH.has(prop) || Object.hasOwn(obj, prop)) {
            return Reflect.get(obj, prop, receiver);
          }
          return (...args) =>
            pool.run((inst) => {
              const { dispatch } = inst;
              return dispatch(name, prop, target, args, { env, ctx, modules: cfg.modules, dispatch, release: inst.release, memory: inst.memory });
            });
        },
      });
    }
  };
  Object.defineProperty(Wrapper, "name", { value: name === "default" ? "Default" : name });
  // workerd finds handlers (fetch, scheduled, queue, ...) on the prototype;
  // the Proxy answers the calls.
  for (const m of info.methods ?? []) Wrapper.prototype[m] = function () {};
  return Wrapper;
}
