# Packages for the WASI Python Worker

The Worker is a single statically linked Wasm module with no dynamic loading. So a package's native extension modules are compiled to static libraries, linked into the module and registered as built-in modules. Its Python files go on `sys.path` at `/site` at build time, and `wasmtime wizer` snapshots whatever the app imports.

```sh
PACKAGES="pydantic fastapi" APP=packages/demo-fastapi OUTDIR=packages/demo-fastapi/out ./build.sh
```

- `PACKAGES` lists recipes in `recipes/`. Each one, and the recipes it `DEPENDS` on, is built on first use into `deps/pkg/<name>/`, and again when the recipe changes; `build.sh` then links them in.
- `APP` is the directory holding `worker.py`; it defaults to the directory `build.sh` runs in.
- `OUTDIR` is where the module and `entry.js` go; it defaults to `out/`.

## A project's pyproject.toml

Without `PACKAGES`, `build.sh` installs the dependencies in `[project].dependencies` of the app's `pyproject.toml` (in `APP` or its parent), as `pywrangler sync` does, with `sync.py`:

- It resolves them for the Worker's CPython 3.14 on WASI (environment markers included), with each recipe's version as a constraint.
- Pure-Python wheels are unpacked into a `python_modules/` that `build.sh` keeps under `deps/sync/`, and the app is built from a copy holding them.
- A distribution with native code becomes its recipe, which `build.sh` links in. One with no recipe stops the build with an error naming it.
- Nothing is synced again until the dependencies or the recipes change.

So a project builds with `wrangler dev` / `wrangler deploy` and a `[build]` command alone (`demo-pyproject/wrangler.toml`):

```toml
[build]
command = "APP=src MAIN=entry.py OUTDIR=out ../../build.sh"
watch_dir = ["src", "pyproject.toml"]
```

`sdk-tests/adapter.py` uses the same `sync.py` for the SDK suite's `pywrangler sync`.

## Demos

Each runs under `wrangler dev`:

| Demo | Packages | Shows |
|---|---|---|
| `demo-fastapi/` | pydantic, fastapi | FastAPI through `asgi.py`: JSON, a path parameter, a pydantic-validated POST body (200 or 422), and 404 |
| `demo-numpy/` | numpy | `arange().sum()`, matmul, ufuncs, `linalg.solve`/`det`, `fft`, and `random.default_rng` |
| `demo-markupsafe/` | markupsafe | a plain C extension (`_speedups`) |
| `demo-native/` | every native recipe | a check per package, run while the snapshot is taken (a failure fails the build) and again in a request |
| `demo-pyproject/` | from `pyproject.toml`: msgspec, pyyaml, python-dateutil | the `[build]`-command flow |

## Recipes

| Recipe | Version | Kind | Notes |
|---|---|---|---|
| aiohttp | 3.14.5 | setuptools | four extensions and llhttp; with multidict, yarl, propcache, frozenlist |
| cffi | 2.1.1 | setuptools | `_cffi_backend` over `libffi-wasi/`; see Limits |
| charset-normalizer | 3.5.3 | pure | its mypyc build is optional; the pure wheel |
| cryptography | 50.0.2 | pyo3 | with a static OpenSSL 3.5.4 (`no-sock`, no threads, `openssl-wasi/`) and cffi |
| frozenlist | 1.8.0 | setuptools | Cython, as C++ |
| jiter | 0.19.0 | pyo3 | |
| markupsafe | 3.0.3 | setuptools | |
| msgspec | 0.22.0 | setuptools | |
| multidict | 7.2.1 | setuptools | |
| numpy | 2.5.5 | meson | C++ with Wasm exceptions; lapack-lite |
| orjson | 3.13.0 | pyo3 | |
| propcache | 0.5.4 | setuptools | Cython |
| pydantic | 2.14.4 / core 2.50.5 | pyo3 | pydantic-core at `opt-level=z` |
| pyyaml | 6.0.4 | setuptools | Cython, with libyaml 0.2.5 |
| regex | 2026.11.23 | setuptools | |
| rpds-py | 2026.9.1 | pyo3 | |
| tiktoken | 0.14.0 | pyo3 | with regex and requests |
| uuid-utils | 0.19.0 | pyo3 | |
| websockets | 17.4 | setuptools | `speedups` |
| xxhash | 4.1.0 | setuptools | `tools/fix-noargs.py` |
| yarl | 1.25.1 | setuptools | Cython; with multidict, propcache |
| zstandard | 0.25.0 | setuptools | single-threaded |

