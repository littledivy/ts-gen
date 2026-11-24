# Go Worker

A Worker in Go over `tests/fixtures/workers-types.d.ts` and the JS standard
library (`std/std.ir`), bound through go-bindgen under
`all-linear, jspi = on`. Each route shows one part of the binding.

```sh
./run.sh serve   # workerd on 127.0.0.1:8977, every route requested (WORKERD or PATH)
./run.sh node    # the routes node can serve
```

`tour.txt` is what `serve` prints, and `tour.node.txt` what `node` does.

| Route | From the platform | From the binding |
|---|---|---|
| `/` | the default export's `fetch`, a text binding | an exported func in package main; `Env` as a struct |
| `/echo` | `Request`, `Headers` | `str?` as `*string`; `future<str>` awaited in place |
| `/json` | `request.json()` | an erased result decoded into a Go struct (`JSON[Order]`); a rejected future as an error |
| `/rewrite` | `HTMLRewriter` | a Go func as a callback in a dictionary |
| `/errors` | `atob`, `new URL` | `@throws {DOMException}` and a `TypeError`, caught with `errors.As` |
| `/parallel` | a service binding's `fetch` | three goroutines awaiting at once |
| `/counter/*` | a Durable Object: storage, SQL | an exported class; `DurableObjectStorageGet[int]`, `One[T]` |

`app.go` is the Worker. `loader.js` instantiates the module on the first
request (Go's runtime seeds itself with `random_get`, which workerd allows
only in a handler) and gives it `wasi.js`, the WASI preview1 calls Go makes,
with `poll_oneoff` suspending under JSPI.
