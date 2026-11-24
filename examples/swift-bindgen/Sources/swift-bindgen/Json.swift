struct JSONError: Error, CustomStringConvertible {
    let description: String
}

/// A JSON value. Objects are shared and mutable, and keep their keys in
/// insertion order (a repeated key keeps its first position and its last
/// value).
enum JSON {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object(JObject)

    /// The value under `key`, or nil when there is none (or this is no object).
    subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o.values[key] }
        return nil
    }

    var str: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var arr: [JSON] {
        if case .array(let xs) = self { return xs }
        return []
    }

    var num: Double? {
        if case .number(let d) = self { return d }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Whether the value counts as true in a condition: not null, false, 0
    /// or the empty string.
    var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let d): return d != 0 && !d.isNaN
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }

    func s(_ key: String) -> String? { self[key]?.str }
    func t(_ key: String) -> Bool { self[key]?.truthy ?? false }
    func a(_ key: String) -> [JSON] { self[key]?.arr ?? [] }
    func strs(_ key: String) -> [String] { a(key).compactMap(\.str) }
    /// The value under `key` unless it is missing or null.
    func o(_ key: String) -> JSON? {
        guard let v = self[key], !v.isNull else { return nil }
        return v
    }

    /// A shallow copy of an object with `key` set to `value`.
    func with(_ key: String, _ value: JSON) -> JSON {
        guard case .object(let o) = self else { return self }
        let c = JObject(keys: o.keys, values: o.values)
        c.set(key, value)
        return .object(c)
    }

    /// Whether some object within has `"kind": "erased"`: the value uses a
    /// type parameter.
    var mentionsErased: Bool {
        switch self {
        case .array(let xs): return xs.contains { $0.mentionsErased }
        case .object(let o):
            if o.values["kind"]?.str == "erased" { return true }
            return o.keys.contains { o.values[$0]!.mentionsErased }
        default: return false
        }
    }
}

final class JObject {
    private(set) var keys: [String]
    private(set) var values: [String: JSON]

    init(keys: [String] = [], values: [String: JSON] = [:]) {
        self.keys = keys
        self.values = values
    }

    func set(_ key: String, _ value: JSON) {
        if values.updateValue(value, forKey: key) == nil { keys.append(key) }
    }
}

/// Builds an object from pairs, in order.
func obj(_ pairs: [(String, JSON)]) -> JSON {
    let o = JObject()
    for (k, v) in pairs { o.set(k, v) }
    return .object(o)
}

func strArr(_ xs: [String]) -> JSON { .array(xs.map(JSON.string)) }

// MARK: Reading

/// A strict JSON reader over UTF-8.
struct JSONReader {
    private let b: [UInt8]
    private var i = 0

    static func read(_ bytes: [UInt8]) throws -> JSON {
        var r = JSONReader(b: bytes)
        let v = try r.value()
        r.ws()
        if r.i != bytes.count { throw r.fail("trailing input") }
        return v
    }

    private init(b: [UInt8]) { self.b = b }

    private func fail(_ msg: String) -> JSONError { JSONError(description: "\(msg) at offset \(i)") }

    private mutating func ws() {
        while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
    }

    private mutating func expect(_ c: UInt8) throws {
        ws()
        guard i < b.count, b[i] == c else { throw fail("expected '\(Character(Unicode.Scalar(c)))'") }
        i += 1
    }

    private mutating func value() throws -> JSON {
        ws()
        guard i < b.count else { throw fail("unexpected end") }
        switch b[i] {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try word("true"); return .bool(true)
        case UInt8(ascii: "f"): try word("false"); return .bool(false)
        case UInt8(ascii: "n"): try word("null"); return .null
        default: return .number(try number())
        }
    }

    private mutating func word(_ w: String) throws {
        let u = Array(w.utf8)
        guard i + u.count <= b.count, b[i..<i + u.count].elementsEqual(u) else { throw fail("bad literal") }
        i += u.count
    }

