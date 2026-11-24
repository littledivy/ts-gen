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


class JsNull:
    """Pyodide's JsNull: JS null, as its one instance `jsnull`."""

    __slots__ = ()
    __module__ = "pyodide.ffi"

    def __repr__(self):
        return "jsnull"

    def __bool__(self):
        return False


jsnull = JsNull()


def _bigint_op(name):
    op = getattr(int, name)

    def f(self, *args):
        r = op(self, *args)
        return JsBigInt(r) if type(r) is int else r

    f.__name__ = name
    return f


class JsBigInt(int):
    """Pyodide's JsBigInt: a JS bigint, an int that goes back to JS as a
    bigint."""

    __slots__ = ()
    __module__ = "pyodide.ffi"

    for _n in ("__add__", "__radd__", "__sub__", "__rsub__", "__mul__", "__rmul__", "__floordiv__", "__rfloordiv__",
               "__mod__", "__rmod__", "__pow__", "__rpow__", "__neg__", "__pos__", "__abs__", "__and__", "__rand__",
               "__or__", "__ror__", "__xor__", "__rxor__", "__lshift__", "__rlshift__", "__rshift__", "__rrshift__",
               "__invert__"):
        locals()[_n] = _bigint_op(_n)
    del _n


# JS type flags, as host/generic.js traits() computes them.
_T_CALL, _T_THEN, _T_ARRAY, _T_ITER, _T_AITER, _T_BUF = 1, 2, 4, 8, 16, 32
_T_GET, _T_LEN, _T_TYPED, _T_ERROR, _T_NEXT = 64, 128, 256, 512, 1024
_T_SET, _T_HAS, _T_INCLUDES, _T_DELETE, _T_PROMISE = 2048, 4096, 8192, 16384, 32768
_T_MAP = _T_GET | _T_LEN | _T_ITER
_T_SEQ = _T_ARRAY | _T_TYPED


class _Flagged(type):
    """The metaclass of pyodide.ffi's JsProxy classes: isinstance asks what
    the JS value can do (its type flags), as Pyodide's do."""

    def __instancecheck__(cls, x):
        check = cls.__dict__.get("_cf_check")
        if check is None:
            return type.__instancecheck__(cls, x)
        return check(x)

    def __subclasscheck__(cls, c):
        check = cls.__dict__.get("_cf_check_type")
        if check is None:
            return type.__subclasscheck__(cls, c)
        return check(c)


def _flag_class(name, test):
    def check(x):
        return isinstance(x, JsRef) and test(type(x)._cf_traits)

    def check_type(c):
        return isinstance(c, type) and issubclass(c, JsRef) and test(getattr(c, "_cf_traits", 0))

    return _Flagged(name, (), {"__slots__": (), "__module__": "pyodide.ffi",
                               "_cf_check": staticmethod(check), "_cf_check_type": staticmethod(check_type)})


class JsProxy(metaclass=_Flagged):
    """Pyodide's JsProxy: every JS value in Python is one (their classes are
    made per set of type flags, by _type_for)."""

    __slots__ = ()
    __module__ = "pyodide.ffi"

    @staticmethod
    def _cf_check(x):
        return isinstance(x, (JsRef, JsException))

    @staticmethod
    def _cf_check_type(c):
        return isinstance(c, type) and (issubclass(c, JsRef) or type.__subclasscheck__(JsException, c))


JsArray = _flag_class("JsArray", lambda t: t & _T_SEQ)
JsTypedArray = _flag_class("JsTypedArray", lambda t: t & _T_TYPED)
JsMap = _flag_class("JsMap", lambda t: t & _T_MAP == _T_MAP and not t & _T_SEQ)
JsMutableMap = _flag_class("JsMutableMap", lambda t: t & (_T_MAP | _T_SET | _T_DELETE) == _T_MAP | _T_SET | _T_DELETE
                           and not t & _T_SEQ)
JsBuffer = _flag_class("JsBuffer", lambda t: t & _T_BUF)
JsCallable = _flag_class("JsCallable", lambda t: t & _T_CALL)
JsIterable = _flag_class("JsIterable", lambda t: t & _T_ITER)
JsAsyncIterable = _flag_class("JsAsyncIterable", lambda t: t & _T_AITER)
JsIterator = _flag_class("JsIterator", lambda t: t & _T_NEXT)
JsAsyncIterator = _flag_class("JsAsyncIterator", lambda t: t & _T_NEXT and t & _T_AITER)
JsGenerator = _flag_class("JsGenerator", lambda t: t & _T_NEXT and t & _T_ITER and not t & _T_SEQ)
JsAsyncGenerator = _flag_class("JsAsyncGenerator", lambda t: t & _T_NEXT and t & _T_AITER)
JsPromise = _flag_class("JsPromise", lambda t: t & _T_THEN)


class JsException(JsProxy, Exception):
    """A JS exception, as Pyodide's: a JsProxy of the thrown value (its
    `js_error`) that Python can raise. str() is the JS String(error)."""

    __module__ = "pyodide.ffi"

    def __init__(self, error=None, message=None):
        if isinstance(error, JsRef):
            super().__init__(error)
            self.__dict__["js_error"] = error
        else:
            msg = error if message is None else message
            super().__init__(msg)
            self.__dict__["js_error"] = None
            self.__dict__["_cf_message"] = msg

    def __getattr__(self, name):
        if name.startswith("__") and name.endswith("__"):
            raise AttributeError(name)
        e = self.__dict__.get("js_error")
        if e is None:
            if name == "message":
                return self.__dict__.get("_cf_message")
            if name == "name":
                return "Error"
            raise AttributeError(name)
        # The JsProxy's own methods (to_py, as_object_map...), then JS's.
        return getattr(e, name)

    @property
    def typeof(self):
        e = self.__dict__.get("js_error")
        return "object" if e is None else _cfjs.type_of(e)

    @property
    def js_id(self):
        e = self.__dict__.get("js_error")
        return id(self) if e is None else e.js_id


