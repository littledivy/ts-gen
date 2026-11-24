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

/// What a value can do, as bits: 1 callable, 2 thenable, 4 array,
/// 8 iterable, 16 async iterable, 32 buffer.
export function traits(v) {
  if (v === null || (typeof v !== "object" && typeof v !== "function")) return 0;
  let t = typeof v === "function" ? 1 : 0;
  try {
    if (fn(v.then)) t |= 2;
    if (Array.isArray(v)) t |= 4;
    if (fn(v[Symbol.iterator])) t |= 8;
    if (fn(v[Symbol.asyncIterator])) t |= 16;
    if (isBuffer(v)) t |= 32;
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
