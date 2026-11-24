#!/bin/bash
# Builds the Python Worker: CPython 3.14 for wasm32-wasip1 (a static
# libpython), cfworkers.c (startup) and cfjs.c (the js FFI and dispatch), the `workers`
# SDK and worker.py. `wasmtime wizer` then runs Py_Initialize and imports the
# app at build time and snapshots the result, so an instance starts with the
# interpreter ready.
#
# The module reaches JS through ts-gen (generic.ir): C bindings and a Wasm
# shim that owns the externref table from bindgen.py, the shim merged in
# after the snapshot, and ts-gen's bridge generated for the result. Needs
# this repository's ts-gen-abi and ts-gen-bridge (built into
# target/release if TSGEN_BIN doesn't name them), wasmtime, wasm-tools and
# binaryen's wasm-merge; env.sh sets up the caches and the host Python.
set -euo pipefail
# APP, OUTDIR and PROJECT may be relative to where build.sh is run from.
CALLER=$PWD
cd "$(dirname "$0")"
from_caller() { case $1 in /*) echo "$1" ;; *) echo "$CALLER/$1" ;; esac; }
export PATH=$HOME/.cargo/bin:$PATH
HERE=$PWD
PYVER=3.14.10
. ./env.sh
D=$PYTHON_DEPS
SDK=$D/wasi-sdk-dl/wasi-sdk-24.0-$HOST
PY=$D/src/Python-$PYVER
# LEAN=1 builds the smaller Worker this example used to ship: no
# docstrings (C or Python), no column ranges in tracebacks, the C modules
# below left out, and library files shrunk (shrink.py). By default the
# Worker keeps all of these, as Pyodide does.
LEAN=${LEAN:-}
if [ -n "$LEAN" ]; then
  XB=${PY_CROSS_BUILD:-$PY/cross-build/wasm32-wasip1-nodoc}
else
  XB=${PY_CROSS_BUILD:-$PY/cross-build/wasm32-wasip1-full}
fi
ROOT=$(cd ../.. && pwd)
BIN=${TSGEN_BIN:-$ROOT/target/release}
if [ -z "${TSGEN_BIN:-}" ]; then
  (cd "$ROOT" && cargo build -q --release -p ts-gen-abi -p ts-gen-bridge)
fi
IR=$HERE/generic.ir
PROFILE="all-linear, jspi = on, box-none = unit"

if [ ! -x "$SDK/bin/clang" ]; then
  mkdir -p "$D/wasi-sdk-dl"
  curl -sSfL https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-24/wasi-sdk-24.0-$HOST.tar.gz | tar xz -C "$D/wasi-sdk-dl"
fi
# zlib, for the zlib module (gzip, zipfile, and the packages that compress
# with them), built once into deps/zlib.
# Its physical path goes into libpython's Setup.local, so checkouts sharing
# one deps/ (through a symlink) agree on it and don't rebuild libpython.
ZLIB=$D/zlib
[ -d "$ZLIB" ] && ZLIB=$(cd "$ZLIB" && pwd -P)
if [ ! -f "$ZLIB/libz.a" ]; then
  ZTAR=$D/zlib-dl/zlib-1.3.1.tar.gz
  [ -f "$ZTAR" ] || { mkdir -p "$D/zlib-dl" && curl -sSfL -o "$ZTAR" https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz; }
  echo "9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23  $ZTAR" | shasum -a 256 -c --quiet
  rm -rf "$ZLIB" && mkdir -p "$ZLIB/src" && tar xzf "$ZTAR" -C "$ZLIB/src" --strip-components 1
  (cd "$ZLIB/src" &&
    for f in adler32 compress crc32 deflate gzclose gzlib gzread gzwrite infback inffast inflate inftrees trees uncompr zutil; do
      "$SDK/bin/clang" --target=wasm32-wasip1 -Os -c $f.c -o $f.o
    done && "$SDK/bin/llvm-ar" rcs "$ZLIB/libz.a" ./*.o)
fi
# The extension modules built into libpython: every module CPython's WASI
# build has, with zlib (as a static module, since configure finds no zlib in
# the WASI sysroot), and without the test modules (which the default build
# links in as built-ins). LEAN also leaves out CJK codecs (large tables) and
# C accelerators whose pure-Python fallbacks the stdlib uses instead
# (decimal, xml.etree, hmac), and builds without docstrings.
SETUP_LOCAL=$(printf '%s\n' '*static*' "zlib zlibmodule.c -I$ZLIB/src")
DOC_FLAGS=()
if [ -n "$LEAN" ]; then
  SETUP_LOCAL=$(printf '%s\n' "$SETUP_LOCAL" '*disabled*' \
    _codecs_cn _codecs_hk _codecs_iso2022 _codecs_jp _codecs_kr _codecs_tw _multibytecodec _decimal _elementtree _lsprof _hmac)
  DOC_FLAGS=(--without-doc-strings)
fi
if [ ! -f "$XB/libpython3.14.a" ]; then
  mkdir -p "$D/src"
  [ -d "$PY" ] || curl -sSfL https://www.python.org/ftp/python/$PYVER/Python-$PYVER.tar.xz | tar xJ -C "$D/src"
  # The build Python (a native CPython of the same version), via CPython's
  # own WASI tooling.
  (cd "$PY" && WASI_SDK_PATH=$SDK "$HOSTPY" Tools/wasm/wasi configure-build-python --quiet &&
    WASI_SDK_PATH=$SDK "$HOSTPY" Tools/wasm/wasi make-build-python --quiet)
  # libpython for wasm32-wasip1: -Os, no test modules.
  mkdir -p "$XB/Modules"
  echo "$SETUP_LOCAL" > "$XB/Modules/Setup.local"
  (cd "$XB" && export PATH=$SDK/bin:$PATH CONFIG_SITE=$PY/Tools/wasm/wasi/config.site-wasm32-wasi \
      WASI_SDK_PATH=$SDK WASI_SYSROOT=$SDK/share/wasi-sysroot PKG_CONFIG_PATH= \
      PKG_CONFIG_LIBDIR=$SDK/share/wasi-sysroot/lib/pkgconfig:$SDK/share/wasi-sysroot/share/pkgconfig \
      PKG_CONFIG_SYSROOT_DIR=$SDK/share/wasi-sysroot CC=$SDK/bin/clang CPP=$SDK/bin/clang-cpp \
      CXX=$SDK/bin/clang++ AR=$SDK/bin/llvm-ar RANLIB=$SDK/bin/ranlib &&
    "$PY/configure" --host=wasm32-wasip1 --build=$("$PY/config.guess") \
      --with-build-python="$(ls "$PY"/cross-build/*-apple-darwin*/python.exe "$PY"/cross-build/*-linux*/python 2>/dev/null | head -1)" \
      --disable-test-modules ${DOC_FLAGS[@]+"${DOC_FLAGS[@]}"} OPT="-DNDEBUG -Os" >/dev/null &&
    make -j"$NCPU" libpython3.14.a >/dev/null)
