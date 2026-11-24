# Exercises each native package the recipes build: GET / runs every check and
# returns {package: "ok" | error}. Build it with the packages to check:
#   PACKAGES="multidict yarl ..." APP=packages/demo-native OUTDIR=... ./build.sh
import importlib
import json
import traceback

from workers import Response, WorkerEntrypoint


def check_multidict():
    from multidict import CIMultiDict, MultiDict, istr
    import multidict._multidict  # noqa: F401  (the C implementation)
    d = MultiDict([("a", 1), ("a", 2)])
    assert d.getall("a") == [1, 2]
    assert CIMultiDict(A=1)["a"] == 1 and istr("X") == "X"


def check_yarl():
    import yarl._quoting_c  # noqa: F401
    from yarl import URL
    u = URL("https://example.com/a b?q=1") / "c"
    assert str(u) == "https://example.com/a%20b/c" and URL("http://x/?a=1").query["a"] == "1"


def check_propcache():
    import propcache._helpers_c  # noqa: F401
    from propcache import cached_property

    class A:
        @cached_property
        def v(self):
            return 42
    assert A().v == 42


def check_frozenlist():
    import frozenlist._frozenlist  # noqa: F401
    from frozenlist import FrozenList
    f = FrozenList([1, 2])
    f.freeze()
    assert f.frozen and f == [1, 2]
    g = FrozenList([1, 2])
    g.freeze()
    assert hash(f) == hash(g)


def check_aiohttp():
    import aiohttp
    import aiohttp._http_parser as p
    import aiohttp._websocket.mask
    import aiohttp._websocket.reader_c  # noqa: F401
    import aiohttp._http_writer  # noqa: F401
    assert aiohttp.http_parser.HttpRequestParser is p.HttpRequestParser
    from aiohttp import web  # noqa: F401
    buf = bytearray(b"abcd")
    aiohttp._websocket.mask._websocket_mask_cython(b"\x01\x02\x03\x04", buf)
    assert bytes(buf) == bytes([0x60, 0x60, 0x60, 0x60])


def check_msgspec():
    import msgspec

    class P(msgspec.Struct):
        x: int
        y: str = "a"
    assert msgspec.json.decode(b'{"x":1}', type=P) == P(1)
    assert msgspec.msgpack.decode(msgspec.msgpack.encode([1, "b"])) == [1, "b"]


def check_xxhash():
    import xxhash
    assert xxhash.xxh64(b"a").hexdigest() == "d24ec4f1a98c6e5b"
    assert xxhash.xxh3_64_intdigest(b"") == 0x2D06800538D394C2


def check_regex():
    import regex
    assert regex.findall(r"\p{L}+", "héllo wörld") == ["héllo", "wörld"]


def check_websockets():
    import websockets.speedups as s
    from websockets.frames import Frame, Opcode  # noqa: F401
    assert s.apply_mask(b"\x00\x00", b"\x01\x02\x03\x04") == b"\x01\x02"


def check_markupsafe():
    import markupsafe._speedups  # noqa: F401
    from markupsafe import escape
    assert escape("<a>") == "&lt;a&gt;"


def check_pyyaml():
    import yaml
    assert yaml.__with_libyaml__
    from yaml import CSafeLoader, CSafeDumper
    assert yaml.load("a: [1, 2]", Loader=CSafeLoader) == {"a": [1, 2]}
    assert yaml.dump({"b": 1}, Dumper=CSafeDumper) == "b: 1\n"


def check_zstandard():
    import zstandard
    assert zstandard.backend == "cext"
    data = b"hello " * 100
    c = zstandard.ZstdCompressor(level=3).compress(data)
    assert zstandard.ZstdDecompressor().decompress(c) == data


def check_cffi():
    import _cffi_backend
    import cffi
    ffi = cffi.FFI()
    ffi.cdef("struct p { int x; int y; };")
    p = ffi.new("struct p *", {"x": 1, "y": 2})
    assert p.y == 2 and ffi.sizeof("struct p") == 8
    assert _cffi_backend.__version__ == cffi.__version__


def check_charset_normalizer():
    import charset_normalizer
    r = charset_normalizer.from_bytes("Bonjour à tous, ça va très bien".encode("cp1252")).best()
    assert r is not None and "ça" in str(r)


def check_jiter():
    import jiter
    assert jiter.from_json(b'{"a": [1, 2.5, "x"]}') == {"a": [1, 2.5, "x"]}


