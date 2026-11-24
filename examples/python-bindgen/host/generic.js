// The host side of generic.ir: generic access to any JS value, for guests
// that reach the Workers API without generated bindings, such as an
// interpreter's FFI, for a module bound through a ts-gen bridge.
// The bridge converts every argument and result (the IR's `Arg` and `Value`
// enums); this module only does the JS operations. Nothing here knows any
// binding or guest language.
//
// No function here throws: a JS exception comes back as a Thrown, which the
// guest reads, so an error never unwinds through the guest's own frames.
// Functions returning a Value with traits return the pair [value, traits].

/// A JS exception, caught. `value` is what was thrown.
export class Thrown {
  constructor(value) {
    this.value = value;
  }
  get message() {
    const v = this.value;
    if (typeof v === "string") return v;
    try {
      return String(v?.message ?? v);
    } catch {
      return "JS error";
    }
  }
}

const fn = (f) => typeof f === "function";
const isBuffer = (v) =>
  v instanceof ArrayBuffer || ArrayBuffer.isView(v) || (typeof SharedArrayBuffer === "function" && v instanceof SharedArrayBuffer);

/// What a value can do, as bits, as Pyodide's JsProxy type flags: 1
/// callable, 2 thenable, 4 array, 8 iterable, 16 async iterable, 32 buffer,
/// 64 get(), 128 a length or size, 256 typed array, 512 Error, 1024 an
/// iterator (next() and Symbol.iterator),
/// 2048 set(), 4096 has(), 8192 includes(), 16384 delete(), 32768 a
/// Promise (not merely a thenable, as an RPC stub is).
export function traits(v) {
  if (v === null || (typeof v !== "object" && typeof v !== "function")) return 0;
  // A PyProxy answers every property through the guest: don't ask it.
  if (states.has(v)) return typeof v === "function" ? 1 : 0;
  let t = typeof v === "function" ? 1 : 0;
  try {
    if (fn(v.then)) t |= 2;
    if (Array.isArray(v)) t |= 4;
    if (fn(v[Symbol.iterator])) t |= 8;
    if (fn(v[Symbol.asyncIterator])) t |= 16;
    if (isBuffer(v)) t |= 32;
    if (fn(v.get)) t |= 64;
    if (typeof v.size === "number" || (typeof v.length === "number" && typeof v !== "function")) t |= 128;
    if (ArrayBuffer.isView(v) && !(v instanceof DataView)) t |= 256;
    if (v instanceof Error) t |= 512;
    if (fn(v.next) && fn(v[Symbol.iterator])) t |= 1024;
    if (fn(v.set)) t |= 2048;
    if (fn(v.has)) t |= 4096;
    if (fn(v.includes)) t |= 8192;
    if (fn(v.delete)) t |= 16384;
    if (v instanceof Promise) t |= 32768;
  } catch {}
  return t;
}

const pair = (v) => [v, traits(v)];
function attempt(f) {
  try {
    return pair(f());
  } catch (e) {
    return [new Thrown(e), 0];
  }
}