fi
# A libpython built with other modules is rebuilt with these.
if [ "$(cat "$XB/Modules/Setup.local")" != "$SETUP_LOCAL" ]; then
  echo "$SETUP_LOCAL" > "$XB/Modules/Setup.local"
  (cd "$XB" && PATH=$SDK/bin:$PATH make -j"$NCPU" libpython3.14.a >/dev/null)
fi
# sysconfig's data module, which zoneinfo and packaging tools import.
[ -f "$XB/pybuilddir.txt" ] || (cd "$XB" && PATH=$SDK/bin:$PATH make pybuilddir.txt >/dev/null)
BUILDPY=$(ls "$PY"/cross-build/*-apple-darwin*/python.exe "$PY"/cross-build/*-linux*/python 2>/dev/null | head -1 || true)
# The standard library as Pyodide ships it: python314.zip, of the modules'
# sources (stdlib-zip.py), built once per kind into deps/stdlib-zip.
# STDLIB_ZIP=stored leaves its members uncompressed, for the upload's
# compression: smaller to upload, larger in memory (see README).
STDLIB_ZIP=${STDLIB_ZIP:-deflated}
ZIPDIR=$D/stdlib-zip/$PYVER-$STDLIB_ZIP-$(cat stdlib-zip.py "$XB/pybuilddir.txt" | shasum | cut -c1-12)
if [ ! -f "$ZIPDIR/python314.zip" ]; then
  mkdir -p "$ZIPDIR"
  "$BUILDPY" -I stdlib-zip.py "$PY/Lib" "$ZIPDIR/python314.zip" $([ "$STDLIB_ZIP" = stored ] && echo --stored) \
    "$XB/$(cat "$XB/pybuilddir.txt")"/_sysconfigdata_*.py