class ConversionError(Exception):
    """Pyodide's: to_js found a value it can't convert."""

    __module__ = "pyodide.ffi"


# The last Python exception raised to JS (as PythonError), by the key on
# the error: that one coming back raises the original again, as in Pyodide
# (which keeps it as sys.last_exc). An older one is a JsException.
_py_errors = {}
_next_py_error = [0]


def _make_error(message, value):
    if isinstance(value, JsRef):
        try:
            k = _cfjs.get(value, "_cf_exc")
        except BaseException:
            k = None
        if isinstance(k, int):
            e = _py_errors.get(k)
            if e is not None:
                return e
        return JsException(value)
    if isinstance(value, JsException):
        return value
    return JsException(message)


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


def _out(v):
    """A JS value as Python code sees it, as Pyodide converts one: an Error
    is a JsException and a promise a PyodideFuture."""
    if isinstance(v, JsRef):
        t = type(v)._cf_traits
        if t & _T_ERROR:
            return JsException(v)
        if t & _T_PROMISE:
            return PyodideFuture(v)
    return v


_js_ids = [None, 0]  # a JS WeakMap of the objects js_id numbered, and the last number


class _JsBase:
    """What every JsProxy can do. _type_for copies this and the classes
    below into each JsProxy class."""

    _cf_traits = 0

    def __getattr__(self, name):
        if name.startswith("__") and name.endswith("__"):
            raise AttributeError(name)
        return _out(_cfjs.getattr(self, _unkeyword(name)))

    def __setattr__(self, name, value):
        _cfjs.set(self, _unkeyword(name), _owned(value))

    def __delattr__(self, name):
        _cfjs.call(_cfjs.getattr(_global, "Reflect"), "deleteProperty", (self, _unkeyword(name)))

    @property
    def typeof(self):
        return _cfjs.type_of(self)

    @property
    def js_id(self):
        if _js_ids[0] is None:
            _js_ids[0] = _cfjs.construct(_cfjs.getattr(_global, "WeakMap"), ())
        m = _js_ids[0]
        i = _cfjs.call(m, "get", (self,))
        if i is None:
            _js_ids[1] += 1
            i = _js_ids[1]
            _cfjs.call(m, "set", (self, i))
        return i

    def __eq__(self, other):
        if isinstance(other, JsRef):
            return _cfjs.same(self, other)
        return NotImplemented

    def __ne__(self, other):
        r = self.__eq__(other)
        return r if r is NotImplemented else not r

    __hash__ = None

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


def _js_args(args, kwargs, borrowed):
    a = [_in(x, borrowed) for x in args]
    if kwargs:
        o = _cfjs.new_object()
        for k, v in kwargs.items():
            _cfjs.set(o, k, _in(v, borrowed))
        a.append(o)
    return a


def _after_call(r, borrowed):
    """Pyodide's end of a call: the PyProxies made for its arguments are
    destroyed, once the promise settles if it returned one."""
    out = _out(r)
    if borrowed:
        if isinstance(out, PyodideFuture):
            out.add_done_callback(lambda _: _destroy_borrowed(borrowed))
        elif isinstance(r, JsRef) and type(r)._cf_traits & _T_THEN:
            # A thenable that isn't a Promise (an RPC call's result).
            _await_promise(r).add_done_callback(lambda _: _destroy_borrowed(borrowed))
        else:
            _destroy_borrowed(borrowed)
    return out


class _JsCallableBag:
    def __call__(self, *args, **kwargs):
        borrowed = []
        try:
            a = _js_args(args, kwargs, borrowed)
            bound = self._cf_bound
            r = _cfjs.call(bound[0], bound[1], a) if bound is not None else _cfjs.invoke(self, a)
        except BaseException:
            _destroy_borrowed(borrowed)
            raise
        return _after_call(r, borrowed)

    def new(self, *args, **kwargs):
        borrowed = []
        try:
            r = _cfjs.construct(self, _js_args(args, kwargs, borrowed))
        except BaseException:
            _destroy_borrowed(borrowed)
            raise
        return _after_call(r, borrowed)

    def call_relaxed(self, *args, **kwargs):
        return self(*args, **kwargs)


class _JsIterableBag:
    def __iter__(self):
        t = type(self)._cf_traits
        if t & _T_SEQ:
            for i in range(_cfjs.length(self)):
                yield _out(_cfjs.get_index(self, i))
            return
        it = _cfjs.call(self, "keys", ()) if t & _T_MAP == _T_MAP else _cfjs.iterator(self, False)
        while True:
            step = _cfjs.call(it, "next", ())
            if _cfjs.get(step, "done"):
                return
            yield _out(_cfjs.get(step, "value"))


