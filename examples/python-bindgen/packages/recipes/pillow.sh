# Pillow with zlib (PNG), libjpeg-turbo, libwebp, FreeType (ImageFont) and
# Little CMS (ImageCms), each built static here. No TIFF, JPEG 2000, AVIF,
# Tk or XCB.
VERSION=13.0.0
KIND=setuptools
# Its JPEG codecs recover from libjpeg errors with setjmp/longjmp, which
# WASI implements with Wasm exceptions: compiled by wasi-sdk 30's clang with
# them on, and the Worker is linked and snapshotted with them (CXX_EH).
CXX_EH=1
LDFLAGS="-lsetjmp"
JPEG=3.1.2
JPEG_SHA256=8f0012234b464ce50890c490f18194f913a7b1f4e6a03d6644179fa0f867d0cf
WEBP=1.6.0
WEBP_SHA256=93a852c2b3efafee3723efd4636de855b46f9fe1efddd607e1f42f60fc8f2136
FREETYPE=2-14-1
FREETYPE_SHA256=44bd69d1f0750603410cfd4f26f1c5523c5a3a087a2dfa8639b757dc7c6677be
LCMS=2.17
LCMS_SHA256=d11af569e42a1baa1650d20ad61d12e41af4fead4aa7964a01f93b08b53ab074
PY_PACKAGES="src/PIL"

build_libs() {
  local p=$SRC/prefix
  if [ ! -f "$p/lib/libjpeg.a" ]; then
    fetch_tarball https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$JPEG/libjpeg-turbo-$JPEG.tar.gz \
      $JPEG_SHA256 "$SRC/jpeg"
    cmake_lib "$SRC/jpeg" "$p" -DWITH_SIMD=0 -DENABLE_SHARED=0 -DWITH_TURBOJPEG=0 -DWITH_TOOLS=0 -DWITH_TESTS=0
  fi
  if [ ! -f "$p/lib/libwebp.a" ]; then
    fetch_tarball https://github.com/webmproject/libwebp/archive/refs/tags/v$WEBP.tar.gz $WEBP_SHA256 "$SRC/webp"
    cmake_lib "$SRC/webp" "$p" -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
      -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF \
      -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF -DWEBP_USE_THREAD=OFF -DWEBP_ENABLE_SIMD=OFF \
      -DWEBP_BUILD_LIBWEBPMUX=ON
  fi
  if [ ! -f "$p/lib/libfreetype.a" ]; then
    fetch_tarball https://github.com/freetype/freetype/archive/refs/tags/VER-$FREETYPE.tar.gz $FREETYPE_SHA256 "$SRC/freetype"
    SJLJ=1 cmake_lib "$SRC/freetype" "$p" -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
      -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON
  fi
  if [ ! -f "$p/lib/liblcms2.a" ]; then
    # Little CMS is plain C with no configuration step needed: its sources.
    fetch_tarball https://github.com/mm2/Little-CMS/releases/download/lcms$LCMS/lcms2-$LCMS.tar.gz $LCMS_SHA256 "$SRC/lcms"
    mkdir -p "$p/lib" "$p/include" "$SRC/lcms/obj"
    local c
    for c in "$SRC"/lcms/src/*.c; do
      $CC -Os -DCMS_NO_PTHREADS -I"$SRC/lcms/include" -c "$c" -o "$SRC/lcms/obj/$(basename "${c%.c}").o"
    done
    "$SDK/bin/llvm-ar" rcs "$p/lib/liblcms2.a" "$SRC"/lcms/obj/*.o
    cp "$SRC"/lcms/include/*.h "$p/include/"
  fi
}

build_native() {
  build_libs
  local p=$SRC/prefix imaging
  # _imaging is _imaging.c, the files setup.py's _IMAGING names and all of
  # libImaging.
  imaging="src/_imaging.c$(for f in decode encode map display outline path; do printf ',src/%s.c' $f; done)"
  imaging="$imaging$(cd "$SRC/src" && for f in src/libImaging/*.c; do printf ',%s' "$f"; done)"
  EXT_SOURCES="PIL._imaging=$imaging PIL._imagingmath=src/_imagingmath.c PIL._imagingmorph=src/_imagingmorph.c
    PIL._imagingft=src/_imagingft.c PIL._imagingcms=src/_imagingcms.c PIL._webp=src/_webp.c"
  EXT_CFLAGS="-Isrc/libImaging -I$p/include -I$p/include/freetype2 -I$D/zlib/src -DHAVE_LIBZ -DHAVE_LIBJPEG
    -DHAVE_WEBPMUX -DPILLOW_VERSION=\"$VERSION\""
  CC="$SDK30/bin/clang --target=wasm32-wasip1 --sysroot=$SDK/share/wasi-sysroot $EH_CXXFLAGS -mllvm -wasm-enable-sjlj"
  default_setuptools
  cp "$p/lib/libjpeg.a" "$p/lib/libwebp.a" "$p/lib/libwebpmux.a" "$p/lib/libwebpdemux.a" "$p/lib/libsharpyuv.a" \
    "$p/lib/libfreetype.a" "$p/lib/liblcms2.a" "$OUT/lib/"
}