fi

OUT=$(from_caller "${OUTDIR:-$PWD/out}")
# Generated files live under the output directory, so builds into different
# OUTDIRs don't share them.
GEN=$OUT/gen
rm -rf "$OUT" && mkdir -p "$GEN" "$GEN/tmp" "$GEN/dev" "$GEN/root"
# The generic JS interface (generic.ir), as C bindings.
"$BIN/ts-gen-abi" lower "$IR" --profile "$PROFILE" > "$GEN/generic.json"
python3 bindgen.py header "$GEN/generic.json" -o "$GEN/tsgen_imports.h"

# Optional native and pure-Python packages: PACKAGES="pydantic fastapi" ./build.sh
# Each is built by packages/build-package.sh into deps/pkg/<name>/. Their
# extension modules are linked in and registered as built-ins, and their Python
# files go in /session/lib/python3.14/site-packages for wizer to snapshot. APP=<dir> picks the app
# directory; by default the app is worker.py alone (this directory also holds
# the runtime, the SDK and the package builds, which aren't the app's).
if [ -z "${APP:-}" ]; then
  mkdir -p "$GEN/app" && cp worker.py "$GEN/app/"
  APP=$GEN/app
fi
APP=$(cd "$(from_caller "$APP")" && pwd)
# A project's dependencies, from its pyproject.toml as pywrangler sync
# installs them (packages/sync.py): pure-Python wheels into the app's
# python_modules/, and the recipes for native ones as PACKAGES. PROJECT is
# the directory with pyproject.toml (default: APP, or its parent, as with a
# src/ layout). The app is copied, with the synced python_modules/, into
# $GEN/app. Setting PACKAGES, even to "", skips this.
if [ -z "${PACKAGES+set}" ]; then
  if [ -z "${PROJECT:-}" ]; then
    for d in "$APP" "$(dirname "$APP")"; do [ -f "$d/pyproject.toml" ] && { PROJECT=$d; break; }; done
  fi
  if [ -n "${PROJECT:-}" ]; then
    PROJECT=$(cd "$(from_caller "$PROJECT")" && pwd)
    [ -x "$D/venv/bin/python" ] || { "$HOSTPY" -m venv "$D/venv" && "$D/venv/bin/pip" -q install meson cython; }
    VENDOR=$D/sync/$(echo "$PROJECT" | shasum | cut -c1-12)/python_modules
    PACKAGES=$("$D/venv/bin/python" -I packages/sync.py "$PROJECT" "$VENDOR")
    mkdir -p "$GEN/app"
    rsync -a --exclude python_modules --exclude node_modules --exclude '.*' --exclude __pycache__ \
      --exclude /out --exclude '/out-*' --exclude /gen --exclude "/${OUT#"$APP"/}" "$APP/" "$GEN/app/"
    cp -R "$VENDOR" "$GEN/app/python_modules"
    APP=$GEN/app
    echo "synced $PROJECT/pyproject.toml: recipes ${PACKAGES:-none}" >&2
  fi
