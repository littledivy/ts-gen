"""The Python Worker runtime: JS values, the event loop, and dispatch.

`_cfjs` (cfjs.c) is the bridge to the generic JS interface of generic.ir. This module builds Pyodide's FFI surface on it (JsProxy,
JsException, to_js, create_proxy, run_sync, the `js` module), runs asyncio on
the host's pendings, and answers dispatch.invoke for the classes and handlers
the app defines.

Life cycle: at build time `wasmtime wizer` calls `_boot()`, which imports the
SDK and the app and records the app's classes for host/package.mjs. If the
app's top level needs JS (env at the top level, say), the import is rolled
back and runs again at startup instead, in the Worker's global scope, from the
"$init" call (the module then has a `workers.init` section).
"""

import asyncio
import asyncio.events
import asyncio.tasks
import builtins
import collections
import collections.abc
import contextlib
import contextvars
import heapq
import inspect
import io
import keyword
import os
import sys
import traceback
import types

import _cfjs
from _cfjs import JsRef

PYODIDE_VERSION = "314.0.6"

# ---- values ----


class _JsNull:
    __slots__ = ()

    def __repr__(self):
        return "jsnull"

    def __bool__(self):
        return False


jsnull = _JsNull()


class JsException(Exception):
    """A JS exception. `name` and `message` are the error's; `js_error` is the
    thrown value itself when it was an object."""

    def __init__(self, message, js_error=None):
        name = "Error"
        if isinstance(js_error, JsRef):
            try:
                n = _cfjs.get(js_error, "name")
                if isinstance(n, str):
                    name = n
                m = _cfjs.get(js_error, "message")
                if isinstance(m, str):
                    message = m
            except Exception:
                pass
        super().__init__(f"{name}: {message}")
        self.name = name
        self.message = message
        self.js_error = js_error


def _make_error(message, value):
    return JsException(message, value if isinstance(value, JsRef) else None)


_global = _cfjs.lazy("globalThis")


def _unkeyword(name):
    # Pyodide's convention: `obj.from_` reads `obj.from`.
    if name.endswith("_") and keyword.iskeyword(name[:-1]):
        return name[:-1]
    return name


def _ctor_name(x):
    try:
        c = _cfjs.get(x, "constructor")
        return _cfjs.get(c, "name") if isinstance(c, JsRef) else None
    except Exception:
        return None


class JsProxy(JsRef):
    """A JS value, with Pyodide's JsProxy behaviour."""

    def __getattr__(self, name):
        if name.startswith("__") and name.endswith("__"):
            raise AttributeError(name)
        return _cfjs.getattr(self, _unkeyword(name))

    def __setattr__(self, name, value):
        _cfjs.set(self, _unkeyword(name), value)

    def __delattr__(self, name):
        _cfjs.call(_cfjs.getattr(_global, "Reflect"), "deleteProperty", (self, _unkeyword(name)))

    def call_relaxed(self, *args, **kwargs):
        return self(*args, **kwargs)

    @property
    def typeof(self):
        return _cfjs.type_of(self)

    @property
    def js_id(self):
        return id(self)

    def __len__(self):
        n = _cfjs.get(self, "length")
        if not isinstance(n, int):
            n = _cfjs.get(self, "size")
        if not isinstance(n, int):
            raise TypeError("object has no length")
        return n

    def _has_method(self, name):
        f = _cfjs.get(self, name)
        return isinstance(f, JsRef) and _cfjs.type_of(f) == "function"

    # x[key]: JsRef's mapping slot (cfjs.c) calls this.
    def _cf_getitem(self, key):
        if isinstance(key, int) and not self._has_method("get"):
            if key < 0:
                key += len(self)
            return _cfjs.get_index(self, key)
        if self._has_method("get"):
            v = _cfjs.call(self, "get", (key,))
            if v is None and self._has_method("has") and not _cfjs.call(self, "has", (key,)):
                raise KeyError(key)
            return v
        v = _cfjs.get(self, str(key))
        if v is None:
            raise KeyError(key)
        return v

    def __setitem__(self, key, value):
        if self._has_method("set"):
            _cfjs.call(self, "set", (key, value))
        else:
            _cfjs.set(self, str(key), value)

    def __delitem__(self, key):
        if self._has_method("delete"):
            _cfjs.call(self, "delete", (key,))
        else:
            _cfjs.call(_cfjs.getattr(_global, "Reflect"), "deleteProperty", (self, str(key)))

    def __contains__(self, key):
        if self._has_method("has"):
            return bool(_cfjs.call(self, "has", (key,)))
        if self._has_method("includes"):
            return bool(_cfjs.call(self, "includes", (key,)))
        return str(key) in _cfjs.keys(self)

    def __eq__(self, other):
        if isinstance(other, JsRef):
            return _cfjs.same(self, other)
        return NotImplemented

    def __ne__(self, other):
        r = self.__eq__(other)
        return r if r is NotImplemented else not r

    def __hash__(self):
        return 0

    def __bool__(self):
        return True

    def __str__(self):
        try:
            return _cfjs.invoke(_cfjs.getattr(_global, "String"), (self,))
        except Exception:
            return "<JsProxy>"

    def __repr__(self):
        if _cfjs.is_lazy(self) and not _cfjs.in_request():
            return "<JsProxy (global)>"
        return self.__str__()

    def __dir__(self):
        names = set()
        try:
            o = self
            obj = _cfjs.getattr(_global, "Object")
            while isinstance(o, JsRef):
                names.update(_cfjs.call(obj, "getOwnPropertyNames", (o,)))
                o = _cfjs.call(obj, "getPrototypeOf", (o,))
        except Exception:
            pass
        return sorted(names)

    def to_py(self, *, depth=-1, default_converter=None):
        return _to_py(self, depth, default_converter, _ToPyCache())

    def as_object_map(self, *, hereditary=False):
        return _ObjectMap(self)

    def object_keys(self):
        return _cfjs.call(_cfjs.getattr(_global, "Object"), "keys", (self,))

    def object_values(self):
        return _cfjs.call(_cfjs.getattr(_global, "Object"), "values", (self,))

    def object_entries(self):
        return _cfjs.call(_cfjs.getattr(_global, "Object"), "entries", (self,))

    def to_bytes(self):
        return _cfjs.to_bytes(_cfjs.construct(_cfjs.getattr(_global, "Uint8Array"), (self,)))

    def to_string(self, encoding=None):
        return self.to_bytes().decode(encoding or "utf-8")

    def destroy(self):
        pass

    def copy(self):
        return self


class JsBuffer(JsProxy):
    """A JS ArrayBuffer, typed array or DataView, as Pyodide's JsBuffer: it
    keeps its JS identity, and to_bytes, to_py and friends copy its bytes."""

    __slots__ = ()

    def to_bytes(self):
        return _cfjs.to_bytes(self)

    def __bytes__(self):
        return _cfjs.to_bytes(self)

    def to_memoryview(self):
        return memoryview(_cfjs.to_bytes(self))

    def to_py(self, *, depth=-1, default_converter=None):
        return self.to_memoryview()

    def to_string(self, encoding=None):
        return _cfjs.to_bytes(self).decode(encoding or "utf-8")

    def to_file(self, f):
        f.write(_cfjs.to_bytes(self))

    def from_file(self, f):
        self.assign(f.read(_cfjs.get(self, "byteLength")))

    def assign(self, rhs):
        data = memoryview(rhs).cast("B")
        if len(data) != _cfjs.get(self, "byteLength"):
            raise ValueError("cannot assign from a buffer of a different size")
        _cfjs.write_bytes(self, 0, data)

    def assign_to(self, to):
        target = memoryview(to).cast("B")
        data = _cfjs.to_bytes(self)
        if len(data) != len(target):
            raise ValueError("cannot assign to a buffer of a different size")
        target[:] = data


class _JsCallable:
    __slots__ = ()

    def __call__(self, *args, **kwargs):
        if kwargs:
            args = (*args, kwargs)
        bound = self._cf_bound
        if bound is not None:
            return _cfjs.call(bound[0], bound[1], args)
        return _cfjs.invoke(self, args)

    def new(self, *args, **kwargs):
        if kwargs:
            args = (*args, kwargs)
        return _cfjs.construct(self, args)



class _JsAwaitable:
    __slots__ = ()

    def __await__(self):
        return (yield from _await_promise(self))


class _JsIterable:
    __slots__ = ()

    def __iter__(self):
        if _cfjs.instance_of(self, "Array"):
            for i in range(_cfjs.length(self)):
                yield _cfjs.get_index(self, i)
            return
        it = _cfjs.iterator(self, False)
        while True:
            step = _cfjs.call(it, "next", ())
            if _cfjs.get(step, "done"):
                return
            yield _cfjs.get(step, "value")


class _JsAsyncIterable:
    __slots__ = ()

    def __aiter__(self):
        return _aiter(self)


_types = {}


def _type_for(traits):
    """The JsProxy class for a value with these js.object.traits bits, as
    Pyodide picks a JsProxy class by what the JS value can do."""
    t = _types.get(traits)
    if t is None:
        bases = []
        if traits & 1:
            bases.append(_JsCallable)
        if traits & 2:
            bases.append(_JsAwaitable)
        if traits & 8:
            bases.append(_JsIterable)
        if traits & 16:
            bases.append(_JsAsyncIterable)
        if traits & 32:
            bases.append(JsBuffer)
        t = _types[traits] = type("JsProxy", (*bases, JsProxy), {"__slots__": (), "__module__": "pyodide.ffi"}) if bases else JsProxy
    return t


