# pytest. Pure Python. While it runs it needs files (the tests it collects,
# and /tmp for tmp_path), which the in-memory filesystem has, and stdlib
# modules it imports lazily (unittest, doctest, pdb), so build with
# RUNTIME_IMPORTS=all. pytest-asyncio 1.1 needs pytest 8.
VERSION=8.4.2
KIND=pure
WHEELS="pytest==$VERSION pluggy==1.7.0 iniconfig==2.3.1 packaging==26.3 pygments==2.21.0"
