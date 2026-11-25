#!/usr/bin/env python3
"""python-bindgen: C bindings for CPython bound through a ts-gen bridge.

Reads the lowered JSON (`ts-gen-abi lower`, under a memory32 linear profile
with `results = multi`). C can't hold an externref, so every call goes
through a generated Wasm shim that owns the module's `tw:table`: JS values
are slots of that table (int32_t), extra results come back through a return
area, and the shim is merged into the C module with wasm-merge after it is
linked (and, for a snapshotted module, after the snapshot, since a table of
JS values can't be snapshotted).

    python3 bindgen.py header <lowered.json> -o <tsgen.h>
    python3 bindgen.py shim <lowered.json> <c.wasm> -o <shim.wat> --c-module <name> [--defer <key>]

`header` declares, for every import the IR has (members, and the `tw`
protocol operations its types need: futures, callbacks), a C function
imported from module "tsgen" under the name "<module>::<name>":

    externref params      int32_t slot (borrowed)
    one externref result  int32_t slot (owned; 0 for null)
    several results       a last `tw_slot *ret` parameter, one 8-byte slot
                          per result, externrefs as owned slots

and, for every export and callback trampoline, the C function the shim
calls, exported from C as "cfts:<name>" with the same conventions (its
externref params are slots the C side now owns; an externref result is a
slot the shim takes and frees). C also exports the slot allocator the shim
uses (cfts_slot_alloc, cfts_slot_free), tw:table/alloc, tw:table/free,
tw:realloc and tw:free.

`shim` writes the shim for the imports and exports the linked C module
(<c.wasm>, merged under the name <name>) actually has. With --defer, every
export or trampoline returning a future first checks cfts_running(): if the
C side is running, JS called it synchronously from inside an import, and the
call waits for the future <key> (a host import that settles once the running
code has suspended or returned) before entering C, so calls into the module
nest strictly.
"""

import json
import re
import sys

C_TYPE = {"i32": "int32_t", "i64": "int64_t", "f32": "float", "f64": "double", "externref": "int32_t"}


def fail(msg):
    raise SystemExit(f"python-bindgen: {msg}")


def collect(lowered):
    """Every import and export of the IR, at the wire level."""
    p = lowered["profile"]
    if p.get("results") != "multi" or p.get("memory") != "32":
        fail("needs a memory32 profile with results = multi")
    imports = {}
    exports = {}

    def add_import(module, name, params, results):
        imports.setdefault(f"{module}::{name}", {"module": module, "name": name, "params": params, "results": results})

    def visit(r):
        if not isinstance(r, dict):
            return
        if r.get("kind") == "host" and r.get("of") == "future":
            add_import("tw:future", "drop", ["externref"], [])
            add_import("tw:future", "new", [], ["externref", "externref"])
            if p.get("jspi") == "on":
                add_import("tw:future", "suspend", ["externref"], ["i32"])
                add_import("tw:future", "suspend_race", ["i32", "i32"], ["i32"])
            if r.get("take"):
                add_import(r["take"]["module"], r["take"]["name"], ["externref"], r["value"]["wire"])
            if r.get("resolve"):
                add_import(r["resolve"]["module"], r["resolve"]["name"], ["externref", *r["value"]["wire"]], [])
            visit(r.get("value"))
        if r.get("kind") == "fn" and r.get("provided") == "linear":
            box = r.get("box")
            if box:
                add_import(box["import"]["module"], box["import"]["name"], box["params"], box["results"])
            params = ["i32", *(w for q in r["params"] for w in q["wire"])]
            exports[r["trampoline"]] = {
                "name": r["trampoline"],
                "params": params,
                "results": r["result"]["wire"],
                "future": r["result"].get("of") == "future",
            }
            drop = f"tw:drop:{r['ty']}"
            exports[drop] = {"name": drop, "params": ["i32"], "results": [], "direct": True}
        for v in r.values():
            if isinstance(v, list):
                for e in v:
                    visit(e)
            elif isinstance(v, dict):
                visit(v)

    for m in lowered["members"]:
        sig = m["sig"]
        if sig.get("throws"):
            fail(f"{m['key']}: throws isn't supported")
        params = [w for q in sig["params"] for w in q["repr"]["wire"]]
        results = [w for q in sig["results"] for w in q["repr"]["wire"]]
        if m["role"] == "import":
            add_import(m.get("module") or "tw:js/global", m["key"], params, results)
        elif m["role"] == "export":
            future = len(sig["results"]) == 1 and sig["results"][0]["repr"].get("of") == "future"
            exports[m["key"]] = {"name": m["key"], "params": params, "results": results, "future": future}
        for q in [*sig["params"], *sig["results"]]:
            visit(q["repr"])
    for e in exports.values():
        if not e.get("direct") and len(e["results"]) > 1:
            fail(f"{e['name']}: an export with several results isn't supported")
    return list(imports.values()), list(exports.values())


