// The Swift side of the ts-gen `tw` ABI under the all-linear profile, shared
// by every binding swift-bindgen generates. It names no Workers
// API. Swift can't hold an externref, so the generated shim (shim.wat, merged
// into the module) keeps JS values in the exported `tw:table` and Swift holds
// their slot numbers:
//
//   JSObject     a JS value in one slot; the slot is freed in deinit
//   RefTable     the slot allocator behind `tw:table/alloc` and `/free`
//   TSGen.block  runs an async export to completion: Swift's cooperative
//                executor drains its jobs, and when every task waits on a JS
//                promise, `tw:future suspend_race` suspends the module
//                (JSPI, the profile's `jspi = on`) until one settles
//   JSValueDecoder / JSValueEncoder   Codable over JS values, through the
//                bridge's discrimination of `TsgenValue` (runtime.ir)

import TSGenImports
#if canImport(WASILibc)
import WASILibc
#endif
#if hasFeature(Embedded)
import _Concurrency
#endif

/// A Swift error's text, for the JS error it becomes.
public func _tsgenDescribe(_ e: any Error) -> String {
  #if hasFeature(Embedded)
  return "Swift error"
  #else
  return String(describing: e)
  #endif
}

// MARK: Pointers and the return area

@inline(__always) func _i32(_ p: UnsafeMutableRawPointer?) -> Int32 {
  Int32(bitPattern: UInt32(UInt(bitPattern: p)))
}
@inline(__always) func _ptr(_ v: Int32) -> UnsafeMutableRawPointer? {
  UnsafeMutableRawPointer(bitPattern: UInt(UInt32(bitPattern: v)))
}

/// Where the shim leaves an import's results and an export leaves its own:
/// one 8-byte slot per wire value. It's read straight after each crossing,
/// before anything else can run, so one area serves every call.
public let _tsgenRet: UnsafeMutableRawPointer = malloc(512)!
public enum TSGenRet {
  @inline(__always) public static var ptr: Int32 { _i32(_tsgenRet) }
  @inline(__always) public static func i32(_ i: Int) -> Int32 { _tsgenRet.load(fromByteOffset: i * 8, as: Int32.self) }
  @inline(__always) public static func i64(_ i: Int) -> Int64 { _tsgenRet.load(fromByteOffset: i * 8, as: Int64.self) }
  @inline(__always) public static func f32(_ i: Int) -> Float { _tsgenRet.load(fromByteOffset: i * 8, as: Float.self) }
  @inline(__always) public static func f64(_ i: Int) -> Double { _tsgenRet.load(fromByteOffset: i * 8, as: Double.self) }
  @inline(__always) public static func set(_ i: Int, _ v: Int32) { _tsgenRet.storeBytes(of: v, toByteOffset: i * 8, as: Int32.self) }
  @inline(__always) public static func set(_ i: Int, _ v: Int64) { _tsgenRet.storeBytes(of: v, toByteOffset: i * 8, as: Int64.self) }
  @inline(__always) public static func set(_ i: Int, _ v: Float) { _tsgenRet.storeBytes(of: v, toByteOffset: i * 8, as: Float.self) }
  @inline(__always) public static func set(_ i: Int, _ v: Double) { _tsgenRet.storeBytes(of: v, toByteOffset: i * 8, as: Double.self) }
}

@_expose(wasm, "tsgen_ret_area")
@_cdecl("tsgen_ret_area")
public func _tsgenRetArea() -> Int32 { TSGenRet.ptr }

// MARK: Memory (IR.md §11)

@_expose(wasm, "tw:realloc")
@_cdecl("tsgen_tw_realloc")
public func _tsgenRealloc(_ old: Int32, _ oldSize: Int32, _ align: Int32, _ size: Int32) -> Int32 {
  if old == 0 { return _i32(malloc(Int(size))) }
  return _i32(realloc(_ptr(old), Int(size)))
}

@_expose(wasm, "tw:free")
@_cdecl("tsgen_tw_free")
public func _tsgenFree(_ p: Int32, _ size: Int32, _ align: Int32) {
  if size != 0 { free(_ptr(p)) }
}