export const get = (o, key) => attempt(() => o[key]);
export const getIndex = (o, i) => attempt(() => o[i]);
/// `key in o`.
export function has(o, key) {
  try {
    return Reflect.has(o, key);
  } catch {
    return false;
  }
}
export function set(o, key, v) {
  try {
    o[key] = v;
  } catch (e) {
    return new Thrown(e);
  }
}
/// The `length` property as a whole number, or 0.
export function length(o) {
  try {
    const n = o.length;
    return Number.isInteger(n) && n >= 0 ? Math.min(n, 0xffffffff) : 0;
  } catch {
    return 0;
  }
}
/// Own enumerable string keys.
export function keys(o) {
  try {
    return Object.keys(o);
  } catch {
    return [];
  }
}
/// Calls a method and returns its result as is: a promise stays a promise.
export function call(o, method, args) {
  return attempt(() => {
    const f = o[method];
    if (!fn(f)) throw new TypeError(`${method} is not a function`);
    return Reflect.apply(f, o, args);
  });
}
export const invoke = (f, args) => attempt(() => Reflect.apply(f, undefined, args));
export const construct = (f, args) => attempt(() => Reflect.construct(f, args));
export const same = (a, b) => Object.is(a, b);
/// `o[Symbol.iterator]()`, or `o[Symbol.asyncIterator]()`.
export function iterator(o, asynchronous) {
  return attempt(() => {
    const f = o?.[asynchronous ? Symbol.asyncIterator : Symbol.iterator];
    if (!fn(f)) throw new TypeError(`${typeof o} is not ${asynchronous ? "async " : ""}iterable`);
    return Reflect.apply(f, o, []);
  });
}
export const typeOf = (o) => typeof o;
/// `instanceof globalThis[name]`; false if there is no such global.
export function instanceOf(o, name) {
  try {
    const ctor = globalThis[name];
    return fn(ctor) && o instanceof ctor;
  } catch {
    return false;
  }
}
/// The bytes of an ArrayBuffer, or of what a typed array or DataView views.
export function toBytes(v) {
  try {
    if (ArrayBuffer.isView(v)) return new Uint8Array(v.buffer, v.byteOffset, v.byteLength).slice();
    if (isBuffer(v)) return new Uint8Array(v.slice(0));
    throw new TypeError(`a ${typeof v} is not an ArrayBuffer, typed array or DataView`);
  } catch (e) {
    return new Thrown(e);
  }
}
/// Copies data into an ArrayBuffer, typed array or DataView at a byte offset
/// into what it views.
export function writeBytes(v, offset, data) {
  try {
    let target;
    if (ArrayBuffer.isView(v)) target = new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
    else if (isBuffer(v)) target = new Uint8Array(v);
    else throw new TypeError(`a ${typeof v} is not an ArrayBuffer, typed array or DataView`);
    if (offset + data.length > target.length) throw new RangeError("writeBytes past the end of the buffer");
    target.set(data, offset);
  } catch (e) {
    return new Thrown(e);
  }
}
export const global = () => globalThis;
export const newArray = (items) => items;
export const newObject = () => ({});
/// A value the guest holds as an Arg, as a JS value: for results.
export const box = (v) => v;
/// A rejected promise, for an export to return as its failure.
export const failure = (message) => Promise.reject(new Error(message));

const caught = (e) => new Thrown(e);
/// Awaits a promise or thenable (or any value). A rejection settles it with
/// a Thrown.
export function settle(o) {
  try {
    return Promise.resolve(o).then(undefined, caught);
  } catch (e) {
    return Promise.resolve(new Thrown(e));
  }
}
/// `await import(specifier)`, or the namespace of a module the packager
/// bundled (cx.modules).
export function importModule(specifier, cx) {
  const modules = cx?.modules;
  if (modules && Object.hasOwn(modules, specifier)) return Promise.resolve(modules[specifier]);
  return settle(import(specifier));
}
/// Settles once the code running now has finished or suspended.
export const later = () => Promise.resolve();
// Tells the guest, through cx.release(id), that JS dropped a callback's
// function, where FinalizationRegistry exists (from compatibility date
// 2025-05-05). Cleanups run outside any request, and only once the guest's
// call has returned or suspended.
const registry = typeof FinalizationRegistry === "function" ? new FinalizationRegistry(({ id, release }) => release(id)) : undefined;

/// A JS function that calls the guest back: its dispatch export, as
/// dispatch("$callback", id, null, args, cx), with cx the context of the call
/// that made it (cx.dispatch, from tsgen.js). It returns a promise.
/// With cx.release, the guest hears when the function is collected.
export function callback(id, cx) {
  const method = String(id);
  const f = (...args) => cx.dispatch("$callback", method, null, args, cx);
  if (registry && cx?.release) registry.register(f, { id, release: cx.release });
  return f;
}

/// What the guest's synchronous export returns for an exception: the
/// caller throws `value`.
export const thrown = (v) => new Thrown(v);

// ---- PyProxy ----
//
// A guest object JS holds, as Pyodide's PyProxy: a Proxy whose every
// operation calls the guest synchronously, through its dispatchSync export
// (cx.sync), as dispatchSync("$py", op, null, [id, ...args], cx). The guest
// decides what the object can do (flags, below) and what each operation
// returns; this side only keeps the proxy's id and whether it has been
// destroyed.

const DEBUG_HINT = "\nFor more information about the cause of this error, use `pyodide.setDebug(true)`";
const ATTRS = Symbol("pyproxy.attrs");
const states = new WeakMap();