    private mutating func number() throws -> Double {
        let start = i
        while i < b.count, b[i] == 0x2D || b[i] == 0x2B || b[i] == 0x2E || b[i] == 0x65 || b[i] == 0x45 || (b[i] >= 0x30 && b[i] <= 0x39) {
            i += 1
        }
        guard i > start, let d = Double(String(decoding: b[start..<i], as: UTF8.self)) else { throw fail("bad number") }
        return d
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= b.count, let v = UInt32(String(decoding: b[i..<i + 4], as: UTF8.self), radix: 16) else {
            throw fail("bad escape")
        }
        i += 4
        return v
    }

    private mutating func string() throws -> String {
        try expect(UInt8(ascii: "\""))
        var out: [UInt8] = []
        func scalar(_ v: UInt32) {
            out.append(contentsOf: String(Unicode.Scalar(v).map(Character.init) ?? "\u{FFFD}").utf8)
        }
        while true {
            guard i < b.count else { throw fail("unterminated string") }
            let c = b[i]
            i += 1
            switch c {
            case UInt8(ascii: "\""):
                return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard i < b.count else { throw fail("unterminated string") }
                let e = b[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "u"):
                    let u = try hex4()
                    if u >= 0xD800 && u < 0xDC00, i + 6 <= b.count, b[i] == 0x5C, b[i + 1] == UInt8(ascii: "u") {
                        let save = i
                        i += 2
                        let lo = try hex4()
                        if lo >= 0xDC00 && lo < 0xE000 {
                            scalar(0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00))
                        } else {
                            i = save
                            scalar(0xFFFD)
                        }
                    } else {
                        scalar(u)
                    }
                default: throw fail("bad escape")
                }
            default:
                out.append(c)
            }
        }
    }

    private mutating func array() throws -> JSON {
        try expect(UInt8(ascii: "["))
        var out: [JSON] = []
        ws()
        if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(out) }
        while true {
            out.append(try value())
            ws()
            guard i < b.count else { throw fail("unexpected end") }
            i += 1
            switch b[i - 1] {
            case UInt8(ascii: ","): continue
            case UInt8(ascii: "]"): return .array(out)
            default: throw fail("expected ',' or ']'")
            }
        }
    }

    private mutating func object() throws -> JSON {
        try expect(UInt8(ascii: "{"))
        let o = JObject()
        ws()
        if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
        while true {
            ws()
            let k = try string()
            try expect(UInt8(ascii: ":"))
            o.set(k, try value())
            ws()
            guard i < b.count else { throw fail("unexpected end") }
            i += 1
            switch b[i - 1] {
            case UInt8(ascii: ","): continue
            case UInt8(ascii: "}"): return .object(o)
            default: throw fail("expected ',' or '}'")
            }
        }
    }
}

// MARK: Writing

/// A JSON string literal: `"`, `\` and control characters escaped, the rest
/// as is.
func jsonQuote(_ s: String) -> String {
    var out = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\u{8}": out += "\\b"
        case "\u{C}": out += "\\f"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if u.value < 0x20 {
                let h = String(u.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - h.count) + h
            } else {
                out.unicodeScalars.append(u)
            }
        }
    }
    return out + "\""
}

/// `v` as JSON, one value or key per line, nested `indent` more spaces at
/// each level; an empty array or object stays on one line. An indent of 0
/// writes it all on one line, without spaces.
func jsonWrite(_ v: JSON, indent: Int, _ at: String = "") -> String {
    let inner = at + String(repeating: " ", count: indent)
    if indent == 0 {
        switch v {
        case .array(let xs): return "[" + xs.map { jsonWrite($0, indent: 0) }.joined(separator: ",") + "]"
        case .object(let o): return "{" + o.keys.map { jsonQuote($0) + ":" + jsonWrite(o.values[$0]!, indent: 0) }.joined(separator: ",") + "}"
        default: break
        }
    }
    switch v {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .number(let d): return jsNum(d)
    case .string(let s): return jsonQuote(s)
    case .array(let xs):
        if xs.isEmpty { return "[]" }
        return "[\n" + xs.map { inner + jsonWrite($0, indent: indent, inner) }.joined(separator: ",\n") + "\n" + at + "]"
    case .object(let o):
        if o.keys.isEmpty { return "{}" }
        return "{\n" + o.keys.map { inner + jsonQuote($0) + ": " + jsonWrite(o.values[$0]!, indent: indent, inner) }
            .joined(separator: ",\n") + "\n" + at + "}"
    }
}