async def _aiter(o):
    it = _cfjs.iterator(o, True)
    while True:
        step = await _cfjs.call(it, "next", ())
        if _cfjs.get(step, "done"):
            return
        yield _cfjs.get(step, "value")


class _ObjectMap(collections.abc.MutableMapping):
    def __init__(self, o):
        self._o = o

    def __getitem__(self, k):
        if k not in self:
            raise KeyError(k)
        return _cfjs.get(self._o, k)

    def __setitem__(self, k, v):
        _cfjs.set(self._o, k, v)

    def __delitem__(self, k):
        _cfjs.call(_cfjs.getattr(_global, "Reflect"), "deleteProperty", (self._o, k))

    def __iter__(self):
        return iter(_cfjs.keys(self._o))

    def __len__(self):
        return len(_cfjs.keys(self._o))

    def __contains__(self, k):
        return k in _cfjs.keys(self._o)


class _ToPyCache:
    """to_py's record of the JS objects it has converted, keyed by JS
    identity (a JS Map, as Pyodide's), so an object reached twice, or through
    a cycle, converts once. Each fetch makes a new JsRef for the same JS
    object, and a freed JsRef's id() is reused, so id() can't be the key."""

    __slots__ = ("_map", "_values")

    def __init__(self):
        self._map = None
        self._values = []

    def get(self, x, default):
        if self._map is None:
            return default
        i = _cfjs.call(self._map, "get", (x,))
        return default if i is None else self._values[i]

    def put(self, x, v):
        if self._map is None:
            self._map = _cfjs.construct(_cfjs.getattr(_global, "Map"), ())
        _cfjs.call(self._map, "set", (x, len(self._values)))
        self._values.append(v)


_MISSING = object()


def _to_py(x, depth, conv, cache):
    if not isinstance(x, JsProxy):
        return x
    if depth == 0:
        return x
    if isinstance(x, JsBuffer):
        return x.to_memoryview()
    r = cache.get(x, _MISSING)
    if r is not _MISSING:
        return r
    d = depth - 1
    name = _ctor_name(x)
    if name == "Array" or _cfjs.instance_of(x, "Array"):
        out = []
        cache.put(x, out)
        out.extend(_to_py(v, d, conv, cache) for v in x)
        return out
    if name == "Map":
        out = {}
        cache.put(x, out)
        for pair in x.entries():
            k, v = pair
            out[_to_py(k, d, conv, cache)] = _to_py(v, d, conv, cache)
        return out
    if name == "Set":
        out = set()
        cache.put(x, out)
        out.update(_to_py(v, d, conv, cache) for v in x)
        return out
    if name == "Object" or name is None and _cfjs.type_of(x) == "object":
        out = {}
        cache.put(x, out)
        for k in _cfjs.keys(x):
            out[k] = _to_py(_cfjs.get(x, k), d, conv, cache)
        return out
    if conv is not None:

        def convert(v):
            return _to_py(v, d, conv, cache)

        def cacheit(k, v):
            if isinstance(k, JsRef):
                cache.put(k, v)

        r = conv(x, convert, cacheit)
        cache.put(x, r)
        return r
    return x


# ---- Python values going to JS ----

# A Python function JS can call is an id here. How long the id lives:
#
# - one create_proxy made (_KEPT) lives until destroy(), as in Pyodide;
# - one made implicitly, by passing a function to JS, belongs to the request
#   that made it, and goes once that request is done (its handler has
#   returned and its tasks have finished) and the next handler call starts.
#   JS calls made while Python ran are held back until it returns or
#   suspends (bindgen.py --defer), so the wait lets the last of
#   them run first: blockConcurrencyWhile(callback) in a Durable Object's
#   constructor, say. Dropping them also breaks a cycle through JS (a
#   function stored on a JS object it refers to), which neither garbage
#   collector can see whole. Ones made outside any request go once no
#   request has tasks left.
# - either goes as soon as JS drops the function, where FinalizationRegistry
#   exists (host/generic.js callback, then dispatch "$release").
_KEPT = "kept"
_callbacks = {}  # id -> function
_callback_owner = {}  # id -> request, _KEPT or None
_request_callbacks = {}  # request -> ids of its implicit callbacks
_loose_callbacks = set()  # ids of implicit callbacks made outside any request
_next_callback = [1]


def _callback_for(func, kept=False):
    cid = _next_callback[0]
    _next_callback[0] += 1
    _callbacks[cid] = func
    owner = _KEPT if kept else _request.get()
    _callback_owner[cid] = owner
    if owner is None:
        _loose_callbacks.add(cid)
    elif owner is not _KEPT:
        _request_callbacks.setdefault(owner, set()).add(cid)
    fn = _cfjs.callback(cid)
    object.__setattr__(fn, "_cf_callback_id", cid)
    return fn


def _drop_callback(cid):
    _callbacks.pop(cid, None)
    owner = _callback_owner.pop(cid, None)
    if owner is None:
        _loose_callbacks.discard(cid)
    elif owner is not _KEPT:
        ids = _request_callbacks.get(owner)
        if ids is not None:
            ids.discard(cid)


def _release(ids):
    """JS dropped these functions (dispatch "$release")."""
    for i in ids.split(","):
        if i:
            cid = int(i)
            _internal.pop(cid, None)
            _drop_callback(cid)


# Requests whose handler has returned but whose tasks are still running.
_finishing = set()


# Implicit callbacks of requests that are done, dropped at the next handler
# call.
_retiring = []


def _finish(rid):
    """Called once the request is done: retires its implicit callbacks."""
    ids = _request_callbacks.pop(rid, None)
    if ids:
        _retiring.append(ids)


def _drop_retiring():
    while _retiring:
        for cid in _retiring.pop():
            _callbacks.pop(cid, None)
            _callback_owner.pop(cid, None)


def _maybe_finish(rid):
    if _pending_tasks(rid):
        _finishing.add(rid)
    else:
        _finishing.discard(rid)
        _finish(rid)


def _drop_loose():
    """Drops the implicit callbacks made outside any request."""
    while _loose_callbacks:
        cid = _loose_callbacks.pop()
        _callbacks.pop(cid, None)
        _callback_owner.pop(cid, None)


class PyProxy:
    """What create_proxy returns: a Python object JS can hold."""

    def __init__(self, obj, once=False):
        self._obj = obj
        self._once = once
        self._js = None

    def _to_js(self):
        if self._js is None:
            obj = self._obj
            if inspect.isawaitable(obj):
                self._js = _promise_for(obj)
            elif callable(obj):
                if self._once:
                    holder = {}

                    def once(*args):
                        _drop_callback(holder.get("id"))
                        return obj(*args)

                    self._js = _callback_for(once, kept=True)
                    holder["id"] = self._js._cf_callback_id
                else:
                    self._js = _callback_for(obj, kept=True)
            else:
                self._js = _implicit(obj)
        return self._js

    def __call__(self, *args, **kwargs):
        return self._obj(*args, **kwargs)

    def destroy(self):
        if self._js is not None:
            _drop_callback(getattr(self._js, "_cf_callback_id", None))

    def copy(self):
        return self

    def callPromising(self, *args):
        """Pyodide's PyProxy.callPromising: calls the function as a call of
        its own, which may block (run_sync) without blocking this one, and
        returns a promise of its result."""
        return _cfjs.invoke(self._to_js(), args)

    def getBuffer(self, type=None):
        return _PyBuffer(self._obj)

    def __getattr__(self, name):
        return getattr(self._obj, name)


class _PyBuffer:
    """Pyodide's PyBuffer. `data` is a JS Uint8Array holding the bytes (a
    copy here, where Pyodide's is a view of the Python heap), so JS methods
    such as slice() work on it."""

    def __init__(self, obj):
        self.data = _cfjs.construct(_cfjs.getattr(_global, "Uint8Array"), (bytes(obj),))

    def release(self):
        pass


def _promise_for(aw, report=False):
    """A JS promise that settles with the awaitable's result. With report, a
    failure is printed too, as a handler's is."""
    task = asyncio.ensure_future(aw, loop=_loop)
    promise, resolve, reject = _resolvers()

    def done(t):
        try:
            if t.cancelled():
                _cfjs.invoke(reject, (_js_error("task was cancelled"),))
            elif t.exception() is not None:
                if report:
                    traceback.print_exception(t.exception())
                _cfjs.invoke(reject, (_python_error(t.exception()),))
            else:
                _cfjs.invoke(resolve, (t.result(),))
        except Exception:
            traceback.print_exc()

    task.add_done_callback(done)
    return promise


def _js_error(message):
    return _cfjs.construct(_cfjs.getattr(_global, "Error"), (message,))


def on_fatal(error):
    """Pyodide's Module.API.on_fatal in workerd: the interpreter can't go on,
    so the isolate is aborted, with the error as the reason. It doesn't
    return."""
    reason = f"Python worker fatal error: {error}"
    print(reason, file=sys.stderr)
    sys.stderr.flush()
    workers = _cfjs.import_module("cloudflare:workers")
    _cfjs.call(workers, "abortIsolate", (reason,))
    raise SystemError(reason)