// Flag bits, as the guest computes them.
const CALLABLE = 1,
  AWAITABLE = 2,
  ITERABLE = 4,
  ITERATOR = 8,
  LENGTH = 16,
  GET = 32,
  SET = 64,
  HAS = 128,
  BUFFER = 256,
  DICT = 512,
  SEQUENCE = 1024,
  MUTABLE_SEQUENCE = 2048,
  GENERATOR = 4096,
  ASYNC_ITERABLE = 8192,
  ASYNC_ITERATOR = 16384;

function state(p) {
  const s = states.get(p);
  if (!s) throw new TypeError("Object is not a PyProxy");
  if (s.destroyed !== undefined) throw new Error(s.destroyed);
  return s;
}

// A call: the guest gets this, kwargs (an object, or undefined) and then
// the arguments themselves.
const callOp = (s, thisArg, args, kwargs) => op(s, "call", thisArg, kwargs, ...args);

function op(s, name, ...args) {
  const r = s.cx.sync("$py", name, null, [s.id, ...args], s.cx);
  if (r instanceof Thrown) throw r.value;
  return r;
}

/// Pyodide's PyProxy: `x instanceof PyProxy` for every proxy.
export class PyProxy {
  static [Symbol.hasInstance](v) {
    return states.has(v);
  }
  get [Symbol.toStringTag]() {
    return "PyProxy";
  }
  get type() {
    return op(state(this), "type");
  }
  toString() {
    return op(state(this), "str");
  }
  destroy(options) {
    const s = states.get(this);
    if (!s || s.destroyed !== undefined) return;
    s.destroyed = options?.message ?? "Object has already been destroyed" + DEBUG_HINT;
    if (!options?.$fromGuest) s.cx.sync("$py", "destroy", null, [s.id], s.cx);
  }
  copy() {
    return op(state(this), "copy");
  }
  toJs(options = {}) {
    const { depth = -1, create_proxies = true, dict_converter, default_converter } = options;
    return op(state(this), "tojs", depth, create_proxies, dict_converter, default_converter);
  }
}

const mixins = {
  [CALLABLE]: {
    apply(thisArg, args) {
      return callOp(state(this), thisArg, Array.from(args ?? []), undefined);
    },
    call(thisArg, ...args) {
      return callOp(state(this), thisArg, args, undefined);
    },
    callKwargs(...args) {
      const kwargs = args.pop();
      return callOp(state(this), undefined, args, kwargs);
    },
    callWithOptions(options, ...args) {
      return callOp(state(this), options?.self, args, options?.kwargs);
    },
    bind(thisArg, ...args) {
      const f = this;
      return function (...rest) {
        return callOp(state(f), thisArg, [...args, ...rest], undefined);
      };
    },
    callPromising(...args) {
      try {
        return Promise.resolve(callOp(state(this), undefined, args, undefined));
      } catch (e) {
        return Promise.reject(e);
      }
    },
  },
  [AWAITABLE]: {
    then(onFulfilled, onRejected) {
      return op(state(this), "promise").then(onFulfilled, onRejected);
    },
    catch(onRejected) {
      return op(state(this), "promise").catch(onRejected);
    },
    finally(onFinally) {
      return op(state(this), "promise").finally(onFinally);
    },
  },
  [ITERABLE]: {
    [Symbol.iterator]() {
      return op(state(this), "iter");
    },
  },
  [ITERATOR]: {
    next(arg) {
      return op(state(this), "next", arg);
    },
    [Symbol.iterator]() {
      return this;
    },
  },
  [LENGTH]: {
    get length() {
      return op(state(this), "len");
    },
  },
  [GET]: {
    get(key) {
      return op(state(this), "getitem", key);
    },
  },
  [SET]: {
    set(key, value) {
      return op(state(this), "setitem", key, value);
    },
    delete(key) {
      return op(state(this), "delitem", key);
    },
  },
  [HAS]: {
    has(key) {
      return op(state(this), "contains", key);
    },
  },
  [BUFFER]: {
    getBuffer(type) {
      return op(state(this), "buffer", type);
    },
  },
  [ASYNC_ITERABLE]: {
    [Symbol.asyncIterator]() {
      return op(state(this), "aiter");
    },
  },
  [ASYNC_ITERATOR]: {
    next(arg) {
      return op(state(this), "anext", arg);
    },
    [Symbol.asyncIterator]() {
      return this;
    },
  },
};

