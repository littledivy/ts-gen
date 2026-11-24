# shapely over GEOS 3.14 (C++, which throws: compiled with Wasm exceptions),
# built static here, with cxx-wasi/no-threads.h for its std::mutex. Its C extension (shapely.lib) and two Cython modules
# use numpy's C API.
VERSION=2.2.0
SDIST_URL=https://files.pythonhosted.org/packages/f3/ab/924b6e202f796d270a3041a230151f7908db5ea48c74effe6f8023e9bd05/shapely-2.2.0.tar.gz
SDIST_SHA256=e8865e553d874a1ec4a032057ea81fca9def37b188cd8fb550af3b3480b3f88c
KIND=setuptools
DEPENDS="numpy"
CXX_EH=1
GEOS=3.14.1
GEOS_SHA256=3c20919cda9a505db07b5216baa980bacdaa0702da715b43f176fb07eff7e716
CYTHON="src/shapely/_geometry_helpers.pyx src/shapely/_geos.pyx"
CYTHON_FLAGS="-Isrc/shapely -Isrc/shapely/lib -I$PYTHON_DEPS/sdist/numpy/src"
PY_PACKAGES="src/shapely"

build_native() {
  if [ ! -f "$SRC/prefix/lib/libgeos_c.a" ]; then
    fetch_tarball https://github.com/libgeos/geos/releases/download/$GEOS/geos-$GEOS.tar.bz2 $GEOS_SHA256 "$SRC/geos"
    EXTRA_CXXFLAGS="-include $HERE/cxx-wasi/no-threads.h" cmake_lib "$SRC/geos" "$SRC/prefix" \
      -DBUILD_GEOSOP=OFF -DBUILD_BENCHMARKS=OFF -DBUILD_DOCUMENTATION=OFF
  fi
  EXT_SOURCES="shapely.lib=$(cd "$SRC/src" && ls src/shapely/lib/*.c | paste -sd, -)
    shapely._geometry_helpers=src/shapely/_geometry_helpers.c shapely._geos=src/shapely/_geos.c"
  EXT_CFLAGS="-Isrc/shapely/lib -I$SRC/prefix/include -I$(numpy_include) -DGEOS_USE_ONLY_R_API -DNPY_NO_DEPRECATED_API=0"
  default_setuptools
  cp "$SRC/prefix/lib/libgeos_c.a" "$SRC/prefix/lib/libgeos.a" "$OUT/lib/"
  # The sdist's version module, which meson-python installs into the package.
  cp "$SRC/src/_version.py" "$OUT/site/shapely/_version.py"
}