public enum TSGenMem {
  /// A string as the `(ptr, len)` the bridge reads. The caller frees it.
  @inline(__always) public static func lower(_ s: String) -> (Int32, Int32) {
    var s = s
    return s.withUTF8 { b in
      if b.isEmpty { return (1, 0) }
      let p = malloc(b.count)!
      memcpy(p, b.baseAddress!, b.count)
      return (_i32(p), Int32(b.count))
    }
  }
  @inline(__always) public static func lower(_ s: String?) -> (Int32, Int32) {
    guard let s else { return (1, -1) }
    return lower(s)
  }
  @inline(__always) public static func release(_ p: Int32, _ n: Int32) {
    if n > 0 { free(_ptr(p)) }
  }
  /// A string the bridge allocated; this frees it.
  @inline(__always) public static func liftString(_ p: Int32, _ n: Int32) -> String {
    if n == 0 { return "" }
    let s = String(decoding: UnsafeRawBufferPointer(start: _ptr(p), count: Int(n)), as: UTF8.self)
    free(_ptr(p))
    return s
  }
  @inline(__always) public static func liftOptString(_ p: Int32, _ n: Int32) -> String? {
    n == -1 ? nil : liftString(p, n)
  }
  public static func alloc(_ size: Int) -> UnsafeMutableRawPointer {
    malloc(max(size, 1))!
  }
  /// A bigint as the `(ptr, len)` of its limbs the bridge reads; `len` is -1
  /// for nil. The caller frees it.
  public static func lower(_ v: JSBigInt?) -> (Int32, Int32) {
    guard let v else { return (8, -1) }
    let limbs = v.minimalLimbs
    let p = alloc(limbs.count * 8)
    limbs.withUnsafeBytes { _ = memcpy(p, $0.baseAddress!, $0.count) }
    return (_i32(p), Int32(limbs.count))
  }
  /// A bigint the bridge allocated, or nil for a `len` of -1; this frees it.
  public static func liftBigInt(_ p: Int32, _ n: Int32) -> JSBigInt? {
    if n == -1 { return nil }
    if n == 0 { return JSBigInt(limbs: []) }
    let limbs = (0..<Int(n)).map { _ptr(p)!.loadUnaligned(fromByteOffset: $0 * 8, as: UInt64.self) }
    free(_ptr(p))
    return JSBigInt(limbs: limbs)
  }
}

// MARK: BigInt (IR.md §11)

/// A JS bigint of any size: its two's-complement little-endian 64-bit limbs.
public struct JSBigInt: Hashable, ExpressibleByIntegerLiteral {
  /// At least one limb; the last one's top bit is the sign.
  public private(set) var limbs: [UInt64]

  public init(limbs: [UInt64]) { self.limbs = limbs.isEmpty ? [0] : limbs }
  public init(_ v: Int64) { limbs = [UInt64(bitPattern: v)] }
  public init(integerLiteral v: Int64) { self.init(v) }

  /// The limbs without the high ones that only extend the sign.
  public var minimalLimbs: [UInt64] {
    var l = limbs
    while l.count > 1 {
      let fill: UInt64 = Int64(bitPattern: l[l.count - 2]) < 0 ? .max : 0
      guard l[l.count - 1] == fill else { break }
      l.removeLast()
    }
    return l
  }

  /// The value, when it fits in an Int64.
  public var int64: Int64? {
    let l = minimalLimbs
    return l.count == 1 ? Int64(bitPattern: l[0]) : nil
  }

  public static func == (a: JSBigInt, b: JSBigInt) -> Bool { a.minimalLimbs == b.minimalLimbs }
  public func hash(into h: inout Hasher) { h.combine(minimalLimbs) }
}

// MARK: The externref table (IR.md §14)

/// Slots of `tw:table` from `heap_base` on. A run of slots for an `arr<T>` of
/// references is contiguous; everything else takes one.
public enum RefTable {
  public static let heapBase: Int32 = 132
  static var used: [Bool] = []
  static var hint = 0

  public static func alloc(_ count: Int32) -> Int32 {
    let n = Int(count)
    if n == 0 { return 0 }
    var i = hint
    search: while true {
      if i + n > used.count {
        let grow = max(i + n - used.count, 64)
        _ = tsgen_table_grow(Int32(grow))
        used.append(contentsOf: repeatElement(false, count: grow))
      }
      for k in i..<(i + n) where used[k] {
        i = k + 1
        continue search
      }
      break
    }
    for k in i..<(i + n) { used[k] = true }
    if i == hint { hint = i + n }
    return heapBase + Int32(i)
  }