// A prototype per flag combination, as Pyodide's PyProxy subclasses.
const protos = new Map();
function protoFor(flags) {
  let p = protos.get(flags);
  if (p) return p;
  p = Object.create(PyProxy.prototype);
  for (const [bit, methods] of Object.entries(mixins)) {
    if (flags & Number(bit)) Object.defineProperties(p, Object.getOwnPropertyDescriptors(methods));
  }
  protos.set(flags, p);
  return p;
}

// A sequence's index properties are its items, as Pyodide's array-like
// PyProxy: so Array.from, Reflect.apply and friends read a list.
const isIndex = (s, key) => s.flags & SEQUENCE && /^(0|[1-9][0-9]*)$/.test(key);

const handler = {
  get(target, key, receiver) {
    if (key === "length" && Array.isArray(target)) return op(state(receiver), "len");
    if (typeof key === "symbol" || key in target) return Reflect.get(target, key, receiver);
    const s = state(receiver);
    return isIndex(s, key) ? op(s, "getitem", Number(key)) : op(s, "get", key);
  },
  set(target, key, value, receiver) {
    if (typeof key === "symbol") return Reflect.set(target, key, value, receiver);
    const s = state(receiver);
    if (isIndex(s, key) && s.flags & MUTABLE_SEQUENCE) op(s, "setitem", Number(key), value);
    else op(s, "set", key, value);
    return true;
  },
  has(target, key) {
    if (typeof key === "symbol" || key in target) return key in target;
    const s = state(proxyOf.get(target));
    if (isIndex(s, key)) return Number(key) < op(s, "len");
    return op(s, "has", key);
  },
  deleteProperty(target, key) {
    if (typeof key === "symbol") return Reflect.deleteProperty(target, key);
    op(state(proxyOf.get(target)), "del", key);
    return true;
  },
  ownKeys(target) {
    const keys = op(state(proxyOf.get(target)), "keys");
    for (const k of Reflect.ownKeys(target)) if (!keys.includes(k)) keys.push(k);
    return keys;
  },
  getOwnPropertyDescriptor(target, key) {
    if (typeof key === "symbol" || Object.hasOwn(target, key)) return Reflect.getOwnPropertyDescriptor(target, key);
    const p = proxyOf.get(target);
    if (!op(state(p), "has", key)) return undefined;
    return { value: op(state(p), "get", key), writable: true, enumerable: true, configurable: true };
  },
  apply(target, thisArg, args) {
    return callOp(state(proxyOf.get(target)), thisArg, args, undefined);
  },
};
const proxyOf = new WeakMap();

/// A PyProxy for the guest object `id`, which can do what `flags` say.
export function pyproxy(id, flags, cx) {
  // A callable's target is a function, so that the proxy is callable and
  // typeof says "function"; a sequence's an array, so that Array.isArray
  // and JSON.stringify take it for one.
  const target = flags & CALLABLE ? () => {} : flags & SEQUENCE ? [] : {};
  if (flags & CALLABLE) {
    for (const k of ["length", "name"]) delete target[k];
  }
  Object.setPrototypeOf(target, protoFor(flags));
  Object.defineProperty(target, ATTRS, { value: undefined });
  const p = new Proxy(target, handler);
  proxyOf.set(target, p);
  states.set(p, { id, cx, flags, destroyed: undefined });
  if (pyRegistry && cx?.release) pyRegistry.register(p, { id, release: cx.release }, p);
  return p;
}

// JS dropping a PyProxy tells the guest (cx.release), as Pyodide's
// finalizers do; destroying one unregisters it.
const pyRegistry = typeof FinalizationRegistry === "function" ? new FinalizationRegistry(({ id, release }) => release(id)) : undefined;

/// The guest object id of a PyProxy and, if it has been destroyed, the
/// message an operation on it throws.
export function pyInfo(p) {
  const s = states.get(p);
  return [s.id, s.destroyed ?? ""];
}

/// Destroys a PyProxy the guest is done with (a borrowed argument, after
/// the call), without calling the guest back. `message` is what an
/// operation on it throws.
export function pyDestroy(p, message) {
  const s = states.get(p);
  if (!s || s.destroyed !== undefined) return;
  s.destroyed = message;
  pyRegistry?.unregister(p);
}
