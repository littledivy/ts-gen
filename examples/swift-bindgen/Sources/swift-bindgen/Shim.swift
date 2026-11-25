// The shim (shim.wat) adapts the Swift module to the `tw` ABI: JS values
// cross as slots of the module's `tw:table`, results beyond the first go
// through the return area, and a tag the bridge throws becomes a status
// code. It is generated once the Swift module is linked, for exactly the
// imports and exports the module kept.

/// A WAT string literal.
private func wat(_ s: String) -> String {
    let b = Array(jsonQuote(s).utf8)
    var out: [UInt8] = []
    func hex(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66) }
    var i = 0
    while i < b.count {
        if b[i] == 0x5C, i + 5 < b.count, b[i + 1] == UInt8(ascii: "u"), b[i + 2...i + 5].allSatisfy(hex) {
            out += Array("\\u{".utf8) + b[i + 2...i + 5] + [UInt8(ascii: "}")]
            i += 6
        } else {
            out.append(b[i])
            i += 1
        }
    }
    return String(decoding: out, as: UTF8.self)
}

/// An entry of manifest.json's imports or exports.
private struct Op {
    let c: String
    let module: String
    let name: String
    let params: [String]
    let results: [String]
    let tag: (module: String, name: String, params: [String])?

    init(_ j: JSON) {
        c = j.s("c") ?? ""
        module = j.s("module") ?? ""
        name = j.s("name") ?? ""
        params = j.strs("params")
        results = j.strs("results")
        tag = j.o("throws").map { (module: $0.s("module") ?? "", name: $0.s("name") ?? "", params: $0.strs("params")) }
    }
}

/// The core type of a flat import's C result.
private func cResultType(_ ret: String) -> String {
    switch ret {
    case "double": return "f64"
    case "float": return "f32"
    case "int64_t": return "i64"
    default: return "i32"
    }
}