  public static func free(_ base: Int32, _ count: Int32) {
    if base < heapBase || count <= 0 { return }
    tsgen_ref_clear(base, count)
    let i = Int(base - heapBase)
    for k in i..<(i + Int(count)) { used[k] = false }
    if i < hint { hint = i }
  }

  /// A new slot holding the same value as `slot`.
  public static func dup(_ slot: Int32) -> Int32 {
    if slot == 0 { return 0 }
    let s = alloc(1)
    tsgen_ref_copy(s, slot)
    return s
  }
}

@_expose(wasm, "tw:table/alloc")
@_cdecl("tsgen_tw_table_alloc")
public func _tsgenTableAlloc(_ n: Int32) -> Int32 { RefTable.alloc(n) }

@_expose(wasm, "tw:table/free")
@_cdecl("tsgen_tw_table_free")
public func _tsgenTableFree(_ base: Int32, _ n: Int32) { RefTable.free(base, n) }

@_expose(wasm, "tsgen_ref_alloc1")
@_cdecl("tsgen_ref_alloc1")
public func _tsgenRefAlloc1() -> Int32 { RefTable.alloc(1) }

@_expose(wasm, "tsgen_ref_free1")
@_cdecl("tsgen_ref_free1")
public func _tsgenRefFree1(_ slot: Int32) { RefTable.free(slot, 1) }

// MARK: JS values

/// Anything that can stand for a JS value: what an `Any` parameter takes.
public protocol JSConvertible {
  /// A new slot holding the value, owned by the caller.
  func jsSlot() -> Int32
}

#if hasFeature(Embedded)
/// What a parameter of type `any` takes. Embedded Swift has no existentials
/// of non-class protocols, so it is an enum there.
public enum JSIn: JSConvertible, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
  case str(String), num(Double), bool(Bool), obj(JSObject)
  public init(stringLiteral v: String) { self = .str(v) }
  public init(integerLiteral v: Int) { self = .num(Double(v)) }
  public init(floatLiteral v: Double) { self = .num(v) }
  public init(booleanLiteral v: Bool) { self = .bool(v) }
  public static func int(_ v: Int) -> JSIn { .num(Double(v)) }
  public func jsSlot() -> Int32 {
    switch self {
    case .str(let s): return s.jsSlot()
    case .num(let n): return n.jsSlot()
    case .bool(let b): return b.jsSlot()
    case .obj(let o): return o.jsSlot()
    }
  }
}
#else
/// What a parameter of type `any` takes.
public typealias JSIn = any JSConvertible
#endif

/// A JS value held in one `tw:table` slot. Generated classes and interfaces
/// derive from it; casting between them is free and unchecked (IR.md §4).
open class JSObject: JSConvertible {
  public let slot: Int32
  public required init(owning slot: Int32) { self.slot = slot }
  deinit { RefTable.free(slot, 1) }
  public func jsSlot() -> Int32 { RefTable.dup(slot) }
  /// The same JS value viewed as another generated type.
  public required convenience init(cast other: JSObject) { self.init(owning: other.jsSlot()) }
}

/// A JS value of no particular type: an `Any` or an erased type parameter.
public final class JSAny: JSObject {}

extension String: JSConvertible {
  public func jsSlot() -> Int32 {
    let (p, n) = TSGenMem.lower(self)
    defer { TSGenMem.release(p, n) }
    return TSGenOps.boxStr(p, n)
  }
}
extension Double: JSConvertible { public func jsSlot() -> Int32 { TSGenOps.boxF64(self) } }
extension Int: JSConvertible { public func jsSlot() -> Int32 { TSGenOps.boxF64(Double(self)) } }
extension Bool: JSConvertible { public func jsSlot() -> Int32 { TSGenOps.boxBool(self ? 1 : 0) } }
extension Optional: JSConvertible where Wrapped: JSConvertible {
  public func jsSlot() -> Int32 { self?.jsSlot() ?? 0 }
}

