# PyYAML with its C extension (yaml._yaml, Cython) over libyaml 0.2.5,
# compiled in, as in Pyodide's build.
VERSION=6.0.4
KIND=setuptools
CYTHON="yaml/_yaml.pyx"
LIBYAML="api dumper emitter loader parser reader scanner writer"
EXT_SOURCES="yaml._yaml=yaml/_yaml.c$(for f in $LIBYAML; do printf ',libyaml/src/%s.c' $f; done)"
EXT_CFLAGS="-Ilibyaml/include -Iyaml -DYAML_DECLARE_STATIC -DYAML_VERSION_MAJOR=0 -DYAML_VERSION_MINOR=2
  -DYAML_VERSION_PATCH=5 -DYAML_VERSION_STRING=\"0.2.5\""
PY_PACKAGES="lib/yaml lib/_yaml"
prepare_source() {
  fetch_tarball https://github.com/yaml/libyaml/releases/download/0.2.5/yaml-0.2.5.tar.gz \
    c642ae9b75fee120b2d96c712538bd2cf283228d2337df2cf2988e3c02678ef4 "$SRC/src/libyaml"
}
