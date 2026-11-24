//! The Zig side of the ts-gen `tw` ABI under the linear profile with
//! `jspi = on`, shared by every set of bindings zig-bindgen generates. It
//! names no API.
//!
//! Zig can't hold an `externref`, so a generated shim (`zig-bindgen shim`,
//! merged into the module) keeps JS values in the module's `tw:table` and
//! Zig holds their slot numbers. Every import and export goes through the
//! shim: slots in place of externrefs, results past the first through the
//! return area, and a thrown tag as a status of 1.
//!
//! Values cross through codecs: comptime types that know a value's wire
//! words and its Zig type (`Str`, `Host(Request)`, `Future(...)`, ...). The
//! generated bindings name a codec per parameter and result, and `call` and
//! `serve` lower and lift through them, so no conversion code is generated
//! per member.
//!
//! Memory is per request. Strings and slices the bindings return live in
//! the request arena (`arena()`), and JS values in slots the request owns;
//! both are released when the outermost export returns, unless kept with
//! `keep()` (a value) or copied into `gpa` (bytes). An exported class's
//! constructor keeps what it receives.
//!
//! Calls block: a future is polled, and while it's pending the module
//! suspends in `("tw:future", "wait")` (JSPI) until it settles, so a
//! binding returns the value, or the future's rejection as an error.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Long-lived memory: what outlives a request.
pub const gpa: Allocator = std.heap.wasm_allocator;

var arena_state: std.heap.ArenaAllocator = .init(std.heap.wasm_allocator);

/// The request arena: what the bindings return lives here until the
/// outermost export returns.
pub fn arena() Allocator {
    return arena_state.allocator();
}

// ---------------------------------------------------------------------------
// The shim's table operations, and the protocol imports the runtime makes.

extern "shim" fn tsgen_table_grow(n: i32) i32;
extern "shim" fn tsgen_ref_clear(base: i32, n: i32) void;
extern "shim" fn tsgen_ref_copy(dst: i32, src: i32) void;
extern "shim" fn tsgen_ref_is_null(slot: i32) i32;

const wait = @extern(*const fn (i32) callconv(.c) void, .{ .name = "wait", .library_name = "tw:future" });

const ops = struct {
    extern "shim" fn @"tsgen:tw:future poll"(f: i32, waker: i32) i32;
    extern "shim" fn @"tsgen:tw:future drop"(f: i32) void;
    extern "shim" fn @"tsgen:tw:box str"(p: i32, n: i32) i32;
    extern "shim" fn @"tsgen:tw:box f64"(v: f64) i32;
    extern "shim" fn @"tsgen:tw:box bool"(v: i32) i32;
    extern "shim" fn @"tsgen:tw:box arr<Any?>"(base: i32, n: i32) i32;
    extern "shim" fn @"tsgen:tw:unbox str"(slot: i32, ret: i32) void;
    extern "shim" fn @"tsgen:tw:unbox f64"(slot: i32) f64;
    extern "shim" fn @"tsgen:tw:unbox bool"(slot: i32) i32;
    extern "shim" fn @"tsgen:tw:isNullish "(slot: i32) i32;
    extern "shim" fn @"tsgen:tw:arr len"(slot: i32) i32;
    extern "shim" fn @"tsgen:tw:arr get<Any?>"(slot: i32, i: i32) i32;
    // runtime.ir: plain objects, for encoding structs and decoding fields.
    extern "shim" fn @"tsgen:tw:js/global TsgenObject.new()"() i32;
    extern "shim" fn @"tsgen:tw:js/global TsgenObject#at(str)"(this: i32, p: i32, n: i32) i32;
    extern "shim" fn @"tsgen:tw:js/global TsgenObject#setAt(str,Any?)"(this: i32, p: i32, n: i32, v: i32) void;
};

// ---------------------------------------------------------------------------
// Requests: the arena and the slots a request owns go at the end of the
// outermost export. The host reads an export's results after it returns,
// so they go at the start of the next entry or allocation instead.

var depth: u32 = 0;
var stale = false;

fn fresh() void {
    if (!stale) return;
    stale = false;
    ntemps = 0;
    sweep();
    _ = arena_state.reset(.retain_capacity);
}

pub fn enter() void {
    fresh();
    depth += 1;
}

pub fn leave() void {
    depth -= 1;
    if (depth == 0) stale = true;
}

// ---------------------------------------------------------------------------
// Words: every wire value as 64 bits, as the return area holds them.

pub inline fn word(comptime T: type, v: T) u64 {
    return switch (T) {
        i32 => @as(u32, @bitCast(v)),
        i64 => @bitCast(v),
        f32 => @as(u32, @bitCast(v)),
        f64 => @bitCast(v),
        else => @compileError("not a wire type: " ++ @typeName(T)),
    };
}

pub inline fn unword(comptime T: type, w: u64) T {
    return switch (T) {
        i32 => @bitCast(@as(u32, @truncate(w))),
        i64 => @bitCast(w),
        f32 => @bitCast(@as(u32, @truncate(w))),
        f64 => @bitCast(w),
        else => @compileError("not a wire type: " ++ @typeName(T)),
    };
}

/// Where the shim leaves an import's results past the first and an
/// export's own results: one 8-byte slot per wire value. It's read straight
/// after each crossing, so one area serves every call.
pub var ret_area: [64]u64 = undefined;

inline fn retPtr() i32 {
    return @intCast(@intFromPtr(&ret_area));
}

fn tsgenRetArea() callconv(.c) i32 {
    return retPtr();
}

// ---------------------------------------------------------------------------
// Memory (IR.md §11): what the bridge allocates for the module is
// request memory.

fn twRealloc(old: i32, old_size: i32, al: i32, size: i32) callconv(.c) i32 {
    fresh();
    const a: std.mem.Alignment = .fromByteUnits(@intCast(@max(al, 1)));
    const n: usize = @intCast(size);
    const p = arena().rawAlloc(@max(n, 1), a, @returnAddress()) orelse @trap();
    if (old != 0 and old_size > 0) {
        const src: [*]const u8 = @ptrFromInt(@as(u32, @bitCast(old)));
        @memcpy(p[0..@min(n, @as(usize, @intCast(old_size)))], src);
    }
    return @intCast(@intFromPtr(p));
}

fn twFree(_: i32, _: i32, _: i32) callconv(.c) void {}

/// A slice of request memory as the `(ptr, len)` a sequence crosses as. An
/// empty one is the dangling `align` (IR.md §11).
inline fn desc(comptime T: type, s: []const T) [2]u64 {
    if (s.len == 0) return .{ @alignOf(T), 0 };
    return .{ @as(u32, @intCast(@intFromPtr(s.ptr))), @as(u32, @intCast(s.len)) };
}

inline fn slice(comptime T: type, p: u64, n: u64) []const T {
    const len: u32 = @truncate(n);
    if (len == 0) return &.{};
    const ptr: [*]const T = @ptrFromInt(@as(u32, @truncate(p)));
    return ptr[0..len];
}

// ---------------------------------------------------------------------------
// The externref table (IR.md §14): slots from heap_base on. A run of slots
// for an `arr<T>` of references is contiguous; everything else takes one.

pub const heap_base: i32 = 132;

const free_slot: u8 = 0;
const scoped_slot: u8 = 1;
const kept_slot: u8 = 2;

var slots: std.ArrayList(u8) = .empty;
var hint: usize = 0;
var keep_mode = false;

