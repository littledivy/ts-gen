"""pyodide.webloop on the WASI runtime: the event loop is _cf_runtime's."""

import asyncio

from _cf_runtime import _Loop as WebLoop  # noqa: F401


class WebLoopPolicy(asyncio.DefaultEventLoopPolicy):
    pass
