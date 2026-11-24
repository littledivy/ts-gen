# tiktoken: OpenAI's BPE tokenizer (PyO3). Encodings are downloaded on first
# use, as elsewhere; pass a cache with TIKTOKEN_CACHE_DIR or build the
# Encoding from ranks the app ships.
VERSION=0.14.0
KIND=pyo3
OPT_LEVEL=z
RUST_FEATURES=python
DEPENDS="regex"
WHEELS="requests charset-normalizer idna urllib3 certifi"
MODULES="tiktoken._tiktoken:PyInit__tiktoken"
build_native() {
  default_pyo3 tiktoken
  cp -R "$SRC/src/tiktoken" "$SRC/src/tiktoken_ext" "$OUT/site/"
}
