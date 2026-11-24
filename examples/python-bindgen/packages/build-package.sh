#!/bin/bash
# Builds one Python package for the WASI Python Worker from a recipe:
#
#   packages/build-package.sh <name>      # reads packages/recipes/<name>.sh
#
# A recipe sets:
#   VERSION   the version to build
#   KIND      pure | pyo3 | meson | setuptools
#   WHEELS    pure-Python distributions to install alongside (pip specs)
#   MODULES   native extension modules, as "dotted.module.name:PyInit_symbol"
#   LDFLAGS   extra link flags for the Worker, e.g. "-lc++ -lc++abi"
#   OPT_LEVEL the Rust opt-level for KIND=pyo3 (default 3)
#   DEPENDS   other recipes this one needs, which build.sh links in first
#   RUST_FEATURES  cargo features for KIND=pyo3
#   CXX_EH    1 to compile C++ with Wasm exceptions (see eh_cxx)
# and for KIND=setuptools (plain C extensions, compiled directly):
#   EXT_SOURCES  "dotted.module=src/a.c,src/b.c ..." per extension module;
#                each one is added to the inittab itself
#   EXT_CFLAGS   extra C flags for every extension module
#   PY_PACKAGES  package directories in the sdist to copy into site/
#   CYTHON       .pyx files in the sdist to cythonize first, to .c (or, for
#                C++ modules, .cpp) beside them
# and, for native kinds, may define `build_native` to override the default.
#
# Output goes to deps/pkg/<name>/:
#   lib/*.a     static libraries to link into the Worker
#   site/       Python files, put on sys.path and snapshotted by wizer
#   inittab     one "dotted.name PyInit_symbol" line per native module
#   ldflags     extra link flags
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../env.sh"
NAME=$1
D=$PYTHON_DEPS
SDK=$D/wasi-sdk-dl/wasi-sdk-24.0-$HOST
PY=$D/src/Python-3.14.10
XB=${PY_CROSS_BUILD:-$PY/cross-build/wasm32-wasip1-lean}
VENV=$D/venv
OUT=$D/pkg/$NAME
SRC=$D/sdist/$NAME
export PATH=$HOME/.cargo/bin:$PATH

VERSION= KIND= WHEELS= MODULES= SDIST= LDFLAGS= EXT_SOURCES= EXT_CFLAGS= PY_PACKAGES= CYTHON= DEPENDS= RUST_FEATURES= CXX_EH=
. "$HERE/recipes/$NAME.sh"
SDIST=${SDIST:-$NAME==$VERSION}

[ -x "$VENV/bin/pip" ] || { "$HOSTPY" -m venv "$VENV" && "$VENV/bin/pip" -q install meson cython; }
# The wheels are downloaded afresh, so a recipe's old versions aren't unpacked too.
rm -rf "$OUT" "$D/dl/$NAME" && mkdir -p "$OUT/lib" "$OUT/site" "$D/dl/$NAME"
: > "$OUT/inittab"

# Pure-Python distributions: wheels unpacked into site/.
for spec in $WHEELS; do
  "$VENV/bin/pip" download -q --no-deps --only-binary=:all: --python-version 3.14 \
    --platform any --implementation py -d "$D/dl/$NAME" "$spec" --disable-pip-version-check
