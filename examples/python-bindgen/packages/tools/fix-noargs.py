"""Gives METH_NOARGS methods the two parameters CPython calls them with.

A C extension may define a METH_NOARGS method as `f(PyObject *self)` and
cast it to PyCFunction. Native ABIs ignore the extra argument CPython
passes, but Wasm checks the type of an indirect call and traps. Each such
definition (and declaration) gets a second, unused parameter.

    python fix-noargs.py file.c ...
"""

import re
import sys

ENTRY = re.compile(r"\{\s*\"[^\"]+\"\s*,\s*\(\s*PyCFunction\s*\)\s*(\w+)\s*,\s*METH_NOARGS")
for path in sys.argv[1:]:
    with open(path) as f:
        src = f.read()
    names = set(ENTRY.findall(src))
    n = 0
    for name in names:
        # `name(Type *self)` or `name(Type *self, ...)` without a second param.
        pat = re.compile(r"(\b" + name + r"\s*\(\s*[\w\s]+\*\s*\w+\s*)\)")
        src, k = pat.subn(r"\1, PyObject *Py_UNUSED(_cf_ignored))", src)
        n += k
    with open(path, "w") as f:
        f.write(src)
    print(f"fix-noargs: {path}: {n} signatures", file=sys.stderr)