/// `n` contiguous new slots, owned by the request (or kept, while an
/// exported class is constructed).
pub fn alloc(count: i32) i32 {
    fresh();
    const n: usize = @intCast(count);
    if (n == 0) return 0;
    var i = hint;
    search: while (true) {
        if (i + n > slots.items.len) {
            const grow = @max(i + n - slots.items.len, 64);
            _ = tsgen_table_grow(@intCast(grow));
            slots.appendNTimes(gpa, free_slot, grow) catch @trap();
        }
        for (i..i + n) |k| if (slots.items[k] != free_slot) {
            i = k + 1;
            continue :search;
        };
        break;
    }
    @memset(slots.items[i .. i + n], if (keep_mode) kept_slot else scoped_slot);
    if (i == hint) hint = i + n;
    return heap_base + @as(i32, @intCast(i));
}

pub fn free(base: i32, count: i32) void {
    if (base < heap_base or count <= 0) return;
    const i: usize = @intCast(base - heap_base);
    const n: usize = @intCast(count);
    if (i + n > slots.items.len) return;
    tsgen_ref_clear(base, count);
    @memset(slots.items[i .. i + n], free_slot);
    if (i < hint) hint = i;
}

fn sweep() void {
    var i: usize = 0;
    while (i < slots.items.len) {
        if (slots.items[i] != scoped_slot) {
            i += 1;
            continue;
        }
        var j = i + 1;
        while (j < slots.items.len and slots.items[j] == scoped_slot) j += 1;
        free(heap_base + @as(i32, @intCast(i)), @intCast(j - i));
        i = j;
    }
}

/// A new slot holding the same value as `slot`.
pub fn dupSlot(slot: i32) i32 {
    if (slot == 0) return 0;
    const s = alloc(1);
    tsgen_ref_copy(s, slot);
    return s;
}

fn keepSlot(slot: i32) void {
    if (slot >= heap_base) slots.items[@intCast(slot - heap_base)] = kept_slot;
}

fn isNull(slot: i32) bool {
    return slot == 0 or tsgen_ref_is_null(slot) != 0;
}

fn twTableAlloc(n: i32) callconv(.c) i32 {
    return alloc(n);
}

fn twTableFree(base: i32, n: i32) callconv(.c) void {
    free(base, n);
}

fn refAlloc1() callconv(.c) i32 {
    return alloc(1);
}

fn refFree1(slot: i32) callconv(.c) void {
    free(slot, 1);
}

// Slots made for one call's arguments, freed after it.
var temps: [256]i32 = undefined;
var ntemps: usize = 0;

fn temp(slot: i32) i32 {
    if (ntemps < temps.len) {
        temps[ntemps] = slot;
        ntemps += 1;
    }
    return slot;
}

fn freeTemps(mark: usize) void {
    while (ntemps > mark) {
        ntemps -= 1;
        free(temps[ntemps], 1);
    }
}

// ---------------------------------------------------------------------------
// JS values

/// A JS value in one slot. Generated classes and interfaces are a `Ref`
/// with their members; casting between them is free and unchecked.
pub const Ref = struct {
    slot: i32,

    /// Releases the value now rather than when the request ends.
    pub fn deinit(r: Ref) void {
        free(r.slot, 1);
    }

    /// The value, kept past the end of the request, until `deinit`.
    pub fn keep(r: Ref) Ref {
        keepSlot(r.slot);
        return r;
    }

    /// The same value in a slot of its own.
    pub fn dup(r: Ref) Ref {
        return .{ .slot = dupSlot(r.slot) };
    }

    pub fn isNullish(r: Ref) bool {
        return r.slot == 0 or ops.@"tsgen:tw:isNullish "(r.slot) != 0;
    }
};

/// A JS value of a class the bindings don't include.
pub const Object = struct {
    ref: Ref,
    pub fn as(self: Object, comptime T: type) T {
        return .{ .ref = self.ref };
    }
};

/// A JS value of no particular type: `any`, or an erased type parameter.
pub const Any = struct {
    ref: Ref,

    /// The value read as T (see `decode`).
    pub fn as(self: Any, comptime T: type) DecodeError!T {
        return decode(T, self.ref.dup().slot);
    }

    /// The value viewed as a generated class or interface.
    pub fn cast(self: Any, comptime T: type) T {
        return .{ .ref = self.ref };
    }

    pub fn isNullish(self: Any) bool {
        return self.ref.isNullish();
    }

    pub fn deinit(self: Any) void {
        self.ref.deinit();
    }

    pub fn keep(self: Any) Any {
        return .{ .ref = self.ref.keep() };
    }

    /// `v` as a JS value (see `toJs`).
    pub fn from(v: anytype) Any {
        return .{ .ref = .{ .slot = toJs(v) } };
    }
};

fn isRefStruct(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasField(T, "ref") and @FieldType(T, "ref") == Ref;
}

fn boxStr(s: []const u8) i32 {
    const d = desc(u8, s);
    return ops.@"tsgen:tw:box str"(unword(i32, d[0]), unword(i32, d[1]));
}

fn unboxStr(slot: i32) []const u8 {
    ops.@"tsgen:tw:unbox str"(slot, retPtr());
    return slice(u8, ret_area[0], ret_area[1]);
}

/// A new slot holding `v` as a JS value:
///
///   a generated class, `Any`, `Object`   itself
///   []const u8, string literals          a string
///   bool, integers, floats               a boolean, a number
///   ?T                                   null, or T
///   enum                                 its tag name, a string
///   struct                               a plain object of its fields;
///                                        null optional fields are left out
///   tuple, slice, array                  an Array
pub fn toJs(v: anytype) i32 {
    const T = @TypeOf(v);
    if (comptime isRefStruct(T)) return dupSlot(v.ref.slot);
    switch (@typeInfo(T)) {
        .bool => return ops.@"tsgen:tw:box bool"(@intFromBool(v)),
        .int, .comptime_int => return ops.@"tsgen:tw:box f64"(@floatFromInt(v)),
        .float, .comptime_float => return ops.@"tsgen:tw:box f64"(@floatCast(v)),
        .null => return 0,
        .optional => return if (v) |x| toJs(x) else 0,
        .@"enum", .enum_literal => return boxStr(@tagName(v)),
        .pointer => |p| {
            if (p.size == .one) {
                if (@typeInfo(p.child) == .array) {
                    if (@typeInfo(p.child).array.child == u8) return boxStr(v);
                    return arrayToJs(v[0..]);
                }
                return toJs(v.*);
            }
            if (p.child == u8) return boxStr(v);
            return arrayToJs(v);
        },
        .array => |a| {
            if (a.child == u8) return boxStr(&v);
            return arrayToJs(&v);
        },
        .@"struct" => |s| {
            if (s.is_tuple) {
                const base = alloc(s.field_names.len);
                inline for (0..s.field_names.len) |i| {
                    const x = toJs(v[i]);
                    tsgen_ref_copy(base + @as(i32, i), x);
                    free(x, 1);
                }
                defer free(base, s.field_names.len);
                return ops.@"tsgen:tw:box arr<Any?>"(base, s.field_names.len);
            }
            const o = ops.@"tsgen:tw:js/global TsgenObject.new()"();
            inline for (s.field_names) |name| {
                const f = @field(v, name);
                if (@typeInfo(@TypeOf(f)) != .optional or f != null) {
                    const x = toJs(f);
                    const d = desc(u8, name);
                    ops.@"tsgen:tw:js/global TsgenObject#setAt(str,Any?)"(o, unword(i32, d[0]), unword(i32, d[1]), x);
                    free(x, 1);
                }
            }
            return o;
        },
        else => @compileError("can't pass a " ++ @typeName(T) ++ " to JS"),
    }
}

