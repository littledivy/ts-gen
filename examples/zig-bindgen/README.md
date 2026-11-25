# zig-bindgen

An example language generator over the ts-gen IR, written in Zig. It reads
`ts-gen-abi lower`'s JSON under the profile `all-linear, jspi = on` and
writes Zig bindings, a `manifest.json` of their wire types, and the shim
that adapts the compiled module to the `tw` ABI.

It is an example of a language project built on ts-gen, not a language
target of ts-gen: the lowered JSON is all it reads, and `ts-gen-bridge`
supplies the JS side of the module it binds.

```sh
zig build   # Zig 0.17; zig-out/bin/zig-bindgen
zig-bindgen bindings <lowered.json> [--lib <lib.json>]... --out <dir> [--roots A,B,...] [--runtime]
zig-bindgen shim <manifest.json> <module.wasm> -o <shim.wat>
zig-bindgen strip <merged.wasm> -o <out.wasm>
zig-bindgen runtime-ir   # declarations the runtime needs, to append to the IR
```

## The bindings

`src/Gen.zig` maps the IR, and nothing else; `src/runtime/tsgen.zig`
(written with `--runtime`) is the fixed runtime they share.

| IR | Zig |
|---|---|
| class, interface | `struct { ref: rt.Ref }` with its members and its parents', `deinit`, `keep` and `as` |
| `@js(object) new()` | `init(.{ .field = v, ... })` over the settable properties |
| `get p` / `set p` | `p()` / `setP(v)` |
| overloads | one function per variant (`put`, `putWithOptions`) |
| enum | `enum(i32)` (index), non-exhaustive `enum(T)` (carrier), `union(enum(i32))` (payload) |
| `T?` | `?T` |
| `future<T, E>` | a call that blocks (JSPI) and returns `E.Error!T` |
| `throws E` | `E.Error!T`; the payload is `E.last()` |
| `fn(A) -> R` | a `Callback`: `.init(&ctx, f)` or `.fromFn(f)` |
| an erased `T` result | a `comptime T: type` parameter, decoded into T |
| `Any`, an erased `T` parameter | `anytype`, encoded from any Zig value |
| `arr<T>`, `T[]`, tuples | slices or tuples |
| an exported namespace or class | `pub fn`s and `pub const C = struct {...}` of the app's root file |

Values cross through codecs: comptime types that know a value's wire words
and Zig type (`rt.Str`, `rt.Host(Request)`, `rt.Future(...)`). Each binding
names its codecs and calls `rt.call`, so no conversion code is generated
per member. Decoding into a Zig type (`json(Order)`, `get(u32)`) walks the
type at comptime: a struct reads an object's properties by field name, a
missing one takes the field's default, and one that doesn't decode is the
member's TypeError.

Memory is per request: what the bindings return lives in a request arena,
and JS values in table slots the request owns; both go when the outermost
export returns, unless kept with `keep()`. A handler may take that arena as
a leading `std.mem.Allocator`.

Zig can't name `externref`, so the module holds slots in the `tw` table and
the shim, a few lines of WAT merged in with `wasm-merge`, moves values
between the table and the wire, catches thrown tags as a status, and
returns multiple results through a return area.

[example](example) is a Cloudflare Worker written in Zig over the
generator's output for workers-types.

`just test-zig` runs the tests (`tests/zig.rs`): snapshots of every
fixture, wasm32 compiles that check each module's imports, its manifest and
its shim against the lowered layouts, and the example under Node and
workerd.