def ident(s):
    """A C identifier, without the IR's punctuation."""
    return re.sub(r"^_+|_+$", "", re.sub(r"[^A-Za-z0-9]+", "_", s))


def c_name(imp):
    """tw_<module>_<name> for an import; a global's arguments are left out."""
    module = imp["module"]
    mod = "" if module == "tw:js/global" or not module.startswith("tw:") else f"{ident(module[3:])}_"
    name = imp["name"] if module.startswith("tw:") else re.sub(r"\(.*$", "", imp["name"], count=1)
    return f"tw_{mod}{ident(name)}"


def flat(params, results):
    ps = [C_TYPE[w] for w in params]
    ret = "void"
    if len(results) == 1:
        ret = C_TYPE[results[0]]
    elif len(results) > 1:
        ps.append("tw_slot *ret")
    return ps, ret


def js_str(s):
    """A string literal as JSON.stringify writes it."""
    return json.dumps(s, ensure_ascii=False)


def header(lowered):
    imports, exports = collect(lowered)
    out = [
        "// Generated by python-bindgen. Do not edit.",
        "#pragma once",
        "#include <stdint.h>",
        "",
        "typedef union { int32_t i32; int64_t i64; float f32; double f64; } tw_slot;",
        "",
        '#define TW_IMPORT(n) __attribute__((import_module("tsgen"), import_name(n)))',
        "",
        "// The shim's table operations.",
        'TW_IMPORT("tsgen_table_grow") int32_t tsgen_table_grow(int32_t n);',
        'TW_IMPORT("tsgen_ref_clear") void tsgen_ref_clear(int32_t base, int32_t n);',
        'TW_IMPORT("tsgen_ref_copy") void tsgen_ref_copy(int32_t dst, int32_t src);',
        'TW_IMPORT("tsgen_ref_is_null") int32_t tsgen_ref_is_null(int32_t slot);',
        "",
    ]
    # Each enum's arm indices.
    for d in lowered["decls"]:
        if d.get("kind") != "enum":
            continue
        for a in d["layout"]["arms"]:
            out.append(f"#define TW_{ident(d['path'])}_{ident(a['name'])} {a['index']}")
    out.append("")
    seen = set()
    for imp in imports:
        n = c_name(imp)
        while n in seen:
            n += "_"
        seen.add(n)
        ps, ret = flat(imp["params"], imp["results"])
        out.append(f'// ("{imp["module"]}", "{imp["name"]}")')
        out.append(f"TW_IMPORT({js_str(imp['module'] + '::' + imp['name'])}) {ret} {n}({', '.join(ps) or 'void'});")
    out += ["", '// Exports and trampolines: export_name("cfts:<name>") definitions the shim calls.']
    for e in exports:
        ps, ret = flat(e["params"], e["results"])
        name = js_str(e["name"]) if e.get("direct") else f'"cfts:{e["name"]}"'
        out.append(f"// {name}: {ret} ({', '.join(ps)})")
    return "\n".join(out) + "\n"


def wat(s):
    """A WAT string literal."""
    return re.sub(r"\\u([0-9a-f]{4})", r"\\u{\1}", js_str(s))