fastapi, pytest and pytest-asyncio are bundles of pure wheels.

## Adding a package

Write `recipes/<name>.sh`, then run `packages/build-package.sh <name>`, or add the name to `PACKAGES`.

```sh
VERSION=1.2.3
KIND=setuptools                # pure | setuptools | pyo3 | meson
SDIST=name==$VERSION           # pip spec of the sdist; default <name>==$VERSION
WHEELS="dep-a dep-b"           # pure-Python wheels unpacked into site/
DEPENDS="other-recipe"         # recipes this one needs; build.sh links them in too
MODULES="pkg._ext:PyInit__ext" # each native module: dotted name and its init symbol
LDFLAGS="-lfoo"                # extra link flags for the Worker, if any
CXX_EH=1                       # compile C++ with Wasm exceptions (see below)
```

The kind picks the build:

- **`pure`**: only `WHEELS`, with nothing to compile (`recipes/fastapi.sh`).
- **`setuptools`**: C and C++ extensions compiled directly with wasi-sdk's clang and CPython's headers, from the sdist's root. Set `EXT_SOURCES="pkg._ext=src/a.c,src/b.c"` (one entry per module), `PY_PACKAGES="src/pkg"` and, if needed, `EXT_CFLAGS` (`recipes/msgspec.sh`).
  - Each module's `PyInit_<name>` is renamed after its dotted name and added to the inittab, so no `MODULES` line is needed and two packages' `_speedups` can be linked together.
  - `CYTHON="pkg/_x.pyx ..."` cythonizes those first; a `.pyx` that says `distutils: language = c++` becomes C++ (`recipes/frozenlist.sh`).
- **`pyo3`**: a Rust crate built with `cargo rustc --target wasm32-wasip1 --crate-type staticlib`. A `PYO3_CONFIG_FILE` points it at the cross-built static libpython. Call `default_pyo3 <libname> [crate dir]` from `build_native`; `RUST_FEATURES` and `RUST_CFLAGS` (for `cc`-built C) go to cargo (`recipes/jiter.sh`, `recipes/cryptography.sh`).
- **`meson`**: `meson_cross_build "<options>" [meson.py]` with a wasm32-wasi cross file (`recipes/numpy.sh`).
  - Meson's `python` is the native build CPython of the same version, reporting the WASI sysconfig.
  - Every object is compiled. Shared-module link steps fail on WASI and are ignored.
  - Each extension's objects, and every static library the build made, are archived into `lib/`, with thin archives made regular.

A recipe can also define:
- `prepare_source`, which runs once after unpacking to patch the sdist;
- `build_native`, which replaces the kind's default build. `fetch_tarball <url> <sha256> <dir>` fetches a C library it bundles (`recipes/pyyaml.sh`).

**Rust packages.** Each one is a static library with its own LTO'd copy of std, so more than one is linked with wasi-sdk 30's `wasm-ld --allow-multiple-definition`. Their `random_get` imports are routed through `entropy.c`'s counter, like the C runtime's, so the SDK's entropy patches (`_cloudflare.import_patch_manager`) count and allow their start-up calls.

**C++ exceptions.** wasi-sdk's libc++ is built without them. A recipe with `CXX_EH=1` compiles its C++ with `-fwasm-exceptions` (the exnref encoding) against libc++, libc++abi and libunwind built the same way by `libcxx-eh.sh` (LLVM 21.1.4, wasi-sdk 30's clang, wasi-sdk 24's sysroot). The Worker is then linked with wasi-sdk 30's wasm-ld and snapshotted with exceptions on, and a C++ throw is caught as the package expects. V8 runs the encoding natively.

**METH_NOARGS.** A C function that CPython calls through a two-argument pointer but defines with one traps on Wasm (a typed indirect call). `tools/fix-noargs.py <files>` adds the unused parameter.