/// A slot this value owns and hands over once.
struct _OwnedSlot: JSConvertible {
  let slot: Int32
  func jsSlot() -> Int32 { slot }
}

// MARK: Closures handed to JS (IR.md §18)

public final class TSGenClosure<F> {
  public let f: F
  public init(_ f: F) { self.f = f }
  /// The handle the bridge wraps in a JS function; `tw:drop:F` releases it.
  public var handle: Int32 { _i32(Unmanaged.passRetained(self).toOpaque()) }
  public static func from(_ handle: Int32) -> F {
    Unmanaged<TSGenClosure<F>>.fromOpaque(_ptr(handle)!).takeUnretainedValue().f
  }
}
public func _tsgenRelease(_ handle: Int32) {
  Unmanaged<AnyObject>.fromOpaque(_ptr(handle)!).release()
}

/// An exported class instance as its handle (IR.md §17).
public enum TSGenHandle {
  public static func retain(_ obj: AnyObject) -> Int32 { _i32(Unmanaged.passRetained(obj).toOpaque()) }
  public static func get<T: AnyObject>(_ handle: Int32, as: T.Type) -> T {
    Unmanaged<T>.fromOpaque(_ptr(handle)!).takeUnretainedValue()
  }
}

// MARK: Async (IR.md §16, over JSPI)

@_silgen_name("swift_task_donateThreadToGlobalExecutorUntil")
func _donate(_ condition: @convention(c) (UnsafeMutableRawPointer?) -> Bool, _ context: UnsafeMutableRawPointer?)

public enum TSGen {
  struct Waiter {
    let id: Int
    let future: Int32
    let resume: UnsafeContinuation<Int32, Never>
  }
  static var waiters: [Waiter] = []
  static var nextId = 0

  /// Waits for a future the bridge handed out. 1 means resolved and 2
  /// rejected, as `tw:future suspend` says; the caller then takes the value
  /// or the error.
  public static func settle(_ future: Int32) async -> Int32 {
    nextId += 1
    let id = nextId
    return await withUnsafeContinuation { waiters.append(Waiter(id: id, future: future, resume: $0)) }
  }

  final class Done { var done = false }

  /// Runs `body` as a task and drains Swift's executor until it finishes.
  /// Tasks the body starts run too, interleaved at their awaits.
  ///
  /// When every task waits on a JS promise, the module suspends until one
  /// of their futures settles (`suspend_race`), and that task resumes.
  /// `waiters` is shared by every `block` on the Wasm stack: another call
  /// that runs while this one is parked may resume this call's tasks, so
  /// the race's winner is looked up again by id once it returns.
  public static func block(_ body: @escaping () async -> Void) {
    let flag = Done()
    Task { await body(); flag.done = true }
    let context = Unmanaged.passUnretained(flag).toOpaque()
    while true {
      _donate({ Unmanaged<Done>.fromOpaque($0!).takeUnretainedValue().done }, context)
      if flag.done { return }
      if waiters.isEmpty { fatalError("ts-gen: every task is waiting, and none on a JS promise") }
      // suspend_race takes a range of slots.
      let racing = waiters
      let n = Int32(racing.count)
      let base = RefTable.alloc(n)
      for (k, w) in racing.enumerated() { tsgen_ref_copy(base + Int32(k), w.future) }
      let i = tsgen_suspend_race(base, n)
      RefTable.free(base, n)
      if i < 0 { fatalError("ts-gen: a future was dropped while awaited") }
      guard let at = waiters.firstIndex(where: { $0.id == racing[Int(i)].id }) else { continue }
      let w = waiters.remove(at: at)
      // It's settled: suspend returns at once.
      let state = tsgen_suspend(w.future)
      if state <= 0 { fatalError("ts-gen: a future was dropped while awaited") }
      w.resume.resume(returning: state)
    }
  }
}

// MARK: Codable
// Embedded Swift has no Codable.
#if !hasFeature(Embedded)

extension JSObject: Encodable {
  public func encode(to encoder: Encoder) throws {
    guard let e = encoder as? _JSEncoder else {
      throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "a JS value encodes only to JS"))
    }
    e.node = .slot(jsSlot())
  }
}

