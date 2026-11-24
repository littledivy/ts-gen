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
    # ABI mode: calls by address and callbacks, through libffi-wasi.
    ffi.cdef("""
        size_t strlen(const char *);
        double pow(double, double);
        float sqrtf(float);
        long long llabs(long long);
        int snprintf(char *, size_t, const char *, ...);
        void qsort(void *, size_t, size_t, int (*)(const void *, const void *));
    """)
    C = ffi.dlopen(None)
    assert C.strlen(b"hello") == 5 and C.pow(2.0, 10.0) == 1024.0
    assert C.sqrtf(2.25) == 1.5 and C.llabs(-(1 << 40)) == 1 << 40
    buf = ffi.new("char[64]")
    C.snprintf(buf, 64, b"%d-%s-%.2f-%lld", ffi.cast("int", 7), ffi.new("char[]", b"x"), ffi.cast("double", 2.5),
               ffi.cast("long long", 1 << 33))
    assert ffi.string(buf) == b"7-x-2.50-8589934592", ffi.string(buf)

    @ffi.callback("int(const void *, const void *)")
    def cmp(a, b):
        x, y = ffi.cast("int *", a)[0], ffi.cast("int *", b)[0]
        return (x > y) - (x < y)
    arr = ffi.new("int[]", [5, 3, 9, 1, 7])
    C.qsort(arr, 5, ffi.sizeof("int"), cmp)
    assert list(arr) == [1, 3, 5, 7, 9]
    # A struct by value, through a function pointer cast from a callback.
    ffi.cdef("struct q { double a; int b; };")
    add = ffi.callback("double(struct q, int)", lambda q, k: q.a * k + q.b)
    assert ffi.cast("double(*)(struct q, int)", add)({"a": 1.5, "b": 2}, 4) == 8.0
    try:
        ffi.dlopen("libz.so")
    except OSError as e:
        assert "cannot load library 'libz.so'" in str(e), e
    else:
        raise AssertionError("dlopen of a missing library")
    try:
        C.not_a_function
    except AttributeError:
        pass


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
    # RandomState's legacy integer distributions and Generator's, seeded:
    # the values numpy gives on a 64-bit host.
    r = np.random.RandomState(0)
    assert [r.poisson(3.0, 4).tolist(), r.binomial(10, 0.4, 4).tolist(), r.negative_binomial(3, 0.4, 4).tolist(),
            r.geometric(0.3, 4).tolist(), r.zipf(2.0, 4).tolist(), r.hypergeometric(10, 5, 6, 4).tolist(),
            r.logseries(0.5, 4).tolist()] == [[5, 6, 2, 0], [5, 5, 6, 7], [2, 7, 8, 8], [2, 1, 1, 1], [2, 1, 5, 6],
                                              [3, 6, 5, 3], [1, 1, 5, 6]]
    g = np.random.default_rng(0)
    assert [g.poisson(3.0, 4).tolist(), g.binomial(10, 0.4, 4).tolist(), g.geometric(0.3, 4).tolist()] == [
        [2, 0, 7, 1], [5, 3, 6, 4], [1, 5, 1, 1]]


def check_pillow():
    import io
    from PIL import Image, ImageCms, ImageDraw, ImageFilter, ImageFont, features
    im = Image.new("RGB", (32, 24), "white")
    ImageDraw.Draw(im).rectangle((4, 4, 20, 16), fill=(200, 10, 30))
    im = im.filter(ImageFilter.GaussianBlur(1)).rotate(15, expand=True)
    for fmt in ("PNG", "JPEG", "WEBP", "GIF", "BMP"):
        buf = io.BytesIO()
        im.save(buf, fmt)
        back = Image.open(io.BytesIO(buf.getvalue()))
        back.load()
        assert back.size == im.size, fmt
    for f in ("jpg", "webp", "zlib", "freetype2", "littlecms2"):
        assert features.check(f), f
    font = ImageFont.load_default(size=12)  # FreeType, over Pillow's embedded font
    assert font.getbbox("Hi")[2] > 0
    srgb = ImageCms.createProfile("sRGB")
    assert ImageCms.profileToProfile(im, srgb, srgb).size == im.size


def check_shapely():
    import numpy as np
    import shapely
    from shapely import wkt
    from shapely.geometry import Point, Polygon
    a = Point(0, 0).buffer(1.0)
    b = Polygon([(0, 0), (2, 0), (2, 2), (0, 2)])
    assert abs(a.area - 3.1365) < 1e-3 and abs(a.intersection(b).area - 0.7841) < 1e-3
    assert wkt.loads("POINT (1 2)").equals(Point(1, 2))
    pts = shapely.points(np.array([[0, 0], [1, 1], [5, 5]]))
    assert shapely.contains(b, pts).tolist() == [False, True, False]
    tree = shapely.STRtree(pts)
    assert tree.query(b, predicate="intersects").tolist() == [0, 1]
    try:
        shapely.from_wkt("POINT (1")
    except shapely.errors.GEOSException:
        pass  # a GEOS C++ exception, caught and raised in Python
    else:
        raise AssertionError("bad WKT parsed")
    assert shapely.geos_version >= (3, 14, 0)


def check_pywavelets():
    import numpy as np
    import pywt
    import pywt.data
    x = np.arange(16.0)
    ca, cd = pywt.dwt(x, "db2")
    assert np.allclose(pywt.idwt(ca, cd, "db2"), x)
    coeffs = pywt.wavedec2(pywt.data.camera()[:64, :64].astype(float), "haar", level=2)
    assert coeffs[0].shape == (16, 16)
    assert len(pywt.swt(x, "haar", level=2)) == 2
    cwt, _ = pywt.cwt(np.sin(np.linspace(0, 8, 64)), [1, 2, 4], "morl")
    assert cwt.shape == (3, 64)
    assert pywt.Wavelet("sym4").dec_len == 8 and "db4" in pywt.wavelist("db")
    try:
        pywt.Wavelet("nope")
    except ValueError:
        pass
    else:
        raise AssertionError("unknown wavelet accepted")


def check_beautifulsoup4():
    from bs4 import BeautifulSoup
    soup = BeautifulSoup("<ul><li class=a>one</li><li>two</li></ul><p id=x>hi</p>", "html.parser")
    assert [li.get_text() for li in soup.select("ul > li")] == ["one", "two"]
    assert soup.select_one("li.a").get_text() == "one" and soup.find(id="x").string == "hi"


CHECKS = {k[len("check_"):]: v for k, v in sorted(globals().items()) if k.startswith("check_")}
MODULES = {"multidict": "multidict", "yarl": "yarl", "propcache": "propcache", "frozenlist": "frozenlist",
           "aiohttp": "aiohttp", "msgspec": "msgspec", "xxhash": "xxhash", "regex": "regex",
           "websockets": "websockets", "markupsafe": "markupsafe", "pyyaml": "yaml", "zstandard": "zstandard",
           "cffi": "cffi", "charset_normalizer": "charset_normalizer", "jiter": "jiter", "orjson": "orjson",
           "rpds": "rpds", "uuid_utils": "uuid_utils", "tiktoken": "tiktoken", "cryptography": "cryptography",
           "numpy": "numpy", "pydantic": "pydantic", "pillow": "PIL", "shapely": "shapely",
           "pywavelets": "pywt", "beautifulsoup4": "bs4"}


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