def _python_error(e):
    """The JS Error for Python exception `e`, shaped as Pyodide's PythonError
    where JS code looks: `e instanceof Error`, `e.constructor.name` is
    "PythonError" and `e.type` is the exception's class name (the SDK's
    workflows.js reads these)."""
    err = _js_error(_format_exc(e))
    if isinstance(e, _PythonUserError):
        return err
    error = _cfjs.getattr(_global, "Error")
    obj = _cfjs.getattr(_global, "Object")
    ctor = _cfjs.call(error, "bind", (None,))
    _cfjs.call(obj, "defineProperty", (ctor, "name", {"value": "PythonError"}))
    proto = _cfjs.call(obj, "create", (_cfjs.getattr(error, "prototype"),))
    _cfjs.call(obj, "defineProperty", (proto, "constructor", {"value": ctor, "writable": True, "configurable": True}))
    _cfjs.set(ctor, "prototype", proto)
    _cfjs.call(obj, "setPrototypeOf", (err, proto))
    _cfjs.set(err, "type", type(e).__name__)
    return err


def _implicit(o):
    """Python -> JS for what cfjs.c doesn't convert itself."""
    if isinstance(o, PyProxy):
        return o._to_js()
    if isinstance(o, (list, tuple)):
        return _cfjs.new_array(o)
    if isinstance(o, dict):
        obj = _cfjs.new_object()
        for k, v in o.items():
            _cfjs.set(obj, str(k), v)
        return obj
    if isinstance(o, (set, frozenset)):
        return _cfjs.construct(_cfjs.getattr(_global, "Set"), (_cfjs.new_array(list(o)),))
    if inspect.isawaitable(o):
        return _promise_for(o)
    if callable(o):
        return _callback_for(o)
    if isinstance(o, BaseException):
        return _python_error(o)
    if hasattr(o, "__iter__"):
        return _cfjs.new_array(list(o))
    import datetime

    if isinstance(o, datetime.datetime):
        return _cfjs.construct(_cfjs.getattr(_global, "Date"), (o.timestamp() * 1000,))
    raise TypeError(f"Cannot convert {type(o).__name__} to a JS value")


def _literal_map(arr, pairs):
    """What to_js makes of a dict by default, like Pyodide's LiteralMap: a
    Map whose string keys also read as properties (`m.value`), except keys
    that would hide a Map method or `size`."""
    m = _cfjs.construct(_cfjs.getattr(_global, "Map"), (arr,))
    props = [p for p in pairs if isinstance(p[0], str) and p[0] not in _MAP_NAMES]
    if props:
        obj = _cfjs.call(_cfjs.getattr(_global, "Object"), "fromEntries", (_cfjs.new_array(props),))
        _cfjs.call(_cfjs.getattr(_global, "Object"), "assign", (m, obj))
    return m


_MAP_NAMES = frozenset({"clear", "constructor", "delete", "entries", "forEach", "get", "has", "keys", "set", "size", "values",
                        "__proto__", "hasOwnProperty", "isPrototypeOf", "propertyIsEnumerable", "toLocaleString", "toString", "valueOf"})


def to_js(obj, depth=-1, pyproxies=None, create_pyproxies=True, dict_converter=None, default_converter=None, **_):
    cache = {}
    # The objects cacheit keys by id(), kept alive so the ids aren't reused.
    keep = []

    def conv(x, d):
        if x is None or x is jsnull or isinstance(x, (bool, int, float, str, bytes, JsRef)):
            return x
        # What create_proxy returned, from the caller or a default_converter:
        # in Pyodide it is already a JS value, so it isn't converted again.
        if isinstance(x, PyProxy):
            return x._to_js()
        if d == 0:
            return x
        k = id(x)
        if k in cache:
            return cache[k]
        if isinstance(x, dict):
            pairs = [[conv(a, d - 1), conv(b, d - 1)] for a, b in x.items()]
            arr = _cfjs.new_array(pairs)
            if dict_converter is not None:
                r = dict_converter(arr)
            else:
                r = _literal_map(arr, pairs)
            cache[k] = r
            return r
        if isinstance(x, (list, tuple)):
            r = cache[k] = _cfjs.new_array([conv(v, d - 1) for v in x])
            return r
        if isinstance(x, (set, frozenset)):
            r = cache[k] = _cfjs.construct(_cfjs.getattr(_global, "Set"), (_cfjs.new_array([conv(v, d - 1) for v in x]),))
            return r
        if isinstance(x, (bytearray, memoryview)):
            return bytes(x)
        if default_converter is not None:

            def convert(v):
                return conv(v, d - 1)

            def cacheit(a, b):
                keep.append(a)
                cache[id(a)] = b

            r = default_converter(x, convert, cacheit)
            if r is not x:
                cache[k] = r
                return conv(r, d) if not isinstance(r, JsRef) else r
        if isinstance(x, (PyProxy, BaseException)) or callable(x) or inspect.isawaitable(x):
            return _implicit(x)
        import datetime

        if isinstance(x, datetime.datetime):
            return _implicit(x)
        if not create_pyproxies:
            raise TypeError(f"Cannot convert {type(x).__name__} to a JS value")
        return _opaque(x)

    return conv(obj, depth)


def _opaque(obj):
    """What to_js gives for a Python object it doesn't convert. Pyodide gives
    a PyProxy, which structured clone and RPC refuse with a DataCloneError.
    This object holds a Symbol, so they refuse it the same way."""
    o = _cfjs.new_object()
    _cfjs.set(o, "pyproxy", _cfjs.invoke(_cfjs.getattr(_global, "Symbol"), (type(obj).__name__,)))
    return o


def create_proxy(obj, *, capture_this=False, roundtrip=True):
    return PyProxy(obj)


def create_once_callable(obj, *, _may_syncify=False):
    return PyProxy(obj, once=True)


def destroy_proxies(proxies):
    pass


# ---- the event loop ----
#
# One asyncio loop serves every request on the instance (see `reentrant` in
# host/tsgen.js), stepped the way Pyodide's WebLoop is: a call into
# Python runs the handles that are ready and returns, and JS calls back in when
# a promise a task awaits settles, a timer is due, or another request made
# this one's handles ready. A request's handler that hasn't finished by then
# returns a promise instead of its result. Nothing suspends while it waits, so
# requests don't hold each other up; only a blocking call (run_sync) suspends.
#
# A JS call runs in the context of the request whose call into Python is
# running, and workerd refuses I/O on another request's objects. So each call
# steps only its own request's handles; tasks and handles carry their request
# in this context variable. None (code outside any request) runs anywhere.
_request = contextvars.ContextVar("_cf_request", default=None)
_next_request = [0]


def _mine(owner, me):
    return me is None or owner is None or owner == me


def _owner(handle):
    ctx = getattr(handle, "_context", None)
    return ctx.get(_request, None) if ctx is not None else None


class _Loop(asyncio.BaseEventLoop):
    def _process_events(self, event_list):
        pass

    def close(self):
        # One loop serves the instance for its whole life.
        pass

    def _write_to_self(self):
        pass

    def run_until_complete(self, future):
        return _run(future)

    def run_forever(self):
        raise RuntimeError("the Workers event loop runs on its own; await the work instead")

    def create_task(self, coro, **kwargs):
        task = super().create_task(coro, **kwargs)
        rid = task.get_context().get(_request, None)
        if rid is not None:
            _request_tasks.setdefault(rid, set()).add(task)
        return task

    def run_in_executor(self, executor, func, *args):
        # There are no threads to run `func` on, so it runs now, as in
        # Pyodide's WebLoop (asyncio.to_thread, asgiref's sync_to_async).
        fut = self.create_future()
        try:
            fut.set_result(func(*args))
        except BaseException as e:
            fut.set_exception(e)
        return fut

    # No executor is ever used, so these do nothing, as in WebLoop.
    # (BaseEventLoop's shutdown_default_executor joins its executor on a new
    # thread.)
    def set_default_executor(self, executor):
        pass

    async def shutdown_default_executor(self, timeout=None):
        pass

    # Sockets (_cf_sockets) await cloudflare:sockets' promises directly.
    async def getaddrinfo(self, host, port, *, family=0, type=0, proto=0, flags=0):
        return _cf_sockets.getaddrinfo(host, port, family, type, proto, flags)

    async def sock_connect(self, sock, address):
        await sock._aconnect(address)

    async def sock_recv(self, sock, n):
        return await sock._arecv(n)

    async def sock_recv_into(self, sock, buf):
        view = memoryview(buf).cast("B")
        data = await sock._arecv(len(view))
        view[: len(data)] = data
        return len(data)

    async def sock_sendall(self, sock, data):
        await sock._asend(data)

    def _make_socket_transport(self, sock, protocol, waiter=None, *, extra=None, server=None):
        return _SocketTransport(self, sock, protocol, waiter, extra)

    def _make_ssl_transport(self, rawsock, protocol, sslcontext, waiter=None, *, server_side=False,
                            server_hostname=None, extra=None, server=None, **kwargs):
        if server_side:
            raise NotImplementedError("TLS servers are not supported by cloudflare:sockets")
        return _SocketTransport(self, rawsock, protocol, waiter, extra, tls=server_hostname or "")

    def _run_ready(self, me):
        """Runs the handles that are ready now and belong to `me`; returns how
        many ran."""
        sched = self._scheduled
        while sched and sched[0]._cancelled:
            self._timer_cancelled_count -= 1
            heapq.heappop(sched)._scheduled = False
        end = self.time() + self._clock_resolution
        while sched and sched[0]._when < end:
            h = heapq.heappop(sched)
            h._scheduled = False
            self._ready.append(h)
        ran = 0
        n = len(self._ready)
        others = []
        while n > 0 and self._ready:
            n -= 1
            h = self._ready.popleft()
            if h._cancelled:
                continue
            if not _mine(_owner(h), me):
                others.append(h)
                continue
            ran += 1
            h._run()
        self._ready.extendleft(reversed(others))
        return ran