**Extension module names.** `PyImport_AppendInittab` takes dotted names, and CPython's `BuiltinImporter` matches the full dotted name. So `numpy._core._multiarray_umath` imports as a built-in with no extra finder.

## Rules for apps

- **Import at module level where you can.** The snapshot holds every module imported while the app loads. A module first imported during a request is read from the in-memory files `RUNTIME_IMPORTS` keeps (the default, `site`, keeps the packages' modules) and compiled on that request. See [../README.md](../README.md#building).
- **Entropy at import time.** Random state seeded while the snapshot is taken would be the same in every instance. The SDK's entropy patches block or reseed what needs it at the first request (numpy.random, uuid-utils, cryptography's OpenSSL RNG, `tempfile`).

## Size of each package (2026-11-24)

`demo-native` built with no packages (base: 3.78 MB gzip -9, 2.82 MB brotli -q 11) and with each recipe alone, which brings its `DEPENDS` and `WHEELS` and runs its check while the snapshot is taken. The cost is the increase of `app.wasm`; snapshot data (the imported modules) is part of it.

| Recipe | + raw | + gzip -9 | + brotli -q 11 |
|---|---|---|---|
| numpy | 13.36 MB | 3.33 MB | 2.21 MB |
| pydantic | 8.27 MB | 2.63 MB | 1.75 MB |
| aiohttp (with multidict, yarl, propcache, frozenlist) | 7.34 MB | 2.48 MB | 1.64 MB |
| cryptography (with cffi) | 7.74 MB | 2.25 MB | 1.65 MB |
| tiktoken (with regex, requests) | 7.29 MB | 1.79 MB | 1.16 MB |
| regex | 5.08 MB | 0.67 MB | 0.41 MB |
| cffi | 2.62 MB | 0.53 MB | 0.35 MB |
| charset-normalizer | 1.50 MB | 0.45 MB | 0.27 MB |
| yarl (with multidict, propcache) | 1.23 MB | 0.42 MB | 0.27 MB |
| websockets | 0.90 MB | 0.36 MB | 0.25 MB |
| msgspec | 0.64 MB | 0.29 MB | 0.21 MB |
| pyyaml | 0.89 MB | 0.26 MB | 0.18 MB |
| zstandard | 0.65 MB | 0.20 MB | 0.15 MB |
| multidict | 0.45 MB | 0.17 MB | 0.11 MB |
| orjson | 0.24 MB | 0.09 MB | 0.06 MB |
| jiter, rpds-py, uuid-utils | 0.10–0.14 MB | 0.08 MB each | 0.06 MB each |
| frozenlist, propcache, xxhash | 0.02–0.08 MB | 0.01–0.03 MB | 0.01–0.02 MB |

**Against the 10 MiB limit** (10.49 MB gzip as wrangler counts it):
- Any one recipe fits with room to spare: the largest, numpy, is 7.11 MB gzip.
- The big five (numpy, pydantic, aiohttp, cryptography, tiktoken) each take 1.8–3.3 MB. Adding the costs, two of them on the base come to about 7.8–9.7 MB: numpy with pydantic is about 9.7 MB, just under, and FastAPI (8.71 MB) with aiohttp or cryptography is over.
- Every recipe at once is 16.6 MB gzip (11.3 MB brotli), over.

## Results (2026-11-23, M-series Mac, `wrangler dev`)

| Build | raw | gzip -9 | brotli -q 11 | Initial memory | Code | `/` p50 / p99 | First request |
|---|---|---|---|---|---|---|---|
| base (the SPEC app) | 11.30 MB | 4.12 MB | 3.06 MB | 169 pages (10.6 MiB) | 2.82 MB | 0.69 / 1.76 ms | 23–39 ms |
| + markupsafe | 11.70 MB | 4.26 MB | 3.16 MB | 179 pages | | | |
| + numpy | 23.15 MB | 7.82 MB | 5.46 MB | 312 pages (19.5 MiB) | 7.68 MB | 0.71 / 1.82 ms | 23–43 ms (`/matmul`) |
| + pydantic + fastapi | 26.13 MB | 8.63 MB | 5.97 MB | — | 4.59 MB | 1.1 / 2.4 ms | — |