def wasm_names(path):
    """The (module, name) of every import, and the name of every export, of a
    core Wasm module."""
    b = open(path, "rb").read()
    if b[:4] != b"\0asm":
        fail(f"{path}: not a Wasm module")
    i = 8

    def leb():
        nonlocal i
        v = shift = 0
        while True:
            x = b[i]
            i += 1
            v |= (x & 0x7F) << shift
            shift += 7
            if not x & 0x80:
                return v

    def name():
        nonlocal i
        n = leb()
        s = b[i : i + n].decode()
        i += n
        return s

    def limits():
        nonlocal i
        flags = b[i]
        i += 1
        leb()
        if flags & 1:
            leb()

    imports, exports = [], []
    while i < len(b):
        sid = b[i]
        i += 1
        size = leb()
        end = i + size
        if sid == 2:
            for _ in range(leb()):
                module, field = name(), name()
                imports.append((module, field))
                kind = b[i]
                i += 1
                if kind == 0:  # func: type index
                    leb()
                elif kind == 1:  # table: reftype, limits
                    if b[i] in (0x63, 0x64):  # (ref null? ht)
                        i += 1
                        leb()
                    else:
                        i += 1
                    limits()
                elif kind == 2:  # memory
                    limits()
                elif kind == 3:  # global: valtype, mut
                    if b[i] in (0x63, 0x64):
                        i += 1
                        leb()
                    else:
                        i += 1
                    i += 1
                elif kind == 4:  # tag: attribute, type index
                    i += 1
                    leb()
                else:
                    fail(f"{path}: unknown import kind {kind:#x}")
        elif sid == 7:
            for _ in range(leb()):
                exports.append(name())
                i += 1
                leb()
        i = end
    return imports, exports


