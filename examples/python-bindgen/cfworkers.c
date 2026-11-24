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
  {
    PyPreConfig pre;
    PyPreConfig_InitIsolatedConfig(&pre);
    pre.allocator = PYMEM_ALLOCATOR_MALLOC;
    Py_PreInitialize(&pre);
  }
  PyConfig config;
  PyConfig_InitIsolatedConfig(&config);
  config.write_bytecode = 0;
  config.site_import = 0;
  config.install_signal_handlers = 0;
  // Code objects keep line numbers but not column ranges (as with
  // -X no_debug_ranges): tracebacks lose their ^^^ markers, and the snapshot
  // is about 6% smaller.
  config.code_debug_ranges = 0;
  // The app is at /app and the stdlib at /lib/python3.14, both preopened by
  // `wasmtime wizer --dir` at pre-initialization time. After the snapshot no
  // file is read: everything the app uses was imported during initialization.
  PyStatus status = PyConfig_SetString(&config, &config.home, L"/");
  if (!PyStatus_Exception(status)) {
    config.module_search_paths_set = 1;
    status = PyWideStringList_Append(&config.module_search_paths, L"/app");
  }
  if (!PyStatus_Exception(status)) status = PyWideStringList_Append(&config.module_search_paths, L"/lib/python3.14");
  // Packages' Python files, when build.sh was given PACKAGES.
  if (!PyStatus_Exception(status)) status = PyWideStringList_Append(&config.module_search_paths, L"/site");
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
  // How modules are compiled into the snapshot (docstrings, asserts).
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

