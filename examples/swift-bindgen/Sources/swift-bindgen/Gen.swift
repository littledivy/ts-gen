/// A position Swift can't express yet; the member is skipped.
struct Unsupported: Error {
    let message: String
}

private func unsupported(_ why: String) throws -> Never { throw Unsupported(message: why) }

/// An insertion-ordered dictionary.
struct OrderedMap<K: Hashable, V> {
    private(set) var keys: [K] = []
    private var dict: [K: V] = [:]

    subscript(k: K) -> V? {
        get { dict[k] }
        set {
            guard let v = newValue else { return }
            if dict.updateValue(v, forKey: k) == nil { keys.append(k) }
        }
    }

    func has(_ k: K) -> Bool { dict[k] != nil }

    mutating func update(_ k: K, default d: @autoclosure () -> V, _ f: (inout V) -> Void) {
        if dict[k] == nil { keys.append(k); dict[k] = d() }
        f(&dict[k]!)
    }
    var count: Int { keys.count }
    var entries: [(K, V)] { keys.map { ($0, dict[$0]!) } }
    var values: [V] { keys.map { dict[$0]! } }
}

/// An insertion-ordered set.
struct OrderedSet<T: Hashable> {
    private(set) var items: [T] = []
    private var set: Set<T> = []

    @discardableResult
    mutating func insert(_ x: T) -> Bool {
        guard set.insert(x).inserted else { return false }
        items.append(x)
        return true
    }

    func has(_ x: T) -> Bool { set.contains(x) }
    var count: Int { items.count }
}

/// Signatures already declared in a class, shared as the class's members are emitted.
final class Signatures {
    var set: Set<String> = []
}

let scalarSwift = [
    "bool": "Bool", "i8": "Int8", "u8": "UInt8", "i16": "Int16", "u16": "UInt16", "i32": "Int32", "u32": "UInt32",
    "i53": "Int", "u53": "Int", "i64": "Int64", "u64": "UInt64", "f32": "Float", "f64": "Double",
]
private let scalarSize = [
    "bool": 1, "i8": 1, "u8": 1, "i16": 2, "u16": 2, "i32": 4, "u32": 4, "f32": 4, "f64": 8, "i53": 8, "u53": 8, "i64": 8, "u64": 8,
]
private let scalarStore = [
    "bool": "UInt8", "i8": "Int8", "u8": "UInt8", "i16": "Int16", "u16": "UInt16", "i32": "Int32", "u32": "UInt32",
    "f32": "Float", "f64": "Double", "i53": "Int64", "u53": "Int64", "i64": "Int64", "u64": "UInt64",
]
private let vecSwift = [
    "i8": "Int8", "u8": "UInt8", "i16": "Int16", "u16": "UInt16", "i32": "Int32", "u32": "UInt32", "i64": "Int64",
    "u64": "UInt64", "f32": "Float", "f64": "Double",
]
private let vecSize = ["i8": 1, "u8": 1, "i16": 2, "u16": 2, "i32": 4, "u32": 4, "i64": 8, "u64": 8, "f32": 4, "f64": 8]
private let wireSwift = ["i32": "Int32", "i64": "Int64", "f32": "Float", "f64": "Double", "externref": "Int32"]
private let zero = ["i32": "0", "i64": "0", "f32": "0", "f64": "0", "externref": "0"]
private let retRead = ["i32": "i32", "i64": "i64", "f32": "f32", "f64": "f64", "externref": "i32"]

private func ws(_ w: String) -> String { wireSwift[w] ?? "" }

/// Wire values ready to pass: statements to run first, one expression per
/// value, and statements to run after the call (releasing what was lowered).
private struct Low {
    var code: [String]
    var vals: [String]
    var post: [String] = []
}

/// A tag a member's call can throw: the tag import and its values, an arm
/// index then the enum's payload slots.
struct TagInfo {
    let module: String
    let name: String
    let params: [String]
    let layout: JSON

    var json: JSON { obj([("module", .string(module)), ("name", .string(name)), ("params", strArr(params))]) }
}

/// An import the Swift module calls through the shim, as `c`.
final class ImportOp {
    let c: String
    let module: String
    let name: String
    let params: [String]
    let results: [String]
    let tag: TagInfo?
    /// The trampolines of the callbacks the members calling it pass.
    var callbacks: [String]?

    init(c: String, module: String, name: String, params: [String], results: [String], tag: TagInfo?) {
        self.c = c
        self.module = module
        self.name = name
        self.params = params
        self.results = results
        self.tag = tag
    }
}

/// A function the Swift module exports as `c`, which the shim exports as `name`.
final class ExportOp {
    let c: String
    let name: String
    let params: [String]
    let results: [String]
    let tag: TagInfo?
    /// For a module export: whether it is async, its class (or null), member name and kind.
    var details: [(String, JSON)] = []

    init(c: String, name: String, params: [String], results: [String], tag: TagInfo?) {
        self.c = c
        self.name = name
        self.params = params
        self.results = results
        self.tag = tag
    }
}

/// A closure result's Swift type, and how to lower a value of it.
private struct ClosureResult {
    let type: String
    let lower: (String) throws -> Low
}

/// A field of an `arr<T>` element.
private struct Field {
    enum Kind { case str, scalar, enumIndex, ref }
    let kind: Kind
    var off = 0
    let r: JSON
    var ref = 0
}

private struct ArrayLayout {
    let fields: [Field]
    let size: Int
    let refs: Int
}

private struct Param {
    let name: String
    let type: String
    let repr: JSON
    let spread: Bool
}

/// One imported member, generated.
private struct Member {
    let sp: [Param]
    let resT: String
    let effects: String
    let body: [String]
    let isFuture: Bool
    let isStatic: Bool
    let usesT: Bool
    let valueR: JSON
}

private struct Ctx {
    var inherited: Set<String>? = nil
    var mine: Signatures? = nil
    var global = false
    var objectInit = false
}

private struct Settable {
    let name: String
    let type: String
    var set: String? = nil
    var tries = false
}

private let unitRepr = obj([("kind", .string("unit")), ("wire", .array([]))])

/// What the app adopts: an export protocol and its requirements.
struct ExportProtocol {
    let name: String
    let isClass: Bool
    /// For a class, its Swift name.
    let typeName: String
    let requirements: [String]
}

/// Swift bindings for a lowered IR under the all-linear profile.
///
/// Every call goes through the shim: each import is a C function the
/// generated TSGenImports.h declares (`tsgen_i<n>`), and each export a
/// `@_cdecl` function (`tsgen_x<n>`); manifest.json lists both for the shim.
final class Gen {
    private let appType: String
    private var decls: [String: JSON] = [:]
    /// The declarations' paths, in the order the sources list them.
    private var declPaths: [String] = []
    private var members: [JSON] = []
    private var exportedClasses: Set<String> = []
    private var byOwner = OrderedMap<String, [JSON]>()
    private var imports = OrderedMap<String, ImportOp>()
    private var exports: [ExportOp] = []
    /// Each trampoline by name, with its callback type, or nil when it can't be mapped.
    private var callbacks: [String: JSON?] = [:]
    private var callbackCode = OrderedMap<String, [String]>()
    private var keepCallbacks: Set<String>?
    /// The shim imports a build without callbacks used: only callbacks the
    /// imports among them take get trampolines. Nil keeps every trampoline.
    var keepCallbacksFor: Set<String>?
    private var out: [String] = []
    private(set) var skipped: [(key: String, why: String)] = []
    /// Members left out for a signature already declared: skipped unless
    /// another class declares them (a member copied into several).
    private var duplicates: [(key: String, why: String)] = []
    private var emittedKeys: Set<String> = []
    private var emittedMembers = 0
    private var tmp = 0
    private var liftCode: [String] = []
    private var memberCallbacks: OrderedSet<String>?
    private var enumsUsed = OrderedMap<String, JSON>()
    private var throwEnums = OrderedMap<String, JSON>()
    private var enumDecls: [String] = []
    private var selected = OrderedSet<String>()
    private var sigs: [String: Signatures] = [:]
    private(set) var protocols: [ExportProtocol] = []

    init(lowered: JSON, libs: [JSON], appType: String) {
        self.appType = appType
        for src in [lowered] + libs {
            for d in src.a("decls") {
                if let p = d.s("path"), decls[p] == nil {
                    decls[p] = d
                    declPaths.append(p)
                }
            }
            members += src.a("members")
        }
        for m in members where m.s("role") == "export" && m.t("owner") {
            exportedClasses.insert(m.s("owner")!)
        }
        for m in members {
            byOwner.update(ownerKey(m), default: []) { $0.append(m) }
        }
    }

    private func ownerKey(_ m: JSON) -> String {
        if let o = m.o("owner") { return jsStr(o) }
        let ns = m.strs("namespace")
        return ns.isEmpty ? "" : "ns:" + ns.joined(separator: ".")
    }

    // MARK: Selection

    /// Limits the bindings to `roots` (declarations or global members) and
    /// everything their members reach, plus the module's exports and the
    /// runtime's declarations; nil selects everything.
    func select(_ roots: [String]?) {
        var sel = OrderedSet<String>()
        var globals: Set<String> = []
        var queue: [String] = []
        func addDecl(_ path: String?) {
            guard let path, !path.isEmpty, !sel.has(path), decls[path] != nil else { return }
            sel.insert(path)
            queue.append(path)
        }
        func walk(_ r: JSON?) {
            switch r {
            case .array(let xs)?:
                xs.forEach(walk)
            case .object(let o)?:
                if let p = o.values["path"]?.str { addDecl(p) }
                for k in o.keys where k != "args" {
                    switch o.values[k]! {
                    case .object, .array: walk(o.values[k])
                    default: break
                    }
                }
            default:
                return
            }
        }
        for m in members where m.s("role") == "export" { walk(m["sig"]) }
        for r in ["TsgenValue", "TsgenObject"] { addDecl(r) }
        let all = roots == nil
        if all { declPaths.forEach(addDecl) }
        for r in roots ?? [] {
            if decls[r] != nil { addDecl(r) } else { globals.insert(r) }
        }
        for m in byOwner[""] ?? [] where m.s("role") == "import" {
            if all || globals.contains(m.s("name") ?? "") {
                if case .object(let o) = m { o.set("_global", .bool(true)) }
                walk(m["sig"])
            }
        }
        var head = 0
        while head < queue.count {
            let p = queue[head]
            head += 1
            let d = decls[p]!
            for e in d.strs("extends") { addDecl(stripArgs(e)) }
            for m in byOwner[p] ?? [] where m.s("role") == "import" { walk(m["sig"]) }
            if d.s("kind") == "enum" { walk(d["layout"]) }
        }
        selected = sel
    }

    // MARK: Names

