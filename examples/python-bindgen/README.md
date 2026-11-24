# python-bindgen

Python Workers on ts-gen: CPython 3.14 for `wasm32-wasip1`, bound to JS
through a ts-gen bridge, running Python Workers' own `workers` SDK and
`asgi.py` on a Pyodide-compatible `js` FFI. workerd's Python Workers tests
and the SDK's own test suite pass against it.

```python
from workers import Response, WorkerEntrypoint


class Default(WorkerEntrypoint):
    async def fetch(self, request):
        n = int(await self.env.KV.get("n") or 0) + 1
        await self.env.KV.put("n", str(n))
        keys = (await self.env.KV.list()).keys
        return Response.json({"count": n, "keys": [k.name for k in keys]})
```

```sh
npm install                  # wrangler, its workerd, and esbuild
./build.sh                   # worker.py -> out/ (CPython and wasi-sdk build into deps/ the first time)
npx wrangler dev             # serves out/entry.js with wrangler.toml's local bindings
./e2e.sh 8787 Python         # the spec checks, 11 of them
```

The generator is [`bindgen.py`](bindgen.py), stdlib Python. It reads
`ts-gen-abi lower`'s JSON for [`generic.ir`](generic.ir) and writes the C
header the interpreter is built against, and the Wasm shim that owns the
externref table (C can't hold an externref):

```sh
ts-gen-abi lower generic.ir --profile "all-linear, jspi = on, box-none = unit" > generic.json
python3 bindgen.py header generic.json -o tsgen_imports.h
python3 bindgen.py shim generic.json core.wasm -o shim.wat --c-module python --defer "later()"
```

## Layout

| Path | What |
|---|---|
| `bindgen.py` | the generator: C header and shim from the lowered JSON |
| `generic.ir` | the generic JS interface the interpreter is bound through |
| `build.sh`, `env.sh` | builds a Worker: CPython, the C side, the snapshot, the shim and the bridge |
| `cfworkers.c`, `cfjs.c`, `vfs.c`, `entropy.c`, `snapshot-realloc.c`, `c/` | the C side: startup, the `js` FFI and dispatch, the filesystem, entropy, the externref slots |
| `runtime/`, `sdk/` | the Python side: the FFI surface, the event loop, dispatch; the `workers` SDK and `asgi.py` |
| `host/` | the JS side: `tsgen.js` (instances, Durable Objects, classes), `generic.js` (generic.ir's host), WASI, and `package.mjs`, which writes a Worker's `entry.js` |
| `packages/` | native and pure-Python package recipes, and `pyproject.toml` sync |
| `worker.py`, `wrangler.toml`, `e2e.sh` | the spec Worker and its checks |
| `compat-tests/`, `sdk-tests/`, `soak/` | workerd's Python Workers tests, the SDK's test suite, and soaks and load against Pyodide |
| `tests/python.rs` | `just test-python`: the generator's snapshots, then the spec Worker's build and checks |

## How it works

- **One module, snapshotted.** `build.sh` links a static libpython with the C side, then runs `wasmtime wizer`. That starts the interpreter, imports the runtime, the SDK and the app, and snapshots memory into the module. An instance starts with the app already imported.
- **Interfaces.** The module is bound through a ts-gen bridge over [`generic.ir`](generic.ir), a generic JS interface: get, set, call and construct on any value, futures and wait-any, and one `dispatch` export. Bindings, handlers, Durable Objects and RPC all go through it:
  - `cfworkers.c` starts the interpreter;
  - `cfjs.c` is the `js` FFI and the `dispatch` export, over the C header `bindgen.py` writes;
  - a JS value is a slot of the externref table, which the shim owns (`c/tsgen_rt.c` allocates the slots), so a `JsProxy` keeps its value alive for as long as Python holds it;
  - `build.sh` merges the shim in after the Wizer snapshot, since a table of JS values can't be snapshotted.
  - A typed IR for `JsProxy` wouldn't help: Python has no static types to bind it to, so every call would still go through erased values.
- **One instance, one event loop.** The module carries the `workers.reentrant` section, so all requests share one instance. A request arriving while another waits re-enters it.
  - `_cf_runtime` runs a WebLoop-style asyncio loop. Each task belongs to the request that started it, and each request's step runs only its own tasks.
  - `run_sync`/blocking calls suspend through JSPI.
  - `asyncio.Runner.close()` and `asyncio.run()` cancel only the current request's other tasks.
  - A trap in any call discards the instance: the next call gets a new one, and the calls still suspended in the old one fail.
- **Python ↔ JS.** `from js import ...`, `pyodide.ffi` and `import_from_javascript` behave as in Pyodide; `ffi-diff/run.sh` runs the same probe on both and diffs the output.
  - A Python value other than a number, string, bool or None reaches JS as a PyProxy (`host/generic.js`), whose operations call Python synchronously through the `dispatchSync` export. A JS call into a Python function returns its result inline.
  - A PyProxy made for a call's argument is borrowed and destroyed once the call returns, or once the promise it returned settles. One stored on a JS object, returned to JS, or made by `create_proxy` lives until `destroy()` or until JS drops it (FinalizationRegistry).
  - A blocking wait (`run_sync`) inside such a synchronous call raises Pyodide's "Cannot stack switch" error, and `can_run_sync()` is False there.
  - JS values get one JsProxy class per set of type flags (`isinstance` with `JsArray`, `JsMap`, `JsBuffer`... asks the flags). Errors are `JsException`, promises `PyodideFuture`, bigints `JsBigInt` and null `jsnull`. A PythonError coming back raises the original exception again.
  - `to_js(dict)` gives a plain object, and JS buffers keep their identity.
- **Sockets and TLS.** `socket`, `ssl` and asyncio streams run over `cloudflare:sockets` (`runtime/_cf_sockets.py`, `runtime/_cf_ssl.py`). `wrap_socket` upgrades with `startTls`.
- **Files.** `vfs.c` serves wasi-libc's filesystem calls from memory once the snapshot is taken:
  - the app's files, read-only, at `/app` and `/session/metadata`;
  - `/tmp`, writable, and `/dev/null`;
  - everything else is read-only (`EROFS`).
  - The app's files leave out hidden directories, `__pycache__`, `node_modules` and build output (`out`, `out-*`, `gen`, `OUTDIR`).

## Building

```sh
./build.sh                                   # worker.py -> out/
APP=dir MAIN=main.py OUTDIR=dir ./build.sh   # another app
PACKAGES="pydantic fastapi" APP=packages/demo-fastapi OUTDIR=out-fastapi ./build.sh
```

`PACKAGES` names recipes in `packages/recipes/`: native ones (numpy, pydantic-core, cryptography, aiohttp and 18 more) are compiled and linked in, pure ones are unpacked. Without `PACKAGES`, a `pyproject.toml` beside the app (or one level up) is installed as `pywrangler sync` would: pure wheels from PyPI and recipes for native distributions, with an error naming any native one that has no recipe. So a project needs only a `[build]` command in its `wrangler.toml`. See [packages/README.md](packages/README.md).

`RUNTIME_IMPORTS` picks which library files a request can import a module from, if the snapshot didn't already import it:

| Value | Files | Cost on the default Worker |
|---|---|---|
| `none` | none; a module first imported in a request fails | baseline |
| `site` (default) | the SDK's and the packages' modules | +6 KB brotli |
| `all` | those, plus the stdlib's sources | +1.27 MB brotli (+7.5 MB raw) |

- These files go through `shrink.py` first, which drops comments, docstrings and long package descriptions. Every line stays in place, so tracebacks still point at the right one.
- FastAPI needs `site`, because it imports a module when the app's lifespan starts.
- pytest needs `all`, because it imports unittest, doctest and pdb as it runs.

Docstrings are left out everywhere: C modules (`--without-doc-strings`), the stdlib's bytecode (`-OO`) and packages. Code objects keep line numbers but not column ranges (`-X no_debug_ranges`), so tracebacks have no `^^^` markers.

## Compatibility

`compat-tests/run.mjs` runs workerd's Python Workers tests (`compat-tests/upstream/`, from workerd's `src/workerd/server/tests/python`; `WORKERD_SRC` is a workerd checkout, for the few files they embed from outside) unchanged against this Worker: **24 pass, 0 fail, 8 N/A**.

- **N/A:** the 8 tests of Pyodide internals with no counterpart here:
  - the vendor directory loader (2);
  - JSPI stack-switching GC;
  - `.pth` processing;
  - the metadata filesystem;
  - the stdlib zip;
  - `on_fatal`;
  - the vendored-package template.
- **Edits:** three, each recorded with its reason in `run.mjs`.
  - Two `subdirectory` variants look for a stdlib zip on `sys.path`.
  - pytest's dynlib test expects wasi-libc's `dlopen not implemented`, since there is no dynamic loading.
- **pytest-asyncio** runs with the `pytest` and `pytest-asyncio` recipes and `RUNTIME_IMPORTS=all`.
  - WASI has no `dup()`, so `PYTEST_ADDOPTS` defaults to `--capture=sys -p no:faulthandler`.
  - `os.getuid` and friends return 0, as in Pyodide.

`e2e.sh` (the spec Worker: KV, R2, D1, a Durable Object with storage and an alarm, `fetch`, a service binding, Queues, logging and a 404) passes 11/11.

`sdk-tests/run.sh` runs the `workers` SDK's own test suite ([workers-py](https://github.com/cloudflare/workers-py)'s `packages/runtime-sdk/tests`, with its `src` as the SDK under test; `WORKERS_PY` is a checkout) against this Worker: **322 pass, 0 fail, 24 skipped**. Each project is built with `build.sh` and served with `wrangler dev`, or with `workerd test` for the `.wd-test` suites; `COMPAT_CONFIGS` is narrowed to its Python 3.14 entry. As `pywrangler` does, each project gets the SDK under test vendored into `python_modules`, which its JS modules import from.

