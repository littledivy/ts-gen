"""The parts of Pyodide's `pyodide` package Python Workers use, on the WASI
runtime (see _cf_runtime)."""

from _cf_runtime import PYODIDE_VERSION as __version__

from . import ffi  # noqa: F401