    func typeName(_ path: String) -> String {
        var n = path
        let u = Array(path.utf8)
        if u.first == 0x22, let close = u.dropFirst().firstIndex(of: 0x22), close > 1, close + 1 < u.count, u[close + 1] == 0x2E {
            var spec = String(decoding: u[1..<close], as: UTF8.self)
            let su = Array(spec.utf8)
            var k = 0
            while k < su.count && su[k] >= 0x61 && su[k] <= 0x7A { k += 1 }
            if k > 0 && k < su.count && su[k] == 0x3A { spec = String(decoding: su[(k + 1)...], as: UTF8.self) }
            n = upperFirst(camel(spec)) + "_" + String(decoding: u[(close + 2)...], as: UTF8.self)
        }
        n = split(n, ".").map(camel).joined(separator: "_")
        if path == "err" { return "JSException" }
        if swiftTypes.contains(n) || swiftKeywords.contains(n) { n = "JS" + n }
        // `Any` as `JSAny` would be the runtime's own.
        if swiftTypes.contains(n) { n += "_" }
        return n
    }

    private func isClassLike(_ path: String?) -> Bool {
        guard let path, let d = decls[path] else { return false }
        let k = d.s("kind")
        return (k == "class" || k == "interface") && selected.has(path) && !exportedClasses.contains(path)
    }

    // MARK: Imports and exports through the shim

    private func importOp(_ module: String, _ name: String, _ params: [String], _ results: [String], _ tag: TagInfo?) -> ImportOp {
        let key = "\(module)\0\(name)"
        if let e = imports[key] { return e }
        let e = ImportOp(c: "tsgen_i\(imports.count)", module: module, name: name, params: params, results: results, tag: tag)
        imports[key] = e
        return e
    }

    private func tagInfo(_ t: JSON?) -> TagInfo? {
        guard let t, t.truthy else { return nil }
        let layout = t["enum"]!
        return TagInfo(
            module: t["tag"]?.s("module") ?? "", name: t["tag"]?.s("name") ?? "",
            params: ["i32"] + layout["shape"]!.strs("slots"), layout: layout)
    }

    private func exportOp(_ name: String, _ params: [String], _ results: [String], _ tag: TagInfo?) -> ExportOp {
        let e = ExportOp(c: "tsgen_x\(exports.count)", name: name, params: params, results: results, tag: tag)
        exports.append(e)
        return e
    }

    // MARK: Type mapping

    /// The Swift type of a value; `pos` is "in" (a parameter) or "out" (a result).
    private func swiftType(_ r: JSON, _ pos: String) throws -> String {
        let nullable = r.t("nullable")
        func opt(_ t: String) -> String { nullable ? "\(t)?" : t }
        switch r.s("kind") {
        case "unit":
            return "Void"
        case "scalar":
            guard let t = scalarSwift[r.s("scalar") ?? ""] else { try unsupported("scalar \(jsStr(r["scalar"]))") }
            return opt(t)
        case "str":
            return opt("String")
        case "bigint":
            return opt("JSBigInt")
        case "enum":
            let layout = r["enum"]!
            if ends(layout.s("path") ?? "", "??") { try unsupported("T??") }
            try checkEnum(layout)
            useEnum(layout)
            return opt(enumName(layout))
        case "host":
            switch r.s("of") {
            case "class", "interface":
                if isClassLike(r.s("path")) { return opt(typeName(r.s("path")!)) }
                return pos == "in" ? (nullable ? "JSObject?" : "JSObject") : opt("JSAny")
            case "any":
                return pos == "in" ? (nullable ? "JSIn?" : "JSIn") : opt("JSAny")
            case "box":
                if r["inner"]?.s("kind") == "str" { return opt("String") }
                return pos == "in" ? (nullable ? "JSObject?" : "JSObject") : opt("JSAny")
            case "future":
                if pos == "in" { return nullable ? "JSObject?" : "JSObject" }
                try unsupported("future in a nested position")
            default:
                try unsupported("host \(jsStr(r["of"]))")
            }
        case "erased":
            if pos == "in" { return nullable ? "JSIn?" : "JSIn" }
            return opt("JSAny")
        case "array":
            _ = try arrayLayout(r["elem"]!)
            return opt("[\(try swiftType(r["elem"]!, pos))]")
        case "vec":
            guard let t = vecSwift[r.s("elem") ?? ""] else { try unsupported("vec \(jsStr(r["elem"]))") }
            return opt("[\(t)]")
        case "tuple":
            if nullable { try unsupported("nullable tuple") }
            return "(\(try r.a("elems").map { try swiftType($0, pos) }.joined(separator: ", ")))"
        case "fn":
            if pos != "in" { return opt("JSAny") }
            let ps = try r.a("params").map { try swiftType($0, "out") }
            let res = try closureResult(r["result"]!)
            let t = "(\(ps.joined(separator: ", "))) -> \(res.type)"
            return nullable ? "(\(t))?" : t
        default:
            try unsupported("kind \(jsStr(r["kind"]))")
        }
    }

    private func closureResult(_ r: JSON) throws -> ClosureResult {
        if r.s("kind") == "unit" { return ClosureResult(type: "Void") { _ in Low(code: [], vals: []) } }
        if r.s("kind") == "host" && r.s("of") == "future" && r.t("nullable") {
            return ClosureResult(type: "Void") { _ in Low(code: [], vals: ["0"]) }
        }
        let type = try swiftType(r, "in")
        return ClosureResult(type: type) { [unowned self] e in try self.lower(r, e) }
    }

    // MARK: Enums

    private func enumName(_ layout: JSON) -> String { typeName(layout.s("path") ?? "") }

    private func useEnum(_ layout: JSON) {
        let p = layout.s("path") ?? ""
        if !enumsUsed.has(p) { enumsUsed[p] = layout }
    }

    /// Whether each payload enum can be declared, by path: nil when it can,
    /// else why not.
    private var enumErrors: [String: String?] = [:]
    private var enumsChecking: Set<String> = []

    /// Throws why a payload enum can't be declared, so that what uses it is
    /// skipped with it. An enum reaching itself counts as declarable.
    private func checkEnum(_ layout: JSON) throws {
        let p = layout.s("path") ?? ""
        if let known = enumErrors[p] {
            if let why = known { try unsupported(why) }
            return
        }
        guard layout["shape"]?.s("kind") == "payload", enumsChecking.insert(p).inserted else { return }
        defer { enumsChecking.remove(p) }
        do {
            for a in layout.a("arms") {
                for pl in a.a("payload") { _ = try payloadType(pl) }
            }
            enumErrors[p] = .some(nil)
        } catch let e as Unsupported {
            enumErrors[p] = .some(e.message)
            throw e
        }
    }

    private func caseName(_ arm: JSON) -> String { memberName(arm.s("name") ?? "") }

    private func payloadType(_ p: JSON) throws -> String { try swiftType(p, p.s("kind") == "fn" ? "in" : "out") }

    private func emitEnum(_ layout: JSON, asError: Bool) throws {
        let name = enumName(layout)
        var lines: [String] = []
        let shape = layout["shape"]!
        let arms = layout.a("arms")
        switch shape.s("kind") {
        case "index":
            lines.append("public enum \(name): Int32\(asError ? ", Error" : "") {")
            for a in arms { lines.append("  case \(caseName(a)) = \(jsStr(a["index"]))") }
            lines.append("}")
        case "carrier":
            let t = scalarSwift[shape.s("scalar") ?? ""] ?? "Int32"
            lines += [
                "public struct \(name): RawRepresentable, Hashable {", "  public var rawValue: \(t)",
                "  public init(rawValue: \(t)) { self.rawValue = rawValue }",
            ]
            for a in arms { lines.append("  public static let \(caseName(a)) = \(name)(rawValue: \(jsStr(a["index"])))") }
            lines.append("}")
        default:
            let typed = try arms.map { a in (a: a, types: try a.a("payload").map(payloadType)) }
            lines.append("public enum \(name)\(asError ? ": Error" : "") {")
            for (a, types) in typed {
                lines.append("  case \(caseName(a))\(types.isEmpty ? "" : "(\(types.joined(separator: ", ")))")")
            }
            lines.append("}")
            // A string literal or a number literal picks the arm that holds one.
            func lit(_ swiftT: String, _ proto: String, _ litT: String) {
                let hits = typed.filter { $0.types.count == 1 && $0.types[0] == swiftT }
                guard hits.count == 1 else { return }
                let label = proto == "ExpressibleByStringLiteral" ? "stringLiteral" : proto == "ExpressibleByFloatLiteral" ? "floatLiteral" : "integerLiteral"
                lines += [
                    "extension \(name): \(proto) {",
                    "  public init(\(label) value: \(litT)) { self = .\(caseName(hits[0].a))(\(swiftT == litT ? "value" : "\(swiftT)(value)")) }",
                    "}",
                ]
            }
            lit("String", "ExpressibleByStringLiteral", "String")
            lit("Double", "ExpressibleByFloatLiteral", "Double")
            lit("Double", "ExpressibleByIntegerLiteral", "Int")
        }
        enumDecls.append(lines.joined(separator: "\n"))
    }

    /// Lowers an enum value to its flat wire values.
    private func lowerEnum(_ r: JSON, _ e: String) throws -> Low {
        let layout = r["enum"]!
        let shape = layout["shape"]!
        let nullable = r.t("nullable")
        if shape.s("kind") == "index" { return Low(code: [], vals: [nullable ? "(\(e)?.rawValue ?? 0)" : "\(e).rawValue"]) }
        if shape.s("kind") == "carrier" {
            if nullable { try unsupported("nullable carrier enum") }
            return Low(code: [], vals: [scalarLower(shape.s("scalar") ?? "", "\(e).rawValue")])
        }
        let id = tmp
        tmp += 1
        let arm = "_a\(id)"
        let slotTypes = shape.strs("slots")
        let slots = slotTypes.indices.map { "_e\(id)_\($0)" }
        let cl = "_cl\(id)"
        var code = ["var \(arm): Int32 = 0"] + slots.indices.map { "var \(slots[$0]): \(ws(slotTypes[$0])) = \(zero[slotTypes[$0]] ?? "")" }
        var cleanup = false
        var cases: [String] = []
        for a in layout.a("arms") {
            let payload = a.a("payload")
            let armSlots = a.a("slots").map { Int($0.num ?? 0) }
            let binds = payload.indices.map { "_p\(id)_\($0)" }
            var body = ["\(arm) = \(jsStr(a["index"]))"]
            var k = 0
            for (i, p) in payload.enumerated() {
                let l = try lower(p, binds[i])
                body += l.code
                for v in l.vals {
                    body.append("\(slots[armSlots[k]]) = \(v)")
                    k += 1
                }
                // What a payload allocated is released after the call.
                if !l.post.isEmpty {
                    cleanup = true
                    body.append("\(cl).append { \(l.post.joined(separator: "; ")) }")
                }
            }
            let pat = ".\(caseName(a))\(binds.isEmpty ? "" : "(\(binds.map { "let \($0)" }.joined(separator: ", ")))")"
            cases.append("case \(nullable ? ".some(\(pat))" : pat):")
            cases += body.map { "  " + $0 }
        }
        if nullable { cases.append("case nil: break") }
        if cleanup { code.append("var \(cl): [() -> Void] = []") }
        code += ["switch \(e) {"] + cases + ["}"]
        return Low(code: code, vals: [arm] + slots, post: cleanup ? ["for c in \(cl) { c() }"] : [])
    }