| Suite | Pass | Fail | Skipped |
| --- | --- | --- | --- |
| bindings | 155 | 0 | 16 (Hyperdrive) |
| Django | 73 | 0 | 8 (Hyperdrive databases) |
| FastAPI | 78 | 0 | 0 |
| Flask | 4 | 0 | 0 |
| in workerd | 12 | 0 | 0 |

- **`entropy-patches`** imports every package the SDK patches (the Rust ones, numpy, pydantic, aiohttp, cryptography and more) while the snapshot is taken, with the SDK's patches counting each entropy call, and passes. With 64 MB of vendored packages besides, its snapshot starts at 147.5 MiB, so the adapter builds it with `MAX_MEMORY_MIB=160`; every native recipe together (`packages/demo-native`) fits the default 96 MiB.
- **Sync:** projects are synced with `packages/sync.py`, as `build.sh` does. The Hyperdrive tests' native drivers (asyncpg, psycopg-binary) have no recipe and are left out; those tests need local databases and are skipped.
- **Threads:** there are none, so `run_in_executor` runs its function inline, as in Pyodide's WebLoop. That covers asyncio's `to_thread` and asgiref's `sync_to_async`, which Django's async path depends on.
- **Workflows:** the SDK's own JS modules (`python_modules/workers/*.js`) are bundled for `doAnImport`. A Python exception reaching JS has the shape of Pyodide's `PythonError`.
- **The resolver** is Emscripten's, as in Pyodide: there is no DNS, so `gethostbyname` and `getaddrinfo` give a name a made-up address (`172.29.<n>.0` for the n-th name), which connecting maps back to the name. `gethostname()` is `emscripten`, and the `AF_*` and `SOCK_*` constants have Emscripten's values.

