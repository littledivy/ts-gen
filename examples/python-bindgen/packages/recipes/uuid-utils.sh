# uuid-utils: UUID versions 1 to 8 in Rust (PyO3), which LangSmith uses.
VERSION=0.19.0
KIND=pyo3
OPT_LEVEL=z
MODULES="uuid_utils._uuid_utils:PyInit__uuid_utils"
build_native() {
  default_pyo3 uuid_utils
  cp -R "$SRC/src/python/uuid_utils" "$OUT/site/"
}
