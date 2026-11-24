"""Copies a tree of library files, smaller, for the in-memory filesystem
(vfs.c) that requests import from:

    python3.14 shrink.py SRC DST

A module loses its comments and docstrings (which _cf_bytecode drops when
compiling it anyway), each line staying where it was so tracebacks still
point at the right one. A distribution's METADATA loses the long
description after its headers. Other files are copied as they are;
__pycache__ is skipped.
"""

import io
import os
import shutil
import sys
import tokenize


def shrink_module(data):
    try:
        text = data.decode("utf-8")
        tokens = list(tokenize.generate_tokens(io.StringIO(text).readline))
    except (UnicodeDecodeError, SyntaxError, tokenize.TokenError):
        return data
    starts = [0]
    for line in text.splitlines(keepends=True):
        starts.append(starts[-1] + len(line))
    edits = []
    statement_start = True
    for i, tok in enumerate(tokens):
        if tok.type == tokenize.COMMENT:
            edits.append((tok.start, tok.end, ""))
        elif tok.type == tokenize.STRING and statement_start:
            nxt = next((t for t in tokens[i + 1 :] if t.type not in (tokenize.COMMENT, tokenize.NL)), None)
            if nxt is not None and nxt.type in (tokenize.NEWLINE, tokenize.ENDMARKER):
                lines = tok.string.count("\n")
                edits.append((tok.start, tok.end, '"""' + "\n" * lines + '"""' if lines else '""'))
        if tok.type not in (tokenize.COMMENT, tokenize.NL):
            statement_start = tok.type in (tokenize.NEWLINE, tokenize.INDENT, tokenize.DEDENT, tokenize.ENCODING)
    out = []
    pos = 0
    for (sr, sc), (er, ec), rep in edits:
        a, b = starts[sr - 1] + sc, starts[er - 1] + ec
        out.append(text[pos:a])
        out.append(rep)
        pos = b
    out.append(text[pos:])
    shrunk = "".join(out).encode("utf-8")
    # Keep the original if the result doesn't compile the same way.
    try:
        compile(shrunk, "<shrunk>", "exec", dont_inherit=True)
    except SyntaxError:
        return data
    return shrunk


def shrink(path, data):
    if path.endswith(".py"):
        return shrink_module(data)
    if path.endswith(os.path.join(".dist-info", "METADATA")):
        end = data.find(b"\n\n")
        return data if end < 0 else data[: end + 1]
    return data


def main(src, dst):
    for dirpath, dirnames, filenames in os.walk(src):
        dirnames[:] = [d for d in dirnames if d != "__pycache__"]
        out_dir = os.path.join(dst, os.path.relpath(dirpath, src))
        os.makedirs(out_dir, exist_ok=True)
        for f in filenames:
            path = os.path.join(dirpath, f)
            if f.endswith(".py") or f == "METADATA":
                with open(path, "rb") as fh:
                    data = shrink(path, fh.read())
                with open(os.path.join(out_dir, f), "wb") as fh:
                    fh.write(data)
            else:
                shutil.copyfile(path, os.path.join(out_dir, f))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
