#!/bin/bash
# Builds libc++, libc++abi and libunwind for wasm32-wasip1 with Wasm
# exception handling, into deps/libcxx-eh/ (include/, lib/):
#
#   packages/libcxx-eh.sh
#
# wasi-sdk's own libc++ has exceptions turned off, so C++ code that throws
# can only trap. These are LLVM 21's runtimes compiled by wasi-sdk 30's
# clang against wasi-sdk 24's sysroot (the libc libpython is built with),
# with the standard exnref encoding (-wasm-use-legacy-eh=false) that
# wasmtime, and so Wizer, runs. C++ that links them is compiled with
# eh_cxxflags (below) by the same clang, and the Worker links with wasi-sdk
# 30's wasm-ld. ABI version 2 and no threads, as wasi-sdk 24's libc++.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../env.sh"
D=$PYTHON_DEPS
SDK=$D/wasi-sdk-dl/wasi-sdk-24.0-$HOST
SDK30=$D/wasi-sdk-30-dl/wasi-sdk-30.0-$HOST
LLVM_VERSION=21.1.4
LLVM=$D/llvm-src/llvm-project-$LLVM_VERSION.src
OUT=$D/libcxx-eh
EH_FLAGS="-fwasm-exceptions -mllvm -wasm-use-legacy-eh=false"

if [ ! -x "$SDK30/bin/clang" ]; then
  mkdir -p "$D/wasi-sdk-30-dl"
  curl -sSfL https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-30/wasi-sdk-30.0-$HOST.tar.gz | tar xz -C "$D/wasi-sdk-30-dl"
fi
# The runtimes' sources, and LLVM libc's shared headers, which libc++'s
# from_chars uses.
if [ ! -d "$LLVM/libc/shared" ]; then
  TAR=$D/llvm-dl/llvm-project-$LLVM_VERSION.src.tar.xz
  [ -f "$TAR" ] || { mkdir -p "$D/llvm-dl" && curl -sSfL -o "$TAR" \
    https://github.com/llvm/llvm-project/releases/download/llvmorg-$LLVM_VERSION/llvm-project-$LLVM_VERSION.src.tar.xz; }
  echo "a01ad7e5167780c945871d75c0413081d12067607a6de5cf71dc3e8d1a82112c  $TAR" | shasum -a 256 -c --quiet
  mkdir -p "$D/llvm-src"
  tar xJf "$TAR" -C "$D/llvm-src" \
    llvm-project-$LLVM_VERSION.src/{cmake,libc,libcxx,libcxxabi,libunwind,llvm/cmake,llvm/utils/llvm-lit,runtimes,third-party}
fi

BUILD=$OUT/build
rm -rf "$OUT" && mkdir -p "$BUILD"
cmake -G Ninja -S "$LLVM/runtimes" -B "$BUILD" \
  -DCMAKE_MODULE_PATH="$SDK30/share/cmake" \
  -DCMAKE_SYSTEM_NAME=WASI -DCMAKE_SYSTEM_VERSION=1 -DCMAKE_SYSTEM_PROCESSOR=wasm32 \
  -DCMAKE_BUILD_TYPE=MinSizeRel \
  -DCMAKE_C_COMPILER="$SDK30/bin/clang" -DCMAKE_CXX_COMPILER="$SDK30/bin/clang++" \
  -DCMAKE_AR="$SDK30/bin/llvm-ar" -DCMAKE_RANLIB="$SDK30/bin/llvm-ranlib" \
  -DCMAKE_C_COMPILER_TARGET=wasm32-wasip1 -DCMAKE_CXX_COMPILER_TARGET=wasm32-wasip1 \
  -DCMAKE_SYSROOT="$SDK/share/wasi-sysroot" \
  -DCMAKE_C_COMPILER_WORKS=ON -DCMAKE_CXX_COMPILER_WORKS=ON \
  -DCMAKE_C_FLAGS="$EH_FLAGS -I$LLVM/libunwind/include" -DCMAKE_CXX_FLAGS="$EH_FLAGS -I$LLVM/libunwind/include" \
  -DCMAKE_INSTALL_PREFIX="$OUT" \
  -DLLVM_ENABLE_RUNTIMES="libcxxabi;libcxx" -DLLVM_COMPILER_CHECKED=ON -DUNIX=ON \
  -DLIBCXXABI_ENABLE_SHARED=OFF -DLIBCXXABI_ENABLE_THREADS=OFF -DLIBCXXABI_ENABLE_EXCEPTIONS=ON \
  -DLIBCXXABI_USE_LLVM_UNWINDER=OFF -DLIBCXXABI_SILENT_TERMINATE=ON -DLIBCXXABI_INCLUDE_TESTS=OFF \
  -DLIBCXX_ENABLE_SHARED=OFF -DLIBCXX_ENABLE_THREADS=OFF -DLIBCXX_ENABLE_EXCEPTIONS=ON \
  -DLIBCXX_CXX_ABI=libcxxabi -DLIBCXX_HAS_MUSL_LIBC=ON -DLIBCXX_ABI_VERSION=2 \
  -DLIBCXX_ENABLE_FILESYSTEM=ON \
  -DLIBCXX_INCLUDE_TESTS=OFF -DLIBCXX_INCLUDE_BENCHMARKS=OFF -DLIBCXX_ENABLE_ABI_LINKER_SCRIPT=OFF \
  >"$OUT/cmake.log"
ninja -C "$BUILD" install >"$OUT/ninja.log"
# libunwind for Wasm is Unwind-wasm.c alone (the VM unwinds; this calls the
# personality function), which its CMake build doesn't single out.
"$SDK30/bin/clang" --target=wasm32-wasip1 --sysroot="$SDK/share/wasi-sysroot" $EH_FLAGS -std=c99 -fexceptions -Os \
  -I"$LLVM/libunwind/include" -D_LIBUNWIND_IS_NATIVE_ONLY -D_LIBUNWIND_HAS_NO_THREADS -D_LIBUNWIND_HIDE_SYMBOLS -DNDEBUG \
  -c "$LLVM/libunwind/src/Unwind-wasm.c" -o "$BUILD/Unwind-wasm.o"
"$SDK30/bin/llvm-ar" rcs "$OUT/lib/libunwind.a" "$BUILD/Unwind-wasm.o"
cp "$LLVM/libunwind/include/"*.h "$OUT/include/"
rm -rf "$BUILD"
echo "built libc++, libc++abi and libunwind with Wasm exceptions -> $OUT"
