# Swift Worker

A tour of the Workers API from Swift: a Cloudflare Worker over
`tests/fixtures/workers-types.d.ts` and the JS standard library
(`std/std.ir`), bound through the IR under the profile
`all-linear, jspi = on`. Each route does one thing and replies in plain
text; `/` lists them.

```sh
./run.sh serve   # the tour: workerd on 127.0.0.1:8951 (or PORT), every route curled (WORKERD or PATH)
./run.sh node    # the routes node can serve
```

`tour.txt` is what `serve` prints, and `tour.node.txt` what `node` does.
It needs a Swift toolchain with its Swift SDK for WASI (see
`../swiftc-wasm.sh`) and binaryen's `wasm-merge`.

The app is `App.swift`. `loader.js` runs it: an instance blocked on a
future (JSPI) owns its stack until the future settles, so the default
export takes an instance from a small pool, and each Durable Object keeps
its own. The bridge is generated with `--factory`, so each instance has
its own. `wasi.js` is the little WASI the Swift runtime imports.

| Route | From the platform | From the IR |
|---|---|---|
| `/` | the default export's `fetch` | an exported function (`@provides`); a binding of `Env` |
| `/echo` | `Request`, `Headers` | `str?` as an optional; `future<str>` as an `async` call |
| `/url` | `URL`, `URLSearchParams` | getters; `arr<str>` as an array; a `union` parameter (`str \| URL`) |
| `/json` | `request.json()` | an erased generic (`json<T>`) decoded through `Codable` |
| `/crypto` | `crypto.randomUUID` | a global |
| `/timers` | `scheduler.wait` | `future<unit>`; tasks waiting at once, the module suspended until one settles |
| `/rewrite` | `HTMLRewriter` | a Swift closure in a dictionary, called once per match |
| `/errors` | `atob`, `URL` | `@throws {DOMException}` and `err` as typed throws |
| `/fetch` | a service binding | `Fetcher.fetch` |
| `/counter` | a Durable Object: an id from a name, `stub.fetch`, KV storage, SQL | an exported class, constructed by JS; a `Decodable` value from storage; a variadic (`sql.exec`) |
