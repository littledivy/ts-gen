"""The FFI probe ffi-diff/run.sh runs on Pyodide and on this Worker: each
case prints one line, its result or the exception it raised, so the two
outputs diff line by line."""

import sys
import traceback

import js
from js import JSON, Array, Map, Object, Promise, Reflect, Uint8Array
from pyodide.ffi import (
    JsArray,
    JsBuffer,
    JsCallable,
    JsException,
    JsIterable,
    JsMap,
    JsPromise,
    JsProxy,
    create_once_callable,
    create_proxy,
    destroy_proxies,
    to_js,
)

out = []


def show(v):
    """A stable spelling of v: no addresses."""
    if isinstance(v, JsProxy):
        try:
            s = str(v)
        except Exception as e:
            s = f"<str failed {type(e).__name__}>"
        return f"JsProxy({js_typeof(v)}, {s!r})"
    if isinstance(v, (list, tuple)):
        inner = ", ".join(show(x) for x in v)
        return f"[{inner}]" if isinstance(v, list) else f"({inner})"
    if isinstance(v, dict):
        return "{" + ", ".join(f"{show(k)}: {show(x)}" for k, x in v.items()) + "}"
    if isinstance(v, memoryview):
        return f"memoryview({v.tolist()})"
    return f"{type(v).__name__}:{v!r}"


def js_typeof(v):
    try:
        return v.typeof
    except Exception:
        return "?"


def case(name, f):
    try:
        r = f()
        line = show(r)
    except BaseException as e:
        line = f"!{type(e).__name__}: {e}"
    out.append(f"{name}: {line}")


async def acase(name, f):
    try:
        r = await f()
        line = show(r)
    except BaseException as e:
        line = f"!{type(e).__name__}: {e}"
    out.append(f"{name}: {line}")


# Workers forbid eval and `new Function`, so JS-side helpers are built from
# built-ins: Reflect.apply calls a function inline.
def call(f, *args):
    return Reflect.apply(f, None, to_js(list(args), create_pyproxies=True))


