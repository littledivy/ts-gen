# swift-bindgen

An example language generator over the ts-gen IR, written in Swift. It
reads `ts-gen-abi lower`'s JSON under the profile `all-linear, jspi = on`
and writes Swift bindings for wasm32-unknown-wasip1, plus the Wasm shim
that adapts them to the `tw` ABI.

It is an example of a language project built on ts-gen, not a language
target of ts-gen: the lowered JSON is all it reads, and `ts-gen-bridge`
supplies the JS side of the module it binds.

```sh
swift build -c release   # Swift 6
swift-bindgen runtime-ir                     # declarations to append to the IR before lowering
swift-bindgen bindings <lowered.json> --out <dir> [--lib <lib.json>]... [--roots A,B,...]
              [--no-callbacks | --callbacks-for <module.wasm>] [--runtime] [--public] [--scaffold <App.swift>]
swift-bindgen shim <dir>/manifest.json <module.wasm> -o <shim.wat>
```

`bindings` writes `Bindings.swift`, the C header and module map its
imports are declared in (`include/`), and `manifest.json` (the imports and
exports, and the members skipped with why), plus `Runtime.swift` with
`--runtime`. The IR maps to Swift as:

| IR | Swift |
|---|---|
| class, interface | a class deriving from `JSObject`; getters and setters are properties, `new` an init |
| `@js(object) new()` | an init taking every settable property, all optional |
| enum | `enum: Int32`, an enum with associated values, or a `RawRepresentable` struct |
| `future<T, E>` | `async throws(E) -> T` |
| `throws E` | `throws(E)`, with `E` an `Error` enum |
| `fn(A) -> R` | a Swift closure, released when JS drops it |
| `T` (a type parameter) | `JSAny`, plus a generic overload that decodes a `Decodable` or encodes an `Encodable` |
| `export namespace` | a protocol of static funcs, which the app's `App` adopts |
| `export class C` | a protocol `CExport`, which the app's class `C` adopts |

Swift can't name `externref`, so every import goes through the shim:
JS values are slots of the module's `tw:table`, extra results go through a
return area, and the tags the bridge throws become a status. `shim`
generates it after the module is linked, for exactly the imports and
exports the module has, and binaryen's `wasm-merge` merges it in.

Swift's executor runs its tasks synchronously, so the bindings block on
futures: `TSGen.block` drains the executor, and when every task waits on
a JS promise, `("tw:future", "suspend_race")` suspends the module (JSPI)
until one of their futures settles. The shim's wrappers put Swift's stack
pointer back as a suspension resumes, since another call can run on that
stack while it's parked. The bridge calls the exports that return a future
through `WebAssembly.promising`.

`--roots` limits the bindings to those declarations and global members,
and everything their members reach. The bindings are internal, so
whole-module optimization drops the members the app doesn't use; the
callbacks' trampolines are exported only for the imports the first link
kept (`--no-callbacks`, then `--callbacks-for`). `--public` keeps every
member public instead, and `--scaffold` writes an app that adopts every
export protocol with stubs, so a module compiles without an app.

[example](example) is a Cloudflare Worker written in Swift over the
generator's output for workers-types. `swiftc-wasm.sh` is the `swiftc`
both use: it finds a Swift toolchain and its Swift SDK for WASI.

`just test-swift` runs the tests (`tests/swift.rs`): snapshots of every
fixture, wasm32-wasip1 compiles that check each merged module's imports
and exports against the lowered layouts, and the example under Node and
workerd.
