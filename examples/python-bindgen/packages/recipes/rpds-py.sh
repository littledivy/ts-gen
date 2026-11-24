# rpds-py: persistent data structures (rpds), the Rust core of jsonschema's
# referencing (PyO3).
VERSION=2026.9.1
KIND=pyo3
OPT_LEVEL=z
MODULES="rpds:PyInit_rpds"
build_native() { default_pyo3 rpds; }
