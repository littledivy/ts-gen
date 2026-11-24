# orjson: JSON in Rust (pyo3-ffi), with yyjson's reader compiled in by its
# build script.
VERSION=3.13.0
KIND=pyo3
OPT_LEVEL=z
MODULES="orjson.orjson:PyInit_orjson"
build_native() {
  default_pyo3 orjson
  cp -R "$SRC/src/pysrc/orjson" "$OUT/site/"
}