done
for whl in "$D/dl/$NAME"/*.whl; do
  [ -e "$whl" ] || continue
  (cd "$OUT/site" && unzip -qo "$whl" -x '*.dist-info/RECORD')
done

# fetch_tarball <url> <sha256> <dir>: a source tarball a recipe needs besides
# its sdist (a C library it bundles), checked and unpacked into <dir>.
fetch_tarball() {
  local url=$1 sum=$2 dir=$3 tarball
  tarball=$D/dl/$(basename "$url")
  [ -f "$tarball" ] || curl -sSfL -o "$tarball" "$url"
  echo "$sum  $tarball" | shasum -a 256 -c --quiet
  rm -rf "$dir" && mkdir -p "$dir" && tar xzf "$tarball" -C "$dir" --strip-components 1
}

# cmake_lib <src dir> <prefix> [cmake options...]: a CMake C/C++ library a
# recipe bundles, built static for wasm32-wasip1 with wasi-sdk's toolchain
# file and installed into <prefix>, once. With SJLJ=1 it is compiled by
# wasi-sdk 30's clang with setjmp/longjmp over Wasm exceptions (a recipe
# using it sets CXX_EH=1, so the Worker is linked with them).
cmake_lib() {
  local src=$1 prefix=$2
  shift 2
  [ -f "$src/.built" ] && return
  local flags="-Os -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_GETPID -D_WASI_EMULATED_MMAN"
  local prefix_sdk=$SDK
  if [ -n "${SJLJ:-}" ]; then
    flags="$flags --sysroot=$SDK/share/wasi-sysroot $EH_CXXFLAGS -mllvm -wasm-enable-sjlj"
    prefix_sdk=$SDK30
  fi
  rm -rf "$src/build-wasi"
  cmake -S "$src" -B "$src/build-wasi" -G Ninja -Wno-dev \
    -DCMAKE_TOOLCHAIN_FILE="$SDK/share/cmake/wasi-sdk.cmake" -DWASI_SDK_PREFIX="$prefix_sdk" \
    -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=OFF \
    -DCMAKE_C_FLAGS="$flags" -DCMAKE_CXX_FLAGS="$flags -fno-exceptions" \
    -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib "$@" >"$src/cmake.log" 2>&1 ||
    { tail -20 "$src/cmake.log" >&2; return 1; }
  ninja -C "$src/build-wasi" -j"$NCPU" install >"$src/ninja.log" 2>&1 ||
    { grep -m5 -B2 -A3 "error" "$src/ninja.log" >&2; return 1; }
  touch "$src/.built"
}

fetch_sdist() {
  mkdir -p "$SRC"
  if [ ! -f "$SRC/src/.unpacked" ]; then
    ls "$SRC"/*.tar.gz >/dev/null 2>&1 ||
      "$VENV/bin/pip" download -q --no-deps --no-binary=:all: -d "$SRC" "$SDIST" --disable-pip-version-check
    local tarball
    tarball=$(ls "$SRC"/*.tar.gz | head -1)
    rm -rf "$SRC/src" && mkdir -p "$SRC/src" && tar xzf "$tarball" -C "$SRC/src" --strip-components 1
    if declare -F prepare_source >/dev/null; then prepare_source; fi
    local pyx
    for pyx in $CYTHON; do
      # A module declaring `distutils: language = c++` becomes a .cpp.
      if grep -q '^# *distutils: *language *= *c++' "$SRC/src/$pyx"; then
        (cd "$SRC/src" && "$VENV/bin/cython" -3 --cplus -X embedsignature=True "$pyx" -o "${pyx%.pyx}.cpp")
      else
        (cd "$SRC/src" && "$VENV/bin/cython" -3 -X embedsignature=True "$pyx" -o "${pyx%.pyx}.c")
      fi
    done
    touch "$SRC/src/.unpacked"
  fi
}

# The C flags every native build uses: the wasi-sdk compiler and CPython's headers.
CC="$SDK/bin/clang --target=wasm32-wasip1"
CXX="$SDK/bin/clang++ --target=wasm32-wasip1"
PYCFLAGS="-I$PY/Include -I$XB -Os -fPIC -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_GETPID"

# default_pyo3 <libname> [crate dir]: the crate (default: the sdist root)
# as a static library for wasm32-wasip1.
default_pyo3() {
  local libname=$1 crate=$SRC/src/${2:-}
  cat > "$D/pyo3-wasi.cfg" <<CFG
implementation=CPython
version=3.14
shared=false
abi3=false
lib_name=python3.14
lib_dir=$XB
executable=
pointer_width=32
build_flags=
suppress_build_script_link_lines=true
CFG
  (cd "$crate" && PYO3_CONFIG_FILE=$D/pyo3-wasi.cfg CARGO_PROFILE_RELEASE_OPT_LEVEL=${OPT_LEVEL:-3} \
    CARGO_TARGET_DIR=$SRC/src/target CC_wasm32_wasip1="$CC" AR_wasm32_wasip1=$SDK/bin/llvm-ar \
    CFLAGS_wasm32_wasip1="${RUST_CFLAGS:--Os}" \
    cargo rustc --release --target wasm32-wasip1 --crate-type staticlib --lib -q ${RUST_FEATURES:+--features "$RUST_FEATURES"})
  cp "$SRC/src/target/wasm32-wasip1/release/lib$libname.a" "$OUT/lib/"
}

# CXX_EH=1: C++ with Wasm exceptions, over libc++, libc++abi and libunwind
# built with them (libcxx-eh.sh): wasi-sdk 30's clang++ against wasi-sdk
# 24's sysroot. eh_cxx prints a compiler wrapper for it, and the package's
# ldflags name the libraries; the "eh" file tells build.sh to link and
# snapshot with exceptions on.
SDK30=$D/wasi-sdk-30-dl/wasi-sdk-30.0-$HOST
EH_CXXFLAGS="-fwasm-exceptions -mllvm -wasm-use-legacy-eh=false"
eh_cxx() {
  [ -f "$D/libcxx-eh/lib/libunwind.a" ] || "$HERE/libcxx-eh.sh" >&2
  cat <<SH
#!/bin/sh
for a; do shift; case \$a in -Wl,--start-group|-Wl,--end-group|-fexceptions) ;; *) set -- "\$@" "\$a";; esac; done
exec $SDK30/bin/clang++ --target=wasm32-wasip1 --sysroot=$SDK/share/wasi-sysroot -nostdinc++ \\
  -isystem $D/libcxx-eh/include/c++/v1 -isystem $D/libcxx-eh/include $EH_CXXFLAGS "\$@"
SH
}

# The target Python as Meson's `python`: the native build Python of the same
# version, reporting the wasm32-wasi sysconfig.
cross_python() {
  local bp
  bp=$(ls "$PY"/cross-build/*-apple-darwin*/python.exe "$PY"/cross-build/*-linux*/python 2>/dev/null | head -1 || true)
  # Meson runs anything named *.exe through mono; give it a plain name, next to
  # the original so it still finds its build tree.
  case $bp in *.exe) ln -sf python.exe "${bp%.exe}3"; bp=${bp%.exe}3;; esac
  cat > "$D/cross-python" <<SH