fn arrayToJs(items: anytype) i32 {
    const n: i32 = @intCast(items.len);
    const base = alloc(n);
    defer free(base, n);
    for (items, 0..) |x, i| {
        const s = toJs(x);
        tsgen_ref_copy(base + @as(i32, @intCast(i)), s);
        free(s, 1);
    }
    return ops.@"tsgen:tw:box arr<Any?>"(base, n);
}

pub const DecodeError = error{ Missing, Range };

// The field a decode failed at, for the error it becomes.
var decode_field: []const u8 = "";

/// Reads the JS value in owned slot `slot` as T, freeing the slot unless T
/// takes it:
///
///   a generated class, `Any`, `Object`   the value itself
///   []const u8                           a string (a TypeError otherwise)
///   bool, integers, floats               a boolean, a number
///   ?T                                   null for null and undefined
///   enum                                 a string naming a tag
///   struct                               an object's properties, by field
///                                        name; a missing one takes the
///                                        field's default, or is null
///   slice                                an Array's elements
pub fn decode(comptime T: type, slot: i32) DecodeError!T {
    if (comptime isRefStruct(T)) return .{ .ref = .{ .slot = slot } };
    if (@typeInfo(T) == .optional) {
        if (slot == 0 or ops.@"tsgen:tw:isNullish "(slot) != 0) {
            free(slot, 1);
            return null;
        }
        return try decode(@typeInfo(T).optional.child, slot);
    }
    if (slot == 0) return error.Missing;
    defer free(slot, 1);
    switch (@typeInfo(T)) {
        .bool => return ops.@"tsgen:tw:unbox bool"(slot) != 0,
        .int => {
            const f = ops.@"tsgen:tw:unbox f64"(slot);
            const lo: f64 = @floatFromInt(std.math.minInt(T));
            const hi: f64 = @floatFromInt(std.math.maxInt(T));
            // Past 53 bits `hi` rounds up to a power of two T can't hold.
            const in_range = f >= lo and if (@bitSizeOf(T) > 53) f < hi else f <= hi;
            if (!in_range) return error.Range;
            return @intFromFloat(@trunc(f));
        },
        .float => return @floatCast(ops.@"tsgen:tw:unbox f64"(slot)),
        .@"enum" => return std.meta.stringToEnum(T, unboxStr(slot)) orelse error.Range,
        .pointer => |p| {
            if (p.size != .slice) @compileError("can't decode a " ++ @typeName(T));
            if (p.child == u8) return unboxStr(slot);
            const n: usize = @intCast(ops.@"tsgen:tw:arr len"(slot));
            const out = arena().alloc(p.child, n) catch @trap();
            for (out, 0..) |*o, i| o.* = try decode(p.child, ops.@"tsgen:tw:arr get<Any?>"(slot, @intCast(i)));
            return out;
        },
        .@"struct" => |s| {
            var out: T = undefined;
            inline for (s.field_names, s.field_types, s.field_attrs) |name, F, attrs| {
                const d = desc(u8, name);
                const v = ops.@"tsgen:tw:js/global TsgenObject#at(str)"(slot, unword(i32, d[0]), unword(i32, d[1]));
                errdefer if (decode_field.len == 0) {
                    decode_field = name;
                };
                if (comptime attrs.defaultValue(F)) |dv| {
                    if (v == 0 or ops.@"tsgen:tw:isNullish "(v) != 0) {
                        free(v, 1);
                        @field(out, name) = dv;
                    } else @field(out, name) = try decode(F, v);
                } else @field(out, name) = try decode(F, v);
            }
            return out;
        },
        else => @compileError("can't decode a " ++ @typeName(T)),
    }
}

// ---------------------------------------------------------------------------
// Errors: an enum used in `throws` or as a future's rejection is a Zig
// error set (its arms' names) plus the payload of the last one raised.

fn LastOf(comptime E: type) type {
    return struct {
        var v: ?E = null;
    };
}

/// The payload of the most recent error of enum E, until the request ends.
pub fn lastError(comptime E: type) ?E {
    return LastOf(E).v;
}

fn raise(comptime E: type, e: E) E.Error {
    LastOf(E).v = e;
    inline for (@typeInfo(E).@"union".field_names, E.tw_errors) |f, name| {
        if (e == @field(std.meta.Tag(E), f)) return @field(E.Error, name);
    }
    unreachable;
}

/// The arm a Zig error leaves an export as: the arm it names, with the
/// last payload of E when that is the same arm, else the fallback arm with
/// the error's name.
fn errorArm(comptime E: type, err: anyerror) E {
    const fields = @typeInfo(E).@"union".field_names;
    inline for (fields, E.tw_errors) |f, name| {
        if (std.mem.eql(u8, @errorName(err), name)) {
            if (LastOf(E).v) |last| if (last == @field(std.meta.Tag(E), f)) return last;
            return @unionInit(E, f, @errorName(err));
        }
    }
    return @unionInit(E, E.tw_fallback, @errorName(err));
}

// ---------------------------------------------------------------------------
// Codecs. Each has `Z`, the Zig type, `wire`, the wire types (an externref
// is an i32 slot), `lower(v, *[n]u64)` and `lift(*const [n]u64) Z`. Those
// arrays can hold `arr<T>` elements also have `mem` and `refs`, the sizes
// of an element's memory and table parts, `store` and `load`.

pub const Unit = struct {
    pub const Z = void;
    pub const wire = [_]type{};
    pub inline fn lower(_: void, _: *[0]u64) void {}
    pub inline fn lift(_: *const [0]u64) void {}
};

fn WireOf(comptime T: type) type {
    return switch (T) {
        bool, i8, u8, i16, u16, i32, u32 => i32,
        i64, u64 => i64,
        f32 => f32,
        f64 => f64,
        else => @compileError("not a scalar: " ++ @typeName(T)),
    };
}

inline fn toWire(comptime T: type, v: T) WireOf(T) {
    return switch (T) {
        bool => @intFromBool(v),
        i8, i16, i32 => v,
        u8, u16 => v,
        u32 => @bitCast(v),
        i64 => v,
        u64 => @bitCast(v),
        f32, f64 => v,
        else => unreachable,
    };
}

inline fn fromWire(comptime T: type, w: WireOf(T)) T {
    return switch (T) {
        bool => w != 0,
        i8 => @bitCast(@as(u8, @truncate(@as(u32, @bitCast(w))))),
        i16 => @bitCast(@as(u16, @truncate(@as(u32, @bitCast(w))))),
        u8, u16 => @truncate(@as(u32, @bitCast(w))),
        i32 => w,
        u32 => @bitCast(w),
        i64 => w,
        u64 => @bitCast(w),
        f32, f64 => w,
        else => unreachable,
    };
}

pub fn Scalar(comptime T: type) type {
    return struct {
        pub const Z = T;
        pub const wire = [_]type{WireOf(T)};
        pub inline fn lower(v: T, out: *[1]u64) void {
            out[0] = word(WireOf(T), toWire(T, v));
        }
        pub inline fn lift(in: *const [1]u64) T {
            return fromWire(T, unword(WireOf(T), in[0]));
        }
        pub const mem = @sizeOf(T);
        pub const refs = 0;
        pub inline fn store(v: T, p: [*]u8, _: i32) void {
            const b: [@sizeOf(T)]u8 = @bitCast(if (T == bool) @as(u8, @intFromBool(v)) else v);
            p[0..@sizeOf(T)].* = b;
        }
        pub inline fn load(p: [*]const u8, _: i32) T {
            if (T == bool) return p[0] != 0;
            return @bitCast(p[0..@sizeOf(T)].*);
        }
    };
}

