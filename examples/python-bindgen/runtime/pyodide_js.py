"""Pyodide's JS API (`import pyodide_js`), for the parts Python code reaches
through it.

`_module` stands for the Emscripten module: stackSave() and HEAPU8 are the
C stack pointer and linear memory, and `_module.FS` is Emscripten's
filesystem API over the in-memory filesystem (vfs.c) Python itself uses, as
far as reading files goes: lookupPath, open, read, close and stat. A node's
usedBytes is the file's size until something sets it, and reads are clamped
to it, as Emscripten's are, and to the bytes the file holds.
"""

import os

import _cfjs
from _cf_runtime import PYODIDE_VERSION as version  # noqa: F401


class _Node:
    __slots__ = ("path", "_used")

    def __init__(self, path):
        self.path = path
        self._used = None

    @property
    def usedBytes(self):
        return os.stat(self.path).st_size if self._used is None else self._used

    @usedBytes.setter
    def usedBytes(self, value):
        self._used = int(value)

    @property
    def name(self):
        return os.path.basename(self.path)

    @property
    def mode(self):
        return os.stat(self.path).st_mode


class _Lookup:
    __slots__ = ("path", "node")

    def __init__(self, path, node):
        self.path, self.node = path, node


class _Stream:
    __slots__ = ("fd", "node", "path", "position")

    def __init__(self, fd, node):
        self.fd, self.node, self.path, self.position = fd, node, node.path, 0


# Emscripten's open flags, as numbers (O_RDONLY is 0).
_O_WRONLY, _O_RDWR, _O_CREAT, _O_EXCL, _O_TRUNC, _O_APPEND = 1, 2, 0o100, 0o200, 0o1000, 0o2000


class _FS:
    def __init__(self):
        self._nodes = {}

    def _node(self, path):
        path = os.path.realpath(path)
        node = self._nodes.get(path)
        if node is None:
            if not os.path.exists(path):
                raise FileNotFoundError(2, "No such file or directory", path)
            node = self._nodes[path] = _Node(path)
        return node

    def lookupPath(self, path, opts=None):
        return _Lookup(path, self._node(path))

    def open(self, path, flags=0, mode=0o666):
        if isinstance(flags, str):
            flags = {"r": 0, "r+": _O_RDWR, "w": _O_WRONLY | _O_CREAT | _O_TRUNC, "a": _O_WRONLY | _O_CREAT | _O_APPEND}[flags]
        f = os.O_RDWR if flags & _O_RDWR else os.O_WRONLY if flags & _O_WRONLY else os.O_RDONLY
        for emflag, flag in ((_O_CREAT, os.O_CREAT), (_O_EXCL, os.O_EXCL), (_O_TRUNC, os.O_TRUNC), (_O_APPEND, os.O_APPEND)):
            if flags & emflag:
                f |= flag
        fd = os.open(path, f, mode)
        return _Stream(fd, self._node(path))

    def read(self, stream, buffer, offset, length, position=None):
        pos = stream.position if position is None else int(position)
        # Clamped to usedBytes, as Emscripten does, and then to the file.
        n = max(0, min(int(length), stream.node.usedBytes - pos, os.fstat(stream.fd).st_size - pos))
        data = os.pread(stream.fd, n, pos) if n else b""
        if data:
            _cfjs.write_bytes(buffer, int(offset), data)
        if position is None:
            stream.position += len(data)
        return len(data)

    def close(self, stream):
        os.close(stream.fd)

    def stat(self, path, dontFollow=False):
        return os.lstat(path) if dontFollow else os.stat(path)

    def readdir(self, path):
        return [".", "..", *os.listdir(path)]

    def readFile(self, path, opts=None):
        with open(path, "rb") as f:
            data = f.read()
        if opts is not None and getattr(opts, "encoding", None) == "utf8":
            return data.decode()
        return data


class _Module:
    def __init__(self):
        self.FS = _FS()

    def stackSave(self):
        """The C stack pointer, in linear memory."""
        return _cfjs.stack_pointer()

    @property
    def HEAPU8(self):
        """Linear memory, as a Uint8Array."""
        import js

        return js.Uint8Array.new(_cfjs.memory().buffer)


_module = _Module()