class _JsIteratorBag:
    def __iter__(self):
        return self

    def __next__(self):
        step = _cfjs.call(self, "next", ())
        if _cfjs.get(step, "done"):
            raise StopIteration(_out(_cfjs.get(step, "value")))
        return _out(_cfjs.get(step, "value"))

    def send(self, value):
        step = _cfjs.call(self, "next", (_owned(value),))
        if _cfjs.get(step, "done"):
            raise StopIteration(_out(_cfjs.get(step, "value")))
        return _out(_cfjs.get(step, "value"))


class _JsAsyncIterableBag:
    def __aiter__(self):
        return _aiter(self)


class _JsLengthBag:
    def __len__(self):
        n = _cfjs.get(self, "size")
        if not isinstance(n, int):
            n = _cfjs.get(self, "length")
        return n

    def __bool__(self):
        return len(self) != 0


class _JsSeqBag:
    """Array-likes: arrays and typed arrays, as Pyodide's JsArray."""

    def _cf_getitem(self, key):
        if isinstance(key, slice):
            start, stop, step = key.indices(_cfjs.length(self))
            if step != 1:
                return _cfjs.new_array([self._cf_getitem(i) for i in range(start, stop, step)])
            return _cfjs.call(self, "slice", (start, stop))
        if not isinstance(key, int):
            raise TypeError("list indices must be integers or slices, not " + type(key).__name__)
        n = _cfjs.length(self)
        i = key + n if key < 0 else key
        if not 0 <= i < n:
            raise IndexError(key)
        return _out(_cfjs.get_index(self, i))

    def __setitem__(self, key, value):
        n = _cfjs.length(self)
        i = key + n if key < 0 else key
        if not 0 <= i < n:
            raise IndexError(key)
        _cfjs.set(self, str(i), _owned(value))

    def __delitem__(self, key):
        n = _cfjs.length(self)
        i = key + n if key < 0 else key
        if not 0 <= i < n:
            raise IndexError(key)
        _cfjs.call(self, "splice", (i, 1))

    def __contains__(self, x):
        return bool(_cfjs.call(self, "includes", (_owned(x),)))

    def __reversed__(self):
        for i in range(_cfjs.length(self) - 1, -1, -1):
            yield _out(_cfjs.get_index(self, i))

    def index(self, value, start=0, stop=None):
        n = _cfjs.length(self)
        stop = n if stop is None else stop
        for i in range(start, min(stop, n)):
            if _cfjs.get_index(self, i) == value:
                return i
        raise ValueError(f"{value!r} is not in list")

    def count(self, value):
        return sum(1 for i in range(_cfjs.length(self)) if _cfjs.get_index(self, i) == value)


class _JsArrayBag:
    def append(self, value):
        _cfjs.call(self, "push", (_owned(value),))

    def extend(self, values):
        for v in values:
            _cfjs.call(self, "push", (_owned(v),))

    def __iadd__(self, values):
        self.extend(values)
        return self

    def insert(self, i, value):
        _cfjs.call(self, "splice", (i, 0, _owned(value)))

    def pop(self, i=-1):
        n = _cfjs.length(self)
        j = i + n if i < 0 else i
        if not 0 <= j < n:
            raise IndexError("pop index out of range")
        r = _cfjs.call(self, "splice", (j, 1))
        return _out(_cfjs.get_index(r, 0))

    def remove(self, value):
        _cfjs.call(self, "splice", (self.index(value), 1))


class _JsGetBag:
    """Objects with get(): Map, Headers, URLSearchParams..."""

    def _cf_getitem(self, key):
        v = _cfjs.call(self, "get", (_owned(key),))
        if v is None and (not type(self)._cf_traits & _T_HAS or not _cfjs.call(self, "has", (_owned(key),))):
            raise KeyError(key)
        return _out(v)


class _JsHasBag:
    def __contains__(self, key):
        return bool(_cfjs.call(self, "has", (_owned(key),)))


class _JsSetBag:
    def __setitem__(self, key, value):
        _cfjs.call(self, "set", (_owned(key), _owned(value)))


class _JsDeleteBag:
    def __delitem__(self, key):
        if not _cfjs.call(self, "delete", (_owned(key),)):
            raise KeyError(key)


class _JsMapBag:
    """Pyodide's JsMap methods, over a JS Map's."""

    def get(self, key, default=None):
        k = _owned(key)
        v = _cfjs.call(self, "get", (k,))
        if v is None and not _cfjs.call(self, "has", (k,)):
            return default
        return _out(v)

    def items(self):
        return [(_out(_cfjs.get_index(p, 0)), _out(_cfjs.get_index(p, 1))) for p in _JsIterableBag.__iter__(
            _cfjs.call(_cfjs.getattr(_global, "Array"), "from", (self,)))]

    def values(self):
        return [_out(v) for v in _JsIterableBag.__iter__(
            _cfjs.call(_cfjs.getattr(_global, "Array"), "from", (_cfjs.call(self, "values", ()),)))]

    def pop(self, key, *default):
        k = _owned(key)
        if not _cfjs.call(self, "has", (k,)):
            if default:
                return default[0]
            raise KeyError(key)
        v = _out(_cfjs.call(self, "get", (k,)))
        _cfjs.call(self, "delete", (k,))
        return v

    def update(self, other=(), **kwargs):
        items = other.items() if hasattr(other, "items") else other
        for k, v in items:
            _cfjs.call(self, "set", (_owned(k), _owned(v)))
        for k, v in kwargs.items():
            _cfjs.call(self, "set", (k, _owned(v)))

    def setdefault(self, key, default=None):
        k = _owned(key)
        if not _cfjs.call(self, "has", (k,)):
            _cfjs.call(self, "set", (k, _owned(default)))
            return default
        return _out(_cfjs.call(self, "get", (k,)))