#!/bin/sh
_PYTHON_HOST_PLATFORM=wasi-wasm32 _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__wasi_wasm32-wasi \\
_PYTHON_PROJECT_BASE=$XB PYTHONPATH=$XB/\$(cat $XB/pybuilddir.txt)\${PYTHONPATH:+:\$PYTHONPATH} exec $bp "\$@"
SH
  chmod +x "$D/cross-python"
  mkdir -p "$D/crossbin" && ln -sf "$D/cross-python" "$D/crossbin/python3" && ln -sf "$D/cross-python" "$D/crossbin/python"
}

# Configures and compiles a Meson project for wasm32-wasip1, then archives each
# extension module's objects, and every static library the build produced, into
# lib/. A WASI build can't link shared modules, so those link steps are
# skipped; only the objects are wanted.
meson_cross_build() {
  local options=$1 meson=${2:-$VENV/bin/meson}
  cross_python
  # wasm-ld 18 has no --start-group/--end-group, which Meson passes to any lld.
  local tool
  for tool in clang clang++; do
    cat > "$D/crossbin/wasi-$tool" <<SH
#!/bin/sh
for a; do shift; case \$a in -Wl,--start-group|-Wl,--end-group) ;; *) set -- "\$@" "\$a";; esac; done
exec $SDK/bin/$tool --target=wasm32-wasip1 "\$@"
SH
    chmod +x "$D/crossbin/wasi-$tool"
  done
  # C++ is compiled without exceptions, or with CXX_EH=1 by eh_cxx.
  local cpp="['$D/crossbin/wasi-clang++', '-fno-exceptions']"
  if [ -n "$CXX_EH" ]; then
    eh_cxx > "$D/crossbin/wasi-eh-clang++" && chmod +x "$D/crossbin/wasi-eh-clang++"
    cpp="['$D/crossbin/wasi-eh-clang++']"
  fi
  cat > "$D/wasi-cross.ini" <<INI