/// A nullable scalar: one wire value with a niche (bool's 2), else a
/// presence flag and the value.
pub fn OptScalar(comptime T: type, comptime niche: ?comptime_int) type {
    const W = WireOf(T);
    if (niche) |n| return struct {
        pub const Z = ?T;
        pub const wire = [_]type{W};
        pub inline fn lower(v: ?T, out: *[1]u64) void {
            out[0] = word(W, if (v) |x| toWire(T, x) else n);
        }
        pub inline fn lift(in: *const [1]u64) ?T {
            const w = unword(W, in[0]);
            return if (w == n) null else fromWire(T, w);
        }
    };
    return struct {
        pub const Z = ?T;
        pub const wire = [_]type{ i32, W };
        pub inline fn lower(v: ?T, out: *[2]u64) void {
            out[0] = @intFromBool(v != null);
            out[1] = if (v) |x| word(W, toWire(T, x)) else 0;
        }
        pub inline fn lift(in: *const [2]u64) ?T {
            if (unword(i32, in[0]) == 0) return null;
            return fromWire(T, unword(W, in[1]));
        }
    };
}

pub const Str = struct {
    pub const Z = []const u8;
    pub const wire = [_]type{ i32, i32 };
    pub inline fn lower(v: []const u8, out: *[2]u64) void {
        out.* = desc(u8, v);
    }
    pub inline fn lift(in: *const [2]u64) []const u8 {
        return slice(u8, in[0], in[1]);
    }
    pub const mem = 8;
    pub const refs = 0;
    pub inline fn store(v: []const u8, p: [*]u8, _: i32) void {
        const d = desc(u8, v);
        p[0..4].* = @bitCast(@as(u32, @truncate(d[0])));
        p[4..8].* = @bitCast(@as(u32, @truncate(d[1])));
    }
    pub inline fn load(p: [*]const u8, _: i32) []const u8 {
        return slice(u8, @as(u32, @bitCast(p[0..4].*)), @as(u32, @bitCast(p[4..8].*)));
    }
};

const none_len: u64 = 0xffff_ffff;

pub const OptStr = struct {
    pub const Z = ?[]const u8;
    pub const wire = [_]type{ i32, i32 };
    pub inline fn lower(v: ?[]const u8, out: *[2]u64) void {
        out.* = if (v) |s| desc(u8, s) else .{ 1, none_len };
    }
    pub inline fn lift(in: *const [2]u64) ?[]const u8 {
        if (@as(u32, @truncate(in[1])) == none_len) return null;
        return slice(u8, in[0], in[1]);
    }
};

/// A typed array `T[]`, as a copy.
pub fn Vec(comptime T: type) type {
    return struct {
        pub const Z = []const T;
        pub const wire = [_]type{ i32, i32 };
        pub inline fn lower(v: []const T, out: *[2]u64) void {
            out.* = desc(T, v);
        }
        pub inline fn lift(in: *const [2]u64) []const T {
            return slice(T, in[0], in[1]);
        }
    };
}

pub fn OptVec(comptime T: type) type {
    return struct {
        pub const Z = ?[]const T;
        pub const wire = [_]type{ i32, i32 };
        pub inline fn lower(v: ?[]const T, out: *[2]u64) void {
            out.* = if (v) |s| desc(T, s) else .{ @alignOf(T), none_len };
        }
        pub inline fn lift(in: *const [2]u64) ?[]const T {
            if (@as(u32, @truncate(in[1])) == none_len) return null;
            return slice(T, in[0], in[1]);
        }
    };
}

/// A class or interface: a parameter is borrowed for the call, a result
/// is a new slot the request owns.
pub fn Host(comptime T: type) type {
    return struct {
        pub const Z = T;
        pub const wire = [_]type{i32};
        pub inline fn lower(v: T, out: *[1]u64) void {
            out[0] = word(i32, v.ref.slot);
        }
        pub inline fn lift(in: *const [1]u64) T {
            return .{ .ref = .{ .slot = unword(i32, in[0]) } };
        }
        pub const mem = 0;
        pub const refs = 1;
        pub inline fn store(v: T, _: [*]u8, base: i32) void {
            tsgen_ref_copy(base, v.ref.slot);
        }
        pub inline fn load(_: [*]const u8, base: i32) T {
            return .{ .ref = .{ .slot = base } };
        }
    };
}

pub fn OptHost(comptime T: type) type {
    return struct {
        pub const Z = ?T;
        pub const wire = [_]type{i32};
        pub inline fn lower(v: ?T, out: *[1]u64) void {
            out[0] = word(i32, if (v) |x| x.ref.slot else 0);
        }
        pub inline fn lift(in: *const [1]u64) ?T {
            const s = unword(i32, in[0]);
            if (isNull(s)) {
                free(s, 1);
                return null;
            }
            return .{ .ref = .{ .slot = s } };
        }
        pub const mem = 0;
        pub const refs = 1;
        pub inline fn store(v: ?T, _: [*]u8, base: i32) void {
            if (v) |x| tsgen_ref_copy(base, x.ref.slot);
        }
        pub inline fn load(_: [*]const u8, base: i32) ?T {
            if (isNull(base)) {
                free(base, 1);
                return null;
            }
            return .{ .ref = .{ .slot = base } };
        }
    };
}

/// `any`, an erased type parameter, or a box other than `Str`: any Zig
/// value in (`toJs`), `Any` out.
pub const Dyn = Erased(Any);
pub const OptDyn = OptErased(Any);

/// An erased type parameter read as T (`decode`).
pub fn Erased(comptime T: type) type {
    return struct {
        pub const Z = T;
        pub const wire = [_]type{i32};
        pub inline fn lower(v: anytype, out: *[1]u64) void {
            out[0] = word(i32, temp(toJs(v)));
        }
        pub inline fn lift(in: *const [1]u64) T {
            return decode(T, unword(i32, in[0])) catch @panic("ts-gen: the JS value doesn't decode as " ++ @typeName(T));
        }
        pub inline fn tryLift(in: *const [1]u64) DecodeError!T {
            return decode(T, unword(i32, in[0]));
        }
        pub const mem = 0;
        pub const refs = 1;
        pub inline fn store(v: anytype, _: [*]u8, base: i32) void {
            const s = toJs(v);
            tsgen_ref_copy(base, s);
            free(s, 1);
        }
        pub inline fn load(_: [*]const u8, base: i32) T {
            return decode(T, base) catch @panic("ts-gen: the JS value doesn't decode as " ++ @typeName(T));
        }
    };
}

pub fn OptErased(comptime T: type) type {
    return struct {
        pub const Z = ?T;
        pub const wire = [_]type{i32};
        pub inline fn lower(v: anytype, out: *[1]u64) void {
            out[0] = word(i32, temp(toJs(v)));
        }
        pub inline fn lift(in: *const [1]u64) ?T {
            return decode(?T, unword(i32, in[0])) catch @panic("ts-gen: the JS value doesn't decode as " ++ @typeName(T));
        }
        pub inline fn tryLift(in: *const [1]u64) DecodeError!?T {
            return decode(?T, unword(i32, in[0]));
        }
        pub const mem = 0;
        pub const refs = 1;
        pub inline fn store(v: anytype, _: [*]u8, base: i32) void {
            const s = toJs(v);
            tsgen_ref_copy(base, s);
            free(s, 1);
        }
        pub inline fn load(_: [*]const u8, base: i32) ?T {
            return decode(?T, base) catch @panic("ts-gen: the JS value doesn't decode as " ++ @typeName(T));
        }
    };
}