# memoryview formats for the typed arrays, as Pyodide's.
_TYPED_FORMATS = {"Int8Array": "b", "Uint8Array": "B", "Uint8ClampedArray": "B", "Int16Array": "h", "Uint16Array": "H",
                  "Int32Array": "i", "Uint32Array": "I", "Float16Array": "e", "Float32Array": "f",
                  "Float64Array": "d", "BigInt64Array": "q", "BigUint64Array": "Q"}


class _JsBufferBag:
    """ArrayBuffer, typed arrays and DataView, as Pyodide's JsBuffer: it
    keeps its JS identity, and to_bytes, to_py and friends copy its bytes."""

    def to_bytes(self):
        return _cfjs.to_bytes(self)

    def __bytes__(self):
        return _cfjs.to_bytes(self)

    def to_memoryview(self):
        m = memoryview(_cfjs.to_bytes(self))
        fmt = _TYPED_FORMATS.get(_ctor_name(self)) if type(self)._cf_traits & _T_TYPED else None
        return m.cast(fmt) if fmt and fmt != "B" else m

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
        n = _cfjs.get(self, "byteLength")
        if len(data) != n:
            # Pyodide's message, lengths in its order.
            raise ValueError(f"cannot assign to TypedArray of length {len(data)} from buffer of length {n}")
        _cfjs.write_bytes(self, 0, data)

    def assign_to(self, to):
        target = memoryview(to).cast("B")
        data = _cfjs.to_bytes(self)
        if len(data) != len(target):
            raise ValueError(f"cannot assign from TypedArray of length {len(data)} to buffer of length {len(target)}")
        target[:] = data


class _JsAwaitableBag:
    def __await__(self):
        # Awaited by Python code: what it gets is converted as a promise's.
        return (yield from _await_promise(self, None, True))


_types = {}
_BAG_SKIP = frozenset({"__dict__", "__weakref__", "__module__", "__qualname__", "__doc__", "__slots__", "__firstlineno__",
                       "__static_attributes__"})


def _type_for(traits):
    """The JsProxy class for a value with these type flags, as Pyodide makes
    one per set of flags."""
    t = _types.get(traits)
    if t is None:
        bags = [_JsBase]
        if traits & _T_CALL:
            bags.append(_JsCallableBag)
        if traits & _T_THEN:
            bags.append(_JsAwaitableBag)
        if traits & _T_ITER:
            bags.append(_JsIterableBag)
        if traits & _T_NEXT:
            bags.append(_JsIteratorBag)
        if traits & _T_AITER:
            bags.append(_JsAsyncIterableBag)
        if traits & _T_LEN:
            bags.append(_JsLengthBag)
        if traits & _T_SEQ:
            bags.append(_JsSeqBag)
            if traits & _T_ARRAY:
                bags.append(_JsArrayBag)
        else:
            if traits & _T_GET:
                bags.append(_JsGetBag)
            if traits & _T_HAS:
                bags.append(_JsHasBag)
            if traits & _T_SET:
                bags.append(_JsSetBag)
            if traits & _T_DELETE:
                bags.append(_JsDeleteBag)
            if traits & _T_MAP == _T_MAP:
                bags.append(_JsMapBag)
        if traits & _T_BUF:
            bags.append(_JsBufferBag)
        ns = {}
        for b in bags:
            ns.update((k, v) for k, v in vars(b).items() if k not in _BAG_SKIP)
        ns["_cf_traits"] = traits
        t = _types[traits] = _cfjs.new_type(ns)
    return t


async def _aiter(o):
    it = _cfjs.iterator(o, True)
    while True:
        step = await _cfjs.call(it, "next", ())
        if _cfjs.get(step, "done"):
            return
        yield _out(_cfjs.get(step, "value"))


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
    if not isinstance(x, JsRef):
        return x
    if depth == 0:
        return x
    if type(x)._cf_traits & _T_BUF:
        return _JsBufferBag.to_memoryview(x)
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
            _py_objects.pop(cid, None)
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


# ---- PyProxy: Python objects JS holds ----
#
# As Pyodide's: a Python value that isn't a number, string, bool or None
# reaches JS as a PyProxy (host/generic.js), whose every operation calls
# back here synchronously (dispatchSync "$py", see _py_op). A PyProxy made
# for a call's argument is borrowed: it is destroyed once the call returns
# (or the promise it returned settles). One stored on a JS object, returned
# to JS, or made by create_proxy is owned, and lives until JS destroys it or
# drops it (FinalizationRegistry, then dispatch "$release").

_py_objects = {}  # id -> [object, mode, PyProxy for a once-callable]
_PY_ONCE, _PY_THIS, _PY_DOUBLE = 1, 2, 4
_BORROWED = ("This borrowed proxy was automatically destroyed at the end of a function call. "
             "Try using create_proxy or create_once_callable.")
_DEBUG_HINT = "\nFor more information about the cause of this error, use `pyodide.setDebug(true)`"
_ONCE_USED = "OnceProxy can only be called once"