[binaries]
c = '$D/crossbin/wasi-clang'
cpp = $cpp
ar = '$SDK/bin/llvm-ar'
strip = '$SDK/bin/llvm-strip'
python = '$D/cross-python'
cython = '$VENV/bin/cython'
pkg-config = 'false'

[built-in options]
c_args = ['-I$XB', '-Os', '-DPOCKETFFT_NO_MULTITHREADING', '-D_WASI_EMULATED_SIGNAL', '-D_WASI_EMULATED_PROCESS_CLOCKS', '-D_WASI_EMULATED_GETPID', '-D_WASI_EMULATED_MMAN']
cpp_args = ['-I$XB', '-Os', '-DPOCKETFFT_NO_MULTITHREADING', '-D_WASI_EMULATED_SIGNAL', '-D_WASI_EMULATED_PROCESS_CLOCKS', '-D_WASI_EMULATED_GETPID', '-D_WASI_EMULATED_MMAN']
c_link_args = ['-lwasi-emulated-signal', '-lwasi-emulated-process-clocks', '-lwasi-emulated-getpid', '-lwasi-emulated-mman']
cpp_link_args = ['-lwasi-emulated-signal', '-lwasi-emulated-process-clocks', '-lwasi-emulated-getpid', '-lwasi-emulated-mman']

[properties]
needs_exe_wrapper = true
longdouble_format = 'IEEE_QUAD_LE'

[host_machine]
system = 'wasi'
cpu_family = 'wasm32'
cpu = 'wasm32'
endian = 'little'
INI
  local build=$SRC/build-wasi
  rm -rf "$build"
  (cd "$SRC/src" && PATH=$D/crossbin:$VENV/bin:$PATH "$D/cross-python" "$meson" setup "$build" \
      --cross-file "$D/wasi-cross.ini" --buildtype=release -Db_ndebug=true $options)
  # Compile everything; shared-module link steps fail on WASI and are ignored.
  PATH=$D/crossbin:$VENV/bin:$PATH ninja -C "$build" -k 0 >"$build/ninja.log" 2>&1 || true
  if grep -q "error:" "$build/ninja.log" && grep -B2 "error:" "$build/ninja.log" | grep -q "\.o$\|\.c\b\|\.cpp\b"; then
    grep -m5 -B3 "error:" "$build/ninja.log" >&2
  fi
  local n=0 dir name
  for dir in $(find "$build" -type d -name '*.so.p'); do
    name=$(basename "$dir" .so.p); name=${name%%.cpython-*}
    find "$dir" -name '*.o' | sort > "$build/$name.objs"
    [ -s "$build/$name.objs" ] || continue
    "$SDK/bin/llvm-ar" rcs "$OUT/lib/libpyext_$(echo "$dir" | md5 -q | cut -c1-6)_$name.a" $(cat "$build/$name.objs")
    n=$((n + 1))
  done
  # Meson writes thin archives, which only point at their objects: copy each
  # as a regular archive.
  local a members
  for a in $(find "$build" -name '*.a'); do
    if head -c 7 "$a" | grep -q '!<thin>'; then
      members=$(cd "$(dirname "$a")" && "$SDK/bin/llvm-ar" t "$a" | sed "s|^\([^/]\)|$(dirname "$a")/\1|")
      rm -f "$OUT/lib/$(basename "$a")"
      "$SDK/bin/llvm-ar" rcs "$OUT/lib/$(basename "$a")" $members
    else
      cp "$a" "$OUT/lib/"
    fi
  done
  echo "archived $n extension modules from $build"
}