def run_sync_cases():
    # ---- JS -> Python ----
    case("int", lambda: JSON.parse("1"))
    case("float", lambda: JSON.parse("1.5"))
    case("big-float", lambda: JSON.parse("9007199254740993"))
    case("neg-zero", lambda: JSON.parse("-0"))
    case("bigint", lambda: js.BigInt("12345678901234567890"))
    case("str", lambda: JSON.parse('"héllo"'))
    case("true", lambda: JSON.parse("true"))
    case("null", lambda: JSON.parse("null"))
    case("undefined", lambda: Object.new().missing)
    case("nan", lambda: JSON.parse("1") * float("nan"))
    case("array-type", lambda: type(JSON.parse("[1,2]")).__name__)
    case("object-type", lambda: type(JSON.parse('{"a":1}')).__name__)
    case("map-type", lambda: type(Map.new()).__name__)
    case("buffer-type", lambda: type(Uint8Array.new(2)).__name__)
    case("func-type", lambda: type(Reflect.apply).__name__)
    case("promise-type", lambda: type(Promise.resolve(1)).__name__)
    case("isinstance-array", lambda: [isinstance(JSON.parse("[1]"), c) for c in (JsArray, JsMap, JsBuffer, JsCallable, JsIterable, JsPromise, JsProxy)])
    case("isinstance-map", lambda: [isinstance(Map.new(), c) for c in (JsArray, JsMap, JsBuffer, JsCallable, JsIterable, JsPromise, JsProxy)])
    case("isinstance-buffer", lambda: [isinstance(Uint8Array.new(1), c) for c in (JsArray, JsMap, JsBuffer, JsCallable, JsIterable, JsPromise, JsProxy)])
    case("isinstance-object", lambda: [isinstance(Object.new(), c) for c in (JsArray, JsMap, JsBuffer, JsCallable, JsIterable, JsPromise, JsProxy)])
    case("isinstance-func", lambda: [isinstance(Reflect.apply, c) for c in (JsArray, JsMap, JsBuffer, JsCallable, JsIterable, JsPromise, JsProxy)])
    case("isinstance-promise", lambda: [isinstance(Promise.resolve(1), c) for c in (JsArray, JsMap, JsBuffer, JsCallable, JsIterable, JsPromise, JsProxy)])
    case("typeof", lambda: [x.typeof for x in (Object.new(), Reflect.apply, JSON.parse("[1]"), Map.new())])
    case("identity-global", lambda: js.Object is js.Object)
    case("identity-same", lambda: (lambda o: (Reflect.get(Reflect.apply(Array.of, None, to_js([o])), 0) is o))(Object.new()))
    case("eq-same", lambda: (lambda o: Reflect.get(Reflect.apply(Array.of, None, to_js([o])), 0) == o)(Object.new()))
    case("js-id-stable", lambda: (lambda o: o.js_id == Reflect.get(Reflect.apply(Array.of, None, to_js([o])), 0).js_id)(Object.new()))
    case("hash-eq", lambda: (lambda o: hash(o) == hash(Reflect.get(Reflect.apply(Array.of, None, to_js([o])), 0)))(Object.new()))
    case("bool-empty-array", lambda: bool(JSON.parse("[]")))
    case("bool-array", lambda: bool(JSON.parse("[0]")))
    case("bool-empty-object", lambda: bool(Object.new()))
    case("bool-map", lambda: bool(Map.new()))
    case("len-array", lambda: len(JSON.parse("[1,2,3]")))
    case("len-object", lambda: len(Object.new()))
    case("len-map", lambda: len(Map.new(to_js([["a", 1]]))))
    case("index-array", lambda: JSON.parse("[1,2,3]")[1])
    case("index-neg", lambda: JSON.parse("[1,2,3]")[-1])
    case("index-oob", lambda: JSON.parse("[1,2,3]")[5])
    case("slice-array", lambda: JSON.parse("[1,2,3]")[1:])
    case("index-object", lambda: JSON.parse('{"a":1}')["a"])
    case("index-object-missing", lambda: JSON.parse('{"a":1}')["b"])
    case("index-map", lambda: Map.new(to_js([["a", 1]]))["a"])
    case("index-map-missing", lambda: Map.new(to_js([["a", 1]]))["b"])
    case("attr-missing", lambda: Object.new().nope)
    case("attr-set", lambda: (lambda o: (setattr(o, "x", 5), o.x)[1])(Object.new()))
    case("attr-del", lambda: (lambda o: (setattr(o, "x", 5), delattr(o, "x"), o.x)[2])(Object.new()))
    case("contains-array", lambda: 2 in JSON.parse("[1,2,3]"))
    case("contains-object", lambda: "a" in JSON.parse('{"a":1}'))
    case("contains-map", lambda: "a" in Map.new(to_js([["a", 1]])))
    case("iter-array", lambda: list(JSON.parse("[1,2,3]")))
    case("iter-object", lambda: list(JSON.parse('{"a":1,"b":2}')))
    case("iter-map", lambda: list(Map.new(to_js([["a", 1], ["b", 2]]))))
    case("dir-has", lambda: "push" in dir(JSON.parse("[]")))
    case("array-append", lambda: (lambda a: (a.append(4), a.to_py())[1])(JSON.parse("[1]")))
    case("array-extend", lambda: (lambda a: (a.extend([2, 3]), a.to_py())[1])(JSON.parse("[1]")))
    case("array-pop", lambda: (lambda a: (a.pop(), a.to_py()))(JSON.parse("[1,2]")))
    case("array-index", lambda: JSON.parse("[1,2,3]").index(2))
    case("array-count", lambda: JSON.parse("[1,2,2]").count(2))
    case("array-reverse", lambda: (lambda a: (a.reverse(), a.to_py())[1])(JSON.parse("[1,2]")))
    case("array-setitem", lambda: (lambda a: (a.__setitem__(0, 9), a.to_py())[1])(JSON.parse("[1,2]")))
    case("array-delitem", lambda: (lambda a: (a.__delitem__(0), a.to_py())[1])(JSON.parse("[1,2]")))
    case("map-get", lambda: Map.new(to_js([["a", 1]])).get("a"))
    case("map-get-default", lambda: Map.new(to_js([["a", 1]])).get("z", 7))
    case("map-keys", lambda: list(Map.new(to_js([["a", 1]])).keys()))
    case("map-items", lambda: list(Map.new(to_js([["a", 1]])).items()))
    case("map-setitem", lambda: (lambda m: (m.__setitem__("b", 2), m.get("b"))[1])(Map.new()))
    case("object-map", lambda: dict(JSON.parse('{"a":1}').as_object_map()))
    case("object-entries", lambda: list(JSON.parse('{"a":1}').object_entries()))
    case("object-keys", lambda: list(JSON.parse('{"a":1}').object_keys()))
    case("object-values", lambda: list(JSON.parse('{"a":1}').object_values()))
    case("new", lambda: Array.new(3).length)
    case("call-method", lambda: JSON.parse("[3,1,2]").sort().to_py())
    case("bind", lambda: Array.of.bind(None)(1, 2).to_py() if hasattr(Array.of, "bind") else "no-bind")
    case("kwargs", lambda: Array.of(1, x=2))
    # ---- to_py ----
    case("to_py-nested", lambda: JSON.parse('{"a":[1,{"b":2}],"c":null}').to_py())
    case("to_py-depth1", lambda: JSON.parse('{"a":[1,{"b":2}]}').to_py(depth=1))
    case("to_py-map", lambda: Map.new(to_js([["a", 1]])).to_py())
    case("to_py-set", lambda: js.Set.new(to_js([1, 2])).to_py())
    case("to_py-buffer", lambda: Uint8Array.new(to_js([1, 2])).to_py())
    case("to_py-date", lambda: type(js.Date.new(0).to_py()).__name__)
    case("to_py-default", lambda: JSON.parse('{"a":[1]}').to_py(default_converter=lambda v, c, cache: "conv"))
    # ---- Python -> JS ----
    case("to_js-list", lambda: JSON.stringify(to_js([1, "a", None, True])))
    case("to_js-dict-type", lambda: Object.prototype.toString.call(to_js({"a": 1})))
    case("to_js-dict-get", lambda: to_js({"a": 1}).get("a"))
    case("to_js-dict-attr", lambda: to_js({"a": 1}).a)
    case("to_js-dict-stringify", lambda: JSON.stringify(to_js({"a": 1})))
    case("to_js-dict_converter", lambda: JSON.stringify(to_js({"a": {"b": 1}}, dict_converter=Object.fromEntries)))
    case("to_js-tuple", lambda: JSON.stringify(to_js((1, 2))))
    case("to_js-set", lambda: Object.prototype.toString.call(to_js({1, 2})))
    case("to_js-bytes", lambda: Object.prototype.toString.call(to_js(b"ab")))
    case("to_js-bytearray", lambda: Object.prototype.toString.call(to_js(bytearray(b"ab"))))
    case("to_js-memoryview", lambda: Object.prototype.toString.call(to_js(memoryview(b"ab"))))
    case("to_js-int-big", lambda: Reflect.apply(js.String, None, to_js([2**60])))
    case("to_js-int-small", lambda: Reflect.apply(js.String, None, to_js([2**31])))
    case("to_js-depth", lambda: Object.prototype.toString.call(Reflect.get(to_js([[1]], depth=1), 0)))
    case("to_js-create_pyproxies-false", lambda: to_js([object()], create_pyproxies=False))
    case("to_js-default_converter", lambda: JSON.stringify(to_js([object()], default_converter=lambda v, c, cache: "x")))
    case("to_js-jsproxy", lambda: (lambda o: to_js(o) is o)(Object.new()))
    case("implicit-list-tostring", lambda: Object.prototype.toString.call([1, 2]))
    case("implicit-dict-tostring", lambda: Object.prototype.toString.call({"a": 1}))
    case("implicit-str", lambda: Reflect.apply(js.String, None, to_js(["s"])))
    case("implicit-none", lambda: Reflect.apply(js.String, None, to_js([None])))
    case("implicit-float", lambda: Reflect.apply(js.String, None, to_js([1.5])))
    case("implicit-bool", lambda: Reflect.apply(js.String, None, to_js([True])))
    case("pyproxy-type", lambda: Reflect.apply(js.String, None, [[1, 2]]))
    case("pyproxy-roundtrip", lambda: (lambda o: Reflect.get(Array.of(o), 0) is o)([1]))
    case("pyproxy-dict-roundtrip", lambda: (lambda o: Reflect.get(Array.of(o), 0) is o)({"a": 1}))
    case("pyproxy-obj-roundtrip", lambda: (lambda o: Reflect.get(Array.of(o), 0) is o)(object.__new__(type("K", (), {}))))
    # ---- callbacks, inline ----
    case("callback-inline", lambda: Reflect.apply(lambda x: x * 2, None, to_js([21])))
    case("callback-proxy-inline", lambda: Reflect.apply(create_proxy(lambda x: x + 1), None, to_js([1])))
    case("callback-map", lambda: JSON.parse("[1,2,3]").map(lambda x, *_: x * 10).to_py())
    case("callback-arg-identity", lambda: (lambda o: Reflect.apply(lambda x: x is o, None, [o]))([1]))
    case("callback-jsarg-type", lambda: Reflect.apply(lambda x: type(x).__name__, None, to_js([Object.new()])))
    case("callback-raises", lambda: Reflect.apply(lambda: 1 / 0, None, to_js([])))
    case("callback-returns-list", lambda: Object.prototype.toString.call(Reflect.apply(lambda: [1], None, to_js([]))))
    case("callback-returns-dict", lambda: Object.prototype.toString.call(Reflect.apply(lambda: {"a": 1}, None, to_js([]))))
    case("callback-async-returns", lambda: Object.prototype.toString.call(Reflect.apply(create_proxy(_coro), None, to_js([]))))
    case("callback-nested", lambda: Reflect.apply(lambda: Reflect.apply(lambda: 5, None, to_js([])), None, to_js([])))
    case("callback-this", lambda: Reflect.apply(lambda *a: len(a), Object.new(), to_js([1, 2])))
    # ---- proxy lifetimes ----
    p = create_proxy(lambda: "alive")
    case("proxy-call", lambda: Reflect.apply(p, None, to_js([])))
    case("proxy-destroy", lambda: p.destroy())
    case("proxy-after-destroy", lambda: Reflect.apply(p, None, to_js([])))
    case("proxy-destroy-twice", lambda: p.destroy())
    o = create_once_callable(lambda: "once")
    case("once-1", lambda: Reflect.apply(o, None, to_js([])))
    case("once-2", lambda: Reflect.apply(o, None, to_js([])))
    case("create_proxy-type", lambda: type(create_proxy(lambda: 1)).__name__)
    case("create_proxy-roundtrip", lambda: (lambda f: Reflect.get(Array.of(create_proxy(f)), 0) is f)(lambda: 1))
    case("create_proxy-nonfunc", lambda: Object.prototype.toString.call(create_proxy([1, 2])))
    case("create_proxy-capture_this", lambda: Reflect.apply(create_proxy(lambda this, a: (type(this).__name__, a), capture_this=True), Object.new(), to_js([3])))
    case("destroy_proxies", lambda: destroy_proxies(to_js([create_proxy(lambda: 1)])))
    # ---- errors ----
    case("js-throw", lambda: JSON.parse("{"))
    case("js-throw-type", lambda: _exc(lambda: JSON.parse("{")))
    case("js-throw-name", lambda: _exc(lambda: JSON.parse("{")).js_error.name)
    case("js-throw-message", lambda: _exc(lambda: JSON.parse("{")).js_error.message)
    case("js-throw-isinstance", lambda: isinstance(_exc(lambda: JSON.parse("{")), JsException))
    case("js-throw-args", lambda: _exc(lambda: JSON.parse("{")).args)
    case("js-throw-typeerror", lambda: Reflect.construct(1))
    case("js-error-attr-name", lambda: _exc(lambda: Object.new().x.y).js_error.name)
    case("python-error-to-js", lambda: _py_err_name())
    case("python-error-reraise", lambda: _reraise())