extension JSAny {
  /// Decodes the value as `T`, through JSValueDecoder.
  public func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
    try JSValueDecoder.decode(T.self, from: self)
  }
}



/// Decodes JS values: objects by key, arrays, strings, numbers, booleans,
/// null, and JS values as any generated class.
public enum JSValueDecoder {
  public static func decode<T: Decodable>(_ type: T.Type, from value: JSObject?) throws -> T {
    if let J = T.self as? JSObject.Type, let value { return J.init(cast: value) as! T }
    let v = value.flatMap { TSGenOps.classify($0.jsSlot()) }
    return try decode(type, from: v, path: [])
  }
  static func decode<T: Decodable>(_ type: T.Type, from value: TsgenValue?, path: [CodingKey]) throws -> T {
    let d = _JSDecoder(value, path)
    if let v = try d.primitive(T.self) { return v }
    return try T(from: d)
  }
}

struct _Key: CodingKey {
  var stringValue: String
  var intValue: Int?
  init(stringValue: String) { self.stringValue = stringValue }
  init(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
}

final class _JSDecoder: Decoder, SingleValueDecodingContainer {
  let value: TsgenValue?
  let codingPath: [CodingKey]
  var userInfo: [CodingUserInfoKey: Any] { [:] }
  init(_ value: TsgenValue?, _ path: [CodingKey]) { self.value = value; self.codingPath = path }

  func mismatch(_ what: String) -> DecodingError {
    .typeMismatch(Any.self, .init(codingPath: codingPath, debugDescription: "expected \(what), got \(String(describing: value))"))
  }

  // Values Swift reads without a container.
  func primitive<T>(_ type: T.Type) throws -> T? {
    switch T.self {
    case is String.Type, is String?.Type: if case .str(let s)? = value { return s as? T }
    case is Bool.Type: if case .bool(let b)? = value { return b as? T }
    default: break
    }
    if let J = T.self as? JSObject.Type {
      switch value {
      case .obj(let o)?: return (J.init(cast: o) as! T)
      case nil: throw mismatch("a JS object")
      default: return nil
      }
    }
    if T.self is any BinaryInteger.Type || T.self is any BinaryFloatingPoint.Type {
      guard case .num(let n)? = value else { return nil }
      switch T.self {
      case is Double.Type: return n as? T
      case is Float.Type: return Float(n) as? T
      case is Int.Type: return Int(n) as? T
      case is Int32.Type: return Int32(n) as? T
      case is Int64.Type: return Int64(n) as? T
      case is UInt.Type: return UInt(n) as? T
      case is UInt32.Type: return UInt32(n) as? T
      case is UInt64.Type: return UInt64(n) as? T
      case is UInt8.Type: return UInt8(n) as? T
      case is UInt16.Type: return UInt16(n) as? T
      case is Int8.Type: return Int8(n) as? T
      case is Int16.Type: return Int16(n) as? T
      default: return nil
      }
    }
    return nil
  }

  func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
    guard case .obj(let o)? = value else { throw mismatch("an object") }
    return KeyedDecodingContainer(_Keyed<Key>(TsgenObject(cast: o), codingPath))
  }
  func unkeyedContainer() throws -> UnkeyedDecodingContainer {
    guard case .list(let items)? = value else { throw mismatch("an array") }
    return _Unkeyed(items, codingPath)
  }
  func singleValueContainer() throws -> SingleValueDecodingContainer { self }

  func decodeNil() -> Bool { value == nil }
  func decode<T: Decodable>(_ type: T.Type) throws -> T {
    if let v = try primitive(T.self) { return v }
    if T.self is String.Type || T.self is Bool.Type || T.self is any Numeric.Type { throw mismatch("\(T.self)") }
    return try T(from: self)
  }
}