    private func liftEnum(_ r: JSON, _ vals: [String]) throws -> String {
        let layout = r["enum"]!
        let shape = layout["shape"]!
        let name = enumName(layout)
        let nullable = r.t("nullable")
        if shape.s("kind") == "index" {
            return nullable ? "(\(vals[0]) == 0 ? nil : \(name)(rawValue: \(vals[0])))" : "\(name)(rawValue: \(vals[0]))!"
        }
        if shape.s("kind") == "carrier" { return "\(name)(rawValue: \(scalarLift(shape.s("scalar") ?? "", vals[0])))" }
        let id = tmp
        tmp += 1
        let v = "_v\(id)"
        // Wire values are read once up front: lifting a payload may make calls
        // that reuse the return area they came from.
        let wv = vals.indices.map { "_w\(id)_\($0)" }
        var code = vals.indices.map { "let \(wv[$0]) = \(vals[$0])" } + ["let \(v): \(name)?", "switch \(wv[0]) {"]
        let outer = liftCode
        for a in layout.a("arms") {
            var k = 0
            let armSlots = a.a("slots").map { Int($0.num ?? 0) }
            liftCode = []
            let ps = try a.a("payload").map { p -> String in
                let w = p.a("wire").map { _ -> String in
                    defer { k += 1 }
                    return wv[1 + armSlots[k]]
                }
                return try lift(p, w)
            }
            code.append("case \(jsStr(a["index"])):")
            code += liftCode.map { "  " + $0 }
            code.append("  \(v) = .\(caseName(a))\(ps.isEmpty ? "" : "(\(ps.joined(separator: ", ")))")")
        }
        liftCode = outer
        code += ["default: \(v) = nil", "}"]
        liftCode += code
        return nullable ? v : "\(v)!"
    }

    // MARK: Arrays

    /// The element layout of `arr<T>` in linear memory (IR.md §11): numeric
    /// fields packed, references in the table.
    private func arrayLayout(_ elem: JSON) throws -> ArrayLayout {
        var fields: [Field] = []
        var size = 0
        var refs = 0
        func add(_ r: JSON) throws {
            let kind = r.s("kind")
            if kind == "str" {
                fields.append(Field(kind: .str, off: size, r: r))
                size += 8
            } else if kind == "scalar" && !r.t("nullable") {
                let s = scalarSize[r.s("scalar") ?? ""] ?? 0
                fields.append(Field(kind: .scalar, off: size, r: r))
                size += s
            } else if kind == "enum" && r["enum"]?["shape"]?.s("kind") == "index" {
                fields.append(Field(kind: .enumIndex, off: size, r: r))
                size += 4
            } else if (kind == "host" && ["class", "interface", "any", "box"].contains(r.s("of") ?? "")) || kind == "erased" {
                if kind == "host" && r.s("of") == "box" && r["inner"]?.s("kind") == "str" { try unsupported("Str in arr") }
                fields.append(Field(kind: .ref, r: r, ref: refs))
                refs += 1
            } else if kind == "tuple" && !r.t("nullable") {
                for el in r.a("elems") { try add(el) }
            } else {
                try unsupported("arr element \(jsStr(r["ty"]))")
            }
        }
        try add(elem)
        return ArrayLayout(fields: fields, size: size, refs: refs)
    }

    private func lowerArray(_ r: JSON, _ e: String) throws -> Low {
        let layout = try arrayLayout(r["elem"]!)
        let id = tmp
        tmp += 1
        let n = "_n\(id)", mem = "_m\(id)", base = "_b\(id)", strs = "_s\(id)", it = "_x\(id)"
        let nullable = r.t("nullable")
        let src = nullable ? "(\(e) ?? [])" : e
        var code = ["let \(n) = Int32(\(src).count)"]
        var post: [String] = []
        let size = layout.size, refs = layout.refs
        if size != 0 {
            code.append("let \(mem) = TSGenMem.alloc(\(size) * Int(\(n)))")
            post.append("free(\(mem))")
        }
        if refs != 0 {
            code.append("let \(base) = RefTable.alloc(\(refs) * \(n))")
            post.append("RefTable.free(\(base), \(refs) * \(n))")
        }
        if layout.fields.contains(where: { $0.kind == .str }) {
            code.append("var \(strs): [(Int32, Int32)] = []")
            post.append("for (p, c) in \(strs) { TSGenMem.release(p, c) }")
        }
        var body: [String] = []
        // Tuple elements flatten in order; track the Swift path of each field.
        var paths: [[Int]] = []
        func walk(_ r: JSON, _ path: [Int]) {
            if r.s("kind") == "tuple" {
                for (i, el) in r.a("elems").enumerated() { walk(el, path + [i]) }
            } else {
                paths.append(path)
            }
        }
        walk(r["elem"]!, [])
        for (fi, f) in layout.fields.enumerated() {
            let path = paths[fi]
            let v = path.isEmpty ? it : "\(it).\(path.map(String.init).joined(separator: "."))"
            switch f.kind {
            case .str:
                body.append(
                    "do { let (p, c) = TSGenMem.lower(\(v)); \(strs).append((p, c)); \(mem).storeBytes(of: p, toByteOffset: i * \(size) + \(f.off), as: Int32.self); \(mem).storeBytes(of: c, toByteOffset: i * \(size) + \(f.off + 4), as: Int32.self) }"
                )
            case .scalar:
                let s = f.r.s("scalar") ?? ""
                body.append("\(mem).storeBytes(of: \(scalarStoreExpr(s, v)), toByteOffset: i * \(size) + \(f.off), as: \(scalarStore[s] ?? "").self)")
            case .enumIndex:
                body.append("\(mem).storeBytes(of: \(v).rawValue, toByteOffset: i * \(size) + \(f.off), as: Int32.self)")
            case .ref:
                let slot = refLowerOwned(f.r, v)
                body.append("do { let s = \(slot); tsgen_ref_copy(\(base) + Int32(i) * \(refs) + \(f.ref), s); RefTable.free(s, 1) }")
            }
        }
        code.append("for (i, \(it)) in \(src).enumerated() {")
        code += body.map { "  " + $0 }
        code.append("}")
        var vals: [String] = []
        if size != 0 { vals.append("(\(n) == 0 ? 1 : _i32(\(mem)))") }
        if refs != 0 { vals.append("(\(n) == 0 ? 0 : \(base))") }
        vals.append(nullable ? "(\(e) == nil ? -1 : \(n))" : n)
        return Low(code: code, vals: vals, post: post)
    }

    private func liftArray(_ r: JSON, _ vals: [String]) throws -> String {
        let layout = try arrayLayout(r["elem"]!)
        let id = tmp
        tmp += 1
        var k = 0
        let size = layout.size, refs = layout.refs
        var mem: String? = nil, base: String? = nil
        if size != 0 { mem = vals[k]; k += 1 }
        if refs != 0 { base = vals[k]; k += 1 }
        let n = vals[k]
        let out = "_r\(id)"
        let elemT = try swiftType(r["elem"]!, "out")
        let m = mem ?? ""
        let fieldVals = try layout.fields.map { f -> String in
            switch f.kind {
            case .str:
                return "TSGenMem.liftString(_ptr(\(m))!.loadUnaligned(fromByteOffset: Int(i) * \(size) + \(f.off), as: Int32.self), _ptr(\(m))!.loadUnaligned(fromByteOffset: Int(i) * \(size) + \(f.off + 4), as: Int32.self))"
            case .scalar:
                let s = f.r.s("scalar") ?? ""
                return scalarLoad(s, "_ptr(\(m))!.loadUnaligned(fromByteOffset: Int(i) * \(size) + \(f.off), as: \(scalarStore[s] ?? "").self)")
            case .enumIndex:
                return "\(enumName(f.r["enum"]!))(rawValue: _ptr(\(m))!.loadUnaligned(fromByteOffset: Int(i) * \(size) + \(f.off), as: Int32.self))!"
            case .ref:
                return try refLift(f.r, "(\(base ?? "") + i * \(refs) + \(f.ref))", maybeNullSlot: true)
            }
        }
        var fi = 0
        func build(_ r: JSON) -> String {
            if r.s("kind") == "tuple" { return "(\(r.a("elems").map(build).joined(separator: ", ")))" }
            defer { fi += 1 }
            return fieldVals[fi]
        }
        let elemExpr = build(r["elem"]!)
        var code = ["var \(out): [\(elemT)] = []"]
        var fill = ["\(out).reserveCapacity(Int(\(n)))", "for i in 0..<\(n) { \(out).append(\(elemExpr)) }"]
        if let mem { fill.append("if \(n) > 0 { free(_ptr(\(mem))) }") }
        if r.t("nullable") {
            code[0] = "var \(out): [\(elemT)]? = nil"
            code += ["if \(n) != -1 {", "  var _t: [\(elemT)] = []"] + fill.map { "  " + replaceAll($0, out, "_t") } + ["  \(out) = _t", "}"]
        } else {
            code += fill
        }
        liftCode += code
        return out
    }

    // MARK: Scalars

    private func scalarLower(_ s: String, _ e: String) -> String {
        switch s {
        case "bool": return "(\(e) ? 1 : 0)"
        case "f64", "f32": return e
        case "i53", "u53", "i64", "u64": return "Int64(truncatingIfNeeded: \(e))"
        default: return "Int32(truncatingIfNeeded: \(e))"
        }
    }

    private func scalarLift(_ s: String, _ v: String) -> String {
        switch s {
        case "bool": return "(\(v) != 0)"
        case "f64", "f32": return v
        default: return "\(scalarSwift[s] ?? "undefined")(truncatingIfNeeded: \(v))"
        }
    }

    private func scalarStoreExpr(_ s: String, _ e: String) -> String { s == "bool" ? "UInt8(\(e) ? 1 : 0)" : e }
    private func scalarLoad(_ s: String, _ e: String) -> String { s == "bool" ? "(\(e) != 0)" : e }

    // MARK: References

    /// A slot the callee may keep: a new one, owned by the caller.
    private func refLowerOwned(_ r: JSON, _ e: String) -> String {
        r.t("nullable") ? "(\(e)?.jsSlot() ?? 0)" : "\(e).jsSlot()"
    }

