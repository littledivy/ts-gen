// Python Workers: starts the interpreter. `wizer-initialize` runs it at build
// time under `wasmtime wizer`, which snapshots the result, so an instance
// starts with Python initialized and the app imported (_cf_runtime._boot).
// cfjs.c is the `js` FFI and the dispatch export every call arrives through.

#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include <stdio.h>

// Set when the interpreter failed to start; dispatch reports it.
int cfworkers_init_failed;

// Registers natively built packages' extension modules. build.sh generates
// the definition (gen/packages.c) when PACKAGES is set.
__attribute__((weak)) void cfworkers_register_packages(void) {}

// The in-memory filesystem (vfs.c).
PyObject *PyInit__cfvfs(void);
PyObject *PyInit__cfentropy(void);
void cfvfs_activate(void);

void cfworkers_start(void) {
  static int started;
  if (started) return;
  started = 1;
  cfworkers_register_packages();
  PyImport_AppendInittab("_cfvfs", PyInit__cfvfs);
  PyImport_AppendInittab("_cfentropy", PyInit__cfentropy);
  // Configured as Pyodide's Python is: not isolated, with the site module,
  // UTF-8 file names, and docstrings and column ranges kept (LEAN, in
  // build.sh, drops the column ranges: tracebacks lose their ^^^ markers,
  // and the snapshot is about 6% smaller).
  {
    PyPreConfig pre;
    PyPreConfig_InitPythonConfig(&pre);
    pre.allocator = PYMEM_ALLOCATOR_MALLOC;
    pre.utf8_mode = 0;
    pre.coerce_c_locale = 0;
    Py_PreInitialize(&pre);
  }
  PyConfig config;
  PyConfig_InitPythonConfig(&config);
  config.parse_argv = 0;
  config.write_bytecode = 0;
  config.install_signal_handlers = 0;
#ifdef CF_LEAN
  config.code_debug_ranges = 0;
#endif
  // The paths are Pyodide's: the stdlib's zip, lib-dynload, the runtime's
  // and the SDK's site-packages, the app, and the packages' site-packages,
  // preopened by `wasmtime wizer --dir` at pre-initialization time (and
  // copied into memory for requests, vfs.c). _cf_runtime then puts the
  // app's vendored packages before site-packages, as Pyodide does.
  static const wchar_t *const paths[] = {
    L"/lib/python314.zip", L"/lib/python3.14/lib-dynload", L"/lib/python3.14/site-packages",
    L"/session/metadata", L"/session/lib/python3.14/site-packages",
  };
  PyStatus status = PyConfig_SetString(&config, &config.home, L"/");
  if (!PyStatus_Exception(status)) status = PyConfig_SetString(&config, &config.filesystem_encoding, L"utf-8");
  if (!PyStatus_Exception(status)) status = PyConfig_SetString(&config, &config.filesystem_errors, L"surrogateescape");
  config.module_search_paths_set = 1;
  for (size_t i = 0; i < sizeof(paths) / sizeof(*paths) && !PyStatus_Exception(status); i++) {
    status = PyWideStringList_Append(&config.module_search_paths, paths[i]);
  }
  if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
  PyConfig_Clear(&config);
  if (PyStatus_Exception(status)) {
    fprintf(stderr, "Python failed to start: %s\n", status.err_msg ? status.err_msg : "?");
    cfworkers_init_failed = 1;
    return;
  }
  // Python's C-stack guard uses the real bounds of the shadow stack, which
  // the link puts first in memory, so deep recursion raises RecursionError.
  extern char __stack_low, __stack_high;
  PyUnstable_ThreadState_SetStackProtection(PyThreadState_Get(), &__stack_low, (size_t)(&__stack_high - &__stack_low));
  // How modules are compiled into the snapshot (with LEAN, without docstrings).
  PyObject *bytecode = PyImport_ImportModule("_cf_bytecode");
  if (!bytecode) goto error;
  Py_DECREF(bytecode);
  PyObject *runtime = PyImport_ImportModule("_cf_runtime");
  if (!runtime) goto error;
  PyObject *boot = PyObject_CallMethod(runtime, "_boot", NULL);
  Py_DECREF(runtime);
  if (!boot) goto error;
  Py_DECREF(boot);
  fflush(stdout);
  fflush(stderr);
  return;
error:
  PyErr_Print();
  fflush(stderr);
  cfworkers_init_failed = 1;
}

// Set while `wasmtime wizer` pre-initializes (see snapshot-realloc.c).
static int snapshotting;
int cfworkers_snapshotting(void) { return snapshotting; }

__attribute__((export_name("wizer-initialize"))) void wizer_initialize(void) {
  snapshotting = 1;
  cfworkers_start();
  // From here on, files come from memory (vfs.c).
  cfvfs_activate();
  snapshotting = 0;
}

