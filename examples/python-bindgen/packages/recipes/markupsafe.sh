# MarkupSafe: one C extension (markupsafe._speedups); the template for any
# package whose extension modules are plain C sources.
VERSION=3.0.3
SDIST=markupsafe==$VERSION
KIND=setuptools
# Each extension module and its sources, relative to the sdist root.
EXT_SOURCES="markupsafe._speedups=src/markupsafe/_speedups.c"
PY_PACKAGES="src/markupsafe"