# PyProxy flags, as host/generic.js reads them.
_P_CALL, _P_AWAIT, _P_ITER, _P_NEXT, _P_LEN, _P_GET, _P_SET, _P_HAS = 1, 2, 4, 8, 16, 32, 64, 128
_P_BUF, _P_DICT, _P_SEQ, _P_MSEQ, _P_GEN, _P_AITER, _P_ANEXT = 256, 512, 1024, 2048, 4096, 8192, 16384
_py_flags_by_type = {}


def _py_flags(o):
    t = type(o)
    f = _py_flags_by_type.get(t)
    if f is None:
        f = 0
        for bit, name in ((_P_CALL, "__call__"), (_P_AWAIT, "__await__"), (_P_ITER, "__iter__"), (_P_NEXT, "__next__"),
                          (_P_LEN, "__len__"), (_P_GET, "__getitem__"), (_P_SET, "__setitem__"),
                          (_P_HAS, "__contains__"), (_P_BUF, "__buffer__"), (_P_AITER, "__aiter__"),
                          (_P_ANEXT, "__anext__")):
            # On the class's MRO, not hasattr(t, ...), which also finds the
            # metaclass's (every class has type.__call__).
            if any(name in vars(c) for c in t.__mro__):
                f |= bit
        if issubclass(t, dict):
            f |= _P_DICT
        if issubclass(t, collections.abc.Sequence):
            f |= _P_SEQ
        if issubclass(t, collections.abc.MutableSequence):
            f |= _P_MSEQ
        if issubclass(t, types.GeneratorType):
            f |= _P_GEN
        _py_flags_by_type[t] = f
    return f


def _new_pyproxy(obj, mode=0):
    cid = _next_callback[0]
    _next_callback[0] += 1
    entry = [obj, mode, None]
    _py_objects[cid] = entry
    ref = _cfjs.pyproxy(cid, _py_flags(obj))
    if mode & _PY_ONCE:
        entry[2] = ref
    return cid, ref


def _is_primitive(x):
    return x is None or x is jsnull or isinstance(x, (bool, int, float, str, JsRef))


def _in(x, borrowed):
    """x as a JS call argument: itself if JS has the same value, else a
    PyProxy, borrowed (listed in `borrowed`) or, with borrowed None, owned."""
    if _is_primitive(x):
        return x
    if isinstance(x, JsException):
        e = x.__dict__.get("js_error")
        if e is not None:
            return e
    elif isinstance(x, PyodideFuture) and x._cf_ref is not None:
        return x._cf_ref
    cid, ref = _new_pyproxy(x)
    # An awaitable is owned even as an argument: JS takes it up later (a
    # promise's resolution reads its then() in a later job).
    if borrowed is not None and not inspect.isawaitable(x):
        borrowed.append((cid, ref))
    return ref


def _owned(x):
    return _in(x, None)


def _destroy_borrowed(borrowed):
    for cid, ref in borrowed:
        if _py_objects.pop(cid, None) is not None:
            _cfjs.py_destroy(ref, _BORROWED + _DEBUG_HINT)
    borrowed.clear()


def _from_pyproxy(cid, destroyed, ref):
    """A PyProxy coming back from JS: the object it holds. (cfjs.c)"""
    if destroyed:
        raise _make_error(destroyed, _js_error(destroyed))
    entry = _py_objects.get(cid)
    if entry is None:
        raise _make_error("Object has already been destroyed", _js_error("Object has already been destroyed" + _DEBUG_HINT))
    if entry[1] & _PY_DOUBLE:
        return ref
    return entry[0]


def _py_type_name(o):
    t = type(o)
    return t.__qualname__ if t.__module__ == "builtins" else f"{t.__module__}.{t.__qualname__}"


def _js_object(**fields):
    o = _cfjs.new_object()
    for k, v in fields.items():
        _cfjs.set(o, k, v)
    return o


def _py_step(it, arg):
    try:
        v = it.send(arg) if arg is not None and hasattr(it, "send") else next(it)
    except StopIteration as e:
        return _js_object(done=True, value=_owned(e.value))
    return _js_object(done=False, value=_owned(v))


async def _py_astep(it):
    try:
        v = await anext(it)
    except StopAsyncIteration:
        return _js_object(done=True, value=None)
    return _js_object(done=False, value=_owned(v))


def _py_promise(aw):
    """A promise for an awaitable JS awaits. Its task first runs from the
    loop's own callback, not this synchronous call, so it can block
    (run_sync), as in Pyodide."""
    me = _request.get()
    p = _promise_for(aw)
    _, cb = _once(lambda *_: _step(me))
    _cfjs.call(_cfjs.call(_cfjs.getattr(_global, "Promise"), "resolve", ()), "then", (cb,))
    return p