# KIND=setuptools: compiles each extension module's C (or C++) sources with
# CPython's headers into its own static library (EXT_CFLAGS' paths are
# relative to the sdist root), and copies the Python
# packages. Every module's init function is renamed after its full dotted
# name (PyInit__core in msgspec._core becomes PyInit_msgspec__core), so two
# packages' modules with the same last name can be linked into one Worker.
default_setuptools() {
  local entry mod srcs src objs obj sym cxx="$CXX -fno-exceptions"
  if [ -n "$CXX_EH" ]; then
    mkdir -p "$D/crossbin" && eh_cxx > "$D/crossbin/wasi-eh-clang++" && chmod +x "$D/crossbin/wasi-eh-clang++"
    cxx=$D/crossbin/wasi-eh-clang++
  fi
  for entry in $EXT_SOURCES; do
    mod=${entry%%=*} srcs=${entry#*=} objs=() sym=PyInit_${mod//./_}
    mkdir -p "$SRC/build-wasi/$mod"
    for src in ${srcs//,/ }; do
      obj=$SRC/build-wasi/$mod/$(basename "${src%.*}").o
      case $src in
        *.cpp|*.cc|*.cxx) (cd "$SRC/src" && $cxx $PYCFLAGS $EXT_CFLAGS -DPyInit_${mod##*.}=$sym -c "$src" -o "$obj") ;;
        *) (cd "$SRC/src" && $CC $PYCFLAGS $EXT_CFLAGS -DPyInit_${mod##*.}=$sym -c "$src" -o "$obj") ;;
      esac
      objs+=("$obj")
    done
    "$SDK/bin/llvm-ar" rcs "$OUT/lib/libpyext_${mod//./_}.a" "${objs[@]}"
    echo "$mod $sym" >> "$OUT/inittab"
  done
  for src in $PY_PACKAGES; do cp -R "$SRC/src/$src" "$OUT/site/"; done
  find "$OUT/site" \( -name '*.c' -o -name '*.h' -o -name '*.cpp' -o -name '*.pyx' -o -name '*.pxd' -o -name '*.so' \) -delete
}

if [ "$KIND" != pure ]; then
  fetch_sdist
  if declare -F build_native >/dev/null; then build_native
  elif [ "$KIND" = setuptools ]; then default_setuptools
  else echo "recipe $NAME: KIND=$KIND needs build_native" >&2; exit 1; fi
fi
for m in $MODULES; do echo "${m%%:*} ${m##*:}" >> "$OUT/inittab"; done
# The built distribution's metadata (the sdist's PKG-INFO), so
# importlib.metadata finds it as it would an installed wheel.
if [ "$KIND" != pure ] && [ -f "$SRC/src/PKG-INFO" ]; then
  dist=$(sed -n 's/^Name: //p' "$SRC/src/PKG-INFO" | head -1 | tr -- '-.' '__')
  mkdir -p "$OUT/site/$dist-$VERSION.dist-info"
  cp "$SRC/src/PKG-INFO" "$OUT/site/$dist-$VERSION.dist-info/METADATA"
  echo cf-workers > "$OUT/site/$dist-$VERSION.dist-info/INSTALLER"
fi
if [ -n "$CXX_EH" ]; then
  LDFLAGS="-L$D/libcxx-eh/lib -lc++ -lc++abi -lunwind $LDFLAGS"
  touch "$OUT/eh"
fi
echo "$LDFLAGS" > "$OUT/ldflags"
# Drop what never runs in a Worker: bytecode, type stubs, tests.
find "$OUT/site" \( -name '__pycache__' -o -name tests -o -name testing \) -type d -prune -exec rm -rf {} +
find "$OUT/site" \( -name '*.pyi' -o -name py.typed \) -delete
# build.sh rebuilds a package whose recipe no longer matches this.
shasum "$HERE/recipes/$NAME.sh" | cut -c1-12 > "$OUT/.recipe"
echo "built $NAME $VERSION -> $OUT ($(ls "$OUT/lib" | wc -l | tr -d ' ') libs, $(wc -l < "$OUT/inittab" | tr -d ' ') native modules)"