## Size and speed

2026-11-24, M-series Mac, `wrangler dev`, p50 over 3000 sequential requests (FastAPI's p50: 2026-11-23). Sizes are of `app.wasm`; the bridge adds 1 KB gzip of Wasm.

| Build | gzip -9 | brotli -q 11 | p50 |
|---|---|---|---|
| Default (`worker.py`) | 3.76 MB | 2.81 MB | `/` 0.79 ms, `/kv` 2.13 ms |
| FastAPI demo (pydantic, fastapi) | 8.70 MB | 6.01 MB | `/` 1.1 ms, path parameter 1.1 ms, validated POST 1.3 ms |

### Against Pyodide

`soak/compare.sh` runs both under `wrangler dev` 4.166 with fresh local state, on 2026-11-24, on a shared M-series Mac (load average 6 to 9 during the runs):
- **Pyodide default:** the same `worker.py`, Pyodide 314.0.6 with `python_workers` and the built-in SDK (`disable_python_external_sdk`; the external SDK turns its KV list into a dict).
- **Pyodide FastAPI:** the same `packages/demo-fastapi` app with the external SDK vendored. pydantic-core needs the external SDK's entropy patches. Pyodide's wheels are fastapi 0.136.1, pydantic 2.12.5 and pydantic-core 2.41.5; ours are fastapi 0.165 and pydantic 2.14.4.

Each route runs with `oha -z 10s` at each concurrency, after 2 s of warmup.

| Route | c | Ours rps | p50 / p99 ms | Pyodide rps | p50 / p99 ms |
|---|---|---|---|---|---|
| default `/` | 50 | 3043 | 14.6 / 48.0 | 2677 | 16.1 / 58.8 |
| default `/` | 200 | 3000 | 64.5 / 116 | 2793 | 68.6 / 132 |
| default `/kv` | 50 | 793 | 59.3 / 115 | 765 | 61.6 / 132 |
| default `/kv` | 200 | 853 | 232 / 366 | 803 | 236 / 637 |
| FastAPI `/` | 50 | 2087 | 22.2 / 46.5 | 1692 | 28.1 / 63.3 |
| FastAPI `/` | 200 | 2225 | 88.2 / 156 | 1684 | 118 / 197 |
| FastAPI `/items/42?q=x` | 50 | 1959 | 23.3 / 55.8 | 1541 | 30.3 / 71.1 |
| FastAPI `/items/42?q=x` | 200 | 2078 | 95.4 / 165 | 1580 | 130 / 203 |
| FastAPI `POST /items` | 50 | 1635 | 28.4 / 57.1 | 1371 | 33.6 / 74.6 |
| FastAPI `POST /items` | 200 | 1431 | 136 / 247 | 1460 | 139 / 204 |

- `/kv` is bound by the local KV simulator in both.
- `POST /items` at 200 is the one row where Pyodide is ahead: 2% on rps, and our p99 is higher.

Cold start, with CPU summed over wrangler's workerd processes (`ps`, 10 ms resolution):

| Worker | Ready | CPU to ready | First request | Its CPU |
|---|---|---|---|---|
| Ours, default | 1.55 s | 0.21 s | 21 ms | 40 ms |
| Pyodide, default | 6.09 s | 1.86 s | 12 ms | 10 ms |
| Ours, FastAPI | 1.67 s | 0.21 s | 59 ms | 210 ms |
| Pyodide, FastAPI | 6.74 s | 2.56 s | 16 ms | 20 ms |

- Pyodide restores its snapshot before it is ready. Ours instantiates on the first request, which pays for it.
- Total CPU to the first response: ours 0.25 s (default) and 0.42 s (FastAPI); Pyodide 1.87 s and 2.58 s.

### Memory

Linear memory, from the runtime's debug stats (`soak/soak.mjs`):
- **Default:** 12.1 MiB.
- **FastAPI:** 24.7 MiB idle, 25.3 MiB at its peak under `-c 200`.

There is one instance per Worker, whatever the load:
- The module is reentrant, so the runtime's instance pool (up to 4) isn't used: requests and Durable Objects share the one instance.
- Each Durable Object keeps its own Python object on it, so 40 objects take 12.1 MiB in all.

The build caps linear memory at 96 MiB (`MAX_MEMORY_MIB`), below the isolate's 128 MB limit:
- A request that allocates past the cap gets `MemoryError` and a 500, and the instance keeps serving (`/mem?n=200` in `soak/app`).
- Wasm memory doesn't shrink, so the instance stays at its high-water mark.
- Without a cap, memory would grow until the isolate is killed, taking every request on the shared instance with it.

### Soaks

`soak/soak.mjs` samples the instance count, linear memory, the GC's object count, externref slots, callbacks and asyncio tasks, timers and wakers. On 2026-11-24 they all level off:

| Run | Requests | Plateau |
|---|---|---|
| Default `/`, `/kv`, `/do/a`, `-c 16` | 100k | 12.1 MiB, slots 2 to 5, object count constant |
| FastAPI `/`, `/items/42?q=x`, `/nope`, `POST /items` | 100k | 24.7 MiB, 53042 objects |
| Default plus `~/do/[a-z]{2}` (676 objects), `-c 200` | 20k | 12.1 MiB; slots level off at about 1330 for the requests in flight |
| FastAPI, `-c 200` | 20k | 25.3 MiB, 53117 objects, 2 slots |
| `soak/ws.mjs`: 6000 hibernatable WebSockets × 20 messages, over 50 objects | 120k messages | 12.1 MiB, 153 slots, no failures |

With Pyodide's proxies, JS holds PyProxies the way Pyodide's does, and FinalizationRegistry frees them in batches as JS collects (`py` in the samples). 20k-request runs on 2026-11-24:
- **Default** `/`, `/kv`, `/do/a`: 13.6 MiB from 13k requests on, slots 5, the object count a sawtooth between about 23k and 46k.
- **FastAPI**: 30.6 MiB from 17k requests on. Each request leaves four PyProxies (the iterator and tuples `Object.fromEntries(headers)` reads from a list), up to about 23k between collections, and the high-water mark follows the largest batch.

Results for the `soak/app` routes, 6000 requests each:
- **Flat:** implicit proxies, `create_proxy` + `destroy()`, cycles through JS, `.then` chains and Durable Object state.
- **Bounded by the GC:** kept proxies, `gather`, `wait_until` and tasks orphaned at the end of a request.
  - A callback handed to JS lives until JS's FinalizationRegistry collects the function, or until its request ends.
  - A `create_proxy` lives until `destroy()`.
- **Traps:** a trap in one call (`/trap`, `/trap-later`) discards the instance.
  - Every call still in flight on it rejects with a 500, rather than waiting on a broken instance.
  - The next request gets a fresh instance.

## Limits

- **C++ exceptions need a rebuilt libc++.** wasi-sdk's libc++ is built without them; recipes that throw (numpy) set `CXX_EH=1` and link libc++ built with Wasm exceptions, and that Worker is linked by wasi-sdk 30's wasm-ld.
- **cffi can't call by address.** ABI-mode calls and callbacks raise `NotImplementedError`; compiled API-mode modules work.
- **No dynamic loading:** native modules are linked in at build time.
- **pytest-asyncio 1.1 is the newest that works.** From 1.2 on it calls `asyncio.Runner` in a way that waits on the task running pytest. workerd's Pyodide tests pin 1.1 for the same reason.
- **A `create_proxy` in a cycle through JS leaks until `destroy()`.** This is the same as in Pyodide: the proxy holds its function, and the JS side holds the proxy.
- **Without FinalizationRegistry (compatibility dates before 2025-05-05), an owned PyProxy JS drops is never freed,** as in Pyodide.
- **A Durable Object's Python object is dropped through FinalizationRegistry** once workerd drops the object. Without it, the object for an id is dropped when workerd makes a new one for the same id, so the state left over is bounded by the ids the isolate has seen.
- **MROs differ in one place:** a `JsException` is a Python exception holding its JsProxy, since a class can't extend both `Exception` and the C type JS values are; its MRO matches Pyodide's by name.
- **A trap discards the instance and fails every request in flight on it,** since they share it.
