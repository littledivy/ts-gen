"""How modules are compiled while the snapshot is built (cfworkers.c imports
this before anything else).

- The standard library loads from bytecode compiled without docstrings or
  asserts (as with -OO), which build.sh compiles.
- Packages and the SDK (/site) are compiled without docstrings, keeping their
  asserts.
- The app keeps both.
"""

import ast
import importlib._bootstrap_external as _be
import marshal

_get_code = _be.SourceFileLoader.get_code


def _strip(body):
    if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant) and isinstance(body[0].value.value, str):
        doc = body.pop(0)
        if not body:
            body.append(ast.copy_location(ast.Pass(), doc))


def _without_docstrings(source, path):
    tree = ast.parse(source, path)
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            _strip(node.body)
    return compile(tree, path, "exec", dont_inherit=True)


def get_code(self, fullname):
    path = self.get_filename(fullname)
    if path.startswith("/lib/"):
        try:
            data = self.get_data(_be.cache_from_source(path, optimization=2))
        except OSError:
            pass
        else:
            return marshal.loads(memoryview(data)[16:])
    elif path.startswith("/site/"):
        return _without_docstrings(self.get_data(path), path)
    return _get_code(self, fullname)


_be.SourceFileLoader.get_code = get_code