def check_orjson():
    import orjson
    assert orjson.loads(orjson.dumps({"a": [1, None]})) == {"a": [1, None]}
    assert orjson.dumps({"b": 1, "a": 2}, option=orjson.OPT_SORT_KEYS) == b'{"a":2,"b":1}'


def check_rpds():
    from rpds import HashTrieMap, List
    m = HashTrieMap({"a": 1}).insert("b", 2)
    assert m["b"] == 2 and len(m) == 2 and list(List([1, 2])) == [1, 2]


def check_uuid_utils(in_request):
    import uuid_utils
    assert uuid_utils.uuid5(uuid_utils.NAMESPACE_DNS, "a").version == 5
    if in_request:
        u = uuid_utils.uuid7()
        assert u.version == 7 and uuid_utils.UUID(str(u)) == u


def check_tiktoken():
    import tiktoken
    import tiktoken._tiktoken  # noqa: F401
    from tiktoken.core import Encoding
    enc = Encoding("t", pat_str=r"\S+|\s+", mergeable_ranks={bytes([i]): i for i in range(256)}, special_tokens={})
    assert enc.decode(enc.encode("hi there")) == "hi there"


def check_cryptography(in_request):
    from cryptography.fernet import Fernet
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import ed25519
    h = hashes.Hash(hashes.SHA256())
    h.update(b"abc")
    assert h.finalize().hex().startswith("ba7816bf")
    if not in_request:
        return  # randomness isn't allowed at the top level
    k = ed25519.Ed25519PrivateKey.generate()
    k.public_key().verify(k.sign(b"m"), b"m")
    f = Fernet(Fernet.generate_key())
    assert f.decrypt(f.encrypt(b"x")) == b"x"


def check_pydantic():
    import pydantic

    class M(pydantic.BaseModel):
        x: int
    assert M(x="3").x == 3
    try:
        M(x="a")
        raise AssertionError("no ValidationError")
    except pydantic.ValidationError:
        pass


def check_numpy():
    import numpy as np
    from numpy.fft import _pocketfft_umath as pfu
    assert int(np.arange(10).sum()) == 45
    assert np.allclose(np.fft.ifft(np.fft.fft(np.arange(8.0))).real, np.arange(8.0))
    # pocketfft throws a C++ exception for a zero-length transform, which
    # numpy's wrapper catches and raises as RuntimeError.
    try:
        pfu.fft(np.zeros(4, complex), 1.0, out=np.zeros(0, complex))
        raise AssertionError("no RuntimeError")
    except RuntimeError as e:
        assert "zero-length" in str(e), e
    assert list(np.unique(np.array([3, 1, 3, 2]), sorted=False)) in ([3, 1, 2], [1, 2, 3], [1, 3, 2], [2, 3, 1], [3, 2, 1], [2, 1, 3])


CHECKS = {k[len("check_"):]: v for k, v in sorted(globals().items()) if k.startswith("check_")}
MODULES = {"multidict": "multidict", "yarl": "yarl", "propcache": "propcache", "frozenlist": "frozenlist",
           "aiohttp": "aiohttp", "msgspec": "msgspec", "xxhash": "xxhash", "regex": "regex",
           "websockets": "websockets", "markupsafe": "markupsafe", "pyyaml": "yaml", "zstandard": "zstandard",
           "cffi": "cffi", "charset_normalizer": "charset_normalizer", "jiter": "jiter", "orjson": "orjson",
           "rpds": "rpds", "uuid_utils": "uuid_utils", "tiktoken": "tiktoken", "cryptography": "cryptography",
           "numpy": "numpy", "pydantic": "pydantic"}


def present(name):
    try:
        importlib.import_module(MODULES[name])
        return True
    except ImportError:
        return False


def run_checks(in_request=False):
    out = {}
    for name, fn in CHECKS.items():
        if not present(name):
            continue
        try:
            fn(in_request) if fn.__code__.co_argcount else fn()
            out[name] = "ok"
        except BaseException:  # noqa: BLE001
            out[name] = traceback.format_exc(limit=-3)
    return out


# The checks run while the snapshot is taken too, so a package that can't
# import or work fails the build.
SNAPSHOT_RESULTS = run_checks()
_failed = {k: v for k, v in SNAPSHOT_RESULTS.items() if v != "ok"}
if _failed:
    raise RuntimeError("checks failed while the snapshot was taken:\n" + "\n".join(f"{k}: {v}" for k, v in _failed.items()))


class Default(WorkerEntrypoint):
    async def fetch(self, request):
        res = {"snapshot": SNAPSHOT_RESULTS, "request": run_checks(True)}
        return Response(json.dumps(res, indent=1), headers={"content-type": "application/json"})
