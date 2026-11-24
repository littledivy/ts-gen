# cffi: its backend (_cffi_backend, a top-level module) over libffi-wasi/, a
# libffi with the types and struct layouts but no calls by address or
# closures, which Wasm can't make. API-mode modules work; see
# libffi-wasi/ffi.h.
VERSION=2.1.1
KIND=setuptools
EXT_SOURCES="_cffi_backend=src/c/_cffi_backend.c,libffi-wasi/ffi.c"
EXT_CFLAGS="-Ilibffi-wasi -include libffi-wasi/no-dup.h -DFFI_BUILDING=1 -D_WASI_EMULATED_MMAN"
PY_PACKAGES="src/cffi"
WHEELS="pycparser"
LDFLAGS="-lwasi-emulated-mman"
# CPython's pthread stubs on WASI reject a TLS key with a destructor, which
# would only run at thread exit; there are no other threads.
prepare_source() {
  cp -R "$HERE/libffi-wasi" "$SRC/src/"
  sed -i '' 's/pthread_key_create(&cffi_tls_key, &cffi_thread_shutdown)/pthread_key_create(\&cffi_tls_key, NULL)/' \
    "$SRC/src/src/c/misc_thread_posix.h"
  grep -q 'pthread_key_create(&cffi_tls_key, NULL)' "$SRC/src/src/c/misc_thread_posix.h"
}