def _py_op(op, args):
    cid = args[0]
    if op == "destroy":
        _py_objects.pop(cid, None)
        return None
    entry = _py_objects.get(cid)
    if entry is None:
        raise RuntimeError("Object has already been destroyed")
    obj = entry[0]
    if op == "call":
        this, kw = args[1], args[2]
        a = [_out(v) for v in args[3:]]
        if entry[1] & _PY_THIS:
            a.insert(0, _out(this))
        kwargs = {k: _out(_cfjs.get(kw, k)) for k in _cfjs.keys(kw)} if isinstance(kw, JsRef) else {}
        if entry[1] & _PY_ONCE:
            del _py_objects[cid]
            _cfjs.py_destroy(entry[2], _ONCE_USED)
        r = obj(*a, **kwargs)
        if not _stepping[0]:
            _wake_ready()
        return _owned(r)
    # A dict's string keys are its properties, as in Pyodide, before its
    # attributes.
    if op == "get":
        key = args[1]
        if isinstance(obj, dict) and key in obj:
            return _owned(obj[key])
        try:
            return _owned(getattr(obj, key))
        except AttributeError:
            return None
    if op == "set":
        if isinstance(obj, dict):
            obj[args[1]] = _out(args[2])
        else:
            setattr(obj, args[1], _out(args[2]))
        return None
    if op == "has":
        return isinstance(obj, dict) and args[1] in obj or hasattr(obj, args[1])
    if op == "del":
        if isinstance(obj, dict) and args[1] in obj:
            del obj[args[1]]
        else:
            delattr(obj, args[1])
        return None
    if op == "keys":
        if isinstance(obj, dict):
            keys = [k for k in obj if isinstance(k, str)]
        elif isinstance(obj, collections.abc.Sequence) and not isinstance(obj, (str, bytes)):
            keys = [str(i) for i in range(len(obj))]
        else:
            keys = [k for k in dir(obj) if isinstance(k, str)]
        return _cfjs.new_array(keys)
    if op == "type":
        return _py_type_name(obj)
    if op == "str":
        return str(obj)
    if op == "copy":
        return _new_pyproxy(obj)[1]
    if op == "tojs":
        depth, create, dict_conv, default_conv = args[1:5]
        r = to_js(obj, depth=-1 if depth is None else depth, create_pyproxies=create is not False,
                  dict_converter=dict_conv, default_converter=default_conv)
        return _owned(r)
    if op == "promise":
        return _py_promise(obj)
    if op == "iter":
        return _owned(iter(obj))
    if op == "next":
        return _py_step(obj, args[1] if len(args) > 1 else None)
    if op == "len":
        return len(obj)
    if op == "getitem":
        try:
            return _owned(obj[_out(args[1])])
        except (KeyError, IndexError):
            return None
    if op == "setitem":
        obj[_out(args[1])] = _out(args[2])
        return None
    if op == "delitem":
        del obj[_out(args[1])]
        return None
    if op == "contains":
        return _out(args[1]) in obj
    if op == "buffer":
        m = memoryview(obj)
        data = _cfjs.construct(_cfjs.getattr(_global, "Uint8Array"), (m.tobytes(),))
        return _js_object(data=data, nbytes=m.nbytes, readonly=m.readonly, format=m.format, itemsize=m.itemsize,
                          ndim=m.ndim, shape=_cfjs.new_array(list(m.shape)), strides=_cfjs.new_array(list(m.strides)),
                          c_contiguous=m.c_contiguous, f_contiguous=m.f_contiguous,
                          release=_owned(lambda: None))
    if op == "aiter":
        return _owned(aiter(obj))
    if op == "anext":
        return _py_promise(_py_astep(obj))
    raise TypeError(f"unknown PyProxy operation {op}")


class PyProxy(metaclass=_Flagged):
    """Pyodide's PyProxy, as Python sees one: what create_proxy returns."""

    __slots__ = ()
    __module__ = "pyodide.ffi"

    @staticmethod
    def _cf_check(x):
        return isinstance(x, JsRef) and x.__dict__.get("_cf_pyproxy", False)


JsDoubleProxy = PyProxy


class PyodideFuture(asyncio.Future):
    """Pyodide's PyodideFuture: what a JS promise is in Python. It follows
    the promise from when something waits on it."""

    __module__ = "pyodide.webloop"

    def __init__(self, js=None):
        super().__init__(loop=_loop)
        self._cf_ref = js
        self._cf_armed = js is None

    def _cf_arm(self):
        if not self._cf_armed:
            self._cf_armed = True
            _await_promise(self._cf_ref, self)

    def add_done_callback(self, fn, *, context=None):
        self._cf_arm()
        return super().add_done_callback(fn, context=context)

    # Asking about it starts following the promise too (run_sync polls done()).
    def done(self):
        self._cf_arm()
        return super().done()

    def result(self):
        self._cf_arm()
        return super().result()

    def exception(self):
        self._cf_arm()
        return super().exception()

    def then(self, onfulfilled=None, onrejected=None):
        result = PyodideFuture()

        def settle(f):
            try:
                if f.cancelled():
                    result.cancel()
                    return
                e = f.exception()
                if e is None:
                    r = f.result() if onfulfilled is None else onfulfilled(f.result())
                elif onrejected is not None:
                    r = onrejected(e)
                else:
                    result.set_exception(e)
                    return
            except BaseException as x:
                result.set_exception(x)
                return
            if inspect.isawaitable(r):
                asyncio.ensure_future(r, loop=_loop).add_done_callback(lambda g: _chain(g, result))
            else:
                result.set_result(r)

        self.add_done_callback(settle)
        return result

    def catch(self, onrejected):
        return self.then(None, onrejected)

    def finally_(self, onfinally):
        def ok(v):
            onfinally()
            return v

        def err(e):
            onfinally()
            raise e

        return self.then(ok, err)

    def syncify(self):
        return run_sync(self)


def _chain(g, result):
    if g.cancelled():
        result.cancel()
    elif g.exception() is not None:
        result.set_exception(g.exception())
    else:
        result.set_result(g.result())


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