class _SocketTransport(asyncio.Transport):
    """An asyncio transport over a _cf_sockets socket: a task reads into the
    protocol, and writes go out in order."""

    def __init__(self, loop, sock, protocol, waiter, extra, tls=None):
        super().__init__({"socket": sock, "peername": sock._peer, "sockname": sock.getsockname(), **(extra or {})})
        self._loop, self._sock, self._protocol = loop, sock, protocol
        self._closing = False
        self._resumed = None  # a Future while reading is paused
        self._last_write = None
        self._reader = loop.create_task(self._run(waiter, tls))

    async def _run(self, waiter, tls):
        try:
            if tls is not None:
                await self._sock._aupgrade(tls or None)
            self._protocol.connection_made(self)
            if waiter is not None and not waiter.cancelled():
                waiter.set_result(None)
        except BaseException as e:
            if waiter is not None and not waiter.cancelled():
                waiter.set_exception(e)
            self._sock.close()
            return
        try:
            while not self._closing:
                if self._resumed is not None:
                    await self._resumed
                data = await self._sock._arecv(65536)
                if not data:
                    if not self._protocol.eof_received():
                        self.close()
                    return
                self._protocol.data_received(data)
        except Exception as e:
            if not self._closing:
                self._lose(e)

    def write(self, data):
        if self._closing or not data:
            return
        prev, data = self._last_write, bytes(data)

        async def send():
            if prev is not None:
                await prev
            await self._sock._asend(data)

        self._last_write = self._loop.create_task(send())

    def writelines(self, chunks):
        self.write(b"".join(chunks))

    def write_eof(self):
        prev = self._last_write

        async def shut():
            if prev is not None:
                await prev
            self._sock.shutdown(socket.SHUT_WR)

        self._last_write = self._loop.create_task(shut())

    def can_write_eof(self):
        return True

    def get_write_buffer_size(self):
        return 0

    def get_write_buffer_limits(self):
        return (0, 0)

    def set_write_buffer_limits(self, high=None, low=None):
        pass

    def pause_reading(self):
        if self._resumed is None:
            self._resumed = self._loop.create_future()

    def resume_reading(self):
        if self._resumed is not None:
            self._resumed.set_result(None)
            self._resumed = None

    def is_reading(self):
        return self._resumed is None and not self._closing

    def is_closing(self):
        return self._closing

    def close(self):
        if self._closing:
            return
        self._closing = True
        prev = self._last_write

        async def finish():
            if prev is not None:
                try:
                    await prev
                except Exception:
                    pass
            self._sock.close()
            self._protocol.connection_lost(None)

        self._loop.create_task(finish())

    def abort(self):
        self._lose(None)

    def _lose(self, exc):
        if self._closing and exc is not None:
            return
        self._closing = True
        self._sock.close()
        self._loop.call_soon(self._protocol.connection_lost, exc)


_loop = _Loop()

# The socket and ssl modules, over cloudflare:sockets (see _cf_sockets).
import socket  # noqa: E402

import _cf_sockets  # noqa: E402

_cf_sockets.patch(socket)


class _Policy(asyncio.events._BaseDefaultEventLoopPolicy):
    def new_event_loop(self):
        return _loop

    def get_event_loop(self):
        return _loop


asyncio.events._set_event_loop_policy(_Policy()) if hasattr(asyncio.events, "_set_event_loop_policy") else asyncio.set_event_loop_policy(_Policy())
asyncio.set_event_loop(_loop)


_callbacks_ids = [1 << 30]  # ids for the loop's own callbacks
_internal = {}  # id -> function, for the loop's own one-shot callbacks


def _once(func):
    """A one-shot JS function that calls func: the loop's own callbacks,
    which outlive the request that made them."""
    cid = _callbacks_ids[0]
    _callbacks_ids[0] += 1
    _internal[cid] = func
    return cid, _cfjs.callback(cid)


def _resolvers():
    r = _cfjs.call(_cfjs.getattr(_global, "Promise"), "withResolvers", ())
    return _cfjs.get(r, "promise"), _cfjs.get(r, "resolve"), _cfjs.get(r, "reject")


_wakers = {}  # request -> (resolve, callback id) of a promise whose settling steps it
_timers = {}  # request -> when its JS timer fires
_sleepers = []  # resolves of blocked _run calls, settled after every step
_idle = {}  # request -> resolve, settled once the request has no tasks left
_stepping = [0]  # steps running ready handles, not counting suspended ones


def _arm_waker(rid):
    # Made while the request's own call runs, so when another request
    # settles it, workerd runs the continuation in this request's context.
    if rid in _wakers:
        return
    promise, resolve, _ = _resolvers()

    def woke(*_):
        # Only if it is still this waker: once _wake_ready has settled it,
        # the request may have armed a newer one, which has to stay.
        w = _wakers.get(rid)
        if w is not None and w[1] == cid:
            del _wakers[rid]
        _step(rid)

    cid, cb = _once(woke)
    _cfjs.call(promise, "then", (cb,))
    _wakers[rid] = (resolve, cid)


def _drop_waker(rid):
    w = _wakers.pop(rid, None)
    if w is not None:
        _internal.pop(w[1], None)


def _arm_timer(rid, when):
    if rid in _timers and _timers[rid] <= when:
        return
    _timers[rid] = when

    def fire(*_):
        if _timers.get(rid) == when:
            del _timers[rid]
        _step(rid)

    _, cb = _once(fire)
    delay = max(0, when - _loop.time()) * 1000
    _cfjs.call(_global, "setTimeout", (cb, delay))


def _step(me):
    """Runs `me`'s ready handles until none are left, then arranges to be
    called again: for its next timer, and through other requests' wakers for
    handles this step made ready for them."""
    loop = _loop
    cur = asyncio.tasks.current_task(loop) if asyncio.events._get_running_loop() is loop else None
    if cur is not None:
        asyncio.tasks._leave_task(loop, cur)
    prev = asyncio.events._get_running_loop()
    prev_thread = loop._thread_id
    asyncio.events._set_running_loop(loop)
    loop._thread_id = 1
    token = _request.set(me)
    _stepping[0] += 1
    try:
        while loop._run_ready(me):
            pass
    finally:
        _stepping[0] -= 1
        _request.reset(token)
        loop._thread_id = prev_thread
        asyncio.events._set_running_loop(prev)
        if cur is not None:
            asyncio.tasks._enter_task(loop, cur)
    _after_step(me)


def _wake_ready(me=None):
    """Wakes the requests, and the blocked _run calls, whose handles are
    ready: after a step, or after JS called a Python callback that made
    them ready (a WebSocket listener settling a future, say)."""
    for h in _loop._ready:
        if h._cancelled:
            continue
        o = _owner(h)
        if o is not None and o != me:
            w = _wakers.pop(o, None)
            if w is not None:
                _cfjs.invoke(w[0], ())
    if _loop._ready:
        while _sleepers:
            _cfjs.invoke(_sleepers.pop(), ())


def _after_step(me):
    loop = _loop
    _wake_ready(me)
    when = min((h._when for h in loop._scheduled if not h._cancelled and _mine(_owner(h), me)), default=None)
    if when is not None:
        _arm_timer(me, when)
    if me is not None:
        if _pending_tasks(me):
            _arm_waker(me)
        else:
            _drop_waker(me)
    for rid, resolve in list(_idle.items()):
        if not _pending_tasks(rid):
            del _idle[rid]
            _cfjs.invoke(resolve, ())
    for rid in list(_finishing):
        if not _pending_tasks(rid):
            _finishing.discard(rid)
            _finish(rid)
    while _sleepers:
        _cfjs.invoke(_sleepers.pop(), ())


def _await_promise(promise):
    """A Future for a JS promise or thenable, settled from its callbacks."""
    loop = _loop
    fut = loop.create_future()
    owner = _request.get()
    p = _cfjs.call(_cfjs.getattr(_global, "Promise"), "resolve", (promise,))
    ids = []

    def settle(ok, value):
        for i in ids:
            _internal.pop(i, None)
        if not fut.cancelled():
            if ok:
                fut.set_result(value)
            else:
                fut.set_exception(_make_error(_error_message(value), value))
        _step(owner)

    ok_id, ok_cb = _once(lambda v=None: settle(True, v))
    err_id, err_cb = _once(lambda e=None: settle(False, e))
    ids += [ok_id, err_id]
    _cfjs.call(p, "then", (ok_cb, err_cb))
    return fut


def _error_message(e):
    if isinstance(e, JsRef):
        try:
            m = _cfjs.get(e, "message")
            if isinstance(m, str):
                return m
            return _cfjs.invoke(_cfjs.getattr(_global, "String"), (e,))
        except Exception:
            return "JS error"
    return str(e)


# Tasks blocked in _run: each waits for the run it started.
_blocked = []