struct _Keyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
  let object: TsgenObject
  let codingPath: [CodingKey]
  init(_ object: TsgenObject, _ path: [CodingKey]) { self.object = object; self.codingPath = path }
  var allKeys: [Key] { [] }
  func contains(_ key: Key) -> Bool { object.at(key.stringValue) != nil }
  func decodeNil(forKey key: Key) throws -> Bool { object.at(key.stringValue) == nil }
  func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
    try JSValueDecoder.decode(T.self, from: object.at(key.stringValue), path: codingPath + [key])
  }
  func nestedContainer<N: CodingKey>(keyedBy type: N.Type, forKey key: Key) throws -> KeyedDecodingContainer<N> {
    try _JSDecoder(object.at(key.stringValue), codingPath + [key]).container(keyedBy: N.self)
  }
  func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
    try _JSDecoder(object.at(key.stringValue), codingPath + [key]).unkeyedContainer()
  }
  func superDecoder() throws -> Decoder { fatalError("superDecoder isn't supported") }
  func superDecoder(forKey key: Key) throws -> Decoder { fatalError("superDecoder isn't supported") }
}

struct _Unkeyed: UnkeyedDecodingContainer {
  let items: [JSAny?]
  let codingPath: [CodingKey]
  var currentIndex = 0
  init(_ items: [JSAny?], _ path: [CodingKey]) { self.items = items; self.codingPath = path }
  var count: Int? { items.count }
  var isAtEnd: Bool { currentIndex >= items.count }
  mutating func next() -> TsgenValue? {
    defer { currentIndex += 1 }
    return items[currentIndex].flatMap { TSGenOps.classify($0.jsSlot()) }
  }
  mutating func decodeNil() throws -> Bool {
    if items[currentIndex] == nil { currentIndex += 1; return true }
    return false
  }
  mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
    let path = codingPath + [_Key(intValue: currentIndex)]
    return try JSValueDecoder.decode(T.self, from: next(), path: path)
  }
  mutating func nestedContainer<N: CodingKey>(keyedBy type: N.Type) throws -> KeyedDecodingContainer<N> {
    try _JSDecoder(next(), codingPath).container(keyedBy: N.self)
  }
  mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
    try _JSDecoder(next(), codingPath).unkeyedContainer()
  }
  mutating func superDecoder() throws -> Decoder { fatalError("superDecoder isn't supported") }
}

/// Encodes Swift values as JS values: structs as plain objects, arrays,
/// strings, numbers, booleans, nil as null, and JSObjects as themselves.
public enum JSValueEncoder {
  /// A new slot holding the encoded value, owned by the caller.
  public static func encode<T: Encodable>(_ value: T) throws -> Int32 {
    if let c = value as? JSConvertible { return c.jsSlot() }
    let e = _JSEncoder([])
    try value.encode(to: e)
    return e.node.materialize()
  }
  /// The encoded value as a JSAny, for a parameter that takes one.
  public static func value<T: Encodable>(_ value: T) -> JSAny {
    JSAny(owning: (try? encode(value)) ?? 0)
  }
}

final class _Box { var node: _Node = .null }

enum _Node {
  case null, bool(Bool), num(Double), str(String), slot(Int32)
  case object(_ObjectNode), array(_ArrayNode)

  func materialize() -> Int32 {
    switch self {
    case .null: return 0
    case .bool(let b): return b.jsSlot()
    case .num(let n): return n.jsSlot()
    case .str(let s): return s.jsSlot()
    case .slot(let s): return s
    case .object(let o):
      let obj = TsgenObject()
      for (k, v) in o.fields { obj.setAt(k, value: _OwnedSlot(slot: v.node.materialize())) }
      return obj.jsSlot()
    case .array(let a):
      let n = Int32(a.items.count)
      let base = RefTable.alloc(n)
      for (i, item) in a.items.enumerated() {
        let s = item.node.materialize()
        tsgen_ref_copy(base + Int32(i), s)
        RefTable.free(s, 1)
      }
      defer { RefTable.free(base, n) }
      return TSGenOps.boxArr(base, n)
    }
  }
}
final class _ObjectNode { var fields: [(String, _Box)] = [] }
final class _ArrayNode { var items: [_Box] = [] }

final class _JSEncoder: Encoder, SingleValueEncodingContainer {
  var node: _Node = .null
  let codingPath: [CodingKey]
  var userInfo: [CodingUserInfoKey: Any] { [:] }
  init(_ path: [CodingKey]) { self.codingPath = path }

