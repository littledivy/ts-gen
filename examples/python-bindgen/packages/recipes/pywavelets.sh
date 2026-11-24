# PyWavelets: four Cython modules over its C wavelet transforms, built on
# numpy's C API. The C sources go into _pywt alone, as the other three
# modules are linked into the same Worker.
VERSION=1.10.0
SDIST_URL=https://files.pythonhosted.org/packages/25/84/a9e80e33eb114e78bd2f1829a90d72d8d4d660109c721a8aa2f0d58d7592/pywavelets-$VERSION.tar.gz
SDIST_SHA256=f3cb8640225a8f3fdcbc3f6f3bd112c78927c9407cbfa65a5ff303990a6a3e32
KIND=setuptools
DEPENDS="numpy"
CYTHON="pywt/_extensions/_pywt.pyx pywt/_extensions/_dwt.pyx pywt/_extensions/_swt.pyx pywt/_extensions/_cwt.pyx"
CYTHON_FLAGS="-Ipywt/_extensions -I$PYTHON_DEPS/sdist/numpy/src"
PY_PACKAGES="pywt"
build_native() {
  local c=pywt/_extensions/c
  EXT_SOURCES="pywt._extensions._pywt=pywt/_extensions/_pywt.c,$c/common.c,$c/convolution.c,$c/cwt.c,$c/wavelets.c,$c/wt.c
    pywt._extensions._dwt=pywt/_extensions/_dwt.c pywt._extensions._swt=pywt/_extensions/_swt.c
    pywt._extensions._cwt=pywt/_extensions/_cwt.c"
  EXT_CFLAGS="-I$c -I$(numpy_include) -DPY_EXTENSION -D_USE_MATH_DEFINES -DNPY_NO_DEPRECATED_API=NPY_1_22_API_VERSION"
  default_setuptools
  rm -rf "$OUT/site/pywt/tests" "$OUT/site/pywt/meson.build" "$OUT/site/pywt/_extensions/meson.build"
  cat > "$OUT/site/pywt/version.py" <<PY
short_version = '$VERSION'
version = '$VERSION'
full_version = '$VERSION'
git_revision = ''
release = True
PY
}