def _python_error(e):
    """The JS Error for Python exception `e`, shaped as Pyodide's PythonError
    where JS code looks: `e instanceof Error`, `e.constructor.name` is
    "PythonError" and `e.type` is the exception's class name (the SDK's
    workflows.js reads these). Coming back to Python, it raises `e` again."""
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
    _next_py_error[0] += 1
    k = _next_py_error[0]
    _py_errors.clear()
    _py_errors[k] = e
    _cfjs.call(obj, "defineProperty", (err, "_cf_exc", {"value": k}))
    return err


def _implicit(o):
    """Python -> JS for what cfjs.c doesn't convert itself, for the
    runtime's own calls through _cfjs (code calling JS through a JsProxy
    gets Pyodide's conversions, _in)."""
    if isinstance(o, JsException):
        e = o.__dict__.get("js_error")
        if e is not None:
            return e
    if isinstance(o, PyodideFuture) and o._cf_ref is not None:
        return o._cf_ref
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


def to_js(obj, depth=-1, pyproxies=None, create_pyproxies=True, dict_converter=None, default_converter=None, **_):
    cache = {}
    # The objects cacheit keys by id(), kept alive so the ids aren't reused.
    keep = []

    def proxy(x):
        if not create_pyproxies:
            raise ConversionError("No conversion known for x.")
        ref = _owned(x)
        if pyproxies is not None:
            pyproxies.append(ref)
        return ref

    def conv(x, d):
        if _is_primitive(x):
            return x
        if isinstance(x, (JsException, PyodideFuture)):
            return _owned(x)
        k = id(x)
        if k in cache:
            return cache[k]
        if d == 0:
            return proxy(x)
        if isinstance(x, dict):
            pairs = [[conv(a, d - 1), conv(b, d - 1)] for a, b in x.items()]
            if dict_converter is not None:
                r = dict_converter(_cfjs.new_array(pairs))
            elif all(isinstance(p[0], str) for p in pairs):
                r = _cfjs.call(_cfjs.getattr(_global, "Object"), "fromEntries", (_cfjs.new_array(pairs),))
            else:
                r = _cfjs.construct(_cfjs.getattr(_global, "Map"), (_cfjs.new_array(pairs),))
            cache[k] = r
            return r
        if isinstance(x, (list, tuple)):
            r = cache[k] = _cfjs.new_array([conv(v, d - 1) for v in x])
            return r
        if isinstance(x, (set, frozenset)):
            r = cache[k] = _cfjs.construct(_cfjs.getattr(_global, "Set"), (_cfjs.new_array([conv(v, d - 1) for v in x]),))
            return r
        if isinstance(x, (bytes, bytearray, memoryview)):
            return _cfjs.construct(_cfjs.getattr(_global, "Uint8Array"), (bytes(x),))
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
        import datetime

        if isinstance(x, datetime.datetime):
            return _implicit(x)
        return proxy(x)

    return conv(obj, depth)


def create_proxy(obj, *, capture_this=False, roundtrip=True):
    """A PyProxy JS owns until it destroys it; in Python, a JsProxy of it
    (Pyodide's JsDoubleProxy), with roundtrip."""
    mode = (_PY_THIS if capture_this else 0) | (_PY_DOUBLE if roundtrip else 0)
    _, ref = _new_pyproxy(obj, mode)
    ref.__dict__["_cf_pyproxy"] = True
    return ref


def create_once_callable(obj, *, _may_syncify=False):
    _, ref = _new_pyproxy(obj, _PY_ONCE | _PY_DOUBLE)
    ref.__dict__["_cf_pyproxy"] = True
    return ref


def destroy_proxies(proxies):
    for p in proxies:
        p.destroy()


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


def _await_promise(promise, fut=None, out=None):
    """A Future for a JS promise or thenable, settled from its callbacks:
    `fut` (a PyodideFuture), or a new one. With out (the default for a
    PyodideFuture), it gets the value as Python code sees it."""
    loop = _loop
    if out is None:
        out = fut is not None
    if fut is None:
        fut = loop.create_future()
    owner = _request.get()
    p = _cfjs.call(_cfjs.getattr(_global, "Promise"), "resolve", (promise,))
    ids = []

    def settle(ok, value):
        for i in ids:
            _internal.pop(i, None)
        if not fut.cancelled():
            if ok:
                fut.set_result(_out(value) if out else value)
            else:
                # A rejection is a JsException, as Pyodide's futures have
                # it: only a synchronous throw raises a PythonError's
                # original exception again.
                if out:
                    fut.set_exception(JsException(value) if isinstance(value, JsRef) else JsException(_error_message(value)))
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


_SYNC_ENTRY = ("Cannot stack switch because the Python entrypoint was a synchronous function. "
               "Use pyFunc.callPromising() to fix.")


def run_sync(aw):
    """Pyodide's run_sync: blocks (suspending the instance) until `aw` is done."""
    if not _cfjs.can_suspend():
        raise RuntimeError(_SYNC_ENTRY if _cfjs.in_request() else "No suspender")
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


def _enter_request():
    global _top_level
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
        return _JsBase.__dir__(_global)


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
        pyproxies=len(_py_objects),
        pyproxy_kinds=dict(collections.Counter(type(e[0]).__qualname__ for e in _py_objects.values()).most_common(8)),
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
    if cls == "$py":
        # A PyProxy operation (dispatchSync): a failure is the PythonError
        # JS throws.
        try:
            return (True, _py_op(method, args))
        except BaseException as e:
            if isinstance(e, (SystemExit, KeyboardInterrupt)):
                raise
            return (False, _python_error(e))
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