  func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
    let o: _ObjectNode
    if case .object(let existing) = node { o = existing } else { o = _ObjectNode(); node = .object(o) }
    return KeyedEncodingContainer(_KeyedEnc<Key>(o, codingPath))
  }
  func unkeyedContainer() -> UnkeyedEncodingContainer {
    let a: _ArrayNode
    if case .array(let existing) = node { a = existing } else { a = _ArrayNode(); node = .array(a) }
    return _UnkeyedEnc(a, codingPath)
  }
  func singleValueContainer() -> SingleValueEncodingContainer { self }

  func encodeNil() { node = .null }
  func encode(_ v: Bool) { node = .bool(v) }
  func encode(_ v: String) { node = .str(v) }
  func encode(_ v: Double) { node = .num(v) }
  func encode(_ v: Float) { node = .num(Double(v)) }
  func encode(_ v: Int) { node = .num(Double(v)) }
  func encode(_ v: Int8) { node = .num(Double(v)) }
  func encode(_ v: Int16) { node = .num(Double(v)) }
  func encode(_ v: Int32) { node = .num(Double(v)) }
  func encode(_ v: Int64) { node = .num(Double(v)) }
  func encode(_ v: UInt) { node = .num(Double(v)) }
  func encode(_ v: UInt8) { node = .num(Double(v)) }
  func encode(_ v: UInt16) { node = .num(Double(v)) }
  func encode(_ v: UInt32) { node = .num(Double(v)) }
  func encode(_ v: UInt64) { node = .num(Double(v)) }
  func encode<T: Encodable>(_ v: T) throws { node = try _encodeNode(v, codingPath) }
}

func _encodeNode<T: Encodable>(_ v: T, _ path: [CodingKey]) throws -> _Node {
  switch v {
  case let s as String: return .str(s)
  case let b as Bool: return .bool(b)
  case let d as Double: return .num(d)
  case let i as Int: return .num(Double(i))
  default:
    let e = _JSEncoder(path)
    try v.encode(to: e)
    return e.node
  }
}

struct _KeyedEnc<Key: CodingKey>: KeyedEncodingContainerProtocol {
  let object: _ObjectNode
  let codingPath: [CodingKey]
  init(_ object: _ObjectNode, _ path: [CodingKey]) { self.object = object; self.codingPath = path }
  func box(_ key: Key) -> _Box {
    let b = _Box()
    object.fields.append((key.stringValue, b))
    return b
  }
  mutating func encodeNil(forKey key: Key) { box(key).node = .null }
  mutating func encode<T: Encodable>(_ v: T, forKey key: Key) throws { box(key).node = try _encodeNode(v, codingPath + [key]) }
  mutating func nestedContainer<N: CodingKey>(keyedBy type: N.Type, forKey key: Key) -> KeyedEncodingContainer<N> {
    let o = _ObjectNode()
    box(key).node = .object(o)
    return KeyedEncodingContainer(_KeyedEnc<N>(o, codingPath + [key]))
  }
  mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
    let a = _ArrayNode()
    box(key).node = .array(a)
    return _UnkeyedEnc(a, codingPath + [key])
  }
  mutating func superEncoder() -> Encoder { fatalError("superEncoder isn't supported") }
  mutating func superEncoder(forKey key: Key) -> Encoder { fatalError("superEncoder isn't supported") }
}

struct _UnkeyedEnc: UnkeyedEncodingContainer {
  let array: _ArrayNode
  let codingPath: [CodingKey]
  init(_ array: _ArrayNode, _ path: [CodingKey]) { self.array = array; self.codingPath = path }
  var count: Int { array.items.count }
  func box() -> _Box {
    let b = _Box()
    array.items.append(b)
    return b
  }
  mutating func encodeNil() { box().node = .null }
  mutating func encode<T: Encodable>(_ v: T) throws { box().node = try _encodeNode(v, codingPath) }
  mutating func nestedContainer<N: CodingKey>(keyedBy type: N.Type) -> KeyedEncodingContainer<N> {
    let o = _ObjectNode()
    box().node = .object(o)
    return KeyedEncodingContainer(_KeyedEnc<N>(o, codingPath))
  }
  mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
    let a = _ArrayNode()
    box().node = .array(a)
    return _UnkeyedEnc(a, codingPath)
  }
  mutating func superEncoder() -> Encoder { fatalError("superEncoder isn't supported") }
}

#endif
