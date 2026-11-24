# numpy, built with its vendored Meson for wasm32-wasip1: no SIMD dispatch, no
# threads, no BLAS (numpy's bundled lapack-lite).
VERSION=2.5.5
KIND=meson
# Its C++ (pocketfft for numpy.fft, np.unique's hash path, sorting) throws
# and catches, so it is compiled with Wasm exceptions.
CXX_EH=1
LDFLAGS="-lc-printscan-long-double"
MODULES="
numpy._core._multiarray_umath:PyInit__multiarray_umath
numpy._core._simd:PyInit__simd
numpy.linalg._umath_linalg:PyInit__umath_linalg
numpy.linalg.lapack_lite:PyInit_lapack_lite
numpy.fft._pocketfft_umath:PyInit__pocketfft_umath
numpy.random._common:PyInit__common
numpy.random.bit_generator:PyInit_bit_generator
numpy.random._bounded_integers:PyInit__bounded_integers
numpy.random._mt19937:PyInit__mt19937
numpy.random._philox:PyInit__philox
numpy.random._pcg64:PyInit__pcg64
numpy.random._sfc64:PyInit__sfc64
numpy.random._generator:PyInit__generator
numpy.random.mtrand:PyInit_mtrand
"
build_native() {
  meson_cross_build "-Dallow-noblas=true -Dblas=none -Dlapack=none -Ddisable-threading=true
    -Ddisable-optimization=true -Ddisable-highway=true -Ddisable-svml=true -Ddisable-intel-sort=true
    -Dcpu-baseline=none -Dcpu-dispatch=none" "$SRC/src/vendored-meson/meson/meson.py"
  # The Python half: numpy's .py sources plus the ones the build generated
  # (version.py, __config__.py, ...).
  (cd "$SRC/src" && find numpy -name '*.py' -not -path '*/tests/*' -not -path 'numpy/f2py/*' \
      -not -path 'numpy/_pyinstaller/*' -not -path 'numpy/typing/*' | cpio -pdm "$OUT/site" 2>/dev/null)
  (cd "$SRC/build-wasi" && find numpy -name '*.py' | cpio -pdmu "$OUT/site" 2>/dev/null)
  # Packages are compiled without docstrings but with their asserts, and
  # numpy.ma asserts on np.fromfunction's docstring unless it is None (as
  # with -OO); finalize_array_function_like makes a missing one "".
  sed -i '' 's/^    if func.__doc__ is not None:$/    if func.__doc__:/' "$OUT/site/numpy/ma/core.py"
  grep -q '^    if func.__doc__:$' "$OUT/site/numpy/ma/core.py"
}