/// The `Str` box: a JS string, as Zig bytes.
pub const StrBox = struct {
    pub const Z = []const u8;
    pub const wire = [_]type{i32};
    pub inline fn lower(v: []const u8, out: *[1]u64) void {
        out[0] = word(i32, temp(boxStr(v)));
    }
    pub inline fn lift(in: *const [1]u64) []const u8 {
        const s = unword(i32, in[0]);
        defer free(s, 1);
        return unboxStr(s);
    }
    /// The slot as the error payload an export leaves with.
    inline fn lowerOwned(v: []const u8, out: *[1]u64) void {
        out[0] = word(i32, boxStr(v));
    }
};

pub const OptStrBox = struct {
    pub const Z = ?[]const u8;
    pub const wire = [_]type{i32};
    pub inline fn lower(v: ?[]const u8, out: *[1]u64) void {
        out[0] = word(i32, if (v) |s| temp(boxStr(s)) else 0);
    }
    pub inline fn lift(in: *const [1]u64) ?[]const u8 {
        const s = unword(i32, in[0]);
        defer free(s, 1);
        if (isNull(s)) return null;
        return unboxStr(s);
    }
};

/// An index enum: `E` is `enum(i32)` with the arms' indices; a nullable
/// one is 0 for none.
pub fn Enum(comptime E: type) type {
    return struct {
        pub const Z = E;
        pub const wire = [_]type{i32};
        pub inline fn lower(v: E, out: *[1]u64) void {
            out[0] = word(i32, @backingInt(v));
        }
        pub inline fn lift(in: *const [1]u64) E {
            return @fromBackingInt(@intCast(unword(i32, in[0])));
        }
        pub const mem = 4;
        pub const refs = 0;
        pub inline fn store(v: E, p: [*]u8, _: i32) void {
            p[0..4].* = @bitCast(@as(i32, @backingInt(v)));
        }
        pub inline fn load(p: [*]const u8, _: i32) E {
            return @fromBackingInt(@intCast(@as(i32, @bitCast(p[0..4].*))));
        }
    };
}

pub fn OptEnum(comptime E: type) type {
    return struct {
        pub const Z = ?E;
        pub const wire = [_]type{i32};
        pub inline fn lower(v: ?E, out: *[1]u64) void {
            out[0] = word(i32, if (v) |x| @backingInt(x) else 0);
        }
        pub inline fn lift(in: *const [1]u64) ?E {
            const w = unword(i32, in[0]);
            return if (w == 0) null else @fromBackingInt(@intCast(w));
        }
    };
}

/// A carrier enum: a non-exhaustive `enum(T)` over its carrier scalar.
pub fn Carrier(comptime E: type) type {
    const T = @typeInfo(E).@"enum".tag_type;
    return struct {
        pub const Z = E;
        pub const wire = [_]type{WireOf(T)};
        pub inline fn lower(v: E, out: *[1]u64) void {
            out[0] = word(WireOf(T), toWire(T, @backingInt(v)));
        }
        pub inline fn lift(in: *const [1]u64) E {
            return @fromBackingInt(@intCast(fromWire(T, unword(WireOf(T), in[0]))));
        }
    };
}

fn wireLen(comptime C: type) usize {
    return C.wire.len;
}

/// A payload enum: `U` is a `union(enum(i32))` whose fields are the arms,
/// tagged with their indices, and whose `tw_slots` and `tw_arms` give the
/// shared wire slots and, per arm, its payload's codec and slots.
pub fn Payload(comptime U: type) type {
    return PayloadOf(U, false);
}

pub fn OptPayload(comptime U: type) type {
    return PayloadOf(U, true);
}

fn PayloadOf(comptime U: type, comptime nullable: bool) type {
    const n = 1 + U.tw_slots.len;
    return struct {
        pub const Z = if (nullable) ?U else U;
        pub const wire = [_]type{i32} ++ U.tw_slots;
        pub inline fn lower(v: Z, out: *[n]u64) void {
            @memset(out, 0);
            const u = if (nullable) (v orelse return) else v;
            out[0] = word(i32, @backingInt(u));
            switch (u) {
                inline else => |x, tag| {
                    const arm = comptime armIndex(U, tag);
                    const A = U.tw_arms[arm];
                    if (A.codec != Unit) {
                        var w: [A.codec.wire.len]u64 = undefined;
                        A.codec.lower(x, &w);
                        inline for (A.slots, 0..) |s, k| out[1 + s] = w[k];
                    }
                },
            }
        }
        pub inline fn lift(in: *const [n]u64) Z {
            const tag = unword(i32, in[0]);
            inline for (@typeInfo(U).@"union".field_names, 0..) |f, arm| {
                const A = U.tw_arms[arm];
                if (tag == @backingInt(@field(std.meta.Tag(U), f))) {
                    if (A.codec == Unit) return @unionInit(U, f, {});
                    var w: [A.codec.wire.len]u64 = undefined;
                    inline for (A.slots, 0..) |s, k| w[k] = in[1 + s];
                    return @unionInit(U, f, A.codec.lift(&w));
                }
            }
            if (nullable) return null;
            // An index outside the enum: its fallback arm, if it has one.
            if (@hasDecl(U, "tw_fallback")) {
                if (U.tw_arms[comptime fieldIndex(U, U.tw_fallback)].codec == StrBox)
                    return @unionInit(U, U.tw_fallback, "unknown error");
            }
            @panic("ts-gen: an enum arm this module doesn't know");
        }
    };
}

fn armIndex(comptime U: type, comptime tag: std.meta.Tag(U)) usize {
    return fieldIndex(U, @tagName(tag));
}

fn fieldIndex(comptime U: type, comptime name: []const u8) usize {
    for (@typeInfo(U).@"union".field_names, 0..) |f, i| if (std.mem.eql(u8, f, name)) return i;
    unreachable;
}

/// An arm of a payload enum: its payload's codec and the shared slots its
/// wire values go to.
pub const Arm = struct {
    codec: type,
    slots: []const usize,
};

/// `arr<T>`, as a copy: each element's numeric values packed in memory,
/// its references in a run of table slots (IR.md §11).
pub fn Arr(comptime C: type) type {
    return ArrOf(C, false);
}

pub fn OptArr(comptime C: type) type {
    return ArrOf(C, true);
}

