"""pyodide.ffi on the WASI runtime."""

from _cf_runtime import (
    JsBuffer,
    JsException,
    JsProxy,
    PyProxy,
    create_once_callable,
    create_proxy,
    destroy_proxies,
    jsnull,
    run_sync,
    to_js,
)

JsArray = JsMap = JsPromise = JsCallable = JsIterable = JsIterator = JsAsyncIterator = JsDoubleProxy = JsProxy
JsTypedArray = JsBuffer
IN_BROWSER = False


def can_run_sync():
    import _cfjs

    return _cfjs.in_request()


__all__ = [
    "IN_BROWSER",
    "JsArray",
    "JsBuffer",
    "JsCallable",
    "JsDoubleProxy",
    "JsException",
    "JsIterable",
    "JsIterator",
    "JsMap",
    "JsPromise",
    "JsProxy",
    "JsTypedArray",
    "PyProxy",
    "can_run_sync",
    "create_once_callable",
    "create_proxy",
    "destroy_proxies",
    "jsnull",
    "run_sync",
    "to_js",
]