# The tasks that were already on the loop when the asyncio.Runner closing
# now started (see _cancel_runner_tasks).
_runner_before = []


def _cancel_runner_tasks(loop):
    """asyncio.runners._cancel_all_tasks, which asyncio.Runner.close() and
    asyncio.run() call, for a loop that is shared and may already be running
    a task: it cancels and waits for only the current request's tasks that
    the runner's lifetime created. The original cancels every task on the
    loop (a runner's own loop elsewhere), which would take other requests'
    tasks with it, cancel the request's handler that is waiting on the
    runner's caller, and wait for the task it is called from (as
    pytest-asyncio does inside a request), which never finishes first."""
    me = _request.get()
    cur = asyncio.tasks.current_task(loop) if asyncio.events._get_running_loop() is loop else None
    before = _runner_before[-1] if _runner_before else set()
    to_cancel = [
        t for t in asyncio.tasks.all_tasks(loop)
        if not t.done() and t is not cur and t not in _blocked and t not in before
        and t.get_context().get(_request, None) == me
    ]
    if not to_cancel:
        return
    for t in to_cancel:
        t.cancel()
    loop.run_until_complete(asyncio.gather(*to_cancel, return_exceptions=True))
    for t in to_cancel:
        if not t.cancelled() and t.exception() is not None:
            loop.call_exception_handler(
                {"message": "unhandled exception during asyncio.run() shutdown", "exception": t.exception(), "task": t}
            )


asyncio.runners._cancel_all_tasks = _cancel_runner_tasks
_runner_lazy_init = asyncio.Runner._lazy_init
_runner_close = asyncio.Runner.close


def _lazy_init(self):
    starting = self._state is asyncio.runners._State.CREATED
    _runner_lazy_init(self)
    if starting:
        self._cf_before = set(asyncio.tasks.all_tasks(self._loop))


def _close(self):
    _runner_before.append(getattr(self, "_cf_before", set()))
    try:
        _runner_close(self)
    finally:
        _runner_before.pop()


asyncio.Runner._lazy_init = _lazy_init
asyncio.Runner.close = _close


def _run(aw):
    """Runs an awaitable to completion, blocking (suspending the instance)
    while it waits: for run_sync and the top level."""
    me = _request.get()
    fut = asyncio.ensure_future(aw, loop=_loop)
    cur = asyncio.tasks.current_task(_loop) if asyncio.events._get_running_loop() is _loop else None
    if cur is not None:
        _blocked.append(cur)
    try:
        while True:
            _step(me)
            if fut.done():
                return fut.result()
            promise, resolve, _ = _resolvers()
            _sleepers.append(resolve)
            h = _cfjs.from_promise(promise)
            # JS may call Python callbacks while this waits; with no step
            # running, they wake what they make ready (see _dispatch).
            stepping, _stepping[0] = _stepping[0], 0
            try:
                _cfjs.wait_any([h])
            finally:
                _stepping[0] = stepping
            _cfjs.drop_pending(h)
    finally:
        if cur is not None:
            _blocked.remove(cur)


def run_sync(aw):
    """Pyodide's run_sync: blocks (suspending the instance) until `aw` is done."""
    if not _cfjs.in_request():
        raise RuntimeError("No suspender")
    return _run(aw)


# Each request's tasks, as the loop created them (_Loop.create_task), so
# that asking for one request's tasks needn't scan every task on the loop:
# _after_step asks on every step, for the request stepped and for each one
# that has returned but still has tasks, and with many requests in flight
# the scans made each step cost O(requests x tasks).
_request_tasks = {}


def _pending_tasks(owner=None):
    """Unfinished tasks; with an owner, only that request's."""
    if owner is not None:
        mine = _request_tasks.get(owner)
        if mine:
            live = [t for t in mine if not t.done()]
            if live:
                if len(live) < len(mine):
                    _request_tasks[owner] = set(live)
                return live
            del _request_tasks[owner]
        # None that the loop made: check every task, for one made some other
        # way (asyncio.Task(coro) directly). That happens about once per
        # request, as it finishes.
    tasks = [t for t in asyncio.tasks.all_tasks(_loop) if not t.done()]
    if owner is None:
        return tasks
    return [t for t in tasks if t.get_context().get(_request, None) == owner]


class _Later:
    """A handler result that isn't ready yet: the promise JS gets instead."""

    def __init__(self, promise):
        self.promise = promise


def _await_result(r, then=None):
    """r's value, after `then`; or, if r is still running once the ready
    handles have run, a _Later for it."""
    if not inspect.isawaitable(r):
        return then(r) if then is not None else r

    async def run():
        v = await r
        return then(v) if then is not None else v

    me = _request.get()
    task = asyncio.ensure_future(run(), loop=_loop)
    _step(me)
    if task.done():
        return task.result()
    return _Later(_promise_for(task, report=True))


def _keep_alive(rid):
    """Hands ctx.waitUntil a promise that settles once the request's tasks
    are done, so background work (waitUntil, streamed bodies) outlives the
    response."""
    if rid in _idle or not _pending_tasks(rid):
        return
    ctx = _cfjs.ctx()
    if ctx is None or not _cfjs.get(ctx, "waitUntil"):
        return
    promise, resolve, _ = _resolvers()
    _idle[rid] = resolve
    _cfjs.call(ctx, "waitUntil", (promise,))


# ---- entropy at the top level ----

_top_level = True
# How many host entropy calls (_cfentropy.calls(): os.urandom, getentropy,
# native packages' seeds) the top level may make, counted from when they
# were allowed, as Pyodide's ALLOWED_ENTROPY_CALLS: [n, calls() then].
_entropy_allowed = [0, 0]
_ENTROPY_MSG = (
    "Randomness is not allowed at the top level (outside of request context); "
    "generate random values inside a handler."
)


# Set while the runtime pre-imports what the app names (see _preimport).
_preimporting = [False]


def _entropy_left():
    import _cfentropy

    n, start = _entropy_allowed
    return n - (_cfentropy.calls() - start)


@contextlib.contextmanager
def _allow_entropy(n, check=True):
    """Lets the top level make `n` host entropy calls; with `check`, fails if
    it made fewer (allow_bad_entropy_calls)."""
    import _cfentropy

    saved = _entropy_allowed[:]
    _entropy_allowed[:] = [n, _cfentropy.calls()]
    try:
        yield
    finally:
        left = _entropy_left()
        _entropy_allowed[:] = saved
    if check and left > 0:
        raise RuntimeError(f"{left} unexpected leftover getentropy calls")


def _take_entropy(kind):
    if not _top_level or _preimporting[0] or _entropy_left() > 0:
        return
    if kind == "os":
        raise OSError(_ENTROPY_MSG)
    raise RuntimeError("Cannot use random outside of request context: " + _ENTROPY_MSG)


def _guard_entropy():
    import random

    real_urandom = os.urandom

    def urandom(n):
        _take_entropy("os")
        return real_urandom(n)

    os.urandom = urandom

    base = random.Random

    class _GuardedRandom(base):
        def random(self):
            _take_entropy("random")
            return super().random()

        def getrandbits(self, k):
            _take_entropy("random")
            return super().getrandbits(k)

        def randbytes(self, n):
            _take_entropy("random")
            return super().randbytes(n)

    inst = random._inst
    inst.__class__ = _GuardedRandom
    for name in dir(random):
        v = getattr(random, name)
        # random.random is the C generator's own (builtin) method.
        if isinstance(v, (types.MethodType, types.BuiltinMethodType)) and getattr(v, "__self__", None) is inst:
            setattr(random, name, getattr(inst, name))


# Modules that use entropy as they are imported, as in Pyodide's
# entropy_import_context.py: each patch wraps the module's execution at the
# top level, and the matching hook undoes it before the first request.
def _multiprocessing_process(module, run):
    # The value is an IPC auth key; there are no other processes to talk to.
    with _allow_entropy(1, check=False):
        run()


class _DeterministicNames:
    characters = "abcdefghijklmnopqrstuvwxyz0123456789_"

    def __init__(self):
        self.i = 0

    def __iter__(self):
        return self

    def __next__(self):
        self.i += 1
        n, out = self.i, []
        while n:
            n, r = divmod(n, len(self.characters))
            out.append(self.characters[r])
        return "".join(out).rjust(8, "a")


def _tempfile(module, run):
    run()
    module._orig_RandomNameSequence = module._RandomNameSequence
    module._RandomNameSequence = _DeterministicNames


def _tempfile_restore(module):
    module._RandomNameSequence = module.__dict__.pop("_orig_RandomNameSequence", module._RandomNameSequence)
    module._name_sequence = None


_exec_patches = {"multiprocessing.process": _multiprocessing_process, "tempfile": _tempfile}
# Native generators seeded while the snapshot was taken are reseeded too, so
# instances restored from one snapshot don't draw the same values. (The
# workers SDK's patches reseed numpy.random as well, when they are loaded.)
def _numpy_random_reseed(module):
    module.seed()


def _uuid_utils_reseed(module):
    module.reseed_rng()


def _openssl_reseed(module):
    # Fresh entropy reseeds OpenSSL's primary DRBG, and through it the ones
    # derived from it, before they produce anything a request sees.
    ffi, lib = module._openssl.ffi, module._openssl.lib
    lib.RAND_add(ffi.from_buffer(os.urandom(48)), 48, 48.0)