def shim(lowered, wasm_path, c_module, defer_key):
    imports, exports = collect(lowered)
    mod_imports, mod_exports = wasm_names(wasm_path)
    used = {n for m, n in mod_imports if m == "tsgen"}
    exported = set(mod_exports)
    imps = [i for i in imports if f"{i['module']}::{i['name']}" in used]
    exps = [e for e in exports if not e.get("direct") and f"cfts:{e['name']}" in exported]
    for e in exports:
        if e.get("direct") and e["name"] not in exported:
            print(f"python-bindgen: warning: {wasm_path} doesn't export {e['name']}", file=sys.stderr)
    defer = next((i for i in imports if i["name"] == defer_key), None) if defer_key else None
    if defer_key and defer is None:
        fail(f"--defer {defer_key}: no such import")
    if defer is not None and defer not in imps:
        imps.append(defer)

    def fut(n):
        return next((i for i in imports if i["module"] == "tw:future" and i["name"] == n), None)

    if defer is not None:
        for n in ("suspend", "drop"):
            if fut(n) not in imps:
                imps.append(fut(n))

    def sig(params, results):
        s = f" (param {' '.join(params)})" if params else ""
        return s + (f" (result {' '.join(results)})" if results else "")

    def slot(w):
        return "i32" if w == "externref" else w

    c = wat(c_module)
    out = ["(module"]
    out.append(f'  (import {c} "cfts_slot_alloc" (func $alloc (result i32)))')
    out.append(f'  (import {c} "cfts_slot_free" (func $free (param i32)))')
    if defer is not None:
        out.append(f'  (import {c} "cfts_running" (func $running (result i32)))')
    out.append(f'  (import {c} "memory" (memory 0))')
    fid = {}
    for k, imp in enumerate(imps):
        fid[id(imp)] = f"$f{k}"
        out.append(f"  (import {wat(imp['module'])} {wat(imp['name'])} (func $f{k}{sig(imp['params'], imp['results'])}))")
    for k, e in enumerate(exps):
        params = [slot(w) for w in e["params"]]
        results = [slot(w) for w in e["results"]]
        out.append(f"  (import {c} {wat('cfts:' + e['name'])} (func $x{k}{sig(params, results)}))")
    # The table and its ranges (IR.md §14).
    out.append('  (table $t (export "tw:table") 132 externref)')
    out.append('  (global (export "tw:table/stack_base") i32 (i32.const 1))')
    out.append('  (global (export "tw:table/const_base") i32 (i32.const 128))')
    out.append('  (global (export "tw:table/heap_base") i32 (i32.const 132))')
    out.append('  (func (export "tsgen_table_grow") (param i32) (result i32) (table.grow $t (ref.null extern) (local.get 0)))')
    out.append('  (func (export "tsgen_ref_clear") (param i32 i32) (table.fill $t (local.get 0) (ref.null extern) (local.get 1)))')
    out.append('  (func (export "tsgen_ref_copy") (param i32 i32) (table.set $t (local.get 0) (table.get $t (local.get 1))))')
    out.append('  (func (export "tsgen_ref_is_null") (param i32) (result i32) (ref.is_null (table.get $t (local.get 0))))')
    # An externref into a new slot (0 for null), and back out of one.
    out.append(
        """  (func $stash (param $v externref) (result i32) (local $s i32)
    (if (ref.is_null (local.get $v)) (then (return (i32.const 0))))
    (local.set $s (call $alloc))
    (table.set $t (local.get $s) (local.get $v))
    (local.get $s))"""
    )
    out.append(
        """  (func $take (param $s i32) (result externref) (local $v externref)
    (if (i32.eqz (local.get $s)) (then (return (ref.null extern))))
    (local.set $v (table.get $t (local.get $s)))
    (table.set $t (local.get $s) (ref.null extern))
    (call $free (local.get $s))
    (local.get $v))"""
    )
    for imp in imps:
        f = fid[id(imp)]
        ps = [f"(param $p{k} {slot(w)})" for k, w in enumerate(imp["params"])]
        rs = imp["results"]
        many = len(rs) > 1
        if many:
            ps.append("(param $ret i32)")
        locs = [f"(local $r{k} {w})" for k, w in enumerate(rs)] if many else []
        args = " ".join(
            f"(table.get $t (local.get $p{k}))" if w == "externref" else f"(local.get $p{k})"
            for k, w in enumerate(imp["params"])
        )
        result = ""
        if many:
            sets = " ".join(f"(local.set $r{len(rs) - 1 - k})" for k in range(len(rs)))
            store = "\n    ".join(
                f"(i32.store offset={k * 8} (local.get $ret) (call $stash (local.get $r{k})))"
                if w == "externref"
                else f"({w}.store offset={k * 8} (local.get $ret) (local.get $r{k}))"
                for k, w in enumerate(rs)
            )
            body = f"(call {f} {args})\n    {sets}\n    {store}"
        elif len(rs) == 1:
            result = f" (result {slot(rs[0])})"
            body = f"(call $stash (call {f} {args}))" if rs[0] == "externref" else f"(call {f} {args})"
        else:
            body = f"(call {f} {args})"
        out.append(f"  (func (export {wat(imp['module'] + '::' + imp['name'])}) {' '.join(ps)}{result} {' '.join(locs)}\n    {body})")
    for k, e in enumerate(exps):
        ps = [f"(param $p{j} {w})" for j, w in enumerate(e["params"])]
        args = " ".join(
            f"(call $stash (local.get $p{j}))" if w == "externref" else f"(local.get $p{j})"
            for j, w in enumerate(e["params"])
        )
        wait = ""
        if defer is not None and e["future"]:
            # JS called in while the C side runs (from inside an import):
            # wait until that code has suspended or returned.
            wait = f"""(local $f externref)
    (if (call $running) (then
      (local.set $f (call {fid[id(defer)]}))
      (drop (call {fid[id(fut('suspend'))]} (local.get $f)))
      (call {fid[id(fut('drop'))]} (local.get $f))))
    """
        if len(e["results"]) == 1 and e["results"][0] == "externref":
            body = f"(call $take (call $x{k} {args}))"
        else:
            body = f"(call $x{k} {args})"
        out.append(f"  (func (export {wat(e['name'])}) {' '.join(ps)}{sig([], e['results'])}\n    {wait}{body})")
    out.append(")")
    return "\n".join(out) + "\n"


def main(argv):
    def opt(name):
        return argv[argv.index(name) + 1] if name in argv else None

    usage = (
        "usage: bindgen.py header <lowered.json> -o <tsgen.h>"
        " | shim <lowered.json> <c.wasm> -o <shim.wat> --c-module <name> [--defer <key>]"
    )
    if not argv or argv[0] not in ("header", "shim") or not opt("-o"):
        print(usage, file=sys.stderr)
        return 2
    lowered = json.load(open(argv[1], encoding="utf-8"))
    if argv[0] == "header":
        text = header(lowered)
    else:
        c_module = opt("--c-module")
        if not c_module:
            fail("shim: --c-module <name> is required")
        text = shim(lowered, argv[2], c_module, opt("--defer"))
    with open(opt("-o"), "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