fi
# The filesystem pre-initialization sees, laid out as Pyodide's:
# - /lib (LIB): python314.zip, and python3.14/site-packages with the runtime
#   (runtime/: the FFI, the event loop, dispatch) and the SDK (sdk/: workers
#   and asgi);
# - /session/metadata: the app;
# - /session/lib/python3.14/site-packages (SESSION_SITE): the packages.
LIB=$GEN/lib
SITE=$LIB/python3.14/site-packages
SESSION_SITE=$GEN/session-site
mkdir -p "$SITE" "$LIB/python3.14/lib-dynload" "$SESSION_SITE"
cp "$ZIPDIR/python314.zip" "$LIB/"
cp -R runtime/. sdk/workers sdk/asgi.py "$SITE/"
# MAIN names the app's main module (default worker.py).
MAIN=${MAIN:-worker.py}
echo "MAIN = \"${MAIN%.py}\"" > "$SITE/_cf_config.py"
# Which library files requests can import from (_cf_runtime._capture_files):
# all (the default: the stdlib's zip, and the SDK's and the packages' files
# the snapshot didn't import), site (all but the stdlib) or none.
echo "RUNTIME_IMPORTS = \"${RUNTIME_IMPORTS:-$([ -n "$LEAN" ] && echo site || echo all)}\"" >> "$SITE/_cf_config.py"
echo "LEAN = $([ -n "$LEAN" ] && echo True || echo False)" >> "$SITE/_cf_config.py"
# The compatibility flags pre-initialization decides with (the vendor
# directories on sys.path, .pth files, the stdlib zip's mount), for
# COMPAT_DATE and COMPAT_FLAGS, by default the compatibility_date and
# compatibility_flags of the app's wrangler.toml (in APP or its parent).
if [ -z "${COMPAT_DATE:-}" ]; then
  for d in "$APP" "$(dirname "$APP")"; do
    if [ -f "$d/wrangler.toml" ]; then
      COMPAT_DATE=$(sed -n 's/^compatibility_date *= *"\([^"]*\)".*/\1/p' "$d/wrangler.toml" | head -1)
      COMPAT_FLAGS=${COMPAT_FLAGS:-$(sed -n 's/^compatibility_flags *= *\[\(.*\)\].*/\1/p' "$d/wrangler.toml" | head -1 | tr -d '"' | tr ',' ' ')}
      break
    fi
  done