def _exc(f):
    try:
        f()
    except BaseException as e:
        return e
    return None


def _py_err_name():
    e = _exc(lambda: Reflect.apply(lambda: (_ for _ in ()).throw(ValueError("boom")), None, to_js([])))
    return (type(e).__name__, str(e).splitlines()[-1] if str(e) else "")


def _reraise():
    class Mine(Exception):
        pass

    e = _exc(lambda: Reflect.apply(lambda: (_ for _ in ()).throw(Mine("x")), None, to_js([])))
    return type(e).__name__


async def _coro():
    return 7


async def run_async_cases():
    await acase("await-promise", lambda: Promise.resolve(5))
    await acase("await-reject", lambda: Promise.reject(js.Error.new("no")))
    await acase("await-async-callback", lambda: Reflect.apply(create_proxy(_coro), None, to_js([])))
    await acase("then-py", lambda: Promise.resolve(2).then(lambda x: x * 3))
    await acase("then-py-raises", lambda: Promise.resolve(2).then(lambda x: 1 / 0))
    await acase("then-chain", lambda: Promise.resolve(2).then(lambda x: x + 1).then(lambda x: x + 1))
    await acase("catch-py", lambda: Promise.reject(js.Error.new("e")).catch(lambda e: e.message))

    async def rejected_message():
        try:
            await Promise.resolve(1).then(lambda x: (_ for _ in ()).throw(KeyError("k")))
        except BaseException as e:
            return [type(e).__name__, str(e).splitlines()[-1]]

    await acase("then-py-raises-type", rejected_message)


