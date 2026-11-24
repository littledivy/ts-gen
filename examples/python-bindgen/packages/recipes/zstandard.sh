# zstandard: its C backend (zstandard.backend_c), which includes the bundled
# single-file zstd 1.5, single-threaded.
VERSION=0.25.0
KIND=setuptools
EXT_SOURCES="zstandard.backend_c=c-ext/backend_c.c"
EXT_CFLAGS="-Ic-ext -Izstd -DZSTD_SINGLE_FILE -DZSTDLIB_VISIBLE= -DZDICTLIB_VISIBLE= -DZSTDERRORLIB_VISIBLE=
  -fvisibility=hidden"
PY_PACKAGES="zstandard"
# The amalgamated zstd.c turns on multithreading everywhere but Emscripten;
# WASI has no threads either.
prepare_source() {
  sed -i '' 's/^#ifndef __EMSCRIPTEN__$/#if !defined(__EMSCRIPTEN__) \&\& !defined(__wasi__)/' "$SRC/src/zstd/zstd.c"
  grep -q '__wasi__' "$SRC/src/zstd/zstd.c"
}
