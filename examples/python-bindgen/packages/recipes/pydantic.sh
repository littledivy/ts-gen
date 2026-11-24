# pydantic and its Rust core (pydantic-core, built with PyO3).
VERSION=2.50.5
SDIST=pydantic-core==$VERSION
KIND=pyo3
# opt-level z: 0.34 MB smaller gzip than 3, with the same FastAPI p50.
OPT_LEVEL=z
WHEELS="pydantic==2.14.4 annotated-types typing-extensions typing-inspection"
MODULES="pydantic_core._pydantic_core:PyInit__pydantic_core"
build_native() {
  default_pyo3 _pydantic_core
  cp -R "$SRC/src/python/pydantic_core" "$OUT/site/"
}
