# yarl: one Cython extension (yarl._quoting_c).
VERSION=1.25.1
KIND=setuptools
CYTHON="yarl/_quoting_c.pyx"
EXT_SOURCES="yarl._quoting_c=yarl/_quoting_c.c"
PY_PACKAGES="yarl"
DEPENDS="multidict propcache"
WHEELS="idna"
