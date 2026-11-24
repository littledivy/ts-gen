// Calls the probe's Go exports through the bridge and checks each result:
// a declared error thrown each way, futures awaited on Go's side under JSPI
// (one at a time and from three goroutines at once), a Go func as a
// callback, a dictionary as a struct, an erased value decoded into a Go
// struct, an exported class, and JS objects released by Go's GC.
import { readFileSync } from 'node:fs';
import { WASI } from 'node:wasi';
import assert from 'node:assert/strict';

class Shelf {
  constructor(item) { this.item = item; }
  first() { return this.item; }
}
globalThis.Shelf = Shelf;
let table;
globalThis.ext = {
  shelf: () => new Shelf('word'),
  stock: async (item) => new Shelf(item),
  apply: (f, x) => f(x) + 1,
  delay: (ms, v) => new Promise((r) => setTimeout(() => r(v), ms)),
  fail: async (msg) => { throw new RangeError(msg); },
  boom: () => { throw new TypeError('kaboom'); },
  bytes: (v) => v.map((b) => b + 1),
  words: (xs) => xs.map((x) => x.toUpperCase()),
  join: (sep, ...parts) => parts.join(sep),
  norm: (p) => ({ x: p.x * 10, label: p.label + '!' }),
  row: async () => ({ id: 3, body: 'hi', extra: true }),
  live: () => {
    let n = 0;
    for (let i = 0; i < table.length; i++) if (table.get(i) instanceof Shelf) n++;
    return n;
  },
};

const { instantiate, probe, Counter } = await import('./bridge.js');
const load = (f) => new WebAssembly.Module(readFileSync(new URL(f, import.meta.url)));
const wasi = new WASI({ version: 'preview1' });
const module = load('./probe.wasm');
const imports = { wasi_snapshot_preview1: wasi.wasiImport };
if (WebAssembly.Module.imports(module).some((i) => i.module === 'tsgen:js')) {
  imports['tsgen:js'] = { tag: WebAssembly.JSTag };
}
const instance = instantiate(module, load('./bridge.wasm'), imports);
table = instance.exports['tw:table'];
wasi.initialize(instance);

const show = (e) => `${e.constructor.name}: ${e.message}`;
const lines = [];
const check = (label, got, want) => {
  lines.push(`${label} = ${got}`);
  assert.equal(got, want, label);
};

check('check(4)', probe.check(4), 8);
try {
  probe.check(0);
  assert.fail('check(0) returned');
} catch (e) {
  check('check(0)', show(e), 'RangeError: zero');
}
check(
  'run()',
  await probe.run(),
  'shelf=word stock=7 apply=16 delay=late fail=true:busy boom=TypeError:kaboom ' +
    'bytes=bcd words=A,B join=x-y-z norm=20:p! row=3:hi held=true',
);
check('parallel()', await probe.parallel(), '0,1,2 overlapped=true');
check('release() live', await probe.release(), 0);
const c = new Counter(5);
c.bump();
check('Counter', c.n, 6);
console.log(lines.join('\n'));