def run_buffer_cases():
    case("buf-to_bytes", lambda: Uint8Array.new(to_js([1, 2, 3])).to_bytes())
    case("buf-to_memoryview", lambda: Uint8Array.new(to_js([1, 2])).to_memoryview())
    case("buf-to_string", lambda: Uint8Array.new(to_js([104, 105])).to_string())
    case("buf-to_string-enc", lambda: Uint8Array.new(to_js([104, 105])).to_string("ascii"))
    case("buf-assign", lambda: (lambda b: (b.assign(b"xy"), b.to_bytes())[1])(Uint8Array.new(2)))
    case("buf-assign_to", lambda: (lambda ba: (Uint8Array.new(to_js([7, 8])).assign_to(ba), bytes(ba))[1])(bytearray(2)))
    case("buf-assign-size", lambda: Uint8Array.new(2).assign(b"xyz"))
    case("buf-len", lambda: len(Uint8Array.new(4)))
    case("buf-index", lambda: Uint8Array.new(to_js([5, 6]))[1])
    case("buf-float64", lambda: js.Float64Array.new(to_js([1.5])).to_py())
    case("buf-arraybuffer-type", lambda: type(js.ArrayBuffer.new(2)).__name__)
    case("buf-arraybuffer-to_bytes", lambda: js.ArrayBuffer.new(2).to_bytes())
    case("buf-dataview", lambda: type(js.DataView.new(js.ArrayBuffer.new(2))).__name__)