_first_request_hooks = {
    "tempfile": _tempfile_restore,
    "numpy.random": _numpy_random_reseed,
    "uuid_utils": _uuid_utils_reseed,
    "cryptography.hazmat.bindings._rust": _openssl_reseed,
}


class _PatchingLoader:
    def __init__(self, loader, patch):
        self.loader, self.patch = loader, patch

    def create_module(self, spec):
        return self.loader.create_module(spec)

    def exec_module(self, module):
        self.patch(module, lambda: self.loader.exec_module(module))

    def __getattr__(self, name):
        return getattr(self.loader, name)


class _EntropyPatchFinder:
    @staticmethod
    def find_spec(name, path=None, target=None):
        patch = _exec_patches.get(name)
        if patch is None or not _top_level:
            return None
        for finder in sys.meta_path:
            if finder is _EntropyPatchFinder:
                continue
            find = getattr(finder, "find_spec", None)
            spec = find and find(name, path, target)
            if spec is not None:
                if spec.loader is not None:
                    spec.loader = _PatchingLoader(spec.loader, patch)
                return spec
        return None


_reseeded = [False]


_started = [False]


def _startup():
    """Once, after the snapshot: as Pyodide does whether or not it restored
    one, places the vendor directories by the Worker's own compatibility
    flags (the snapshot's are build.sh's)."""
    if _started[0]:
        return
    _started[0] = True
    _setup_search_path()


def _enter_request():
    global _top_level
    _startup()
    if _top_level:
        _top_level = False
    if not _reseeded[0]:
        # The snapshot holds the generator state from build time: reseed it
        # from the host, now that randomness is allowed.
        _reseeded[0] = True
        import random

        random.seed(os.urandom(32))
        # Packages' patches registered with import_patch_manager (the workers
        # SDK's, for instance), as workerd runs them after restoring a snapshot:
        # the manager is removed first, which unblocks the calls those patches
        # blocked, and then the handlers run.
        ipm = sys.modules["_cloudflare.import_patch_manager"]
        ipm.remove_import_patch_manager()
        for handler in (*ipm.after_snapshot_handlers, *ipm.before_first_request_handlers):
            handler()
        for name, hook in _first_request_hooks.items():
            if name in sys.modules:
                hook(sys.modules[name])


# ---- the `js` module ----


class _JsModule(types.ModuleType):
    def __getattr__(self, name):
        if name.startswith("__") and name.endswith("__"):
            raise AttributeError(name)
        if not _cfjs.in_request():
            return _cfjs.lazy(name)
        if _phase == "init" and name == "setTimeout":
            return _init_set_timeout
        return _cfjs.getattr(_global, name)

    def __eq__(self, other):
        if isinstance(other, JsRef) and _cfjs.in_request() and _phase != "init":
            return _cfjs.same(_global, other)
        return self is other

    def __ne__(self, other):
        return not self.__eq__(other)

    __hash__ = types.ModuleType.__hash__

    def __dir__(self):
        if not _cfjs.in_request():
            return []
        return JsProxy.__dir__(_global)


def _init_set_timeout(cb, delay=0, *args):
    # In the global scope workerd allows no timers. A zero delay just means
    # "soon", which the event loop can do without one.
    if not delay:
        func = cb._obj if isinstance(cb, PyProxy) else cb
        if callable(func):
            _loop.call_soon(func, *args)
            return 0
    return _cfjs.call(_global, "setTimeout", (cb, delay, *args))


# ---- app, classes and dispatch ----

MAIN = "worker"
_phase = "boot"
_main = None
_classes = {}  # class name -> (kind, Python class or None for global handlers)
_do_instances = {}
_flags = None

SUPPORTED_HANDLER_NAMES = ["fetch", "alarm", "scheduled", "trace", "queue", "pubsub"]
SPECIAL_HANDLER_NAMES = ["fetch", "connect"]
SPECIAL_DO_HANDLER_NAMES = ["alarm", "webSocketMessage", "webSocketClose", "webSocketError"]


def _flag(name):
    try:
        import _cloudflare_compat_flags

        return bool(getattr(_cloudflare_compat_flags, name))
    except Exception:
        return False


class _PythonUserError(TypeError):
    """A mistake in the Worker's setup, reported to JS as a plain Error
    carrying only the message (helper.ts's PythonUserError)."""


def _format_exc(e):
    if isinstance(e, _PythonUserError):
        return str(e)
    return "PythonError: " + "".join(traceback.format_exception(e))


def relaxed_call(func, *args, **kwargs):
    try:
        sig = inspect.signature(func)
    except (TypeError, ValueError):
        return func(*args, **kwargs)
    params = list(sig.parameters.values())
    if not any(p.kind == p.VAR_POSITIONAL for p in params):
        n = sum(1 for p in params if p.kind in (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD))
        args = args[:n]
    if not any(p.kind == p.VAR_KEYWORD for p in params):
        kwargs = {k: v for k, v in kwargs.items() if k in sig.parameters}
    return func(*args, **kwargs)


def _result_to_js(r):
    # Support returning a pyodide.http.FetchResponse.
    js_response = getattr(r, "js_response", None) if not isinstance(r, JsRef) else None
    return js_response if js_response is not None else r


def _wrapper_call(relaxed, inst, prop, args):
    from workers import python_from_rpc, python_to_rpc

    method = getattr(inst, prop)
    py_args = [python_from_rpc(a) for a in args]
    result = relaxed_call(method, *py_args) if relaxed else method(*py_args)
    return _await_result(result, python_to_rpc)


def _instance(cls_name, kind, pycls, this):
    if kind == "durable-object":
        # One Python object per Durable Object. All of a Worker's objects share
        # this instance, and host/tsgen.js names each one (see tsgenClass);
        # a module with an instance per object has just the one, by class.
        key = _cfjs.get(this, "$cfObject")
        if not isinstance(key, str):
            key = cls_name
        inst = _do_instances.get(key)
        if inst is None:
            inst = _do_instances[key] = pycls(_cfjs.get(this, "ctx"), _cfjs.get(this, "env"))
        return inst
    return pycls(_cfjs.get(this, "ctx"), _cfjs.get(this, "env"))


def _call_class(cls_name, kind, pycls, prop, this, args):
    legacy = not _flag("python_no_global_handlers")
    inst = _instance(cls_name, kind, pycls, this)
    is_do = kind == "durable-object"
    known = prop in SPECIAL_HANDLER_NAMES
    known_do = is_do and prop in SPECIAL_DO_HANDLER_NAMES
    name = prop
    if (known or known_do) and legacy and callable(getattr(inst, "on_" + prop, None)):
        name = "on_" + prop
    if not callable(getattr(inst, name, None)):
        raise TypeError(f"Method {prop} does not exist")
    if (known or known_do) and prop != "fetch":
        return _await_result(relaxed_call(getattr(inst, name), *args), _result_to_js)
    if kind == "workflow" and prop == "run" and _flag("python_workflows"):
        return _await_result(relaxed_call(getattr(inst, name), *args))
    return _wrapper_call(prop in ("fetch", "test"), inst, name, args)


def _call_global_handler(prop, this, args):
    if _flag("python_no_global_handlers") and prop != "test":
        raise _PythonUserError(f'Python entrypoint "{MAIN}.py" does not define a Default class')
    name = prop if prop == "test" else "on_" + prop
    handler = getattr(_main, name, None)
    if not callable(handler):
        raise _PythonUserError(f'Python entrypoint "{MAIN}.py" does not export a handler named "{name}"')
    # A module's handlers take (event, env, ctx), as in a JS module Worker.
    # The host exports them as a class, so the runtime passes only the event
    # (the rest is undefined); env and ctx come from the instance.
    args = [*args[:1], _cfjs.get(this, "env"), _cfjs.get(this, "ctx")]
    return _await_result(relaxed_call(handler, *args), _result_to_js)


def _stats(what):
    """The instance's counts, as JSON, for debug stats (dispatch "$stats"):
    linear memory and table slots, the Python heap, and what the runtime
    holds for JS. "tracemalloc" starts tracing first (it slows every
    allocation, so it's off until asked for); "gc" collects first."""
    import gc
    import json

    if what == "tracemalloc":
        import tracemalloc

        if not tracemalloc.is_tracing():
            tracemalloc.start()
    if what == "gc":
        gc.collect()
    out = dict(_cfjs.stats())
    out.update(
        gc_count=list(gc.get_count()),
        gc_collections=[g["collections"] for g in gc.get_stats()],
        gc_objects=len(gc.get_objects()),
        callbacks=len(_callbacks),
        kept_callbacks=sum(1 for o in _callback_owner.values() if o is _KEPT),
        loose_callbacks=len(_loose_callbacks),
        finishing=len(_finishing),
        retiring=sum(len(i) for i in _retiring),
        internal_callbacks=len(_internal),
        internal_kinds=dict(collections.Counter(getattr(f, "__qualname__", "?") for f in _internal.values())),
        tasks=len(_pending_tasks()),
        all_tasks=len(asyncio.tasks.all_tasks(_loop)),
        ready=len(_loop._ready),
        scheduled=len(_loop._scheduled),
        wakers=len(_wakers),
        timers=len(_timers),
        idle=len(_idle),
        sleepers=len(_sleepers),
        do_instances=len(_do_instances),
        requests=_next_request[0],
    )
    if "tracemalloc" in sys.modules and sys.modules["tracemalloc"].is_tracing():
        out["traced_bytes"], out["traced_peak"] = sys.modules["tracemalloc"].get_traced_memory()
    return json.dumps(out)


