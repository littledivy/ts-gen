"""How modules are compiled while the snapshot is built (cfworkers.c imports
this before anything else).

By default, as in Pyodide, nothing changes: every module keeps its
docstrings and asserts. With LEAN (build.sh), the standard library is
compiled as with -OO (no docstrings or asserts), and packages and the SDK
without docstrings, keeping their asserts. The app keeps both either way.
"""

import ast

try:
    import _cf_config

    LEAN = getattr(_cf_config, "LEAN", False)
except ImportError:
    LEAN = False


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


if LEAN:
    import importlib._bootstrap_external as _be
    import zipimport

    _get_code = _be.SourceFileLoader.get_code

    def get_code(self, fullname):
        path = self.get_filename(fullname)
        if "/site-packages/" in path:
            return _without_docstrings(self.get_data(path), path)
        return _get_code(self, fullname)

    def _compile_source(pathname, source):
        return compile(zipimport._normalize_line_endings(source), pathname, "exec", dont_inherit=True, optimize=2)

    _be.SourceFileLoader.get_code = get_code
    zipimport._compile_source = _compile_source
