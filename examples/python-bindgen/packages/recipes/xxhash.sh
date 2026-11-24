# xxhash: the binding (xxhash._xxhash) with the bundled xxHash library, and
# no x86 dispatch.
VERSION=4.1.0
KIND=setuptools
EXT_SOURCES="xxhash._xxhash=src/_xxhash.c,deps/xxhash/xxhash.c"
EXT_CFLAGS="-Ideps/xxhash"
PY_PACKAGES="xxhash"
# Its METH_NOARGS methods take only `self`, which traps on Wasm.
prepare_source() { "$VENV/bin/python" "$HERE/tools/fix-noargs.py" "$SRC/src/src/_xxhash.c"; }