fi
echo "COMPAT_FLAGS = $("$HOSTPY" -I compat-flags.py "${COMPAT_DATE:-2000-01-01}" ${COMPAT_FLAGS:-})" >> "$SITE/_cf_config.py"
PKG_SRCS=() PKG_LIBS=()
# Each recipe's DEPENDS (the recipes it needs) come before it.
recipe_deps() { (DEPENDS=; . "packages/recipes/$1.sh" >/dev/null; echo $DEPENDS); }
expand_packages() {
  local p
  for p; do
    [ -f "packages/recipes/$p.sh" ] || { echo "no recipe packages/recipes/$p.sh" >&2; exit 1; }
    case " $SEEN " in *" $p "*) continue ;; esac
    SEEN="$SEEN $p"
    expand_packages $(recipe_deps "$p")
    ORDER="$ORDER $p"
  done
}
SEEN= ORDER=
expand_packages ${PACKAGES:-}
PACKAGES=${ORDER# }
if [ -n "${PACKAGES:-}" ]; then
  { echo '#include <Python.h>'
    for p in $PACKAGES; do
      # A package is rebuilt when its recipe changes.
      sum=$(shasum "packages/recipes/$p.sh" | cut -c1-12)
      if [ ! -f "$D/pkg/$p/inittab" ] || [ "$(cat "$D/pkg/$p/.recipe" 2>/dev/null)" != "$sum" ]; then
        packages/build-package.sh "$p" >&2
      fi
      cp -R "$D/pkg/$p/site/." "$SESSION_SITE/"
      for l in "$D/pkg/$p"/lib/*.a; do [ -e "$l" ] && PKG_LIBS+=("$l"); done
      for f in $(cat "$D/pkg/$p/ldflags" 2>/dev/null); do PKG_LIBS+=("$f"); done
      while read -r mod sym; do echo "PyObject *$sym(void);"; done < "$D/pkg/$p/inittab"
    done
    echo 'void cfworkers_register_packages(void) {'
    for p in $PACKAGES; do
      while read -r mod sym; do echo "  PyImport_AppendInittab(\"$mod\", $sym);"; done < "$D/pkg/$p/inittab"
    done
    echo '}'; } > "$GEN/packages.c"
  PKG_SRCS=("$GEN/packages.c")
  # Native packages' Rust code imports WASI random_get itself, bypassing
  # wasi-libc; each such symbol is defined here to go through entropy.c, so
  # the top level's entropy calls are all counted.
  { echo '#include <stdint.h>'
    echo 'int32_t __imported_wasi_snapshot_preview1_random_get(int32_t, int32_t);'
    # Only symbols no member of the library defines: the imports, not Rust
    # wrappers named random_get that other members call.
    for l in ${PKG_LIBS[@]+"${PKG_LIBS[@]}"}; do
      case $l in *.a) "$SDK/bin/llvm-nm" "$l" 2>/dev/null | awk '$NF ~ /random_get$/ && $NF !~ /^__imported/ {
          if ($(NF-1) == "U") u[$NF] = 1; else d[$NF] = 1 }
        END { for (s in u) if (!(s in d)) print s }' ;; esac
    done | sort -u |
      while read -r sym; do echo "int32_t $sym(int32_t b, int32_t n) { return __imported_wasi_snapshot_preview1_random_get(b, n); }"; done
  } > "$GEN/package-entropy.c"
  PKG_SRCS+=("$GEN/package-entropy.c")
fi
# With LEAN, smaller copies of the library files requests may import
# (shrink.py), which _cf_runtime reads from /.build while pre-initializing.
mkdir -p "$GEN/shrunk"
if [ -n "$LEAN" ]; then
  "$BUILDPY" -I shrink.py "$SITE" "$GEN/shrunk/lib/python3.14/site-packages"
  "$BUILDPY" -I shrink.py "$SESSION_SITE" "$GEN/shrunk/session/lib/python3.14/site-packages"
fi

LINK_FLAGS=() WASM_FEATURES=()
# Each Rust package is a static library with its own LTO'd copy of std,
# which exports the same few symbols (rust_eh_personality, ...) as the
# others; built by the same rustc, they are the same code, so the first
# copy is kept. wasm-ld 18 can't do that, so wasi-sdk 30's links instead.
# It also links packages whose C++ uses Wasm exceptions (an "eh" file;
# packages/libcxx-eh.sh), which wasm-ld 18 can't read, and the snapshot
# then runs with exceptions on.
SDK30=$D/wasi-sdk-30-dl/wasi-sdk-30.0-$HOST
NRUST=0 EH=
for l in ${PKG_LIBS[@]+"${PKG_LIBS[@]}"}; do
  case $l in *.a) [ "$("$SDK/bin/llvm-nm" "$l" 2>/dev/null | grep -c ' T rust_eh_personality$')" = 0 ] || NRUST=$((NRUST + 1)) ;; esac
done
for p in ${PACKAGES:-}; do [ -f "$D/pkg/$p/eh" ] && EH=1; done
[ -n "$EH" ] && WASM_FEATURES=(-W exceptions=y)
if [ "$NRUST" -gt 1 ] || [ -n "$EH" ]; then
  if [ ! -x "$SDK30/bin/wasm-ld" ]; then
    mkdir -p "$D/wasi-sdk-30-dl"
    curl -sSfL https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-30/wasi-sdk-30.0-$HOST.tar.gz | tar xz -C "$D/wasi-sdk-30-dl"
  fi
  LINK_FLAGS+=(-fuse-ld="$SDK30/bin/wasm-ld" -Wl,--allow-multiple-definition)
fi
# A 1 MiB shadow stack, first in memory so an overflow traps; the heap grows
# on demand up to MAX_MEMORY_MIB (default 96), below the isolate's 128 MB
# limit, so an allocation past it raises MemoryError in that request instead
# of growing memory until the isolate is killed. libpython is built with -g,
# so debug info is stripped.
"$SDK/bin/clang" --target=wasm32-wasip1 -mexec-model=reactor -O2 \
  -I "$PY/Include" -I "$PY/Include/internal" -I "$XB" -I "$GEN" -I c \
  ${LEAN:+-DCF_LEAN} cfworkers.c cfjs.c vfs.c entropy.c packages/snapshot.c snapshot-realloc.c c/tsgen_rt.c c/pytask.c \
  ${PKG_SRCS[@]+"${PKG_SRCS[@]}"} ${PKG_LIBS[@]+"${PKG_LIBS[@]}"} \
  "$XB/libpython3.14.a" $(find "$XB/Modules" -name '*.a') "$ZLIB/libz.a" \
  -ldl -lwasi-emulated-signal -lwasi-emulated-getpid -lwasi-emulated-process-clocks -lm \
  -Wl,-z,stack-size=1048576 -Wl,--stack-first -Wl,--strip-debug -Wl,--wrap=free -Wl,--wrap=realloc \
  -Wl,--max-memory=$(( ${MAX_MEMORY_MIB:-96} * 1048576 )) \
  ${LINK_FLAGS[@]+"${LINK_FLAGS[@]}"} -o "$OUT/core-raw.wasm"

# Pre-initialize: start Python with the stdlib and the app on preopened dirs,
# import the app, snapshot memory into the module. The runtime logs the app's
# classes (and whether its import waits for startup) for add-sections.mjs.
# An empty / makes the filesystem's root a directory holding the others, as
# in Pyodide, so chdir("/") (pytest's startup directory) works.
wasmtime wizer --init-func snapshot-initialize -S cli=y -W unknown-imports-trap=y ${WASM_FEATURES[@]+"${WASM_FEATURES[@]}"} \
  --dir "$LIB::/lib" --dir "$APP::/session/metadata" --dir "$SESSION_SITE::/session/lib/python3.14/site-packages" \
  --dir "$GEN/tmp::/tmp" --dir "$GEN/dev::/dev" --dir "$GEN/shrunk::/.build" --dir "$GEN/root::/" \
  -o "$OUT/core.wasm" "$OUT/core-raw.wasm" 2>"$GEN/wizer.log" || { cat "$GEN/wizer.log" >&2; exit 1; }
grep -v '^@@workers' "$GEN/wizer.log" >&2 || true
# A failed start still leaves a module behind; don't ship it.
if grep -q -e Traceback -e "Python failed" "$GEN/wizer.log"; then echo "pre-initialization failed" >&2; exit 1; fi
mkdir -p "$GEN/meta"
sed -n 's/^@@workers.classes@@ //p' "$GEN/wizer.log" > "$GEN/meta/classes.json"
[ -s "$GEN/meta/classes.json" ] || rm "$GEN/meta/classes.json"
if grep -q '^@@workers.init@@' "$GEN/wizer.log"; then touch "$GEN/meta/init"; fi
# The shim (the externref table, and the adapters between C and the
# bridge's imports and exports), merged into the snapshot; then the bridge.
python3 bindgen.py shim "$GEN/generic.json" "$OUT/core.wasm" -o "$GEN/shim.wat" --c-module python --defer "later()"
wasm-tools parse "$GEN/shim.wat" -o "$GEN/shim.wasm"
wasm-merge "$OUT/core.wasm" python "$GEN/shim.wasm" tsgen -o "$OUT/app-tw.wasm" \
  --enable-reference-types --enable-exception-handling --enable-multivalue --enable-bulk-memory \
  --enable-sign-ext --enable-mutable-globals --enable-nontrapping-float-to-int --enable-simd 2>&1 | grep -v "name subsection" >&2 || true
node add-sections.mjs "$OUT/app-tw.wasm" "$GEN/meta" "$APP"
"$BIN/ts-gen-bridge" generate "$IR" "$OUT/app-tw.wasm" --profile "$PROFILE" --factory -o "$GEN/bridge"
node host/package.mjs "$OUT/app-tw.wasm" "$OUT" --bridge "$GEN/bridge"
