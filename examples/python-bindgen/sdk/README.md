# The `workers` SDK

`workers/` and `asgi.py` are Python Workers' SDK from workerd
(`src/pyodide/internal/workers-api/src/`, Apache-2.0, Copyright (c)
Cloudflare, Inc.), copied from commit 6581cf017, with one change: in `asgi.py`, the lifespan
handler's second `receive()` waits for shutdown and then returns
`lifespan.shutdown`. Upstream's returns a `Future` that never resolves, so
every request leaves a lifespan task pending, and requests slow down as they
accumulate.
They run on the Pyodide-compatible FFI in `../runtime/` (`js`, `pyodide.ffi`,
`pyodide.http`, `_pyodide_entrypoint_helper`, `_cloudflare_compat_flags`).
To update them, copy the files again and reapply that change.