The FastAPI row is the current build (pydantic-core at `opt-level=z`, `RUNTIME_IMPORTS=site`), its p50 / p99 over 2000 sequential requests; the others are from the earlier `opt-level=3` builds. First-request times are three cold `wrangler dev` starts each, and they are noisy. For comparison, JS `/` p50 is 0.58 ms.

**Where the bytes go.**
- **Snapshot data dominates.** It's the live heap after importing: base 8.5 MB, numpy 15.5 MB, FastAPI 21.5 MB (11.3 MB of it nonzero).
- **It is live objects, not garbage.**
  - `snapshot.c` zeros every block freed during pre-initialization, which saved about 1 MB gzip on FastAPI.
  - Running Python on plain malloc instead of pymalloc, so those frees were zeroed too, saved nothing more.
- **Most of it is code objects.** A native tracemalloc run of the same FastAPI imports holds 18.9 MB live, half of it code objects for the 316 modules imported. Those include opentelemetry (30 modules) and email (15), which FastAPI pulls in. Stripping docstrings (`-OO`) didn't reduce it.
- **Code:** pydantic-core adds about 3.5 MB at `opt-level=3`, numpy about 4.9 MB.

**What would shrink it:**
1. Import less at snapshot time: lazy imports (PEP 810 in 3.15), or keeping FastAPI from importing opentelemetry and email.
2. Store code objects compactly: marshal them into a data blob and unmarshal on first use, instead of keeping them live.
3. Build numpy with `-Oz` (pydantic-core already builds at `opt-level=z`, with p50 unchanged from `opt-level=3`).

## Known limitations

- **cffi's ABI mode is bounded.** Wasm calls a function pointer with a type fixed in the code, so `libffi-wasi/` has a trampoline compiled per signature (`gen-trampolines.py`): calls of up to 3 arguments of any type, 6 of int/pointer and double, or 12 of int/pointer; callbacks of up to 2, 4 or 6, and 4 alive per signature. Structs go by value as clang's wasm32 ABI has them, and varargs work. A signature beyond those raises `NotImplementedError`. `ffi.dlopen(None)` (or `"c"`, `"libc.so.6"`, `"m"`) finds about 100 libc and libm functions (`libffi-wasi/dlsym.c`); there are no shared libraries to load, so any other name fails with the `OSError` it gives when a library is missing. The trampolines cost about 90 KB of code.
- **OpenSSL has no sockets.** cryptography's OpenSSL is built `no-sock`; its `BIO_ADDR`, `DTLSv1_listen` and `SSL_set_fd` are stubs that fail.
- **Native packages without a recipe** stop the build. Pyodide 314.0.6 ships 146 native packages; the recipes cover 18 of them (see Missing).
- **Legacy `np.random` signatures.** `src/legacy/legacy-distributions.c` declares `random_poisson` and `random_geometric_search` returning `long`. That is 32 bits on wasm32, so the declaration disagrees with their `int64_t` definitions, and wasm-ld warns about the signature mismatch. The legacy `RandomState.poisson` and `RandomState.geometric` calls are affected; `default_rng()` isn't.
- **No BLAS.** numpy uses its bundled lapack-lite, with no SIMD dispatch and no threads.
- **The 10 MiB compressed upload limit.** See Size of each package.

## Missing compared with Pyodide

Pyodide 314.0.6 has 285 packages, 146 with native code. Recipes cover aiohttp, cffi, cryptography, frozenlist, jiter, markupsafe, msgspec, multidict, numpy, orjson, pydantic-core, pyyaml, regex, rpds-py, tiktoken, xxhash, yarl and zstandard. The most used of the rest:

- **Scientific:** pandas, scipy, scikit-learn, matplotlib, pyarrow, polars, statsmodels, shapely, pillow, opencv-python, h5py.
- **Web and data:** lxml, sqlalchemy, protobuf, msgpack, ujson, simplejson, wrapt, duckdb, pymongo, psycopg-c, mysqlclient.
- **Crypto and compression:** bcrypt, pynacl, argon2-cffi-bindings, pycryptodome, brotli, lz4, crc32c, mmh3.
- **Other:** tree-sitter, sentencepiece, safetensors, nh3, libcst, pyrsistent, lazy-object-proxy.

Pure-Python packages need no recipe: `sync.py` installs any with a `py3-none-any` wheel.