    /// A value from an owned slot.
    private func refLift(_ r: JSON, _ s: String, maybeNullSlot: Bool = false) throws -> String {
        let t = try swiftType(r.with("nullable", .bool(false)), "out")
        let cls = t == "String" ? "null" : t
        let nullable = r.t("nullable")
        if r.s("kind") == "host" && r.s("of") == "box" && r["inner"]?.s("kind") == "str" {
            let unbox = r["unbox"]!
            let op = importOp(unbox.s("module") ?? "", unbox.s("name") ?? "", ["externref"], ["i32", "i32"], nil)
            let id = tmp
            tmp += 1
            var code = ["let _u\(id): String\(nullable ? "?" : "")"]
            let read = "{ \(op.c)(\(s), TSGenRet.ptr); _u\(id) = TSGenMem.liftString(TSGenRet.i32(0), TSGenRet.i32(1)); RefTable.free(\(s), 1) }"
            if nullable {
                code.append("if \(s) == 0 || tsgen_ref_is_null(\(s)) != 0 { RefTable.free(\(s), 1); _u\(id) = nil } else \(read)")
            } else {
                code.append("do \(read)")
            }
            liftCode += code
            return "_u\(id)"
        }
        if nullable {
            if maybeNullSlot {
                return "({ let s = \(s); if tsgen_ref_is_null(s) != 0 { RefTable.free(s, 1); return nil } ; return \(cls)(owning: s) } as () -> \(cls)?)()"
            }
            return "(\(s) == 0 ? nil : \(cls)(owning: \(s)))"
        }
        return "\(cls)(owning: \(s))"
    }

    // MARK: Lowering and lifting

    /// Lowers the Swift expression `e` of repr `r`.
    private func lower(_ r: JSON, _ e: String) throws -> Low {
        let nullable = r.t("nullable")
        switch r.s("kind") {
        case "unit":
            return Low(code: [], vals: [])
        case "scalar":
            return lowerScalar(r, e)
        case "str":
            let id = tmp
            tmp += 1
            return Low(
                code: ["let (_sp\(id), _sn\(id)) = TSGenMem.lower(\(e))"], vals: ["_sp\(id)", "_sn\(id)"],
                post: ["TSGenMem.release(_sp\(id), _sn\(id))"])
        case "bigint":
            let id = tmp
            tmp += 1
            return Low(
                code: ["let (_bp\(id), _bn\(id)) = TSGenMem.lower(\(e) as JSBigInt?)"], vals: ["_bp\(id)", "_bn\(id)"],
                post: ["TSGenMem.release(_bp\(id), _bn\(id))"])
        case "enum":
            return try lowerEnum(r, e)
        case "host":
            let of = r.s("of")
            let boxStr = of == "box" && r["inner"]?.s("kind") == "str"
            if of == "class" || of == "interface" || (of == "box" && !boxStr) || of == "future" {
                return Low(code: [], vals: [nullable ? "(\(e)?.slot ?? 0)" : "\(e).slot"])
            }
            if of == "any" || boxStr {
                let id = tmp
                tmp += 1
                return Low(code: ["let _o\(id) = \(refLowerOwned(r, e))"], vals: ["_o\(id)"], post: ["RefTable.free(_o\(id), 1)"])
            }
            try unsupported("lower host \(jsStr(r["of"]))")
        case "erased":
            let id = tmp
            tmp += 1
            return Low(code: ["let _o\(id) = \(refLowerOwned(r, e))"], vals: ["_o\(id)"], post: ["RefTable.free(_o\(id), 1)"])
        case "array":
            return try lowerArray(r, e)
        case "vec":
            let id = tmp
            tmp += 1
            let sz = vecSize[r.s("elem") ?? ""].map(String.init) ?? "undefined"
            let src = nullable ? "(\(e) ?? [])" : e
            return Low(
                code: [
                    "let _vn\(id) = Int32(\(src).count)", "let _vm\(id) = TSGenMem.alloc(Int(_vn\(id)) * \(sz))",
                    "\(src).withUnsafeBytes { if let b = $0.baseAddress { _ = memcpy(_vm\(id), b, $0.count) } }",
                ],
                vals: ["(_vn\(id) == 0 ? \(sz) : _i32(_vm\(id)))", nullable ? "(\(e) == nil ? -1 : _vn\(id))" : "_vn\(id)"],
                post: ["free(_vm\(id))"])
        case "tuple":
            let parts = try r.a("elems").enumerated().map { i, el in try lower(el, "\(e).\(i)") }
            return Low(code: parts.flatMap(\.code), vals: parts.flatMap(\.vals), post: parts.flatMap(\.post))
        case "fn":
            try useCallback(r)
            let t = try swiftType(r.with("nullable", .bool(false)), "in")
            return Low(code: [], vals: [nullable ? "(\(e).map { TSGenClosure<\(t)>($0).handle } ?? 0)" : "TSGenClosure<\(t)>(\(e)).handle"])
        default:
            try unsupported("lower \(jsStr(r["kind"]))")
        }
    }

    private func niche(_ r: JSON) -> String {
        r.s("scalar") == "bool" ? "2" : r.a("wire").first?.str == "i64" ? "Int64.min" : "Int32.min"
    }

    private func lowerScalar(_ r: JSON, _ e: String) -> Low {
        let s = r.s("scalar") ?? ""
        if !r.t("nullable") { return Low(code: [], vals: [scalarLower(s, e)]) }
        if r.o("niche") != nil {
            return Low(code: [], vals: ["(\(e).map { \(scalarLower(s, "$0")) } ?? \(niche(r)))"])
        }
        return Low(code: [], vals: ["(\(e) == nil ? 0 : 1)", "(\(e).map { \(scalarLower(s, "$0")) } ?? 0)"])
    }

    /// Lifts wire values (Swift expressions) of repr `r` to a Swift
    /// expression; statements it needs go to `liftCode`.
    private func lift(_ r: JSON, _ vals: [String]) throws -> String {
        let nullable = r.t("nullable")
        switch r.s("kind") {
        case "unit":
            return "()"
        case "scalar":
            let s = r.s("scalar") ?? ""
            if !nullable { return scalarLift(s, vals[0]) }
            if r.o("niche") != nil { return "(\(vals[0]) == \(niche(r)) ? nil : \(scalarLift(s, vals[0])))" }
            return "(\(vals[0]) == 0 ? nil : \(scalarLift(s, vals[1])))"
        case "str":
            return nullable ? "TSGenMem.liftOptString(\(vals[0]), \(vals[1]))" : "TSGenMem.liftString(\(vals[0]), \(vals[1]))"
        case "bigint":
            return "TSGenMem.liftBigInt(\(vals[0]), \(vals[1]))\(nullable ? "" : "!")"
        case "enum":
            return try liftEnum(r, vals)
        case "host", "erased":
            if r.s("kind") == "host" && r.s("of") == "future" { try unsupported("future in a nested position") }
            return try refLift(r, vals[0])
        case "array":
            return try liftArray(r, vals)
        case "vec":
            let t = vecSwift[r.s("elem") ?? ""] ?? "undefined"
            let id = tmp
            tmp += 1
            let body = "Array(UnsafeBufferPointer(start: _ptr(\(vals[0]))?.assumingMemoryBound(to: \(t).self), count: Int(\(vals[1]))))"
            liftCode += [
                "let _vv\(id): [\(t)]\(nullable ? "?" : "") = \(nullable ? "\(vals[1]) == -1 ? nil : " : "")\(vals[1]) == 0 ? [] : \(body)",
                "if \(vals[1]) > 0 { free(_ptr(\(vals[0]))) }",
            ]
            return "_vv\(id)"
        case "tuple":
            var k = 0
            let parts = try r.a("elems").map { el -> String in
                let w = el.a("wire").map { _ -> String in
                    defer { k += 1 }
                    return vals[k]
                }
                return try lift(el, w)
            }
            return "(\(parts.joined(separator: ", ")))"
        case "fn":
            try unsupported("a JS function as a result")
        default:
            try unsupported("lift \(jsStr(r["kind"]))")
        }
    }

    // MARK: Callbacks

    /// A callback type's trampoline is generated when first used, so a member
    /// whose callback can't be mapped is skipped along with it.
    private func useCallback(_ r: JSON) throws {
        let tramp = r.s("trampoline") ?? ""
        memberCallbacks?.insert(tramp)
        if let known = callbacks[tramp] {
            if known == nil { try unsupported("callback \(jsStr(r["ty"]))") }
            return
        }
        let saved = liftCode
        let savedOut = out
        out = []
        callbacks[tramp] = .some(nil)
        defer {
            out = savedOut
            liftCode = saved
        }
        try emitCallback(r)
        callbacks[tramp] = .some(r)
        callbackCode[tramp] = out
    }

    private func emitCallback(_ r: JSON) throws {
        let t = try swiftType(r.with("nullable", .bool(false)), "in")
        let result = r["result"]!
        let res = try closureResult(result)
        var params: [(name: String, w: String)] = []
        for (i, p) in r.a("params").enumerated() {
            for (j, w) in p.strs("wire").enumerated() { params.append(("_a\(i)_\(j)", w)) }
        }
        let wireResults = res.type == "Void" ? (result.s("kind") == "unit" ? [] : result.strs("wire")) : result.strs("wire")
        liftCode = []
        var k = 0
        let args = try r.a("params").map { p -> String in
            let w = p.a("wire").map { _ -> String in
                defer { k += 1 }
                return params[k].name
            }
            return try lift(p, w)
        }
        let pre = liftCode
        let call = "TSGenClosure<\(t)>.from(env)(\(args.joined(separator: ", ")))"
        let x = exportOp(r.s("trampoline") ?? "", ["i32"] + params.map(\.w), wireResults, nil)
        var body = pre
        if res.type == "Void" {
            body.append(call)
            if wireResults.count == 1 { body.append("return 0") }
        } else {
            let l = try res.lower("_r")
            body.append("let _r = \(call)")
            body += l.code
            if wireResults.count == 1 {
                body.append("return \(l.vals[0])")
            } else {
                for (i, v) in l.vals.enumerated() { body.append("TSGenRet.set(\(i), \(v))") }
            }
        }
        let flatRet = wireResults.count == 1 ? " -> \(ws(wireResults[0]))" : ""
        let ps = params.map { ", _ \($0.name): \(ws($0.w))" }.joined()
        out.append("@_expose(wasm, \"\(x.c)\")\n@_cdecl(\"\(x.c)\")\npublic func _\(x.c)(_ env: Int32\(ps))\(flatRet) {\n  \(body.joined(separator: "\n  "))\n}")
        out.append("@_expose(wasm, \(swiftLit("tw:drop:\(jsStr(r["ty"]))")))\n@_cdecl(\"tsgen_drop_\(x.c)\")\npublic func _tsgen_drop_\(x.c)(_ env: Int32) { _tsgenRelease(env) }")
    }

