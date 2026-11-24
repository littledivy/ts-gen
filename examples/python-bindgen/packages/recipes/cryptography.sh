# cryptography: its Rust core (cryptography.hazmat.bindings._rust, PyO3)
# with the cffi bindings it compiles in, over OpenSSL 3.5 built here for
# wasm32-wasip1 (static, no assembly, threads, sockets or engines). The
# bindings are a cffi API-mode module, so they need the cffi recipe's
# _cffi_backend.
VERSION=50.0.2
KIND=pyo3
OPT_LEVEL=z
DEPENDS="cffi"
MODULES="cryptography.hazmat.bindings._rust:PyInit__rust"
OPENSSL=3.5.4
OPENSSL_SHA256=967311f84955316969bdb1d8d4b983718ef42338639c621ec4c34fddef355e99

build_openssl() {
  local src=$SRC/openssl prefix=$SRC/openssl-prefix
  [ -f "$prefix/lib/libcrypto.a" ] && return
  fetch_tarball https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL/openssl-$OPENSSL.tar.gz \
    $OPENSSL_SHA256 "$src"
  (cd "$src" && CC="$CC" AR=$SDK/bin/llvm-ar RANLIB=$SDK/bin/llvm-ranlib ./Configure linux-generic32 \
      no-asm no-shared no-dso no-threads no-async no-afalgeng no-ui-console no-secure-memory no-sock \
      no-dgram no-tests no-apps no-docs no-module no-engine no-ktls no-posix-io no-quic no-http \
      no-ocsp no-cmp no-ct no-srp no-ts no-legacy -Os -D_WASI_EMULATED_SIGNAL \
      -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_GETPID -DNO_SYSLOG \
      --prefix="$prefix" --openssldir="$prefix/ssl" >/dev/null &&
    make -j"$NCPU" build_libs >/dev/null && make install_dev >/dev/null)
}

build_native() {
  build_openssl
  # build_openssl.py generates the bindings' C with cffi, run by a host
  # Python that has it.
  local venv=$D/venv-cffi
  [ -x "$venv/bin/python" ] || { "$HOSTPY" -m venv "$venv" &&
    "$venv/bin/pip" -q install --disable-pip-version-check cffi setuptools; }
  # The bindings compile against the target CPython's headers, which the
  # build script finds beside PYO3_CROSS_LIB_DIR.
  local pyprefix=$SRC/pyprefix
  rm -rf "$pyprefix" && mkdir -p "$pyprefix/lib/python3.14" "$pyprefix/include/python3.14"
  cp -R "$PY/Include/." "$pyprefix/include/python3.14/" && cp "$XB/pyconfig.h" "$pyprefix/include/python3.14/"
  # openssl-wasi/no-sock.h stands in for the socket functions no-sock
  # leaves out.
  OPENSSL_DIR=$SRC/openssl-prefix OPENSSL_STATIC=1 PYO3_PYTHON=$venv/bin/python \
    RUST_CFLAGS="-Os -include $HERE/openssl-wasi/no-sock.h" \
    PYO3_CROSS_LIB_DIR=$pyprefix/lib/python3.14 default_pyo3 cryptography_rust src/rust
  # OpenSSL's libraries, which the Rust library only names.
  cp "$SRC/openssl-prefix/lib/libssl.a" "$SRC/openssl-prefix/lib/libcrypto.a" "$OUT/lib/"
  cp -R "$SRC/src/src/cryptography" "$OUT/site/"
}