def run_resolver_cases():
    import socket

    case("gethostbyname-ip", lambda: socket.gethostbyname("1.2.3.4"))
    case("gethostbyname-localhost", lambda: socket.gethostbyname("localhost"))
    case("gethostbyname-name", lambda: socket.gethostbyname("example.com"))
    case("gethostbyname_ex-ip", lambda: socket.gethostbyname_ex("1.2.3.4"))
    case("gethostbyname_ex-name", lambda: socket.gethostbyname_ex("example.com"))
    case("gethostbyaddr", lambda: socket.gethostbyaddr("1.2.3.4"))
    case("getaddrinfo-ip", lambda: socket.getaddrinfo("1.2.3.4", 80))
    case("getaddrinfo-name", lambda: socket.getaddrinfo("example.com", 443, type=socket.SOCK_STREAM))
    case("getaddrinfo-none", lambda: socket.getaddrinfo(None, 80))
    case("gethostname", lambda: socket.gethostname())
    case("getfqdn", lambda: socket.getfqdn())
    case("inet_aton", lambda: socket.inet_aton("1.2.3.4"))
    case("getnameinfo", lambda: socket.getnameinfo(("1.2.3.4", 80), 0))
    case("has_ipv6", lambda: socket.has_ipv6)

def run_extra_cases():
    from pyodide.ffi import run_sync, can_run_sync

    case("sync-run_sync", lambda: Reflect.apply(lambda: run_sync(Promise.resolve(1)), None, to_js([])))
    case("sync-can_run_sync", lambda: Reflect.apply(lambda: can_run_sync(), None, to_js([])))
    case("implicit-bytes", lambda: Object.prototype.toString.call(b"ab"))
    case("implicit-tuple", lambda: Object.prototype.toString.call((1,)))
    case("implicit-set", lambda: Object.prototype.toString.call({1}))
    case("implicit-int-big", lambda: Reflect.apply(js.String, None, [2**70]))
    case("implicit-int-big-typeof", lambda: Reflect.apply(Reflect.get(js.globalThis, "Number"), None, [2**70]))
    case("pyproxy-string", lambda: Reflect.apply(js.String, None, [{"a": [1]}]))
    case("result-pyproxy-type", lambda: Reflect.get(Reflect.apply(lambda: [1, 2], None, []), "type"))
    case("result-pyproxy-length", lambda: Reflect.get(Reflect.apply(lambda: [1, 2], None, []), "length"))
    case("result-pyproxy-toString", lambda: Reflect.apply(js.String, None, [Reflect.apply(lambda: {"a": 1}, None, [])]))
    case("result-pyproxy-get", lambda: Reflect.apply(Reflect.get(Reflect.apply(lambda: {"a": 5}, None, []), "get"), Reflect.apply(lambda: {"a": 5}, None, []), to_js(["a"])))
    case("result-pyproxy-has", lambda: Reflect.has(Reflect.apply(lambda: _K(), None, []), "x"))
    case("result-pyproxy-attr", lambda: Reflect.get(Reflect.apply(lambda: _K(), None, []), "x"))
    case("result-pyproxy-missing-attr", lambda: Reflect.get(Reflect.apply(lambda: _K(), None, []), "nope"))
    case("result-pyproxy-keys", lambda: [k for k in Reflect.ownKeys(Reflect.apply(lambda: _K(), None, [])) if not str(k).startswith("_")][:5])
    case("result-pyproxy-tojs", lambda: JSON.stringify(Reflect.apply(Reflect.get(Reflect.apply(lambda: {"a": [1]}, None, []), "toJs"), Reflect.apply(lambda: {"a": [1]}, None, []), to_js([]))))
    case("result-pyproxy-func-type", lambda: Reflect.get(Reflect.apply(lambda: (lambda: 1), None, []), "type"))
    case("result-pyproxy-typeof-func", lambda: Reflect.apply(lambda: (lambda: 1), None, []).typeof)
    case("result-pyproxy-typeof-list", lambda: Reflect.apply(lambda: [1], None, []).typeof)
    case("result-pyproxy-back", lambda: (lambda o: Reflect.apply(lambda: o, None, []) is o)([1]))
    case("result-func-back-type", lambda: type(Reflect.apply(lambda: (lambda: 1), None, [])).__name__)
    case("setattr-list-back", lambda: (lambda o, l: (setattr(o, "v", l), o.v is l)[1])(Object.new(), [1]))
    case("setattr-list-tostring", lambda: (lambda o: (setattr(o, "v", [1]), Object.prototype.toString.call(o.v))[1])(Object.new()))
    case("kwargs-type", lambda: JSON.stringify(Array.of(1, a=2, b="x")))
    case("kwargs-list", lambda: Object.prototype.toString.call(Reflect.get(Reflect.get(Array.of(a=[1]), 0), "a")))
    case("jsnull-bool", lambda: bool(JSON.parse("null")))
    case("jsnull-repr", lambda: repr(JSON.parse("null")))
    case("jsnull-is", lambda: JSON.parse("null") is js.JSON.parse("null"))
    case("jsnull-module", lambda: type(JSON.parse("null")).__module__)
    case("bigint-type-mro", lambda: [c.__name__ for c in type(js.BigInt("5")).__mro__])
    case("bigint-small", lambda: js.BigInt("5"))
    case("bigint-arith", lambda: js.BigInt("5") + 1)
    case("future-mro", lambda: [c.__name__ for c in type(Promise.resolve(1)).__mro__])
    case("future-done", lambda: Promise.resolve(1).done())
    case("future-js", lambda: hasattr(Promise.resolve(1), "then"))
    case("jsproxy-mro-array", lambda: [c.__name__ for c in type(JSON.parse("[]")).__mro__])
    case("jsproxy-mro-map", lambda: [c.__name__ for c in type(Map.new()).__mro__])
    case("jsproxy-mro-buffer", lambda: [c.__name__ for c in type(Uint8Array.new(1)).__mro__])
    case("jsproxy-mro-func", lambda: [c.__name__ for c in type(Reflect.apply).__mro__])
    case("jsproxy-mro-object", lambda: [c.__name__ for c in type(Object.new()).__mro__])
    case("jsproxy-mro-error", lambda: [c.__name__ for c in type(js.Error.new("x")).__mro__])
    case("jsproxy-mro-iterator", lambda: [c.__name__ for c in type(JSON.parse("[1]").values()).__mro__])
    case("jsproxy-mro-set", lambda: [c.__name__ for c in type(js.Set.new()).__mro__])
    case("jsproxy-mro-generator-like", lambda: [c.__name__ for c in type(Map.new().entries()).__mro__])
    case("jsproxy-repr-object", lambda: repr(Object.new()))
    case("jsproxy-repr-array", lambda: repr(JSON.parse("[1,2]")))
    case("jsproxy-repr-func", lambda: repr(Array.of)[:40])
    case("jsproxy-str-error", lambda: str(js.Error.new("m")))
    case("error-new-type", lambda: type(js.Error.new("m")).__name__)
    case("error-raise", lambda: _raise_js(js.Error.new("m")))
    case("iterator-next", lambda: next(JSON.parse("[7]").values()))
    case("iterator-list", lambda: list(Map.new(to_js([["a", 1]])).entries()))
    case("iter-set", lambda: sorted(js.Set.new(to_js([2, 1]))))
    case("array-insert", lambda: (lambda a: (a.insert(0, 9), a.to_py())[1] if hasattr(a, "insert") else "no-insert")(JSON.parse("[1]")))
    case("array-iadd", lambda: (lambda a: (a.__iadd__([2]), a.to_py())[1] if hasattr(a, "__iadd__") else "no")(JSON.parse("[1]")))
    case("array-reversed", lambda: list(reversed(JSON.parse("[1,2]"))))
    case("array-eq", lambda: JSON.parse("[1]") == [1])
    case("array-to_py-type", lambda: type(JSON.parse("[1]").to_py()).__name__)
    case("object-to_py-type", lambda: type(JSON.parse("{}").to_py()).__name__)
    case("map-len", lambda: len(Map.new(to_js([[1, 2]]))))
    case("map-values", lambda: list(Map.new(to_js([["a", 1]])).values()))
    case("map-pop", lambda: (lambda m: (m.pop("a"), m.size))(Map.new(to_js([["a", 1]]))) if hasattr(Map.new(), "pop") else "no-pop")
    case("map-delitem", lambda: (lambda m: (m.__delitem__("a"), m.size)[1])(Map.new(to_js([["a", 1]]))))
    case("map-update", lambda: (lambda m: (m.update({"b": 2}), m.get("b"))[1] if hasattr(m, "update") else "no-update")(Map.new()))
    case("typed-index-set", lambda: (lambda b: (b.__setitem__(0, 7), b[0])[1])(Uint8Array.new(1)))
    case("typed-format", lambda: Uint8Array.new(1).to_memoryview().format)
    case("typed-f32-format", lambda: js.Float32Array.new(1).to_memoryview().format)
    case("typed-i16-tobytes", lambda: js.Int16Array.new(to_js([258])).to_bytes())
    case("buffer-to_py-type", lambda: type(Uint8Array.new(1).to_py()).__name__)
    case("arraybuffer-to_py", lambda: js.ArrayBuffer.new(1).to_py())
    case("call-none-arg", lambda: Reflect.apply(js.String, None, [None]))
    case("call-jsnull-arg", lambda: Reflect.apply(js.String, None, [JSON.parse("null")]))
    case("undefined-in-array", lambda: Array.of(None).to_py())
    case("pyproxy-dict-prop", lambda: Reflect.get({"contentType": "t"}, "contentType"))
    case("pyproxy-dict-stringify", lambda: JSON.stringify({"a": 1}))
    case("pyproxy-list-stringify", lambda: JSON.stringify([1, "a"]))
    case("pyproxy-dict-keys", lambda: Object.keys({"a": 1}).to_py())


class _K:
    x = 3


def _raise_js(e):
    try:
        raise e
    except BaseException as x:
        return [type(x).__name__, str(x)]



async def run():
    out.clear()
    run_sync_cases()
    run_buffer_cases()
    await run_async_cases()
    run_resolver_cases()
    run_extra_cases()
    return "\n".join(out) + "\n"


# The second request reads what the first left in JS: an implicit proxy
# for a function passed to JS, once its request is done.
def stash():
    js.globalThis.__ffi_kept = lambda: "kept"
    js.globalThis.__ffi_kept_proxy = create_proxy(lambda: "kept-proxy")
    return "stashed\n"


def after():
    out.clear()
    case("implicit-after-request", lambda: Reflect.apply(js.globalThis.__ffi_kept, None, to_js([])))
    case("create_proxy-after-request", lambda: Reflect.apply(js.globalThis.__ffi_kept_proxy, None, to_js([])))
    return "\n".join(out) + "\n"