    // MARK: Members

    /// One imported member as Swift declarations, or throws Unsupported.
    private func genMember(_ m: JSON) throws -> Member {
        guard let sig = m.o("sig") else { try unsupported(m.s("error") ?? "no layout") }
        let sigParams = sig.a("params")
        let thisP = sigParams.first { $0.s("role") == "this" }
        let params = sigParams.filter { $0.s("role") == "param" }
        let resultR = sig.a("results").first?.o("repr") ?? unitRepr
        let throwsInfo = tagInfo(sig["throws"])
        let isFuture = resultR.s("kind") == "host" && resultR.s("of") == "future"
        let valueR = isFuture ? resultR["value"]! : resultR
        memberCallbacks = OrderedSet()
        let metas = m.a("params")

        // Swift parameters.
        let sp = try params.enumerated().map { i, p -> Param in
            let idx = Int(p["index"]?.num ?? -1)
            let meta = idx >= 0 && idx < metas.count && !metas[idx].isNull ? metas[idx] : obj([])
            let name = memberName(meta.o("name").map(jsStr) ?? "p\(i)")
            let repr = p["repr"]!
            var type: String
            if meta.t("spread") && repr.s("kind") == "array" {
                type = "\(try swiftType(repr["elem"]!, "in"))..."
            } else {
                type = try swiftType(repr, "in")
            }
            if repr.s("kind") == "fn" && !repr.t("nullable") { type = "@escaping \(type)" }
            return Param(name: name, type: type, repr: repr, spread: meta.t("spread"))
        }
        let errT = throwsInfo.map { throwType($0.layout) }
        let rejT = isFuture ? throwType(resultR["rejection"]!) : nil
        let resT = try swiftType(valueR, "out")

        // The call.
        var code: [String] = []
        var post: [String] = []
        var args: [String] = []
        if thisP != nil { args.append("slot") }
        for p in sp {
            let l = try lower(p.repr, p.name)
            code += l.code
            args += l.vals
            post += l.post
        }
        let wireParams = sig["core"]?.strs("params") ?? []
        let wireResults = sig["core"]?.strs("results") ?? []
        let op = importOp(m.s("module") ?? "tw:js/global", m.s("key") ?? "", wireParams, wireResults, throwsInfo)
        var cbs = OrderedSet<String>()
        for c in (op.callbacks ?? []) + (memberCallbacks?.items ?? []) { cbs.insert(c) }
        op.callbacks = cbs.items
        let useRet = throwsInfo != nil || wireResults.count > 1
        if useRet { args.append("TSGenRet.ptr") }
        let call = "\(op.c)(\(args.joined(separator: ", ")))"
        var body = code
        if !post.isEmpty { body.append("defer { \(post.joined(separator: "; ")) }") }
        liftCode = []
        var resultExpr: String? = nil
        if let throwsInfo {
            let thrown = try liftThrow(throwsInfo.layout) { "TSGenRet.\(retRead[throwsInfo.params[$0]] ?? "")(\($0))" }
            body.append("if \(call) != 0 {")
            body += liftCode.map { "  " + $0 }
            liftCode = []
            body += ["  throw \(thrown)", "}"]
        } else if wireResults.count == 1 {
            body.append("let _w = \(call)")
        } else {
            body.append(call)
        }
        func readResult(_ i: Int) -> String {
            throwsInfo != nil || wireResults.count > 1 ? "TSGenRet.\(retRead[wireResults[i]] ?? "")(\(i))" : "_w"
        }

        if isFuture {
            let f = throwsInfo != nil || wireResults.count > 1 ? "TSGenRet.i32(0)" : "_w"
            body += ["let _f = \(f)", "defer { RefTable.free(_f, 1) }"]
            let rejection = resultR["rejection"]!
            let errWire = ["i32"] + rejection["shape"]!.strs("slots")
            let errOp = resultR["errorOp"]!
            let eop = importOp(errOp.s("module") ?? "", errOp.s("name") ?? "", ["externref"], errWire, nil)
            liftCode = []
            let thrown = try liftThrow(rejection) { "TSGenRet.\(retRead[errWire[$0]] ?? "")(\($0))" }
            body += ["if await TSGen.settle(_f) == 2 {", "  \(eop.c)(_f, TSGenRet.ptr)"]
            body += liftCode.map { "  " + $0 }
            liftCode = []
            body += ["  throw \(thrown)", "}"]
            let vw = valueR.strs("wire")
            let take = resultR["take"]!
            let takeOp = importOp(take.s("module") ?? "", take.s("name") ?? "", ["externref"], vw, nil)
            if vw.isEmpty {
                body.append("\(takeOp.c)(_f)")
            } else if vw.count == 1 {
                body.append("let _t = \(takeOp.c)(_f)")
                resultExpr = try lift(valueR, ["_t"])
            } else {
                body.append("\(takeOp.c)(_f, TSGenRet.ptr)")
                for (i, w) in vw.enumerated() { body.append("let _t\(i) = TSGenRet.\(retRead[w] ?? "")(\(i))") }
                resultExpr = try lift(valueR, vw.indices.map { "_t\($0)" })
            }
        } else if !wireResults.isEmpty {
            for i in wireResults.indices { body.append("let _r\(i) = \(readResult(i))") }
            resultExpr = try lift(valueR, wireResults.indices.map { "_r\($0)" })
        }
        body += liftCode
        liftCode = []
        if let resultExpr, resT != "Void" { body.append("return \(resultExpr)") }

        let effects = "\(isFuture ? " async" : "")\(errT != nil || rejT != nil ? " throws(\(errT ?? rejT!))" : "")"
        if let errT, let rejT, errT != rejT { try unsupported("throws and a rejection of different types") }
        return Member(
            sp: sp, resT: resT, effects: effects, body: body, isFuture: isFuture, isStatic: thisP == nil,
            usesT: valueR.mentionsErased, valueR: valueR)
    }

    private func throwType(_ layout: JSON) -> String {
        throwEnums[layout.s("path") ?? ""] = layout
        return enumName(layout)
    }

