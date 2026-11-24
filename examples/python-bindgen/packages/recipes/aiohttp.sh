# aiohttp: four Cython extensions, already cythonized in the sdist, and the
# bundled llhttp parser.
VERSION=3.14.5
KIND=setuptools
EXT_SOURCES="
aiohttp._websocket.mask=aiohttp/_websocket/mask.c
aiohttp._http_parser=aiohttp/_http_parser.c,aiohttp/_find_header.c,vendor/llhttp/build/c/llhttp.c,vendor/llhttp/src/native/api.c,vendor/llhttp/src/native/http.c
aiohttp._http_writer=aiohttp/_http_writer.c
aiohttp._websocket.reader_c=aiohttp/_websocket/reader_c.c
"
EXT_CFLAGS="-Ivendor/llhttp/build -DLLHTTP_STRICT_MODE=0"
PY_PACKAGES="aiohttp"
DEPENDS="multidict yarl propcache frozenlist"
WHEELS="aiohappyeyeballs aiosignal attrs"
