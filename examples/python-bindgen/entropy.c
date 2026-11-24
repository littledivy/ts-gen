// Counts the Worker's calls for host entropy (WASI random_get: getentropy,
// os.urandom, and Rust's HashMap seeds in native packages). This file
// defines wasi-libc's `__imported_wasi_snapshot_preview1_random_get`, which
// the link uses instead of the host's import, so every call passes through
// here.
//
// `_cfentropy.calls()` is the count so far. At the top level _cf_runtime
// lets only a set number of these through (allow_bad_entropy_calls), as
// Pyodide does with getentropy, and checks the count to see how many a
// patched import used.
#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include <stdint.h>

__attribute__((import_module("wasi_snapshot_preview1"), import_name("random_get")))
int32_t host_random_get(int32_t, int32_t);

static unsigned long long calls;

int32_t __imported_wasi_snapshot_preview1_random_get(int32_t buf, int32_t len) {
  calls++;
  return host_random_get(buf, len);
}

static PyObject *entropy_calls(PyObject *self, PyObject *args) { return PyLong_FromUnsignedLongLong(calls); }

static PyMethodDef entropy_methods[] = {
  {"calls", entropy_calls, METH_NOARGS, NULL},
  {NULL, NULL, 0, NULL},
};

static struct PyModuleDef entropy_module = {PyModuleDef_HEAD_INIT, "_cfentropy", NULL, -1, entropy_methods};

PyObject *PyInit__cfentropy(void) { return PyModule_Create(&entropy_module); }