fn ArrOf(comptime C: type, comptime nullable: bool) type {
    const has_mem = C.mem > 0;
    const has_refs = C.refs > 0;
    const n = @as(usize, @intFromBool(has_mem)) + @intFromBool(has_refs) + 1;
    return struct {
        pub const Z = if (nullable) ?[]const C.Z else []const C.Z;
        pub const wire: [n]type = @splat(i32);
        pub fn lower(v: anytype, out: *[n]u64) void {
            if (nullable and @typeInfo(@TypeOf(v)) == .optional) {
                if (v) |x| return lower(x, out);
                out[n - 1] = none_len;
                if (has_mem) out[0] = 1;
                if (has_refs) out[n - 2] = 0;
                return;
            }
            if (nullable and @TypeOf(v) == @TypeOf(null)) return lower(@as(?[]const C.Z, null), out);
            const T = @TypeOf(v);
            const tuple = @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple;
            const len: usize = if (tuple) @typeInfo(T).@"struct".field_names.len else v.len;
            const m: [*]u8 = if (has_mem and len > 0) (arena().alloc(u8, C.mem * len) catch @trap()).ptr else @ptrFromInt(1);
            const base: i32 = if (has_refs and len > 0) temps_run(@intCast(C.refs * len)) else 0;
            if (tuple) {
                inline for (0..len) |i| C.store(v[i], m + C.mem * i, base + @as(i32, @intCast(C.refs * i)));
            } else {
                for (v, 0..) |x, i| C.store(x, m + C.mem * i, base + @as(i32, @intCast(C.refs * i)));
            }
            var k: usize = 0;
            if (has_mem) {
                out[k] = @as(u32, @intCast(@intFromPtr(m)));
                k += 1;
            }
            if (has_refs) {
                out[k] = word(i32, base);
                k += 1;
            }
            out[k] = @as(u32, @intCast(len));
        }
        pub inline fn lift(in: *const [n]u64) Z {
            const len32: u32 = @truncate(in[n - 1]);
            if (nullable and len32 == none_len) return null;
            const len: usize = len32;
            if (len == 0) return &.{};
            const m: [*]const u8 = if (has_mem) @ptrFromInt(@as(u32, @truncate(in[0]))) else undefined;
            const base: i32 = if (has_refs) unword(i32, in[n - 2]) else 0;
            const out = arena().alloc(C.Z, len) catch @trap();
            for (out, 0..) |*o, i| o.* = C.load(m + C.mem * i, base + @as(i32, @intCast(C.refs * i)));
            return out;
        }
    };
}

// A run of table slots for one call's argument, freed after it.
fn temps_run(count: i32) i32 {
    const base = alloc(count);
    var i: i32 = 0;
    while (i < count) : (i += 1) _ = temp(base + i);
    return base;
}

/// A tuple in a direct position: its elements' wire values in order.
pub fn Tuple(comptime Cs: anytype) type {
    comptime var wires: []const type = &.{};
    comptime var zs: [Cs.len]type = undefined;
    inline for (Cs, 0..) |C, i| {
        wires = wires ++ C.wire;
        zs[i] = C.Z;
    }
    const W = wires[0..wires.len].*;
    const ZT = @Tuple(&zs);
    return struct {
        pub const Z = ZT;
        pub const wire = W;
        pub inline fn lower(v: anytype, out: *[W.len]u64) void {
            comptime var off = 0;
            inline for (Cs, 0..) |C, i| {
                C.lower(v[i], out[off..][0..C.wire.len]);
                off += C.wire.len;
            }
        }
        pub inline fn lift(in: *const [W.len]u64) Z {
            var out: Z = undefined;
            comptime var off = 0;
            inline for (Cs, 0..) |C, i| {
                out[i] = C.lift(in[off..][0..C.wire.len]);
                off += C.wire.len;
            }
            return out;
        }
        pub const mem = blk: {
            var s = 0;
            for (Cs) |C| s += C.mem;
            break :blk s;
        };
        pub const refs = blk: {
            var s = 0;
            for (Cs) |C| s += C.refs;
            break :blk s;
        };
        pub inline fn store(v: anytype, p: [*]u8, base: i32) void {
            comptime var m = 0;
            comptime var r = 0;
            inline for (Cs, 0..) |C, i| {
                C.store(v[i], p + m, base + r);
                m += C.mem;
                r += C.refs;
            }
        }
        pub inline fn load(p: [*]const u8, base: i32) Z {
            var out: Z = undefined;
            comptime var m = 0;
            comptime var r = 0;
            inline for (Cs, 0..) |C, i| {
                out[i] = C.load(p + m, base + r);
                m += C.mem;
                r += C.refs;
            }
            return out;
        }
    };
}

/// A future: awaited, so a result of `Future(V, ...)` is `V.Z`, or the
/// rejection as an error of E.
pub fn Future(comptime V: type, comptime take: anytype, comptime err_op: anytype, comptime E: type) type {
    return struct {
        pub const Value = V;
        pub const Rejection = E;
        pub const Z = E.Error!V.Z;
        pub const wire = [_]type{i32};

        /// Waits for the future in owned slot `f`, then takes its value or
        /// its rejection, and frees the slot.
        pub fn settle(f: i32) Z {
            defer free(f, 1);
            while (true) {
                const state = ops.@"tsgen:tw:future poll"(f, 0);
                if (state == 1) break;
                if (state == 2) {
                    const P = Payload(E);
                    const r = invoke(err_op, P.wire.len, .{word(i32, f)});
                    return raise(E, P.lift(&r));
                }
                wait(0);
            }
            if (V == Unit) {
                _ = invoke(take, 0, .{word(i32, f)});
                return;
            }
            const r = invoke(take, V.wire.len, .{word(i32, f)});
            if (comptime @hasDecl(V, "tryLift")) {
                return V.tryLift(&r) catch |err| raise(E, decodeFailure(E, V.Z, err));
            }
            return V.lift(&r);
        }
    };
}

/// A value that doesn't decode as the Zig type asked for, as an arm of E:
/// its TypeError, else its fallback, naming the type and the field.
fn decodeFailure(comptime E: type, comptime T: type, err: DecodeError) E {
    const what = switch (err) {
        error.Missing => "missing",
        error.Range => "out of range",
    };
    const msg = std.fmt.allocPrint(arena(), "the value doesn't decode as {s}: {s}{s} {s}", .{
        @typeName(T), decode_field, if (decode_field.len > 0) " is" else "", what,
    }) catch "the value doesn't decode";
    decode_field = "";
    inline for (@typeInfo(E).@"union".field_names, E.tw_errors) |f, name| {
        if (comptime std.mem.eql(u8, name, "TypeError")) return @unionInit(E, f, msg);
    }
    return @unionInit(E, E.tw_fallback, msg);
}

fn isFuture(comptime C: type) bool {
    return @hasDecl(C, "settle");
}