def _dispatch(cls, method, this, args):
    if cls == "$stats":
        # Before anything else here, so that reading the stats changes none
        # of them.
        return (True, _stats(method))
    if cls == "$release":
        _release(method)
        return (True, None)
    if cls == "$drop-objects":
        # JS collected these Durable Objects (host/tsgen.js).
        for key in method.split(","):
            _do_instances.pop(key, None)
        return (True, None)
    top = _cfjs.depth() == 1
    if cls == "$callback":
        f = _internal.pop(int(method), None)
        if f is not None:
            # The loop's own callbacks: a promise settled, a timer is due.
            try:
                f(*args)
            except BaseException as e:
                if isinstance(e, (SystemExit, KeyboardInterrupt)):
                    raise
                traceback.print_exception(e)
            sys.stdout.flush()
            sys.stderr.flush()
            return (True, None)
    rid = token = None
    if not cls.startswith("$"):
        _drop_retiring()
        _next_request[0] += 1
        rid = _next_request[0]
        token = _request.set(rid)
    try:
        if cls == "$callback":
            cid = int(method)
            f = _callbacks.get(cid)
            if f is None:
                if cid >= 1 << 30:
                    # One of the loop's own, for a request that is done (a
                    # timer it no longer needs): nothing to run.
                    return (True, None)
                raise RuntimeError("this Python callback was destroyed")
            res = f(*args)
            if inspect.isawaitable(res):
                # As in Pyodide, an async callback's failure rejects the
                # promise it returns (with a PythonError) rather than throwing.
                try:
                    r = (True, _await_result(res))
                except Exception as e:
                    r = (True, _cfjs.call(_cfjs.getattr(_global, "Promise"), "reject", (_python_error(e),)))
            else:
                r = (True, res)
            if not _stepping[0]:
                _wake_ready()
        elif cls == "$continue":
            _step(None)
            r = (True, None)
        elif cls == "$init":
            _init_at_startup()
            r = (True, None)
        else:
            if top:
                _enter_request()
            r = (True, _call(cls, method, this, args))
    except BaseException as e:
        if isinstance(e, (SystemExit, KeyboardInterrupt)):
            raise
        traceback.print_exception(e)
        r = (False, _format_exc(e))
    if r[0] and isinstance(r[1], _Later):
        r = (True, r[1].promise)
    if token is not None:
        _keep_alive(rid)
        _maybe_finish(rid)
        _request.reset(token)
    if top and _loose_callbacks and not _pending_tasks():
        _drop_loose()
    sys.stdout.flush()
    sys.stderr.flush()
    return r


def _call(cls, method, this, args):
    entry = _classes.get(cls)
    if entry is None:
        raise TypeError(f"There is no '{cls}' class defined in the Python Worker's main module")
    kind, pycls = entry
    if pycls is None:
        return _call_global_handler(method, this, args)
    return _call_class(cls, kind, pycls, method, this, args)


# ---- build time ----

_app_sources = {}  # module name -> (path, source, is_package)


def _app_dirs(root, dirpath, dirnames):
    """The subdirectories of `dirpath` that hold the app's files: not hidden
    directories, __pycache__, node_modules or build output (out, out-*, gen,
    and build.sh's OUTDIR)."""
    try:
        import _cf_config

        skip = getattr(_cf_config, "APP_SKIP", None)
    except ImportError:
        skip = None
    rel = os.path.relpath(dirpath, root)
    return [
        d
        for d in dirnames
        if not d.startswith((".", "out-"))
        and d not in ("__pycache__", "node_modules", "out", "gen")
        and os.path.normpath(os.path.join(rel, d)) != skip
    ]


# The app's vendored packages: pywrangler sync's python_modules/ and, before
# the python_workers_force_new_vendor_path flag, vendor/.
VENDOR_PATH = "/session/metadata/vendor"
PYTHON_MODULES_PATH = "/session/metadata/python_modules"


def setup_python_search_path(*, LEGACY_VENDOR_PATH, PROCESS_PTH_FILES):
    """Pyodide's (workerd's setup_python_search_path.py): puts the vendor
    directories after the stdlib and before site-packages, so a vendored
    `workers` SDK replaces the built-in one while the app's own modules
    (/session/metadata, after site-packages) don't, and with
    python_process_pth_files runs python_modules/'s .pth files."""
    if VENDOR_PATH in sys.path and LEGACY_VENDOR_PATH:
        sys.path.remove(VENDOR_PATH)
    if PYTHON_MODULES_PATH in sys.path:
        sys.path.remove(PYTHON_MODULES_PATH)
    for i, path in enumerate(sys.path):
        if "site-packages" in path:
            if LEGACY_VENDOR_PATH:
                sys.path.insert(i, VENDOR_PATH)
            sys.path.insert(i, PYTHON_MODULES_PATH)
            break
    else:
        raise ValueError("No site-packages found in sys.path")
    if PROCESS_PTH_FILES:
        from site import addsitedir

        addsitedir(PYTHON_MODULES_PATH)


def _setup_search_path():
    setup_python_search_path(
        LEGACY_VENDOR_PATH=not _flag("python_workers_force_new_vendor_path"),
        PROCESS_PTH_FILES=_flag("python_process_pth_files"),
    )


def _collect_app(root="/session/metadata"):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = _app_dirs(root, dirpath, dirnames)
        if dirpath == root and "python_modules" in dirnames:
            dirnames.remove("python_modules")  # see setup_python_search_path
        rel = os.path.relpath(dirpath, root)
        pkg = [] if rel == "." else rel.split(os.sep)
        if pkg and not all(p.isidentifier() for p in pkg):
            continue
        for f in filenames:
            if not f.endswith(".py"):
                continue
            path = os.path.join(dirpath, f)
            with open(path, encoding="utf-8") as fh:
                source = fh.read()
            stem = f[:-3]
            if stem == "__init__":
                if pkg:
                    _app_sources[".".join(pkg)] = (path, source, True)
            elif stem.isidentifier():
                _app_sources[".".join([*pkg, stem])] = (path, source, False)