    private func liftThrow(_ layout: JSON, _ readVal: (Int) -> String) throws -> String {
        let n = 1 + layout["shape"]!.strs("slots").count
        let vals = (0..<n).map(readVal)
        let e = try liftEnum(obj([("kind", .string("enum")), ("enum", layout), ("nullable", .bool(true))]), vals)
        let arms = layout.a("arms")
        let fb = arms.first { $0.t("fallback") }
        let arm = fb ?? arms[0]
        return "(\(e) ?? .\(caseName(arm))\(fb.map { !$0.a("payload").isEmpty } ?? false ? "(\"unknown error\")" : ""))"
    }

    // MARK: Declarations

    func emitAll() throws {
        enumDecls = []
        throwEnums = OrderedMap()
        let classes = selected.items.filter { isClassLike($0) }
        // Parents first, so inherited signatures are known.
        var order: [String] = []
        var seen: Set<String> = []
        func visit(_ p: String) {
            guard seen.insert(p).inserted else { return }
            if let parent = primaryParent(p) { visit(parent) }
            order.append(p)
        }
        classes.forEach(visit)
        sigs = [:]
        for p in order { try emitClass(p) }
        try emitGlobals()
        emitExports()
        try emitOps()
        if let keepFor = keepCallbacksFor {
            keepCallbacks = Set(imports.values.filter { keepFor.contains($0.c) }.flatMap { $0.callbacks ?? [] })
        }
        var enums = enumsUsed
        for p in selected.items {
            let d = decls[p]!
            if d.s("kind") == "enum" && !enums.has(p) { enums[p] = d["layout"]! }
        }
        var dropped: Set<String> = []
        for d in duplicates where !emittedKeys.contains(d.key) && dropped.insert(d.key).inserted { skipped.append(d) }
        // Enums can pull in more enums through their payloads.
        var done: Set<String> = []
        var more = true
        while more {
            more = false
            for (p, layout) in enums.entries + enumsUsed.entries {
                guard done.insert(p).inserted else { continue }
                more = true
                do {
                    try emitEnum(layout, asError: throwEnums.has(p))
                } catch let e as Unsupported {
                    skipped.append(("enum \(p)", e.message))
                }
            }
            for (p, layout) in throwEnums.entries where !done.contains(p) {
                enums[p] = layout
                more = true
            }
        }
    }

    private func primaryParent(_ p: String) -> String? {
        for e in decls[p]?.strs("extends") ?? [] {
            let q = stripArgs(e)
            if isClassLike(q) { return q }
        }
        return nil
    }

    private func ancestors(_ p: String) -> [String] {
        var out: [String] = []
        var q = primaryParent(p)
        while let a = q {
            out.append(a)
            q = primaryParent(a)
        }
        return out
    }

    private func signature(_ name: String, _ sp: [Param], _ isStatic: Bool) -> String {
        "\(isStatic ? "static " : "")\(name)(\(sp.enumerated().map { i, p in "\(i == 0 ? "_" : p.name):\(p.type)" }.joined(separator: ",")))"
    }

    private func emitClass(_ path: String) throws {
        let name = typeName(path)
        let parent = primaryParent(path)
        let ancestors = ancestors(path)
        let inherited = Set(ancestors.flatMap { sigs[$0]?.set ?? [] })
        let mine = Signatures()
        sigs[path] = mine
        var owners = [path]
        // Members of the other parents (and their ancestors) are copied in.
        func extra(_ p: String) {
            for e in decls[p]?.strs("extends") ?? [] {
                let q = stripArgs(e)
                if decls[q] == nil || owners.contains(q) { continue }
                if q == primaryParent(p) && p == path { continue }
                owners.append(q)
                extra(q)
            }
        }
        extra(path)
        var ownerSet = OrderedSet<String>()
        for o in owners where !ancestors.contains(o) { ownerSet.insert(o) }
        let members = ownerSet.items.flatMap { (byOwner[$0] ?? []).filter { $0.s("role") == "import" } }
        let objectInit = members.contains { m in
            m.s("kind") == "new" && (m["sig"]?["core"]?.a("params").isEmpty ?? false) && (m["jsName"]?.isNull ?? false)
                && isObjectNew(m)
        }
        var lines = ["/// `\(path)`", "open class \(name): \(parent.map(typeName) ?? "JSObject") {"]
        let body = try emitMembers(members, Ctx(inherited: inherited, mine: mine, objectInit: objectInit))
        lines += body.map { "  " + replaceAll($0, "\n", "\n  ") }
        lines.append("}")
        out.append(lines.joined(separator: "\n"))
    }

    /// `@js(object) new()`: the lowered JSON has no flag, but an interface's
    /// no-argument constructor can only be one.
    private func isObjectNew(_ m: JSON) -> Bool {
        guard let o = m.o("owner") else { return false }
        return decls[jsStr(o)]?.s("kind") == "interface"
    }

    private func emitMembers(_ members: [JSON], _ ctx: Ctx) throws -> [String] {
        var out: [String] = []
        var props = OrderedMap<String, (get: JSON?, sets: [JSON])>()
        for m in members {
            let kind = m.s("kind")
            guard kind == "get" || kind == "set" else { continue }
            let k = "\(m.t("static") ? "s:" : "")\(jsStr(m["name"]))"
            var p = props[k] ?? (nil, [])
            if kind == "get" {
                if p.get == nil { p.get = m }
            } else {
                p.sets.append(m)
            }
            props[k] = p
        }
        var settable: [Settable] = []
        for m in members where m.s("kind") != "get" && m.s("kind") != "set" {
            emitOne(m, ctx, &out)
        }
        for (_, p) in props.entries {
            try emitProperty(p.get, p.sets, ctx, &out, &settable)
        }
        if ctx.objectInit && !settable.isEmpty {
            func opt(_ t: String) -> String { isFunctionType(t) ? "(\(t))?" : ends(t, "?") ? t : "\(t)?" }
            let ps = settable.map { "\($0.name): \(opt($0.type)) = nil" }
            let sets = settable.map { s in
                s.set.map { "  if let \(s.name) { \(s.tries ? "try? " : "")self.\($0)(\(s.name)) }" }
                    ?? "  if let \(s.name) { self.\(s.name) = \(s.name) }"
            }
            out.append("/// A plain object with the properties given.\npublic convenience init(\(ps.joined(separator: ", "))) {\n  self.init()\n\(sets.joined(separator: "\n"))\n}")
        }
        return out
    }

    private func docComment(_ m: JSON?) -> String {
        guard let d = m?["doc"], d.truthy else { return "" }
        return split(jsStr(d), "\n").map { "/// \($0)" }.joined(separator: "\n") + "\n"
    }

    private func paramList(_ sp: [Param]) -> String {
        sp.enumerated().map { i, p in "\(i == 0 ? "_ " : "")\(p.name): \(p.type)" }.joined(separator: ", ")
    }

    private func emitOne(_ m: JSON, _ ctx: Ctx, _ out: inout [String]) {
        let g: Member
        do {
            g = try genMember(m)
        } catch {
            skipped.append((m.s("key") ?? "", (error as? Unsupported)?.message ?? "\(error)"))
            return
        }
        // A named constructor (`new wrap2(..)`) is a static factory.
        let isCtor = m.s("kind") == "new" && m.o("name") == nil
        var name = isCtor ? "init" : memberName(jsStr(m.o("name") ?? m["variant"]))
        func taken(_ name: String) -> String? {
            let sig = signature(name, g.sp, g.isStatic && !isCtor)
            // A class declares its own inits: an inherited one makes the parent.
            if !isCtor && ctx.inherited?.contains(sig) == true { return "declared by a parent class" }
            if ctx.mine?.set.contains(sig) == true { return "the same Swift signature as an overload" }
            return nil
        }
        if let why = taken(name) {
            // Overloads Swift can't tell apart are named by their variant.
            let variant = memberName(jsStr(m["variant"]))
            if !isCtor, m["variant"]?.str != nil, variant != name, taken(variant) == nil {
                name = variant
            } else {
                duplicates.append((m.s("key") ?? "", why))
                return
            }
        }
        ctx.mine?.set.insert(signature(name, g.sp, g.isStatic && !isCtor))
        emittedKeys.insert(m.s("key") ?? "")
        let params = paramList(g.sp)
        let doc = docComment(m)
        emittedMembers += 1
        let mod = ctx.global ? "public" : g.isStatic ? "public static" : "public final"
        if isCtor {
            // The call's result is the new object's slot.
            let body = g.body.map(ctorReturn)
            out.append("\(doc)public convenience init(\(params))\(g.effects) {\n  \(body.joined(separator: "\n  "))\n}")
            return
        }
        let recv = ctx.global ? "" : g.isStatic ? "Self." : "self."
        let tryKw = has(g.effects, "throws") ? "try " : ""
        let spread = g.sp.contains { $0.spread }
        if g.usesT && g.resT != "Void" && !spread {
            // The erased form, and one that decodes a Decodable.
            out.append("\(doc)@discardableResult\n\(mod) func \(name)(\(params))\(g.effects) -> \(g.resT) {\n  \(g.body.joined(separator: "\n  "))\n}")
            if let dec = decodeExpr(g.valueR, "_v") {
                let asParams = (g.sp.enumerated().map { i, p in "\(i == 0 ? "_ " : "")\(p.name): \(p.type)" } + ["as type: R.Type = R.self"])
                    .joined(separator: ", ")
                let callArgs = g.sp.enumerated().map { i, p in unquote(i == 0 ? p.name : "\(p.name): \(p.name)") }.joined(separator: ", ")
                let awaitKw = g.isFuture ? "await " : ""
                out.append(codable("\(doc)\(mod) func \(name)<R: Decodable>(\(asParams))\(g.isFuture ? " async" : "") throws -> \(dec.type) {\n  let _v = \(tryKw)\(awaitKw)\(recv)\(name)(\(callArgs))\n  return \(dec.expr)\n}"))
            }
            return
        }
        let ret = g.resT == "Void" ? "" : " -> \(g.resT)"
        let discard = g.resT == "Void" ? "" : "@discardableResult\n"
        out.append("\(doc)\(discard)\(mod) func \(name)(\(params))\(g.effects)\(ret) {\n  \(g.body.joined(separator: "\n  "))\n}")
        // A parameter of an erased type also takes any Encodable.
        if g.sp.contains(where: { $0.repr.s("kind") == "erased" }) && !spread {
            let ps = g.sp.enumerated().map { i, p in
                let t = p.repr.s("kind") == "erased" ? (p.repr.t("nullable") ? "(some Encodable)?" : "some Encodable") : p.type
                return "\(i == 0 ? "_ " : "")\(p.name): \(t)"
            }.joined(separator: ", ")
            let callArgs = g.sp.enumerated().map { i, p -> String in
                let v = unquote(p.name)
                let e = p.repr.s("kind") == "erased" ? (p.repr.t("nullable") ? "\(v).map { JSValueEncoder.value($0) }" : "JSValueEncoder.value(\(v))") : v
                return i == 0 ? e : "\(v): \(e)"
            }
            out.append(codable("\(doc)\(discard)\(mod) func \(name)(\(ps))\(g.effects)\(ret) {\n  \(g.resT == "Void" ? "" : "return ")\(tryKw)\(g.isFuture ? "await " : "")\(recv)\(name)(\(callArgs.joined(separator: ", ")))\n}"))
        }
    }

    /// `return T(owning: x)` as `self.init(owning: x)`, for a constructor.
    private func ctorReturn(_ l: String) -> String {
        guard starts(l, "return "), !l.unicodeScalars.contains(where: { [0x0A, 0x0D, 0x2028, 0x2029].contains($0.value) }) else { return l }
        let u = Array(l.utf8)
        var i = 7
        let w0 = i
        while i < u.count, u[i] == 0x5F || (u[i] >= 0x30 && u[i] <= 0x39) || (u[i] >= 0x41 && u[i] <= 0x5A) || (u[i] >= 0x61 && u[i] <= 0x7A) { i += 1 }
        let open = Array("(owning: ".utf8)
        guard i > w0, i + open.count < u.count - 1, u[i..<i + open.count].elementsEqual(open), u.last == 0x29 else { return l }
        let arg = String(decoding: u[(i + open.count)..<(u.count - 1)], as: UTF8.self)
        return "self.init(owning: \(arg))"
    }

    private func decodeExpr(_ r: JSON, _ v: String) -> (type: String, expr: String)? {
        func isAny(_ r: JSON) -> Bool { r.s("kind") == "erased" || (r.s("kind") == "host" && r.s("of") == "any") }
        if isAny(r) {
            return r.t("nullable") ? ("R?", "try \(v).map { try $0.decode(as: R.self) }") : ("R", "try \(v).decode(as: R.self)")
        }
        if r.s("kind") == "array", let el = r["elem"], isAny(el) {
            let e = el.t("nullable") ? "try $0.map { try $0.decode(as: R.self) }" : "try $0.decode(as: R.self)"
            return (el.t("nullable") ? "[R?]" : "[R]", "try \(v)\(r.t("nullable") ? "?" : "").map { \(e) }")
        }
        return nil
    }

    private func setterName(_ m: JSON) -> String { memberName("set" + upperFirst(camel(jsStr(m["name"])))) }

    private func emitProperty(_ get: JSON?, _ sets: [JSON], _ ctx: Ctx, _ out: inout [String], _ settable: inout [Settable]) throws {
        let first = get ?? sets[0]
        let isStatic = first.t("static")
        let name = memberName(jsStr(first["name"]))
        var gg: Member? = nil
        if let get {
            do {
                gg = try genMember(get)
            } catch {
                skipped.append((get.s("key") ?? "", (error as? Unsupported)?.message ?? "\(error)"))
            }
        }
        var gs: [(m: JSON, g: Member)] = []
        for s in sets {
            do {
                gs.append((s, try genMember(s)))
            } catch {
                skipped.append((s.s("key") ?? "", (error as? Unsupported)?.message ?? "\(error)"))
            }
        }
        let mod = ctx.global ? "public" : isStatic ? "public static" : "public final"
        let getter = gg.flatMap { $0.isFuture ? nil : $0 }
        let sig = signature(name, [], isStatic) + ":prop"
        if ctx.inherited?.contains(sig) == true || ctx.mine?.set.contains(sig) == true {
            let why = ctx.inherited?.contains(sig) == true ? "declared by a parent class" : "the same Swift name as another property"
            if gg != nil, let get { duplicates.append((get.s("key") ?? "", why)) }
            for (m, _) in gs { duplicates.append((m.s("key") ?? "", why)) }
            return
        }
        ctx.mine?.set.insert(sig)
        let plainSet = gs.filter { $0.g.sp.count == 1 && !$0.g.isFuture }
        let one = plainSet.count == 1 ? plainSet[0] : nil
        let tSet = one?.g.sp[0].type
        let doc = docComment(first)
        if let gg = getter, let one, let tSet, gg.resT == tSet || gg.resT == "\(tSet)?", !has(gg.effects, "throws") {
            // A property: setting nil on a non-null setter leaves it unset.
            let tGet = gg.resT
            let v = unquote(one.g.sp[0].name)
            let setBody = one.g.body.joined(separator: "\n      ")
            let setter = tGet == tSet ? "let \(v) = newValue\n      \(setBody)" : "guard let \(v) = newValue else { return }\n      \(setBody)"
            let setTry = has(one.g.effects, "throws") ? "do {\n      \(replaceAll(setter, "\n", "\n  "))\n      } catch { }" : setter
            out.append("\(doc)\(mod) var \(name): \(tGet) {\n  get {\n    \(gg.body.joined(separator: "\n    "))\n  }\n  set {\n      \(setTry)\n  }\n}")
            emittedMembers += 2
            emittedKeys.formUnion([get?.s("key") ?? "", one.m.s("key") ?? ""])
            if !isStatic { settable.append(Settable(name: name, type: tGet)) }
            return
        }
        // A union read back as an enum, set through one setter per arm: a
        // property of the enum type whose setter picks the setter.
        var layout: JSON? = nil
        if let gg = getter, gg.valueR.s("kind") == "enum", gg.valueR["enum"]?["shape"]?.s("kind") == "payload" { layout = gg.valueR["enum"] }
        func armFor(_ t: String) throws -> [JSON] {
            try (layout?.a("arms") ?? []).filter { a in
                let p = a.a("payload")
                return try p.count == 1 && payloadType(p[0]) == t
            }
        }
        func allOneArm() throws -> Bool {
            for x in plainSet {
                if try armFor(dropPrefix(x.g.sp[0].type, "@escaping ")).count != 1 { return false }
            }
            return true
        }
        if let gg = getter, layout != nil, !plainSet.isEmpty, !has(gg.effects, "throws"), try allOneArm() {
            let cases = try plainSet.map { x -> String in
                let a = try armFor(dropPrefix(x.g.sp[0].type, "@escaping "))[0]
                return "case .\(caseName(a))(let v)?: \(has(x.g.effects, "throws") ? "try? " : "")self.\(setterName(x.m))(v)"
            }
            let t = ends(gg.resT, "?") ? gg.resT : "\(gg.resT)?"
            out.append("\(doc)\(mod) var \(name): \(t) {\n  get {\n    \(gg.body.joined(separator: "\n    "))\n  }\n  set {\n    switch newValue {\n    \(cases.joined(separator: "\n    "))\n    default: break\n    }\n  }\n}")
            emittedMembers += 1
            emittedKeys.insert(get?.s("key") ?? "")
            if !isStatic { settable.append(Settable(name: name, type: t)) }
        } else if let gg {
            // Read-only, or a getter of a future: an effectful property.
            emittedMembers += 1
            emittedKeys.insert(get?.s("key") ?? "")
            out.append("\(doc)\(mod) var \(name): \(gg.resT) {\n  get\(gg.effects) {\n    \(gg.body.joined(separator: "\n    "))\n  }\n}")
        } else if let one, !isStatic {
            // Write-only (a callback, say): settable through the init.
            settable.append(Settable(name: name, type: dropPrefix(one.g.sp[0].type, "@escaping "), set: setterName(one.m), tries: has(one.g.effects, "throws")))
        }
        for (m, g) in gs {
            let fn = setterName(m)
            let s = signature(fn, g.sp, isStatic)
            if ctx.inherited?.contains(s) == true || ctx.mine?.set.contains(s) == true {
                duplicates.append((m.s("key") ?? "", ctx.inherited?.contains(s) == true ? "declared by a parent class" : "the same Swift signature as an overload"))
                continue
            }
            ctx.mine?.set.insert(s)
            emittedMembers += 1
            emittedKeys.insert(m.s("key") ?? "")
            out.append("\(mod) func \(fn)(\(paramList(g.sp)))\(g.effects) {\n  \(g.body.joined(separator: "\n  "))\n}")
        }
    }

    private func emitGlobals() throws {
        let globals = (byOwner[""] ?? []).filter { $0.t("_global") }
        out += try emitMembers(globals, Ctx(mine: Signatures(), global: true))
        // Namespaces (`console`-style objects are globals; these are JS namespaces).
        for (k, ms) in byOwner.entries where starts(k, "ns:") {
            let ns = dropPrefix(k, "ns:")
            if !selected.has(ns) && !ms.contains(where: { $0.t("_global") }) { continue }
            let imports = ms.filter { $0.s("role") == "import" }
            if imports.isEmpty { continue }
            let body = try emitMembers(imports.map { $0.with("static", .bool(true)) }, Ctx(mine: Signatures()))
            let text = replaceAll(replaceAll(body.joined(separator: "\n"), "\n", "\n  "), "public final", "public static")
            out.append("public enum \(typeName(ns)) {\n  \(text)\n}")
        }
    }

    // MARK: Exports

    private func emitExports() {
        var groups = OrderedMap<String, [JSON]>()
        for m in members where m.s("role") == "export" {
            let k = m.o("owner").map { "class:\(jsStr($0))" } ?? "ns:\(m.strs("namespace").joined(separator: "."))"
            groups.update(k, default: []) { $0.append(m) }
        }
        for (k, ms) in groups.entries {
            let isClass = starts(k, "class:")
            let owner = dropPrefix(k, isClass ? "class:" : "ns:")
            let proto = isClass ? "\(typeName(owner))Export" : "\(upperFirst(camel(owner == "default" ? "worker" : owner)))Export"
            var reqs: [String] = []
            for m in ms {
                // An export Swift can't express is skipped like an import,
                // with whatever it generated.
                let (nOut, nExports, nTmp) = (out.count, exports.count, tmp)
                do {
                    reqs.append(try emitExport(m, isClass: isClass, owner: owner))
                } catch {
                    out.removeLast(out.count - nOut)
                    exports.removeLast(exports.count - nExports)
                    tmp = nTmp
                    skipped.append((m.s("key") ?? "", (error as? Unsupported)?.message ?? "\(error)"))
                }
            }
            protocols.append(ExportProtocol(name: proto, isClass: isClass, typeName: typeName(owner), requirements: reqs))
            let typed = reqs.joined(separator: "\n  ")
            let untyped = untypedThrows(typed)
            out.append("/// What the module exports as `\(isClass ? "class \(owner)" : "namespace \(owner)")`.\npublic protocol \(proto)\(isClass ? ": AnyObject" : "") {\n#if hasFeature(Embedded)\n  \(typed)\n#else\n  \(untyped)\n#endif\n}")
            if isClass {
                let c = camel(owner)
                out.append("@_expose(wasm, \(swiftLit("tw:drop:\(owner)")))\n@_cdecl(\"tsgen_drop_class_\(c)\")\npublic func _tsgen_drop_class_\(c)(_ h: Int32) { _tsgenRelease(h) }")
            }
        }
    }

    /// `throws(E)` as a plain `throws`.
    private func untypedThrows(_ s: String) -> String {
        let u = Array(s.utf8)
        let head = Array("throws(".utf8)
        var out: [UInt8] = []
        var i = 0
        while i < u.count {
            if i + head.count < u.count, u[i..<i + head.count].elementsEqual(head) {
                var j = i + head.count
                while j < u.count, u[j] == 0x5F || (u[j] >= 0x41 && u[j] <= 0x5A) || (u[j] >= 0x61 && u[j] <= 0x7A) { j += 1 }
                if j > i + head.count, j < u.count, u[j] == 0x29 {
                    out += Array("throws".utf8)
                    i = j + 1
                    continue
                }
            }
            out.append(u[i])
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func emitExport(_ m: JSON, isClass: Bool, owner: String) throws -> String {
        guard let sig = m.o("sig") else { try unsupported(m.s("error") ?? "no layout") }
        let sigParams = sig.a("params")
        let params = sigParams.filter { $0.s("role") == "param" }
        let hasThis = sigParams.contains { $0.s("role") == "this" }
        let hasHandle = sigParams.contains { $0.s("role") == "handle" }
        let resultR = sig.a("results").first?.o("repr") ?? unitRepr
        let isFuture = resultR.s("kind") == "host" && resultR.s("of") == "future"
        let valueR = isFuture ? resultR["value"]! : resultR
        // An async export's errors become its future's rejection, thrown as that
        // enum's tag (the runtime awaits the export under JSPI).
        let sigThrows = sig.o("throws")
        let throwLayout = sigThrows?["enum"] ?? (isFuture ? resultR["rejection"] : nil)
        var throwsInfo: TagInfo? = nil
        if sigThrows != nil {
            throwsInfo = tagInfo(sigThrows)
        } else if isFuture {
            let rej = resultR["rejection"]!
            throwsInfo = TagInfo(module: "tw:tag", name: rej.s("path") ?? "", params: ["i32"] + rej["shape"]!.strs("slots"), layout: rej)
        }
        if let throwLayout { _ = throwType(throwLayout) }
        var flat: [(n: String, w: String)] = []
        let metas = m.a("params")
        let sp = try params.enumerated().map { i, p -> Param in
            let idx = Int(p["index"]?.num ?? -1)
            let meta = idx >= 0 && idx < metas.count && !metas[idx].isNull ? metas[idx] : obj([])
            return Param(name: memberName(meta.o("name").map(jsStr) ?? "p\(i)"), type: try swiftType(p["repr"]!, "out"), repr: p["repr"]!, spread: false)
        }
        liftCode = []
        var pre: [String] = []
        if hasThis {
            flat.append(("_this", "i32"))
            pre.append("RefTable.free(_this, 1)")
        }
        if hasHandle { flat.append(("_h", "i32")) }
        let args = try sp.enumerated().map { i, p -> String in
            let w = p.repr.strs("wire").enumerated().map { j, w -> String in
                let n = "_p\(i)_\(j)"
                flat.append((n, w))
                return n
            }
            return try lift(p.repr, w)
        }
        pre += liftCode
        let isCtor = m.s("kind") == "new"
        let resT = isCtor ? "Self" : try swiftType(valueR, "in")
        let name = isCtor ? "init" : memberName(jsStr(m["name"]))
        let labels = paramList(sp)
        // Embedded Swift throws only typed errors: there, the app throws the
        // enum the bridge maps to JS errors.
        let thr = "throws(\(throwLayout.map(enumName) ?? "JSException"))"
        let req = isCtor
            ? "init(\(labels)) \(thr)"
            : "\(isClass ? "" : "static ")func \(name)(\(labels))\(isFuture ? " async" : "") \(thr)\(resT == "Void" ? "" : " -> \(resT)")"
        let callArgs = sp.enumerated().map { i, p in i == 0 ? args[i] : "\(unquote(p.name)): \(args[i])" }.joined(separator: ", ")
        let owned = typeName(owner)
        let target = isCtor ? "\(owned)(\(callArgs))" : isClass ? "TSGenHandle.get(_h, as: \(owned).self).\(name)(\(callArgs))" : "\(appType).\(name)(\(callArgs))"
        let wireResults = isCtor ? ["i32"] : isFuture ? resultR.strs("wire") : sig["core"]?.strs("results") ?? []
        let x = exportOp(m.s("key") ?? "", sig["core"]?.strs("params") ?? [], wireResults, throwsInfo)
        x.details = [("async", .bool(isFuture)), ("owner", m.o("owner") ?? .null)]
        if let n = m["name"] { x.details.append(("member", n)) }
        if let k = m["kind"] { x.details.append(("kind", k)) }
        // The result as wire values, then the error path.
        var l: Low
        if isCtor {
            l = Low(code: [], vals: ["TSGenHandle.retain(_r)"])
        } else if valueR.s("kind") == "unit" {
            l = Low(code: [], vals: isFuture ? ["0"] : [])
        } else if isFuture {
            l = try resolvedFuture(resultR, valueR, "_r")
        } else if valueR.s("kind") == "host" {
            l = Low(code: [], vals: [valueR.t("nullable") ? "(_r?.jsSlot() ?? 0)" : "_r.jsSlot()"])
        } else {
            l = try lower(valueR, "_r")
        }
        let errLower = try throwLayout.map { try lowerThrow($0, "_e") }
        var body = pre
        let runCall = "\(isFuture ? "try await " : "try ")\(target)"
        let resultBind = resT == "Void" ? runCall : "let _r = \(runCall)"
        if let throwsInfo, let throwLayout, let errLower {
            // Results and error values are kept in locals until the task is done:
            // other tasks the executor runs meanwhile use the return area too.
            let okVars = l.vals.indices.map { (n: "_ok\($0)", w: wireResults[$0]) }
            let errVars = throwsInfo.params.enumerated().map { (n: "_ev\($0.offset)", w: $0.element) }
            body.append("var _failed = false")
            body += (okVars + errVars).map { "var \($0.n): \(ws($0.w)) = \(zero[$0.w] ?? "")" }
            func doCatch(_ head: String) -> [String] {
                [head, "  \(resultBind)"] + l.code.map { "  " + $0 } + okVars.enumerated().map { "  \($0.element.n) = \(l.vals[$0.offset])" }
                    + ["} catch {", "  let _e = error"] + errLower.code.map { "  " + $0 }
                    + errVars.enumerated().map { "  \($0.element.n) = \(errLower.vals[$0.offset])" } + ["  _failed = true", "}"]
            }
            // Embedded Swift infers no error type for a bare `do`.
            let task = ["#if hasFeature(Embedded)"] + doCatch("do throws(\(enumName(throwLayout))) {") + ["#else"] + doCatch("do {") + ["#endif"]
            if isFuture {
                body += ["TSGen.block {"] + task.map { "  " + $0 } + ["}"]
            } else {
                body += task
            }
            body.append("if _failed {")
            body += errVars.enumerated().map { "  TSGenRet.set(\($0.offset), \($0.element.n))" }
            body += ["  return 1", "}"]
            body += okVars.enumerated().map { "TSGenRet.set(\($0.offset), \($0.element.n))" }
            body.append("return 0")
        } else {
            body.append("let _r = try! \(target)")
            body += l.code
            if wireResults.count == 1 {
                body.append("return \(l.vals[0])")
            } else {
                body += l.vals.enumerated().map { "TSGenRet.set(\($0.offset), \($0.element))" }
            }
        }
        let flatRet = throwsInfo != nil ? " -> Int32" : wireResults.count == 1 ? " -> \(ws(wireResults[0]))" : ""
        out.append("@_expose(wasm, \"\(x.c)\")\n@_cdecl(\"\(x.c)\")\npublic func _\(x.c)(\(flat.map { "_ \($0.n): \(ws($0.w))" }.joined(separator: ", ")))\(flatRet) {\n  \(body.joined(separator: "\n  "))\n}")
        return req
    }

    /// An async export's result: a new future, resolved with the value, which
    /// JS sees as the Promise the call returns (IR.md §16).
    private func resolvedFuture(_ futureR: JSON, _ valueR: JSON, _ e: String) throws -> Low {
        let v = try lower(valueR, e)
        let newOp = importOp("tw:future", "new", [], ["externref", "externref"], nil)
        let res = futureR["resolve"]!
        let resolveOp = importOp(res.s("module") ?? "", res.s("name") ?? "", ["externref"] + valueR.strs("wire"), [], nil)
        let id = tmp
        tmp += 1
        let code = v.code + [
            "\(newOp.c)(TSGenRet.ptr)",
            "let _fu\(id) = TSGenRet.i32(0), _fr\(id) = TSGenRet.i32(1)",
            "\(resolveOp.c)(\((["_fr\(id)"] + v.vals).joined(separator: ", ")))",
            "RefTable.free(_fr\(id), 1)",
        ] + v.post
        return Low(code: code, vals: ["_fu\(id)"])
    }

    /// Lowers a thrown Swift error to the enum's wire values: a value of the
    /// enum itself, or any other Error as the fallback arm with its description.
    private func lowerThrow(_ layout: JSON, _ e: String) throws -> Low {
        let name = enumName(layout)
        let arms = layout.a("arms")
        let fb = arms.first { $0.t("fallback") } ?? arms[arms.count - 1]
        let id = tmp
        tmp += 1
        var code = [
            "#if hasFeature(Embedded)",
            "let _te\(id): \(name) = \(e)",
            "#else",
            "let _te\(id): \(name) = (\(e) as? \(name)) ?? .\(caseName(fb))\(fb.a("payload").isEmpty ? "" : "(_tsgenDescribe(\(e)))")",
            "#endif",
        ]
        let l = try lowerEnum(obj([("kind", .string("enum")), ("enum", layout), ("nullable", .bool(false))]), "_te\(id)")
        code += l.code
        // Error payload slots are handed to the shim, which frees them.
        return Low(code: code, vals: l.vals)
    }

    // MARK: Protocol operations the runtime uses

    private func emitOps() throws {
        let boxStr = importOp("tw:box", "str", ["i32", "i32"], ["externref"], nil)
        let boxF64 = importOp("tw:box", "f64", ["f64"], ["externref"], nil)
        let boxBool = importOp("tw:box", "bool", ["i32"], ["externref"], nil)
        let boxArr = importOp("tw:box", "arr<Any?>", ["i32", "i32"], ["externref"], nil)
        guard let layout = decls["TsgenValue"]?["layout"] else {
            throw GenError(description: "the IR declares no TsgenValue: append `swift-bindgen runtime-ir` to it before lowering")
        }
        useEnum(layout)
        let slots = ["i32"] + layout["shape"]!.strs("slots")
        let unbox = importOp("tw:unbox", "TsgenValue?", ["externref"], slots, nil)
        liftCode = []
        let vals = slots.enumerated().map { "TSGenRet.\(retRead[$0.element] ?? "")(\($0.offset))" }
        let e = try liftEnum(obj([("kind", .string("enum")), ("enum", layout), ("nullable", .bool(true))]), vals)
        out.append("""
            /// The `tw` protocol operations the runtime needs (IR.md §13, §16).
            public enum TSGenOps {
              public static func boxStr(_ p: Int32, _ n: Int32) -> Int32 { \(boxStr.c)(p, n) }
              public static func boxF64(_ v: Double) -> Int32 { \(boxF64.c)(v) }
              public static func boxBool(_ v: Int32) -> Int32 { \(boxBool.c)(v) }
              public static func boxArr(_ base: Int32, _ n: Int32) -> Int32 { \(boxArr.c)(base, n) }
              /// Classifies an owned slot's value; frees the slot.
              public static func classify(_ slot: Int32) -> TsgenValue? {
                defer { RefTable.free(slot, 1) }
                if slot == 0 { return nil }
                \(unbox.c)(slot, TSGenRet.ptr)
                \(liftCode.joined(separator: "\n    "))
                return \(e)
              }
            }
            """)
    }

    // MARK: Output

    /// The bindings. They compile into the app's module, so unless `keepPublic`
    /// they are internal: that lets whole-module optimization drop every
    /// member the app doesn't use.
    func swift(keepPublic: Bool) -> String {
        let decls = (enumDecls + out + keptCallbacks().flatMap { callbackCode[$0]! }).joined(separator: "\n\n")
        return """
            // Generated by swift-bindgen. Do not edit.
            import TSGenImports
            #if canImport(WASILibc)
            import WASILibc
            #endif

            \(keepPublic ? decls : dropPublic(decls))

            """
    }

    private func keptCallbacks() -> [String] {
        callbackCode.keys.filter { keepCallbacks?.contains($0) ?? true }
    }

    func header() -> String {
        var lines = [
            "// Generated by swift-bindgen. Do not edit.",
            "#include <stdint.h>",
            "#include <stdlib.h>",
            "#include <string.h>",
            "#define TSGEN_SHIM(n) __attribute__((import_module(\"shim\"), import_name(n)))",
            "int32_t tsgen_table_grow(int32_t n) TSGEN_SHIM(\"tsgen_table_grow\");",
            "void tsgen_ref_clear(int32_t base, int32_t n) TSGEN_SHIM(\"tsgen_ref_clear\");",
            "void tsgen_ref_copy(int32_t dst, int32_t src) TSGEN_SHIM(\"tsgen_ref_copy\");",
            "int32_t tsgen_ref_is_null(int32_t slot) TSGEN_SHIM(\"tsgen_ref_is_null\");",
            "int32_t tsgen_suspend(int32_t f) TSGEN_SHIM(\"tsgen_suspend\");",
            "int32_t tsgen_suspend_race(int32_t base, int32_t n) TSGEN_SHIM(\"tsgen_suspend_race\");",
        ]
        for e in imports.values {
            let f = flatImport(params: e.params, results: e.results, throws: e.tag != nil)
            lines.append("\(f.ret) \(e.c)(\(f.params.isEmpty ? "void" : f.params.joined(separator: ", "))) TSGEN_SHIM(\"\(e.c)\");")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func manifest() -> JSON {
        let kept = Set(keptCallbacks())
        let imps: [JSON] = imports.values.map { e in
            var pairs: [(String, JSON)] = [
                ("c", .string(e.c)), ("module", .string(e.module)), ("name", .string(e.name)), ("params", strArr(e.params)),
                ("results", strArr(e.results)), ("throws", e.tag?.json ?? .null),
            ]
            if let cbs = e.callbacks { pairs.append(("callbacks", strArr(cbs))) }
            return obj(pairs)
        }
        let exps: [JSON] = exports.filter { callbackCode[$0.name] == nil || kept.contains($0.name) }.map { e in
            obj([
                ("c", .string(e.c)), ("name", .string(e.name)), ("params", strArr(e.params)), ("results", strArr(e.results)),
                ("throws", e.tag?.json ?? .null),
            ] + e.details)
        }
        let skips: [JSON] = skipped.map { obj([("key", .string($0.key)), ("why", .string($0.why))]) }
        return obj([("imports", .array(imps)), ("exports", .array(exps)), ("skipped", .array(skips))])
    }

    func stats() -> String {
        "\(selected.count) declarations, \(emittedMembers) members, \(imports.count) imports, \(exports.count) exports, \(skipped.count) skipped"
    }
}

struct GenError: Error, CustomStringConvertible {
    let description: String
}