/// The JS function a Zig function and its context become (IR.md §18).
/// Build one with `init(ctx, f)`, where `f` takes `ctx` (a pointer)
/// first, then the callback's arguments; or `fromFn(f)`. Each crossing to
/// JS makes a JS function that lives until JS drops it.
pub fn Callback(comptime Params: anytype, comptime Res: type, comptime trampoline: anytype, comptime name: []const u8) type {
    comptime var nin = 0;
    for (Params) |P| nin += P.wire.len;
    const n_in = nin;
    const n_out = Res.wire.len;
    return struct {
        const Self = @This();
        ctx: ?*anyopaque,
        thunk: *const fn (?*anyopaque, *const [n_in]u64, *[n_out]u64) void,

        pub fn init(ctx: anytype, comptime f: anytype) Self {
            return .{ .ctx = @ptrCast(@constCast(ctx)), .thunk = struct {
                fn t(c: ?*anyopaque, in: *const [n_in]u64, out: *[n_out]u64) void {
                    var args: std.meta.ArgsTuple(@TypeOf(f)) = undefined;
                    args[0] = @ptrCast(@alignCast(c));
                    liftArgs(&args, 1, in);
                    finish(@call(.auto, f, args), out);
                }
            }.t };
        }

        pub fn fromFn(comptime f: anytype) Self {
            return .{ .ctx = null, .thunk = struct {
                fn t(_: ?*anyopaque, in: *const [n_in]u64, out: *[n_out]u64) void {
                    var args: std.meta.ArgsTuple(@TypeOf(f)) = undefined;
                    liftArgs(&args, 0, in);
                    finish(@call(.auto, f, args), out);
                }
            }.t };
        }

        inline fn liftArgs(args: anytype, comptime first: usize, in: *const [n_in]u64) void {
            comptime var off = 0;
            inline for (Params, 0..) |P, i| {
                if (first + i < args.len) args[first + i] = P.lift(in[off..][0..P.wire.len]);
                off += P.wire.len;
            }
        }

        inline fn finish(r: anytype, out: *[n_out]u64) void {
            if (@typeInfo(@TypeOf(r)) == .error_union) @compileError("a callback can't return an error: handle it in the callback");
            if (comptime isFuture(Res) or Res == Unit) {
                @memset(out, 0);
            } else Res.lower(r, out);
        }

        pub const Z = Self;
        pub const wire = [_]type{i32};
        // The trampoline and drop are exported once the module lowers
        // one of these.
        const exported = blk: {
            @export(trampoline, .{ .name = "tsgen:" ++ name });
            @export(&drop, .{ .name = "tw:drop:" ++ name["tw:call:".len..] });
            break :blk {};
        };

        pub inline fn lower(v: Self, out: *[1]u64) void {
            _ = exported;
            const box = gpa.create(Self) catch @trap();
            box.* = v;
            out[0] = @as(u32, @intCast(@intFromPtr(box)));
        }

        fn drop(env: i32) callconv(.c) void {
            gpa.destroy(@as(*Self, @ptrFromInt(@as(u32, @bitCast(env)))));
        }

        /// The trampoline's body: JS calls the function.
        pub inline fn call(env: i32, in: [n_in]u64) [n_out]u64 {
            enter();
            defer leave();
            const self: *Self = @ptrFromInt(@as(u32, @bitCast(env)));
            var out: [n_out]u64 = undefined;
            self.thunk(self.ctx, &in, &out);
            return out;
        }
    };
}

/// A callback's `future<T>?` result: it returns none, having done its
/// work before it returns.
pub const NoFuture = struct {
    pub const Z = void;
    pub const wire = [_]type{i32};
    pub inline fn lower(_: void, out: *[1]u64) void {
        out[0] = 0;
    }
    pub inline fn lift(_: *const [1]u64) void {}
};

pub fn OptCallback(comptime C: type) type {
    return struct {
        pub const Z = ?C;
        pub const wire = [_]type{i32};
        pub inline fn lower(v: ?C, out: *[1]u64) void {
            if (v) |x| C.lower(x, out) else out[0] = 0;
        }
    };
}

// ---------------------------------------------------------------------------
// Calls

/// Calls shim import `f` with wire words `in`; its result words, from the
/// return area when it has more than one.
inline fn invoke(comptime f: anytype, comptime nres: usize, in: anytype) [nres]u64 {
    const F = @typeInfo(@TypeOf(f)).@"fn";
    const use_ret = F.param_types.len == in.len + 1;
    var args: std.meta.ArgsTuple(@TypeOf(f)) = undefined;
    inline for (0..in.len) |i| args[i] = unword(F.param_types[i].?, in[i]);
    if (use_ret) args[in.len] = retPtr();
    const r = @call(.auto, f, args);
    var out: [nres]u64 = undefined;
    if (use_ret) {
        inline for (0..nres) |i| out[i] = ret_area[i];
    } else if (nres == 1) {
        out[0] = word(F.return_type.?, r);
    }
    return out;
}

fn ErrorSetOf(comptime C: ?type) type {
    return if (C) |E| E.Error else error{};
}

/// What a call returns: the result's Zig type, with the errors of `throws`
/// and of a future's rejection.
pub fn Ret(comptime Res: type, comptime Thr: ?type) type {
    if (isFuture(Res)) return (Res.Rejection.Error || ErrorSetOf(Thr))!Res.Value.Z;
    if (Thr) |E| return E.Error!Res.Z;
    return Res.Z;
}

/// Calls an import: lowers `args` through the parameter codecs `P`, calls
/// the shim's `f`, raises a thrown tag as an error of `Thr`, awaits a
/// future, and lifts the result through `Res`.
pub inline fn call(comptime f: anytype, comptime P: anytype, comptime Res: type, comptime Thr: ?type, args: anytype) Ret(Res, Thr) {
    comptime var nin = 0;
    inline for (P) |C| nin += C.wire.len;
    var in: [nin]u64 = undefined;
    const mark = ntemps;
    comptime var off = 0;
    inline for (P, 0..) |C, i| {
        C.lower(args[i], in[off..][0..C.wire.len]);
        off += C.wire.len;
    }
    const F = @typeInfo(@TypeOf(f)).@"fn";
    var fargs: std.meta.ArgsTuple(@TypeOf(f)) = undefined;
    inline for (0..nin) |i| fargs[i] = unword(F.param_types[i].?, in[i]);
    const use_ret = F.param_types.len == nin + 1;
    if (use_ret) fargs[nin] = retPtr();
    const r = @call(.auto, f, fargs);
    freeTemps(mark);
    const nres = Res.wire.len;
    if (Thr) |E| {
        if (r != 0) {
            const PE = Payload(E);
            var ew: [PE.wire.len]u64 = undefined;
            inline for (0..PE.wire.len) |i| ew[i] = ret_area[i];
            return raise(E, PE.lift(&ew));
        }
    }
    var w: [nres]u64 = undefined;
    if (use_ret) {
        inline for (0..nres) |i| w[i] = ret_area[i];
    } else if (nres == 1) {
        w[0] = word(F.return_type.?, r);
    }
    if (comptime isFuture(Res)) return Res.settle(unword(i32, w[0]));
    if (Thr) |E| if (comptime @hasDecl(Res, "tryLift")) {
        return Res.tryLift(&w) catch |err| raise(E, decodeFailure(E, Res.Z, err));
    };
    return Res.lift(&w);
}

// ---------------------------------------------------------------------------
// Exports

/// What an export returns to the shim: a status when it can fail (results
/// in the return area), else its one result, or nothing.
pub fn ServeRet(comptime n: usize, comptime fails: bool, comptime W: type) type {
    if (fails) return i32;
    if (n == 1) return W;
    return void;
}

/// The function an export of App runs: `App.<ns>.<name>`, or for the
/// `default` namespace `App.<name>` too.
pub fn handler(comptime App: type, comptime ns: []const u8, comptime name: []const u8) type {
    if (ns.len != 0 and @hasDecl(App, ns) and @TypeOf(@field(App, ns)) == type and @hasDecl(@field(App, ns), name))
        return struct {
            pub const f = @field(@field(App, ns), name);
        };
    if ((ns.len == 0 or std.mem.eql(u8, ns, "default")) and @hasDecl(App, name)) return struct {
        pub const f = @field(App, name);
    };
    @compileError("the module exports " ++ ns ++ "." ++ name ++ ": declare pub fn " ++ name ++
        (if (ns.len == 0 or std.mem.eql(u8, ns, "default")) " at the top level of the root file" else " in pub const " ++ ns ++ " = struct { ... }"));
}

