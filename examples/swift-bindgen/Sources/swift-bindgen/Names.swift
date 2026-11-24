let swiftKeywords: Set<String> = Set(
    ("associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private "
        + "precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer "
        + "do else fallthrough for guard if in repeat return throw switch where while as false is nil self Self super throws true try "
        + "Any Protocol Type await async some any").split(separator: " ").map(String.init)
)

/// Global names a generated type must not shadow.
let swiftTypes: Set<String> = Set(
    ("Error Set Result Array String Int Double Float Bool Character Optional Never Any Dictionary Sequence Collection "
        + "Task Actor Equatable Hashable Codable Encoder Decoder Encodable Decodable Range Substring Unicode Comparable Identifiable "
        + "Duration Clock Mirror Void Iterator Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64 Float16 Math Hasher "
        + "JSObject JSAny JSConvertible RefTable TSGen TSGenMem TSGenRet TSGenOps TSGenClosure TSGenHandle JSValueDecoder JSValueEncoder")
        .split(separator: " ").map(String.init)
)

/// Backticks a name Swift would read as a keyword.
func esc(_ n: String) -> String { swiftKeywords.contains(n) ? "`\(n)`" : n }

private func isAlnum(_ c: UInt8) -> Bool {
    (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
}
private func isUpper(_ c: UInt8) -> Bool { c >= 0x41 && c <= 0x5A }
private func isLower(_ c: UInt8) -> Bool { c >= 0x61 && c <= 0x7A }
private func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
private func toUpper(_ c: UInt8) -> UInt8 { isLower(c) ? c - 32 : c }
private func toLower(_ c: UInt8) -> UInt8 { isUpper(c) ? c + 32 : c }

/// An identifier for any name, in camel case: every UTF-16 unit outside
/// `[A-Za-z0-9_]` becomes `_`, a run of `_` before a letter or digit
/// uppercases it, trailing `_`s go, and a leading digit gets a `_`.
func camel(_ s: String) -> String {
    let units: [UInt8] = s.utf16.map { u in
        u < 128 && (isAlnum(UInt8(u)) || u == 0x5F) ? UInt8(u) : 0x5F
    }
    var out: [UInt8] = []
    var i = 0
    while i < units.count {
        if units[i] == 0x5F {
            var j = i
            while j < units.count && units[j] == 0x5F { j += 1 }
            if j < units.count {
                out.append(toUpper(units[j]))
                i = j + 1
            } else {
                i = j
            }
        } else {
            out.append(units[i])
            i += 1
        }
    }
    if let f = out.first, isDigit(f) { out.insert(0x5F, at: 0) }
    return out.isEmpty ? "_" : String(decoding: out, as: UTF8.self)
}

/// Lowercases a name's leading capital, or its leading acronym (`URLSearch`
/// becomes `urlSearch`, `URL` becomes `url`). Names are ASCII by now.
func lowerFirst(_ s: String) -> String {
    var b = Array(s.utf8)
    if b.count >= 2 && isUpper(b[0]) && b.dropFirst().allSatisfy({ isUpper($0) || isDigit($0) }) {
        return String(decoding: b.map(toLower), as: UTF8.self)
    }
    var k = 0
    while k < b.count && isUpper(b[k]) { k += 1 }
    var len = 0
    var n = k
    while n >= 1 {
        if n == b.count || (isUpper(b[n]) && n + 1 < b.count && isLower(b[n + 1])) { len = n; break }
        n -= 1
    }
    if len == 0 && k >= 1 { len = 1 }
    for i in 0..<len { b[i] = toLower(b[i]) }
    return String(decoding: b, as: UTF8.self)
}

func upperFirst(_ s: String) -> String {
    guard let f = s.unicodeScalars.first else { return s }
    return String(f).uppercased() + String(s.unicodeScalars.dropFirst())
}

func memberName(_ n: String) -> String { esc(lowerFirst(camel(n))) }

/// Overloads over Codable, which Embedded Swift lacks.
func codable(_ decl: String) -> String { "#if !hasFeature(Embedded)\n\(decl)\n#endif" }

// MARK: Text
//
// Generated code splices in names and doc comments from the IR, so text is
// matched by bytes, never by Swift's grapheme clusters (in which `\r\n` is
// one character).

func split(_ s: String, _ sep: String) -> [String] {
    let b = Array(s.utf8), p = Array(sep.utf8)
    var out: [String] = []
    var start = 0, i = 0
    while i + p.count <= b.count {
        if b[i..<i + p.count].elementsEqual(p) {
            out.append(String(decoding: b[start..<i], as: UTF8.self))
            i += p.count
            start = i
        } else {
            i += 1
        }
    }
    out.append(String(decoding: b[start...], as: UTF8.self))
    return out
}

func replaceAll(_ s: String, _ a: String, _ b: String) -> String {
    split(s, a).joined(separator: b)
}

func has(_ s: String, _ p: String) -> Bool {
    let b = Array(s.utf8), q = Array(p.utf8)
    if q.isEmpty { return true }
    if q.count > b.count { return false }
    for i in 0...(b.count - q.count) where b[i..<i + q.count].elementsEqual(q) { return true }
    return false
}

func starts(_ s: String, _ p: String) -> Bool { s.utf8.starts(with: p.utf8) }

func ends(_ s: String, _ p: String) -> Bool {
    let b = Array(s.utf8), q = Array(p.utf8)
    return q.count <= b.count && b[(b.count - q.count)...].elementsEqual(q)
}

func dropPrefix(_ s: String, _ p: String) -> String {
    starts(s, p) ? String(decoding: Array(s.utf8).dropFirst(p.utf8.count), as: UTF8.self) : s
}

/// `s` up to its first `<`: a base's path without its type arguments.
func stripArgs(_ s: String) -> String {
    guard let i = s.utf8.firstIndex(of: 0x3C) else { return s }
    return String(s[..<i])
}

/// `s` without its backticks.
func unquote(_ s: String) -> String { replaceAll(s, "`", "") }

private let lineBreaks: Set<UInt32> = [0x0A, 0x0D, 0x2028, 0x2029]
private let spaces: Set<UInt32> = [
    0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006,
    0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF,
]

/// Drops `public ` or `open ` where it starts a line (after indentation),
/// making declarations internal.
func dropPublic(_ s: String) -> String {
    let u = Array(s.unicodeScalars)
    var out = String.UnicodeScalarView()
    var i = 0
    var lineStart = true
    func word(_ at: Int, _ w: String) -> Bool {
        let ws = Array(w.unicodeScalars)
        return at + ws.count <= u.count && u[at..<at + ws.count].elementsEqual(ws)
    }
    while i < u.count {
        if lineStart {
            var j = i
            while j < u.count && spaces.contains(u[j].value) { j += 1 }
            let w = word(j, "public ") ? 7 : word(j, "open ") ? 5 : 0
            if w > 0 {
                out.append(contentsOf: u[i..<j])
                i = j + w
                lineStart = false
                continue
            }
        }
        lineStart = lineBreaks.contains(u[i].value)
        out.append(u[i])
        i += 1
    }
    return String(out)
}

/// A value as a template string spells it: `undefined` for a missing one.
func jsStr(_ v: JSON?) -> String {
    switch v {
    case nil: return "undefined"
    case .null?: return "null"
    case .bool(let b)?: return b ? "true" : "false"
    case .number(let d)?: return jsNum(d)
    case .string(let s)?: return s
    case .array(let xs)?: return xs.map { x in x.isNull ? "" : jsStr(x) }.joined(separator: ",")
    case .object?: return "[object Object]"
    }
}

func jsNum(_ d: Double) -> String {
    if d == d.rounded() && abs(d) < 1e21 { return String(Int64(d)) }
    return String(d)
}
