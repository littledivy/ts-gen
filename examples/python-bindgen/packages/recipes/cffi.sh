# cffi: its backend (_cffi_backend, a top-level module) over libffi-wasi/, a
# libffi whose calls and closures go through trampolines compiled per
# signature (gen-trampolines.py). ABI mode works for those signatures, and
# ffi.dlopen(None) finds the functions in libffi-wasi/dlsym.c; see
# libffi-wasi/ffi.h.
VERSION=2.1.1
KIND=setuptools
EXT_SOURCES="_cffi_backend=src/c/_cffi_backend.c,libffi-wasi/ffi.c,libffi-wasi/trampolines.c,libffi-wasi/dlsym.c"
EXT_CFLAGS="-Ilibffi-wasi -Ddlopen=ffi_wasi_dlopen -Ddlsym=ffi_wasi_dlsym -Ddlclose=ffi_wasi_dlclose -Ddlerror=ffi_wasi_dlerror -include libffi-wasi/no-dup.h -DFFI_BUILDING=1 -D_WASI_EMULATED_MMAN"
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
  "$HOSTPY" -I "$HERE/libffi-wasi/gen-trampolines.py" > "$SRC/src/libffi-wasi/trampolines.c"
  "$HOSTPY" -I - "$SRC/src/src/c/_cffi_backend.c" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
def sub(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new)
# libffi-wasi has ffi_closure_alloc, ffi_prep_closure_loc and
# ffi_prep_cif_var, as Emscripten's libffi does.
sub("#elif defined(__EMSCRIPTEN__)", "#elif defined(__EMSCRIPTEN__) || defined(__wasi__)")
# A closure's code pointer is a compiled entry point for its signature,
# chosen by ffi_prep_closure_loc; libffi-wasi keeps it first in tramp.
sub("""    if (status != FFI_OK) {
        PyErr_SetString(PyExc_SystemError,
                        "libffi failed to build this callback");
        goto error;
    }
""", """    if (status != FFI_OK) {
        if (!PyErr_Occurred())
            PyErr_SetString(PyExc_SystemError,
                            "libffi failed to build this callback");
        goto error;
    }
#ifdef __wasi__
    cd->head.c_data = *(char **)closure->tramp;
#endif
""")
# ffi_call raises for a signature it has no trampoline for.
sub("""    save_errno();
    Py_END_ALLOW_THREADS
""", """    save_errno();
    Py_END_ALLOW_THREADS
#ifdef __wasi__
    if (PyErr_Occurred())
        goto error;
#endif
""")
open(p, "w").write(s)
PY
  # cffi looks a library name up with ctypes, which WASI's CPython lacks:
  # with nothing found, dlopen fails with the OSError it gives elsewhere.
  "$HOSTPY" -I - "$SRC/src/src/cffi/api.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = """    import ctypes.util
    path = ctypes.util.find_library(name)
"""
assert s.count(old) == 1
s = s.replace(old, """    try:
        import ctypes.util
        path = ctypes.util.find_library(name)
    except ImportError:
        path = None
""")
open(p, "w").write(s)
PY
}