def _imported_names(source):
    import ast

    try:
        tree = ast.parse(source)
    except SyntaxError:
        return set()
    names = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names.update(a.name for a in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
            names.add(node.module)
            names.update(f"{node.module}.{a.name}" for a in node.names)
    return names


def _preimport(names):
    """Imports what the app may import later: after the snapshot the stdlib's
    files are gone (unless RUNTIME_IMPORTS is "all"), and importing in a
    request is slower than having imported."""
    import importlib

    for name in sorted(names):
        top = name.split(".")[0]
        if top in _app_sources or name in sys.modules:
            continue
        # Some modules print as they are imported; that output isn't the app's.
        so, se = sys.stdout, sys.stderr
        sys.stdout = sys.stderr = io.StringIO()
        # A package may draw entropy as it is imported (a uuid4 for a context
        # key, say), as Pyodide's package import patches allow. The generators
        # are reseeded before the first request; the app's own top level
        # still may not use entropy.
        _preimporting[0] = True
        try:
            importlib.import_module(name)
        except BaseException:
            pass
        finally:
            _preimporting[0] = False
            sys.stdout, sys.stderr = so, se


def _introspect(mod):
    """{name: (kind, class, methods)} for the app's module. Like Pyodide's
    introspection module, it is imported once, after the app's top level."""
    from _cloudflare import introspection_entrypoints

    return introspection_entrypoints.collect_entrypoint_classes(mod)


def _classes_json(found, mod_functions):
    """The workers.classes section: every class, and "default" for the
    Default entrypoint or the module's global handlers."""
    out = {}
    for name, (kind, _, methods) in found.items():
        ms = [m[3:] if m.startswith("on_") and m[3:] in SUPPORTED_HANDLER_NAMES else m for m in methods]
        info = {"kind": kind, "methods": sorted(set(ms))}
        out["default" if name == "Default" and kind == "entrypoint" else name] = info
    if "default" not in out:
        ms = set(SUPPORTED_HANDLER_NAMES)
        if "test" in mod_functions:
            ms.add("test")
        out["default"] = {"kind": "entrypoint", "methods": sorted(ms)}
    return out


def _ast_classes(source):
    """The classes a module defines, from its source, for an app whose import
    has to wait for startup."""
    import ast

    tree = ast.parse(source)
    bases = {"WorkerEntrypoint": "entrypoint", "DurableObject": "durable-object", "WorkflowEntrypoint": "workflow"}
    found, funcs = {}, set()
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            funcs.add(node.name)
        if not isinstance(node, ast.ClassDef):
            continue
        for b in node.bases:
            bname = b.attr if isinstance(b, ast.Attribute) else getattr(b, "id", None)
            if bname in bases:
                methods = [
                    n.name
                    for n in node.body
                    if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and not n.name.startswith("_")
                ]
                found[node.name] = (bases[bname], None, sorted(methods))
    return found, funcs


def _register(mod):
    global _main
    _main = mod
    _classes.clear()
    found = _introspect(mod)
    for name, (kind, cls, _) in found.items():
        _classes["default" if name == "Default" and kind == "entrypoint" else name] = (kind, cls)
    if "default" not in _classes:
        _classes["default"] = ("entrypoint", None)


class _SslFinder:
    """Imports _cf_ssl as ssl: the stdlib's ssl needs _ssl (OpenSSL)."""

    @staticmethod
    def find_spec(name, path=None, target=None):
        if name != "ssl":
            return None
        import importlib.machinery
        import importlib.util

        spec = importlib.machinery.PathFinder.find_spec("_cf_ssl")
        return importlib.util.spec_from_file_location("ssl", spec.origin) if spec else None


def _install_modules():
    js = _JsModule("js")
    sys.modules["js"] = js
    sys.meta_path.insert(0, _SslFinder)
    _install_os()


def _install_os():
    """What os has in Pyodide and not in WASI."""
    import errno

    import _cfvfs

    # Descriptors of the in-memory filesystem (vfs.c), which pytest's
    # fd-level capture, faulthandler and subprocess-free pipes use.
    os.dup = _cfvfs.dup
    os.dup2 = _cfvfs.dup2
    os.pipe = _cfvfs.pipe
    # WASI has no users; as in Pyodide, everything runs as uid and gid 0
    # (which os.stat reports as every file's owner), and as web_user.
    for name in ("getuid", "geteuid", "getgid", "getegid"):
        if not hasattr(os, name):
            setattr(os, name, lambda: 0)
    mask = [0]

    def umask(new, /):
        old, mask[0] = mask[0], new & 0o777
        return old

    def getlogin():
        return "web_user"

    def get_terminal_size(fd=1, /):
        return os.terminal_size((80, 24))

    def fork():
        raise OSError(errno.ENOSYS, os.strerror(errno.ENOSYS))

    def kill(pid, signal, /):
        raise OSError(errno.ENOSYS, os.strerror(errno.ENOSYS))

    def register_at_fork(*, before=None, after_in_child=None, after_in_parent=None):
        # Nothing forks.
        for f in (before, after_in_child, after_in_parent):
            if f is not None and not callable(f):
                raise TypeError("'%s' must be callable, not %s" % (f, type(f).__name__))

    for f in (umask, getlogin, get_terminal_size, fork, kill, register_at_fork):
        if not hasattr(os, f.__name__):
            f.__module__ = "posix"
            setattr(os, f.__name__, f)
    # As in workerd's Pyodide, a shared library on a writable filesystem
    # (/tmp) isn't loaded. Here none is: native modules are linked in.
    from importlib.machinery import ExtensionFileLoader

    create_module = ExtensionFileLoader.create_module

    def create_extension(self, spec):
        if _cfvfs.writable(self.path):
            raise ImportError("Can only load shared libraries from read only file systems", name=spec.name, path=self.path)
        return create_module(self, spec)

    ExtensionFileLoader.create_module = create_extension
    # Pyodide's environment.
    os.environ.update(
        {
            "USER": "web_user",
            "LOGNAME": "web_user",
            "PATH": "/",
            "PWD": "/",
            "HOME": "/session",
            "LANG": "en.UTF-8",
            "_": "./this.program",
            "LD_LIBRARY_PATH": "/usr/lib:/lib/python3.14/site-packages:/session/metadata/python_modules/lib/",
            "PYTHONHASHSEED": "111",
        }
    )


def _boot():
    """Runs at build time, inside wizer."""
    global _phase, MAIN
    try:
        import _cf_config

        MAIN = _cf_config.MAIN
    except ImportError:
        pass
    _install_modules()
    _cfjs.set_hooks(JsProxy, bytes, _implicit, _make_error, _dispatch, jsnull, _type_for)
    _collect_app()
    from _cloudflare import import_patch_manager

    import_patch_manager.install_import_patch_manager()
    _setup_search_path()
    # The SDK, and what it imports lazily.
    import http.client  # noqa: F401
    import json  # noqa: F401
    import workers  # noqa: F401

    try:
        import asgi  # noqa: F401
    except Exception:
        pass
    _guard_entropy()
    sys.meta_path.insert(0, _EntropyPatchFinder)
    names = set()
    for _, source, _ in _app_sources.values():
        names |= _imported_names(source)
    _preimport(names)

    _phase = "top-level"
    before = set(sys.modules)
    deferred = None
    try:
        mod = __import__(MAIN)
    except BaseException as e:
        deferred = e
        for name in set(sys.modules) - before:
            if name.split(".")[0] in _app_sources:
                del sys.modules[name]
    meta = {}
    if deferred is None:
        _register(mod)
        funcs = {k for k, v in vars(mod).items() if inspect.isfunction(v)}
        meta["classes"] = _classes_json(_introspect(mod), funcs)
    else:
        print(
            f"note: {MAIN}.py needs JS at its top level ({type(deferred).__name__}: {deferred}); "
            "it will be imported at startup",
            file=sys.stderr,
        )
        for frame in traceback.extract_tb(deferred.__traceback__)[-4:]:
            print(f"note:   {frame.filename}:{frame.lineno} in {frame.name}", file=sys.stderr)
        entry = _app_sources.get(MAIN)
        if entry is None:
            raise deferred
        # The SDK's files may not be there at startup, so the introspection
        # module is imported now.
        from _cloudflare import introspection_entrypoints  # noqa: F401

        found, funcs = _ast_classes(entry[1])
        meta["classes"] = _classes_json(found, funcs)
        meta["init"] = True
    _phase = "ready"
    import json as _json

    sys.path[:] = _capture_files()
    sys.path_importer_cache.clear()
    # Garbage and caches left by importing go before the snapshot is taken.
    import linecache
    import re

    linecache.clearcache()
    re.purge()
    import gc

    gc.collect()
    sys.stdout.flush()
    # build.sh reads these lines from the pre-initialization log.
    print("@@workers.classes@@ " + _json.dumps(meta["classes"]), file=sys.stderr)
    if meta.get("init"):
        print("@@workers.init@@", file=sys.stderr)
    sys.stderr.flush()


_STDLIB_ZIP = "/lib/python314.zip"
_SITE_DIRS = ("/lib/python3.14/site-packages", "/session/lib/python3.14/site-packages")


def _capture_files():
    """Copies files into the in-memory filesystem (vfs.c) that requests see
    after the snapshot, laid out as Pyodide's, and returns sys.path for
    request-time imports.

    - /session/metadata: the app's files, without hidden directories,
      __pycache__, node_modules or build output (out, out-*, gen, and
      OUTDIR).
    - RUNTIME_IMPORTS "all" (the default) adds the stdlib's zip, and
      site-packages' files (the SDK's and the packages') the snapshot didn't
      import. With python_shared_standard_library the zip is a read-only
      file that /lib/python314.zip links to, as in Pyodide; without it, a
      writable file. "site" leaves out the zip, and "none" site-packages too,
      so a module first imported during a request fails.
    - /tmp is an empty writable directory, and /home/web_user, /usr/lib and
      /proc/self are empty, as in Pyodide.
    """
    import _cfvfs

    try:
        import _cf_config
    except ImportError:
        _cf_config = None
    mode = getattr(_cf_config, "RUNTIME_IMPORTS", "all")

    def walk(root, keep, dirs=lambda root, dirpath, dirnames: [d for d in dirnames if d != "__pycache__"]):
        # `dirs` picks the subdirectories to walk into. build.sh's copy of a
        # file without comments, docstrings or long descriptions (shrink.py,
        # with LEAN) under /.build is read instead when it has one.
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = dirs(root, dirpath, dirnames)
            _cfvfs.add(dirpath, None)
            for f in filenames:
                path = os.path.join(dirpath, f)
                if keep(root, path):
                    src = "/.build" + path
                    if not os.path.exists(src):
                        src = path
                    with open(src, "rb") as fh:
                        _cfvfs.add(path, fh.read())

    def not_imported(root, path):
        if path.endswith((".pyc", ".so", ".a")):
            return False
        if not path.endswith(".py"):
            return True
        parts = os.path.relpath(path[:-3], root).split(os.sep)
        if parts[-1] == "__init__":
            parts.pop()
        return ".".join(parts) not in sys.modules

    for d in ("/home/web_user", "/usr/lib", "/proc/self", "/lib/python3.14/lib-dynload", *_SITE_DIRS):
        _cfvfs.add(d, None)
    walk("/session/metadata", lambda root, path: True, _app_dirs)
    path = list(sys.path)
    if mode in ("site", "all"):
        for d in _SITE_DIRS:
            walk(d, not_imported)
    else:
        path = [p for p in path if p not in _SITE_DIRS]
    if mode == "all":
        with open(_STDLIB_ZIP, "rb") as fh:
            data = fh.read()
        if _flag("python_shared_standard_library"):
            _cfvfs.add("/lib/stdlib-zip/python314.zip", data)
            _cfvfs.symlink(_STDLIB_ZIP, "/lib/stdlib-zip/python314.zip")
        else:
            _cfvfs.add(_STDLIB_ZIP, data, True)
    else:
        path.remove(_STDLIB_ZIP)
    return path


def _init_at_startup():
    """"$init": imports an app whose top level needs JS, in the global scope."""
    global _phase
    _startup()
    if _main is not None:
        return
    _phase = "init"
    try:
        mod = __import__(MAIN)
        # The top level may have scheduled work with a zero timeout.
        if _loop._ready:
            _run(asyncio.sleep(0))
    finally:
        _phase = "ready"
    _register(mod)