/// Calls handler `h` with the export's arguments: an optional leading
/// `std.mem.Allocator` (the request arena), then as many of the lifted
/// parameters as it takes.
inline fn invokeHandler(comptime h: anytype, comptime P: anytype, comptime pre: usize, prefix: anytype, in: anytype) HandlerRet(h) {
    const H = @typeInfo(@TypeOf(h)).@"fn";
    var args: std.meta.ArgsTuple(@TypeOf(h)) = undefined;
    comptime var k = 0;
    inline for (0..pre) |i| {
        args[k] = prefix[i];
        k += 1;
    }
    if (H.param_types.len > k and H.param_types[k] == Allocator) {
        args[k] = arena();
        k += 1;
    }
    const first = k;
    comptime var off = 0;
    inline for (P, 0..) |C, i| {
        if (first + i < H.param_types.len) {
            args[first + i] = C.lift(in[off..][0..C.wire.len]);
        } else if (C.wire.len == 1 and C.wire[0] == i32 and @hasDecl(C, "refs") and C.refs == 1) {
            // A JS value the handler doesn't take.
            free(unword(i32, in[off]), 1);
        }
        off += C.wire.len;
    }
    return @call(.auto, h, args);
}

fn HandlerRet(comptime h: anytype) type {
    return @typeInfo(@TypeOf(h)).@"fn".return_type.?;
}

/// Runs an export: lifts its wire arguments, calls the handler, and lowers
/// its result, or its error as an arm of `E` (the export's `throws`, or
/// its future's rejection). `Res` is the result's codec; for a future, the
/// value's, which the export returns as itself (JSPI resolves the call's
/// promise with it).
pub inline fn serve(comptime h: anytype, comptime P: anytype, comptime Res: type, comptime E: ?type, in: anytype) ServeRet(Res.wire.len, E != null, if (Res.wire.len == 1) Res.wire[0] else void) {
    enter();
    defer leave();
    const out = invokeHandler(h, P, 0, .{}, wordsOf(P, in));
    return finishExport(Res, E, out);
}

/// An exported class's constructor: the instance, made with `App.C.init`
/// (or the struct itself when it has none), is the handle. What it
/// receives is kept.
pub inline fn serveNew(comptime T: type, comptime P: anytype, comptime E: ?type, this: i32, in: anytype) ServeRet(1, E != null, i32) {
    enter();
    defer leave();
    free(this, 1);
    keep_mode = true;
    const words = wordsOf(P, in);
    // The shim put the JS values it received in request slots: keep them.
    comptime var off = 0;
    inline for (P) |C| {
        if (comptime @hasDecl(C, "refs") and C.refs == 1 and C.mem == 0) keepSlot(unword(i32, words[off]));
        off += C.wire.len;
    }
    const v = if (@hasDecl(T, "init")) invokeHandler(T.init, P, 0, .{}, words) else T{};
    keep_mode = false;
    const obj = gpa.create(T) catch @trap();
    obj.* = if (@typeInfo(@TypeOf(v)) == .error_union) (v catch |err| {
        gpa.destroy(obj);
        return failExport(E, err);
    }) else v;
    return finishExport(Scalar(i32), E, @as(i32, @intCast(@intFromPtr(obj))));
}

/// An exported class's method, on the instance `h`.
pub inline fn serveMethod(comptime T: type, comptime name: []const u8, comptime P: anytype, comptime Res: type, comptime E: ?type, this: i32, h: i32, in: anytype) ServeRet(Res.wire.len, E != null, if (Res.wire.len == 1) Res.wire[0] else void) {
    enter();
    defer leave();
    free(this, 1);
    const obj: *T = @ptrFromInt(@as(u32, @bitCast(h)));
    const out = invokeHandler(@field(T, name), P, 1, .{obj}, wordsOf(P, in));
    return finishExport(Res, E, out);
}

/// Drops an exported class's instance when JS has collected its wrapper.
pub fn dropInstance(comptime T: type) fn (i32) callconv(.c) void {
    return struct {
        fn d(h: i32) callconv(.c) void {
            const obj: *T = @ptrFromInt(@as(u32, @bitCast(h)));
            if (@hasDecl(T, "deinit")) obj.deinit();
            gpa.destroy(obj);
        }
    }.d;
}

inline fn wordsOf(comptime P: anytype, in: anytype) [
    blk: {
        var n = 0;
        for (P) |C| n += C.wire.len;
        break :blk n;
    }
]u64 {
    var w: [in.len]u64 = undefined;
    inline for (0..in.len) |i| w[i] = word(@TypeOf(in[i]), in[i]);
    return w;
}

inline fn finishExport(comptime Res: type, comptime E: ?type, out: anytype) ServeRet(Res.wire.len, E != null, if (Res.wire.len == 1) Res.wire[0] else void) {
    const fails = @typeInfo(@TypeOf(out)) == .error_union;
    const v = if (fails) (out catch |err| return failExport(E, err)) else out;
    var w: [Res.wire.len]u64 = undefined;
    lowerResult(Res, v, &w);
    if (E != null or w.len > 1) inline for (0..w.len) |i| {
        ret_area[i] = w[i];
    };
    if (E != null) return 0;
    if (w.len == 1) return unword(Res.wire[0], w[0]);
}

// A host result leaves in a slot of its own, which the shim takes.
inline fn lowerResult(comptime Res: type, v: anytype, w: anytype) void {
    if (comptime @hasDecl(Res, "refs") and Res.refs == 1 and Res.mem == 0 and isRefStruct(@TypeOf(v))) {
        w[0] = word(i32, dupSlot(v.ref.slot));
    } else if (comptime @hasDecl(Res, "refs") and Res.refs == 1 and Res.mem == 0 and @typeInfo(@TypeOf(v)) == .optional) {
        w[0] = word(i32, if (v) |x| dupSlot(x.ref.slot) else 0);
    } else Res.lower(v, w);
}

inline fn failExport(comptime E: ?type, err: anyerror) i32 {
    const Et = E orelse @panic("ts-gen: an export that can't fail returned an error");
    const arm = errorArm(Et, err);
    const PE = Payload(Et);
    var w: [PE.wire.len]u64 = @splat(0);
    w[0] = word(i32, @backingInt(arm));
    switch (arm) {
        inline else => |msg, tag| {
            const A = Et.tw_arms[comptime armIndex(Et, tag)];
            if (A.codec == StrBox) {
                var mw: [1]u64 = undefined;
                StrBox.lowerOwned(msg, &mw);
                w[1 + A.slots[0]] = mw[0];
            }
        },
    }
    inline for (0..w.len) |i| ret_area[i] = w[i];
    return 1;
}

/// A callback trampoline's body: calls callback type C's function with
/// the wire arguments `in`, and returns its one wire result, if any.
pub inline fn tramp(comptime C: type, comptime R: type, env: i32, in: anytype) R {
    const r = C.call(env, wordsOfArgs(in));
    if (R == void) return;
    return unword(R, r[0]);
}

inline fn wordsOfArgs(in: anytype) [in.len]u64 {
    var w: [in.len]u64 = undefined;
    inline for (0..in.len) |i| w[i] = word(@TypeOf(in[i]), in[i]);
    return w;
}

// ---------------------------------------------------------------------------
// Exports every module has.

fn wake(_: i32) callconv(.c) void {}

comptime {
    @export(&tsgenRetArea, .{ .name = "tsgen_ret_area" });
    @export(&twRealloc, .{ .name = "tw:realloc" });
    @export(&twFree, .{ .name = "tw:free" });
    @export(&twTableAlloc, .{ .name = "tw:table/alloc" });
    @export(&twTableFree, .{ .name = "tw:table/free" });
    @export(&refAlloc1, .{ .name = "tsgen_ref_alloc1" });
    @export(&refFree1, .{ .name = "tsgen_ref_free1" });
    @export(&wake, .{ .name = "tw:future/wake" });
}

/// A Worker has no stderr: a panic traps. Declare
/// `pub const panic = tsgen.panic;` in the root file.
pub const panic = std.debug.no_panic;
