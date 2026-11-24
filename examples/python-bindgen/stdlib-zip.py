"""Packs the standard library into /lib/python314.zip, as Pyodide's
python314.zip is: the modules' sources (zipimport compiles them as they are
imported), and a directory entry for each package.

    python3.14 stdlib-zip.py LIB OUT.zip [--stored] [EXTRA.py...]

Left out, as Pyodide leaves them out: the tests, the GUI (tkinter, idlelib,
turtledemo), and the tools for installing packages or making environments
(ensurepip, venv). EXTRA files (sysconfig's data module) go at the top.
Members are deflated unless --stored is given, which leaves them for the
compression of the Worker's upload instead (smaller to upload, larger in
memory). The archive is the same for the same inputs.
"""

import os
import sys
import zipfile

SKIP = {"test", "tests", "idlelib", "tkinter", "turtledemo", "ensurepip", "venv", "__pycache__", "site-packages", "__phello__"}
SKIP_FILES = {"__hello__.py", "_pyio.py.orig"}
STAMP = (2000, 1, 1, 0, 0, 0)


def add(z, name, data, method):
    info = zipfile.ZipInfo(name, STAMP)
    info.external_attr = (0o40755 << 16) | 0x10 if name.endswith("/") else 0o100644 << 16
    info.compress_type = zipfile.ZIP_STORED if name.endswith("/") else method
    z.writestr(info, data, compresslevel=9 if method == zipfile.ZIP_DEFLATED else None)


def main(lib, out, stored, extra):
    method = zipfile.ZIP_STORED if stored else zipfile.ZIP_DEFLATED
    with zipfile.ZipFile(out + ".tmp", "w") as z:
        for path in extra:
            with open(path, "rb") as f:
                add(z, os.path.basename(path), f.read(), method)
        for dirpath, dirnames, filenames in os.walk(lib):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP)
            rel = os.path.relpath(dirpath, lib)
            if rel != ".":
                add(z, rel.replace(os.sep, "/") + "/", b"", method)
            for f in sorted(filenames):
                if not f.endswith(".py") or f in SKIP_FILES:
                    continue
                with open(os.path.join(dirpath, f), "rb") as fh:
                    data = fh.read()
                add(z, os.path.normpath(os.path.join(rel, f)).replace(os.sep, "/"), data, method)
    os.replace(out + ".tmp", out)


if __name__ == "__main__":
    args = sys.argv[1:]
    stored = "--stored" in args
    args = [a for a in args if a != "--stored"]
    main(args[0], args[1], stored, args[2:])
