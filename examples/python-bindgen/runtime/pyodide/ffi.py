"""pyodide.ffi on the WASI runtime."""

import _cfjs
from _cf_runtime import (
    ConversionError,
    JsArray,
    JsAsyncGenerator,
    JsAsyncIterable,
    JsAsyncIterator,
    JsBigInt,
    JsBuffer,
    JsCallable,
    JsDoubleProxy,
    JsException,
    JsGenerator,
    JsIterable,
    JsIterator,
    JsMap,
    JsMutableMap,
    JsNull,
    JsPromise,
    JsProxy,
    JsTypedArray,
    PyProxy,
    create_once_callable,
    create_proxy,
    destroy_proxies,
    jsnull,
    run_sync,
    to_js,
)

IN_BROWSER = False


def can_run_sync():
    """Whether run_sync can block here: inside a request, and not in a
    synchronous call from JS."""
    return _cfjs.can_suspend()


__all__ = [
    "IN_BROWSER",
    "ConversionError",
    "JsArray",
    "JsAsyncGenerator",
    "JsAsyncIterable",
    "JsAsyncIterator",
    "JsBigInt",
    "JsBuffer",
    "JsCallable",
    "JsDoubleProxy",
    "JsException",
    "JsGenerator",
    "JsIterable",
    "JsIterator",
    "JsMap",
    "JsMutableMap",
    "JsNull",
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
