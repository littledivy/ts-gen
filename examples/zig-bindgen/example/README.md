# Zig Worker

A tour of the Workers API from Zig: a Cloudflare Worker over
`tests/fixtures/workers-types.d.ts` and the JS standard library
(`std/std.ir`), bound through the IR under the profile
`all-linear, jspi = on`. Each route does one thing and replies in plain
text or JSON; `/` lists them.

```sh
./run.sh serve   # the tour: workerd on 127.0.0.1:8962 (or PORT), every route curled (WORKERD or PATH)
./run.sh node    # the routes node can serve
```

`tour.txt` is what `serve` prints, and `tour.node.txt` what `node` does.

## The tour

The app is `app.zig`.

| Route | From the platform | From the IR |
|---|---|---|
| `/` | the default export's `fetch` | an exported function (`@provides`) taking the request arena |
| `/echo` | `Request`, `Headers` | `str?` (`headers.get`); `future<str>` awaited in place |
| `/url` | `URL`, `URLSearchParams` | a `union` parameter (`str \| URL`); `arr<str>` as a slice |
| `/json` | `request.json()`, `Response.json` | an erased generic decoded as a Zig struct (`json(Order)`), a missing field as the member's TypeError; a struct encoded as `Any` |
| `/rewrite` | `HTMLRewriter` | a Zig function and its context as a callback in a dictionary |
| `/errors` | `atob`, `URL` | `@throws {DOMException}` and `err` as Zig errors, with their payloads |
| `/fetch` | a service binding | a payload enum (`RequestInfo`) |
| `/counter` | a Durable Object: storage `get`/`put`, SQL | an exported class with `init` and `deinit`; `get(u32)`; a variadic (`exec`); `one(struct { ... })` |

The declarations beside the app:

* `env.d.ts`: the bindings of `config.capnp` as `Env`, and HTMLRewriter's
  handlers as callback properties.
* `provides.d.ts`: the default export and the `Counter` class.
* `annotate.d.ts`: a `u16` status, and `atob`'s `@throws {DOMException}`.

`loader.js` runs the module: a pool of instances for the default export
(a request waiting on a future holds its instance's stack), and an
instance per Durable Object.
