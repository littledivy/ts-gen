"""What workers._workers reads from the runtime's entrypoint helper."""

import _cfjs


async def _import(module_name):
    return _cfjs.import_module(module_name)


def doAnImport(module_name):
    return _import(module_name)


# cloudflare:workers and cloudflare:sockets, resolved on first use in a
# request (or at startup), like the globals of the `js` module.
cloudflareWorkersModule = _cfjs.lazy(lambda: _cfjs.import_module("cloudflare:workers"))
cloudflareSocketsModule = _cfjs.lazy(lambda: _cfjs.import_module("cloudflare:sockets"))


def patchWaitUntil(ctx):
    # Python awaitables already become promises when passed to JS.
    pass
