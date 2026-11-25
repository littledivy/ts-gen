# go-bindgen

Go bindings from `ts-gen-abi lower`'s JSON, under the profile
`all-linear, jspi = on`, written in Go. A Go program built for wasip1 calls
JS through the bridge with ordinary blocking calls:

```go
func Fetch(req *w.Request, env w.Env, ctx *w.ExecutionContext) (*w.Response, error) {
	stmt, err := env.DB.Prepare("SELECT id, body FROM notes LIMIT 1")
	if err != nil {
		return nil, err
	}
	note, err := w.First[Note](stmt) // a future, awaited in place; the row decoded
	if err != nil {
		return nil, err
	}
	return w.ResponseJSON(note)
}
```

```sh
go build -o go-bindgen .
go-bindgen bindings worker.json --lib std.json --out workers --package workers \
  --main exports.go --import example/workers
GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -o go.wasm .
go-bindgen shim workers/manifest.json go.wasm -o shim.wat
wasm-tools parse shim.wat -o shim.wasm
wasm-merge go.wasm go shim.wasm shim -o worker.wasm --enable-reference-types --enable-exception-handling ...
ts-gen-bridge generate worker.ir worker.wasm --profile "all-linear, jspi = on" -o out
```

[example/run.sh](example/run.sh) does all of it for a Worker; the IR needs
`go-bindgen runtime-ir` appended. Callbacks need two builds:
`--no-callbacks` first, then `--callbacks-for` that build, since a callback's
trampoline is exported only for the imports the app uses.

## The mapping

| IR | Go |
|---|---|
| class, interface | `*T`, a struct embedding its parent; `x.AsParent()` |
| getter, setter, constructor, static | `x.Name()`, `x.SetName(v)`, `NewT`, `TName` |
| overloads | the fewest parameters get the name; the rest are named for what they add (`FirstWithColName`) |
| interface with `@js(object) new()` (a dictionary) | a plain struct, read whole; a zero field is unset |
| `T?` scalar or string | `*T`; in a dictionary, the zero value |
| index and carrier enums | a named integer, with constants |
| union (payload enum) | a sealed interface: `*Class`, `Str`, `Num`, `Bool`, a dictionary, or `<Union><Arm>{V}` |
| `fn(...)` | a Go func, held by JS until it drops it |
| `future<T>` | blocks the calling goroutine, other goroutines run meanwhile; the module suspends (JSPI) once all wait |
| `throws E`, `future<T, E>` | `(T, error)`, the error a `*E` with `Kind` and `Message` (`errors.As`); any other JS exception is an `*Exception` |
| `Any`, an erased `T` | `any` in (JSON, or boxed); `*Value` out, `Decode[T]`; a generic func per member (`First[T]`, `GetJSON[T]`, `One[T]`) |
| `u8[]`, `arr<T>`, tuples | `[]byte`, `[]T`, `TupleN` |
| exports | funcs in package main, a class's methods through its `NewT`; the generated glue passes them to `SetExports` |

JS objects live in the shim's `tw:table`. Go holds slot numbers, freed by
`Close` or, once the Go value is unreachable, a `runtime.AddCleanup`.
`Decode` and `any` parameters go through JSON (`runtime/json.go`, a small
codec over reflect with encoding/json's mapping, which the tests check
against encoding/json).

## The shim

Go can't name `externref` and returns one value, so `go-bindgen shim`
writes a module for exactly the imports and exports a build has, and
wasm-merge folds it in. It owns `tw:table`, keeps each JS value in a slot,
and calls each import for Go, leaving results in Go's return area and
returning a status: 0, 1 for the member's declared error, 2 for any other
JS exception, which it catches with `WebAssembly.JSTag`. The host passes
the tag as `("tsgen:js", "tag")`.

## Tests

```sh
just test-go   # snapshots, wasip1 vet, the JSON codec, and a probe through the bridge in node
```

`tests/go.rs` generates every fixture under `tests/lower` (and
`abi/tests/json/sample.ir`) against `tests/testdata/snapshots`, vets them, and
generates workers-types from a Worker's roots, snapshotting what it skips.
`tests/runtime` builds `probe.ir` through the whole pipeline and runs
`test.mjs` in node. Needs Go 1.24+, node, wasm-tools and wasm-merge.

## Gaps

- A dictionary field is set from its zero value, so a field can't be set
  to `0`, `""` or `false` explicitly.
- `bigint` arms, `arr` of unions and tuples of one are skipped, as is a
  callback returning a future; `skipped.txt` lists each skip.
- Snapshots repeat what a fixture reaches in std, since the bindings are
  one package.