/// The shim for a manifest, given the shim imports the Swift module uses
/// and the names it exports.
func shimWat(manifest: JSON, used: Set<String>, exported: Set<String>) -> String {
    var lines: [String] = []
    var tags: [(key: String, id: String, module: String, name: String, params: [String])] = []
    func tagOf(_ t: (module: String, name: String, params: [String])) -> String {
        let k = "\(t.module)\0\(t.name)"
        if let hit = tags.first(where: { $0.key == k }) { return hit.id }
        let id = "$tag\(tags.count)"
        tags.append((k, id, t.module, t.name, t.params))
        return id
    }
    let imports = manifest.a("imports").map(Op.init).filter { used.contains($0.c) }
    let exports = manifest.a("exports").map(Op.init).filter { exported.contains($0.c) }
    for e in imports + exports { if let t = e.tag { _ = tagOf(t) } }
    lines.append("(module")
    lines.append("  (import \"swift\" \"tsgen_ref_alloc1\" (func $alloc (result i32)))")
    lines.append("  (import \"swift\" \"tsgen_ref_free1\" (func $free (param i32)))")
    lines.append("  (import \"swift\" \"tsgen_ret_area\" (func $ret (result i32)))")
    lines.append("  (import \"swift\" \"memory\" (memory 0))")
    for t in tags {
        lines.append("  (import \(wat(t.module)) \(wat(t.name)) (tag \(t.id) (param \(t.params.joined(separator: " ")))))")
    }
    for (i, e) in imports.enumerated() {
        let ps = e.params.isEmpty ? "" : " (param \(e.params.joined(separator: " ")))"
        let rs = e.results.isEmpty ? "" : " (result \(e.results.joined(separator: " ")))"
        lines.append("  (import \(wat(e.module)) \(wat(e.name)) (func $f\(i)\(ps)\(rs)))")
    }
    for (i, e) in exports.enumerated() {
        let f = flatExport(e)
        let ps = f.params.isEmpty ? "" : " (param \(f.params.joined(separator: " ")))"
        let rs = f.ret.map { " (result \($0))" } ?? ""
        lines.append("  (import \"swift\" \(wat(e.c)) (func $x\(i)\(ps)\(rs)))")
    }
    let suspends = used.contains("tsgen_suspend") || used.contains("tsgen_suspend_race")
    if suspends {
        lines.append("  (import \"swift\" \"__stack_pointer\" (global $sp (mut i32)))")
        lines.append("  (import \"tw:future\" \"suspend\" (func $suspend (param externref) (result i32)))")
        lines.append("  (import \"tw:future\" \"suspend_race\" (func $suspendRace (param i32 i32) (result i32)))")
    }
    // The table and its ranges (IR.md §14).
    lines.append("  (table $t (export \"tw:table\") 132 externref)")
    lines.append("  (global (export \"tw:table/stack_base\") i32 (i32.const 1))")
    lines.append("  (global (export \"tw:table/const_base\") i32 (i32.const 128))")
    lines.append("  (global (export \"tw:table/heap_base\") i32 (i32.const 132))")
    lines.append("  (func (export \"tsgen_table_grow\") (param i32) (result i32) (table.grow $t (ref.null extern) (local.get 0)))")
    lines.append("  (func (export \"tsgen_ref_clear\") (param i32 i32) (table.fill $t (local.get 0) (ref.null extern) (local.get 1)))")
    lines.append("  (func (export \"tsgen_ref_copy\") (param i32 i32) (table.set $t (local.get 0) (table.get $t (local.get 1))))")
    lines.append("  (func (export \"tsgen_ref_is_null\") (param i32) (result i32) (ref.is_null (table.get $t (local.get 0))))")
    if suspends {
        // Suspensions (IR.md §16), for slots. Another call can run on
        // Swift's linear-memory stack while this one is parked, so the stack
        // pointer is put back as it resumes. Swift's slots are all on its
        // heap, so there's no table stack to keep.
        lines.append("""
              (func (export "tsgen_suspend") (param $f i32) (result i32) (local $s i32) (local $r i32)
                (local.set $s (global.get $sp))
                (local.set $r (call $suspend (table.get $t (local.get $f))))
                (global.set $sp (local.get $s))
                (local.get $r))
            """)
        lines.append("""
              (func (export "tsgen_suspend_race") (param $base i32) (param $n i32) (result i32) (local $s i32) (local $r i32)
                (local.set $s (global.get $sp))
                (local.set $r (call $suspendRace (local.get $base) (local.get $n)))
                (global.set $sp (local.get $s))
                (local.get $r))
            """)
    }
    // An externref into a new slot (0 for null), and back out of one.
    lines.append("""
          (func $stash (param $v externref) (result i32) (local $s i32)
            (if (ref.is_null (local.get $v)) (then (return (i32.const 0))))
            (local.set $s (call $alloc))
            (table.set $t (local.get $s) (local.get $v))
            (local.get $s))
        """)
    lines.append("""
          (func $take (param $s i32) (result externref) (local $v externref)
            (if (i32.eqz (local.get $s)) (then (return (ref.null extern))))
            (local.set $v (table.get $t (local.get $s)))
            (call $free (local.get $s))
            (local.get $v))
        """)
    func store(_ w: String, _ addr: String, _ off: Int, _ val: String) -> String {
        w == "externref" ? "(i32.store offset=\(off) \(addr) (call $stash \(val)))" : "(\(w).store offset=\(off) \(addr) \(val))"
    }
    func load(_ w: String, _ addr: String, _ off: Int) -> String {
        w == "externref" ? "(call $take (i32.load offset=\(off) \(addr)))" : "(\(w).load offset=\(off) \(addr))"
    }
    for (i, e) in imports.enumerated() {
        let f = flatImport(params: e.params, results: e.results, throws: e.tag != nil)
        var ps = e.params.enumerated().map { k, w in "(param $p\(k) \(w == "externref" ? "i32" : w))" }
        if f.useRet { ps.append("(param $ret i32)") }
        var locals = e.results.enumerated().map { k, w in "(local $r\(k) \(w))" }
        let args = e.params.enumerated().map { k, w in
            w == "externref" ? "(table.get $t (local.get $p\(k)))" : "(local.get $p\(k))"
        }.joined(separator: " ")
        let n = e.results.count
        let setResults = (0..<n).map { k in "(local.set $r\(n - 1 - k))" }.joined(separator: " ")
        let storeResults = e.results.enumerated().map { k, w in store(w, "(local.get $ret)", k * 8, "(local.get $r\(k))") }
            .joined(separator: "\n      ")
        let body: String
        if let t = e.tag {
            let tp = t.params
            locals += tp.enumerated().map { k, w in "(local $e\(k) \(w))" }
            body = """
                (block $ok
                      (block $err (result \(tp.joined(separator: " ")))
                        (try_table (catch \(tagOf(t)) $err)
                          (call $f\(i) \(args))
                          \(setResults)
                          \(storeResults)
                          (br $ok)))
                      \((0..<tp.count).map { k in "(local.set $e\(tp.count - 1 - k))" }.joined(separator: " "))
                      \(tp.enumerated().map { k, w in store(w, "(local.get $ret)", k * 8, "(local.get $e\(k))") }.joined(separator: "\n      "))
                      (return (i32.const 1)))
                    (i32.const 0)
                """
        } else if n == 1 {
            body = e.results[0] == "externref" ? "(call $stash (call $f\(i) \(args)))" : "(call $f\(i) \(args))"
        } else {
            body = "(call $f\(i) \(args))\n    \(setResults)\n    \(storeResults)"
        }
        let rs = f.ret != "void" ? " (result \(cResultType(f.ret)))" : ""
        lines.append("  (func (export \(wat(e.c))) \(ps.joined(separator: " "))\(rs) \(locals.joined(separator: " "))\n    \(body))")
    }
    for (i, e) in exports.enumerated() {
        let ps = e.params.enumerated().map { k, w in "(param $p\(k) \(w))" }
        let args = e.params.enumerated().map { k, w in
            w == "externref" ? "(call $stash (local.get $p\(k)))" : "(local.get $p\(k))"
        }.joined(separator: " ")
        let loads = e.results.enumerated().map { k, w in load(w, "(local.get $a)", k * 8) }.joined(separator: " ")
        let body: String
        if let t = e.tag {
            let thrown = t.params.enumerated().map { k, w in load(w, "(local.get $a)", k * 8) }.joined(separator: " ")
            body = """
                (local $a i32)
                    (if (call $x\(i) \(args))
                      (then
                        (local.set $a (call $ret))
                        (throw \(tagOf(t)) \(thrown))))
                    (local.set $a (call $ret))
                    \(loads)
                """
        } else if e.results.count == 1 {
            body = e.results[0] == "externref" ? "(call $take (call $x\(i) \(args)))" : "(call $x\(i) \(args))"
        } else if e.results.isEmpty {
            body = "(call $x\(i) \(args))"
        } else {
            body = "(local $a i32)\n    (call $x\(i) \(args))\n    (local.set $a (call $ret))\n    \(loads)"
        }
        let rs = e.results.isEmpty ? "" : " (result \(e.results.joined(separator: " ")))"
        lines.append("  (func (export \(wat(e.name))) \(ps.joined(separator: " "))\(rs)\n    \(body))")
    }
    lines.append(")")
    return lines.joined(separator: "\n") + "\n"
}

/// The Swift function behind an export: its slots are `i32`s, and a
/// throwing one returns a status.
private func flatExport(_ e: Op) -> (params: [String], ret: String?) {
    let params = e.params.map { $0 == "externref" ? "i32" : $0 }
    let ret: String? = e.tag != nil ? "i32" : e.results.count == 1 ? (e.results[0] == "externref" ? "i32" : e.results[0]) : nil
    return (params, ret)
}

private let wireC = ["i32": "int32_t", "i64": "int64_t", "f32": "float", "f64": "double", "externref": "int32_t"]

/// The C declaration of an import as Swift calls it: slots are `int32_t`s,
/// and results beyond one, or a status for a throwing import, go through a
/// return area passed last.
func flatImport(params: [String], results: [String], throws isThrowing: Bool) -> (params: [String], ret: String, useRet: Bool) {
    var ps = params.map { wireC[$0] ?? "" }
    let useRet = isThrowing || results.count > 1
    if useRet { ps.append("int32_t") }
    let ret = isThrowing ? "int32_t" : results.count == 1 ? wireC[results[0]] ?? "" : "void"
    return (ps, ret, useRet)
}
