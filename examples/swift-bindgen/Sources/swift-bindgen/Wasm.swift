/// The imports and exports of a Wasm module, read from its binary: all the
/// shim and `--callbacks-for` need to know about a linked Swift module.
struct WasmModule {
    var imports: [(module: String, name: String)] = []
    var exports: [String] = []

    struct Malformed: Error, CustomStringConvertible {
        let description: String
    }

    init(_ bytes: [UInt8]) throws {
        var r = Reader(b: bytes, i: 0, end: bytes.count)
        guard bytes.count >= 8, bytes[0..<4].elementsEqual([0x00, 0x61, 0x73, 0x6D]) else {
            throw Malformed(description: "not a Wasm module")
        }
        r.i = 8
        while r.i < r.end {
            let id = try r.byte()
            let size = Int(try r.u32())
            guard r.i + size <= r.end else { throw Malformed(description: "section \(id) runs past the end") }
            var s = Reader(b: bytes, i: r.i, end: r.i + size)
            r.i += size
            switch id {
            case 2:
                for _ in 0..<(try s.u32()) {
                    let module = try s.name(), name = try s.name()
                    imports.append((module, name))
                    try s.importDesc()
                }
            case 7:
                for _ in 0..<(try s.u32()) {
                    exports.append(try s.name())
                    _ = try s.byte()
                    _ = try s.u32()
                }
            default:
                break
            }
        }
    }

    private struct Reader {
        let b: [UInt8]
        var i: Int
        let end: Int

        mutating func byte() throws -> UInt8 {
            guard i < end else { throw Malformed(description: "unexpected end at offset \(i)") }
            i += 1
            return b[i - 1]
        }

        /// An unsigned or signed LEB128, as far as its bits go.
        mutating func leb() throws -> UInt64 {
            var v: UInt64 = 0, shift: UInt64 = 0
            while true {
                let c = try byte()
                if shift < 64 { v |= UInt64(c & 0x7F) << shift }
                shift += 7
                if c & 0x80 == 0 { return v }
            }
        }

        mutating func u32() throws -> UInt32 { UInt32(truncatingIfNeeded: try leb()) }

        mutating func name() throws -> String {
            let n = Int(try u32())
            guard i + n <= end else { throw Malformed(description: "name runs past the end at offset \(i)") }
            defer { i += n }
            return String(decoding: b[i..<i + n], as: UTF8.self)
        }

        /// A value or reference type; a GC reference type carries a heap type.
        mutating func valType() throws {
            let c = try byte()
            if c == 0x63 || c == 0x64 { _ = try leb() }
        }

        mutating func limits() throws {
            let flags = try byte()
            _ = try leb()
            if flags & 1 != 0 { _ = try leb() }
        }

        mutating func importDesc() throws {
            switch try byte() {
            case 0x00: _ = try u32()
            case 0x01: try valType(); try limits()
            case 0x02: try limits()
            case 0x03: try valType(); _ = try byte()
            case 0x04: _ = try byte(); _ = try u32()
            case let k: throw Malformed(description: "unknown import kind \(k)")
            }
        }
    }
}