class _MemoryFinder:
    """Imports the app's own modules from the sources read before the
    snapshot."""

    @classmethod
    def find_spec(cls, name, path=None, target=None):
        entry = _app_sources.get(name)
        if entry is None:
            return None
        import importlib.util
        file, source, is_pkg = entry
        spec = importlib.util.spec_from_loader(name, _MemoryLoader(file, source), is_package=is_pkg)
        spec.origin = file
        spec.has_location = True
        if is_pkg:
            spec.submodule_search_locations = [os.path.dirname(file)]
        return spec


class _MemoryLoader:
    def __init__(self, file, source):
        self.file = file
        self.source = source

    def create_module(self, spec):
        return None

    def exec_module(self, module):
        module.__file__ = self.file
        exec(compile(self.source, self.file, "exec", dont_inherit=True), module.__dict__)

    def get_source(self, name):
        return self.source


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


# The app's vendored packages (pywrangler sync's python_modules/), which, as
# in Pyodide, are importable ahead of the runtime's own packages, so a
# vendored `workers` SDK replaces the built-in one.
_VENDOR_DIR = "/app/python_modules"


def _add_vendor_dir():
    """Puts python_modules/ first on sys.path, running its .pth files."""
    if not os.path.isdir(_VENDOR_DIR):
        return
    import site

    site.addsitedir(_VENDOR_DIR)
    sys.path.remove(_VENDOR_DIR)
    sys.path.insert(0, _VENDOR_DIR)


def _collect_app(root="/app"):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = _app_dirs(root, dirpath, dirnames)
        if dirpath == root and "python_modules" in dirnames:
            dirnames.remove("python_modules")  # see _add_vendor_dir
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
    # WASI has no dup(), which pytest's default fd-level capture and its
    # faulthandler plugin need; sys-level capture works. Arguments given to
    # pytest still override these.
    os.environ.setdefault("PYTEST_ADDOPTS", "--capture=sys -p no:faulthandler")
    # WASI has no users; as in Pyodide, everything runs as uid and gid 0
    # (which os.stat reports as every file's owner).
    for name in ("getuid", "geteuid", "getgid", "getegid"):
        if not hasattr(os, name):
            setattr(os, name, lambda: 0)


def _boot():
    """Runs at build time, inside wizer."""
    global _phase, MAIN
    try:
        import _cf_config

        MAIN = _cf_config.MAIN
    except ImportError:
        pass
    _install_modules()
    _cfjs.set_hooks(_type_for(0), bytes, _implicit, _make_error, _dispatch, jsnull, _type_for)
    _cfjs.set_pyproxy_hook(_from_pyproxy, JsBigInt)
    sys.meta_path.insert(0, _MemoryFinder)
    _collect_app()
    from _cloudflare import import_patch_manager

    import_patch_manager.install_import_patch_manager()
    _add_vendor_dir()
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


# What the stdlib keeps out of the in-memory filesystem: tests, GUI and
# tooling that can't run in a Worker.
_STDLIB_SKIP = frozenset({"test", "tests", "idlelib", "tkinter", "turtledemo", "ensurepip", "__pycache__", "site-packages", "venv"})


def _capture_files():
    """Copies files into the in-memory filesystem (vfs.c) that requests see
    after the snapshot, and returns sys.path for request-time imports.

    - The app directory's files, at /app and at /session/metadata (as in
      Pyodide), without hidden directories, __pycache__, node_modules or
      build output (out, out-*, gen, and OUTDIR). /tmp is an empty writable
      directory.
    - RUNTIME_IMPORTS "site" (the default) adds /site, the SDK's and the
      packages' files, leaving out modules the snapshot already imported.
    - "all" also adds the stdlib's sources the same way. "none" adds
      neither, so a module first imported during a request fails.
    """
    import _cfvfs

    try:
        import _cf_config
    except ImportError:
        _cf_config = None
    mode = getattr(_cf_config, "RUNTIME_IMPORTS", "site")

    def skipping(names):
        return lambda root, dirpath, dirnames: [d for d in dirnames if d not in names]

    def walk(root, keep, dirs=skipping({"__pycache__"}), shrunk=None):
        # `dirs` picks the subdirectories to walk into. `shrunk` is build.sh's
        # copy of `root` without comments, docstrings or long descriptions
        # (shrink.py), read instead when it has the file.
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = dirs(root, dirpath, dirnames)
            for f in filenames:
                path = os.path.join(dirpath, f)
                if keep(root, path):
                    src = path
                    if shrunk is not None:
                        alt = os.path.join(shrunk, os.path.relpath(path, root))
                        if os.path.exists(alt):
                            src = alt
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

    _cfvfs.add("/app", None)
    walk("/app", lambda root, path: True, _app_dirs)
    _cfvfs.alias("/session/metadata", "/app")
    path = [_VENDOR_DIR] if os.path.isdir(_VENDOR_DIR) else []
    if mode in ("site", "all"):
        walk("/site", not_imported, shrunk="/.build/site")
        path.append("/site")
    if mode == "all":
        walk("/lib/python3.14", lambda root, p: p.endswith(".py") and not_imported(root, p), skipping(_STDLIB_SKIP), "/.build/lib")
        path.insert(0, "/lib/python3.14")
    return path


def _init_at_startup():
    """"$init": imports an app whose top level needs JS, in the global scope."""
    global _phase
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
