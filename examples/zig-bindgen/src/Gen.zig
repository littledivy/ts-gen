//! Zig bindings from lowered JSON (IR.md, through `ts-gen-abi lower`).
//! Nothing here knows any one API; it maps the IR:
//!
//!   class, interface     struct { ref: rt.Ref } with its members (and its
//!                        parents', copied in), `deinit`, `keep` and `as`
//!   @js(object) new()    init(.{ .field = v, ... }) over the settable
//!                        properties, all optional
//!   get p / set p        p() / setP(v)
//!   overloads            one function per variant (put, putWithOptions)
//!   enum (index)         enum(i32); (carrier) enum(T) { ..., _ };
//!                        (payload) union(enum(i32))
//!   T?                   ?T
//!   future<T, E>         a blocking call returning E.Error!T (JSPI)
//!   throws E             E.Error!T; the payload is E.last()
//!   fn(A) -> R           a Callback: a Zig function with a context
//!   T (a type param)     a result: `comptime T: type` decodes it as T;
//!                        a parameter: anytype, through rt.toJs
//!   Any                  anytype in, rt.Any out
//!   arr<T>, T[], (A, B)  []const T, []const T, a tuple
//!   export namespace     a pub fn of the app's root file
//!   export class C       the app's pub const C = struct { ... }
//!
//! Every call goes through the shim (shim.zig), named `tsgen:<module>
//! <name>`, and manifest.json lists each one's wire types for it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const Gen = @This();

a: Allocator,
decls: std.StringHashMapUnmanaged(Value) = .empty,
decl_order: std.ArrayList([]const u8) = .empty,
members: std.ArrayList(Value) = .empty,
by_owner: std.StringArrayHashMapUnmanaged(std.ArrayList(usize)) = .empty,
exported_classes: std.StringHashMapUnmanaged(void) = .empty,
selected: std.StringArrayHashMapUnmanaged(void) = .empty,
global_sel: std.AutoHashMapUnmanaged(usize, void) = .empty,
imports: std.StringArrayHashMapUnmanaged(Import) = .empty,
exports: std.ArrayList(Export) = .empty,
callbacks: std.StringArrayHashMapUnmanaged(?[]const u8) = .empty,
callback_code: std.ArrayList(u8) = .empty,
enums: std.StringArrayHashMapUnmanaged(Value) = .empty,
bad_enums: std.StringHashMapUnmanaged([]const u8) = .empty,
throw_enums: std.StringHashMapUnmanaged(void) = .empty,
top_names: std.StringHashMapUnmanaged(void) = .empty,
type_names: std.StringHashMapUnmanaged([]const u8) = .empty,
used_type_names: std.StringHashMapUnmanaged(void) = .empty,
global_names: std.StringHashMapUnmanaged(void) = .empty,
out: std.ArrayList(u8) = .empty,
export_code: std.ArrayList(u8) = .empty,
skipped: std.ArrayList([2][]const u8) = .empty,
why: []const u8 = "",
/// The input's own declarations and members, ahead of its libraries'.
main_decls: usize = 0,
main_members: usize = 0,
emitted: usize = 0,
tmp: usize = 0,

const Import = struct {
    c: []const u8,
    module: []const u8,
    name: []const u8,
    params: []const []const u8,
    results: []const []const u8,
    throws: ?Tag,
};

const Tag = struct {
    module: []const u8,
    name: []const u8,
    params: []const []const u8,
};

const Export = struct {
    c: []const u8,
    name: []const u8,
    params: []const []const u8,
    results: []const []const u8,
    throws: ?Tag,
    // Set for the module's own exports, not callbacks' trampolines.
    async_: ?bool = null,
    owner: ?[]const u8 = null,
    member: ?[]const u8 = null,
    kind: ?[]const u8 = null,
};

const Error = error{ Unsupported, OutOfMemory, Profile };

// ---------------------------------------------------------------------------
// JSON

fn get(v: Value, k: []const u8) ?Value {
    if (v != .object) return null;
    const x = v.object.get(k) orelse return null;
    if (x == .null) return null;
    return x;
}

fn str(v: Value, k: []const u8) []const u8 {
    const x = get(v, k) orelse return "";
    return if (x == .string) x.string else "";
}

fn optStr(v: Value, k: []const u8) ?[]const u8 {
    const x = get(v, k) orelse return null;
    return if (x == .string) x.string else null;
}

fn boolean(v: Value, k: []const u8) bool {
    const x = get(v, k) orelse return false;
    return x == .bool and x.bool;
}

fn items(v: ?Value) []const Value {
    const x = v orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}

fn strs(a: Allocator, v: ?Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (items(v)) |x| try out.append(a, x.string);
    return out.items;
}

fn int(v: Value, k: []const u8) i64 {
    const x = get(v, k) orelse return 0;
    return switch (x) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

fn kind(r: Value) []const u8 {
    return str(r, "kind");
}

fn isKind(r: Value, k: []const u8) bool {
    return std.mem.eql(u8, kind(r), k);
}

fn isHost(r: Value, of: []const u8) bool {
    return isKind(r, "host") and std.mem.eql(u8, str(r, "of"), of);
}

fn nullable(r: Value) bool {
    return boolean(r, "nullable");
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

// ---------------------------------------------------------------------------
// Names

const zig_reserved = std.StaticStringMap(void).initComptime(.{
    .{"addrspace"},   .{"align"},          .{"allowzero"},    .{"and"},         .{"anyframe"}, .{"anytype"},
    .{"asm"},         .{"break"},          .{"callconv"},     .{"catch"},       .{"comptime"}, .{"const"},
    .{"continue"},    .{"defer"},          .{"else"},         .{"enum"},        .{"errdefer"}, .{"error"},
    .{"export"},      .{"extern"},         .{"fn"},           .{"for"},         .{"if"},       .{"inline"},
    .{"linksection"}, .{"noalias"},        .{"noinline"},     .{"nosuspend"},   .{"opaque"},   .{"or"},
    .{"orelse"},      .{"packed"},         .{"pub"},          .{"resume"},      .{"return"},   .{"struct"},
    .{"suspend"},     .{"switch"},         .{"test"},         .{"threadlocal"}, .{"try"},      .{"union"},
    .{"unreachable"}, .{"var"},            .{"volatile"},     .{"while"},       .{"anyerror"}, .{"anyopaque"},
    .{"bool"},        .{"comptime_float"}, .{"comptime_int"}, .{"f16"},         .{"f32"},      .{"f64"},
    .{"f80"},         .{"f128"},           .{"false"},        .{"isize"},       .{"noreturn"}, .{"null"},
    .{"true"},        .{"type"},           .{"undefined"},    .{"usize"},       .{"void"},     .{"c_char"},
    .{"c_short"},     .{"c_ushort"},       .{"c_int"},        .{"c_uint"},      .{"c_long"},   .{"c_ulong"},
    .{"c_longlong"},  .{"c_ulonglong"},    .{"c_longdouble"}, .{"async"},       .{"await"},    .{"usingnamespace"},
});

fn isPrimitiveInt(s: []const u8) bool {
    if (s.len < 2 or (s[0] != 'i' and s[0] != 'u')) return false;
    for (s[1..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn validIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return !zig_reserved.has(s) and !isPrimitiveInt(s) and !eql(s, "_");
}

/// `s` as a Zig identifier, quoted when it isn't one.
fn ident(a: Allocator, s: []const u8) ![]const u8 {
    if (validIdent(s)) return s;
    return std.fmt.allocPrint(a, "@\"{s}\"", .{s});
}

/// Letters and digits, words joined camelCase from `_`-separated parts.
fn camel(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var up = false;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try out.append(a, if (up and out.items.len > 0) std.ascii.toUpper(c) else c);
            up = false;
        } else up = true;
    }
    if (out.items.len == 0) return "_";
    if (std.ascii.isDigit(out.items[0])) try out.insert(a, 0, '_');
    return out.items;
}

fn lowerFirst(a: Allocator, s: []const u8) ![]const u8 {
    if (s.len == 0) return s;
    var out = try a.dupe(u8, s);
    var all_caps = std.ascii.isUpper(s[0]);
    for (s) |c| if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c))) {
        all_caps = false;
    };
    if (all_caps) {
        for (out) |*c| c.* = std.ascii.toLower(c.*);
        return out;
    }
    // A leading run of capitals is an acronym: all but its last letter,
    // when a lowercase letter follows, are lowered (URLPattern: urlPattern).
    var n: usize = 0;
    while (n < s.len and std.ascii.isUpper(s[n])) n += 1;
    if (n > 1 and n < s.len and std.ascii.isLower(s[n])) n -= 1;
    if (n == 0) return out;
    for (out[0..n]) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

fn upperFirst(a: Allocator, s: []const u8) ![]const u8 {
    if (s.len == 0) return s;
    var out = try a.dupe(u8, s);
    out[0] = std.ascii.toUpper(out[0]);
    return out;
}

/// snake_case: words split at case changes and acronyms
/// (R2HTTPMetadata: r2_http_metadata).
fn snake(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s, 0..) |c, i| {
        if (!std.ascii.isAlphanumeric(c)) {
            if (out.items.len > 0 and out.items[out.items.len - 1] != '_') try out.append(a, '_');
            continue;
        }
        if (std.ascii.isUpper(c) and i > 0 and out.items.len > 0 and out.items[out.items.len - 1] != '_') {
            const prev = s[i - 1];
            const next_lower = i + 1 < s.len and std.ascii.isLower(s[i + 1]);
            if (std.ascii.isLower(prev) or std.ascii.isDigit(prev) or (std.ascii.isUpper(prev) and next_lower))
                try out.append(a, '_');
        }
        try out.append(a, std.ascii.toLower(c));
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '_') _ = out.pop();
    if (out.items.len == 0) return "_";
    if (std.ascii.isDigit(out.items[0])) try out.insert(a, 0, '_');
    return out.items;
}

/// `s` inside a Zig string literal.
fn esc(a: Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, s, "\\\"") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (c == '\\' or c == '"') try out.append(a, '\\');
        try out.append(a, c);
    }
    return out.items;
}

fn memberName(a: Allocator, s: []const u8) ![]const u8 {
    return lowerFirst(a, try camel(a, s));
}

/// The Zig type name of an IR path, unique in the file: `rawTypeName`,
/// with `_` appended until it's free.
fn typeName(g: *Gen, path: []const u8) ![]const u8 {
    const a = g.a;
    if (g.type_names.get(path)) |n| return n;
    if (g.used_type_names.count() == 0) {
        for ([_][]const u8{ "std", "rt", "shim", "tsgen", "Any", "panic", "exports" }) |r| try g.used_type_names.put(a, r, {});
        // `err` first: it's in every module that awaits or throws.
        try g.type_names.put(a, "err", "JsError");
        try g.used_type_names.put(a, "JsError", {});
        if (eql(path, "err")) return "JsError";
    }
    var n = try g.rawTypeName(path);
    while (g.used_type_names.contains(n)) n = try std.fmt.allocPrint(a, "{s}_", .{n});
    try g.used_type_names.put(a, n, {});
    try g.type_names.put(a, path, n);
    return n;
}

/// The Zig type name of an IR path: dots become `_`, a module specifier
/// its name (`"cloudflare:workers".DurableObject`: Workers_DurableObject).
fn rawTypeName(g: *Gen, path: []const u8) ![]const u8 {
    const a = g.a;
    if (eql(path, "err")) return "JsError";
    var out: std.ArrayList(u8) = .empty;
    var rest = path;
    if (rest.len > 0 and rest[0] == '"') {
        const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse rest.len;
        var spec = rest[1..end];
        if (std.mem.indexOfScalar(u8, spec, ':')) |i| spec = spec[i + 1 ..];
        try out.appendSlice(a, try upperFirst(a, try camel(a, spec)));
        rest = if (end + 1 < rest.len) rest[end + 2 ..] else "";
        if (rest.len > 0) try out.append(a, '_');
    }
    var it = std.mem.splitScalar(u8, rest, '.');
    var first = true;
    while (it.next()) |seg| {
        if (!first) try out.append(a, '_');
        first = false;
        try out.appendSlice(a, try camel(a, seg));
    }
    const n = out.items;
    if (!validIdent(n) or eql(n, "Error") or eql(n, "Callback")) return std.fmt.allocPrint(a, "Js{s}", .{n});
    return n;
}

// ---------------------------------------------------------------------------

pub fn init(a: Allocator, docs: []const Value) Error!Gen {
    var g: Gen = .{ .a = a };
    const p = get(docs[0], "profile") orelse return error.Profile;
    if (!eql(str(p, "str"), "linear+utf8") or !eql(str(p, "handles"), "linear") or !eql(str(p, "results"), "multi") or
        !eql(str(p, "throws"), "tag") or !eql(str(p, "jspi"), "on") or !eql(str(p, "memory"), "32")) return error.Profile;
    for (docs, 0..) |d, di| {
        for (items(get(d, "decls"))) |decl| {
            const path = str(decl, "path");
            const e = try g.decls.getOrPut(a, path);
            if (!e.found_existing) {
                e.value_ptr.* = decl;
                try g.decl_order.append(a, path);
            }
        }
        for (items(get(d, "members"))) |m| try g.members.append(a, m);
        if (di == 0) {
            g.main_decls = g.decl_order.items.len;
            g.main_members = g.members.items.len;
        }
    }
    for (g.members.items, 0..) |m, i| {
        if (eql(str(m, "role"), "export")) {
            if (optStr(m, "owner")) |o| try g.exported_classes.put(a, o, {});
        }
        const k = try g.ownerKey(m);
        const e = try g.by_owner.getOrPut(a, k);
        if (!e.found_existing) e.value_ptr.* = .empty;
        try e.value_ptr.append(a, i);
    }
    return g;
}

fn ownerKey(g: *Gen, m: Value) ![]const u8 {
    if (optStr(m, "owner")) |o| return o;
    const ns = items(get(m, "namespace"));
    if (ns.len == 0) return "";
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(g.a, "ns:");
    for (ns, 0..) |s, i| {
        if (i > 0) try out.append(g.a, '.');
        try out.appendSlice(g.a, s.string);
    }
    return out.items;
}

fn ownerMembers(g: *Gen, k: []const u8) []const usize {
    const l = g.by_owner.getPtr(k) orelse return &.{};
    return l.items;
}

// ---- selection ------------------------------------------------------------

/// Limits the bindings to `roots` (declarations, or global members by
/// name) and everything their members reach; the module's exports and the
/// runtime's declarations always count. No roots: everything the input
/// declares, and what that reaches in its libraries.
pub fn select(g: *Gen, roots: ?[]const []const u8) !void {
    var queue: std.ArrayList([]const u8) = .empty;
    var globals: std.StringHashMapUnmanaged(void) = .empty;
    const all = roots == null;
    if (all) {
        for (g.decl_order.items[0..g.main_decls]) |p| try g.addDecl(&queue, p);
    }
    for (roots orelse &.{}) |r| {
        if (g.decls.contains(r)) try g.addDecl(&queue, r) else try globals.put(g.a, r, {});
    }
    try g.addDecl(&queue, "TsgenObject");
    for (g.members.items) |m| if (eql(str(m, "role"), "export")) try g.walk(&queue, get(m, "sig"));
    for (g.ownerMembers("")) |i| {
        const m = g.members.items[i];
        if (!eql(str(m, "role"), "import")) continue;
        if ((all and i < g.main_members) or globals.contains(str(m, "name"))) {
            try g.global_sel.put(g.a, i, {});
            try g.walk(&queue, get(m, "sig"));
        }
    }
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const p = queue.items[qi];
        const d = g.decls.get(p).?;
        for (items(get(d, "extends"))) |e| try g.addDecl(&queue, baseName(e.string));
        for (g.ownerMembers(p)) |i| {
            const m = g.members.items[i];
            if (eql(str(m, "role"), "import")) try g.walk(&queue, get(m, "sig"));
        }
        if (eql(str(d, "kind"), "enum")) try g.walk(&queue, get(d, "layout"));
        if (eql(str(d, "kind"), "namespace")) {
            const k = try std.fmt.allocPrint(g.a, "ns:{s}", .{p});
            for (g.ownerMembers(k)) |i| try g.walk(&queue, get(g.members.items[i], "sig"));
        }
    }
}

fn baseName(s: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, s, '<')) |i| s[0..i] else s;
}

fn addDecl(g: *Gen, queue: *std.ArrayList([]const u8), path: []const u8) !void {
    if (!g.decls.contains(path) or g.selected.contains(path)) return;
    try g.selected.put(g.a, path, {});
    try queue.append(g.a, path);
}

fn walk(g: *Gen, queue: *std.ArrayList([]const u8), v: ?Value) !void {
    const x = v orelse return;
    switch (x) {
        .array => |l| for (l.items) |e| try g.walk(queue, e),
        .object => |o| {
            if (o.get("path")) |p| if (p == .string) try g.addDecl(queue, p.string);
            var it = o.iterator();
            while (it.next()) |e| {
                if (eql(e.key_ptr.*, "args")) continue;
                if (e.value_ptr.* == .object or e.value_ptr.* == .array) try g.walk(queue, e.value_ptr.*);
            }
        },
        else => {},
    }
}

fn isClassLike(g: *Gen, path: []const u8) bool {
    const d = g.decls.get(path) orelse return false;
    const k = str(d, "kind");
    return (eql(k, "class") or eql(k, "interface")) and g.selected.contains(path) and !g.exported_classes.contains(path);
}

// ---- codecs ---------------------------------------------------------------

const Pos = enum { in, out };

/// A value's codec and Zig type. `T` names the comptime type a result's
/// erased type parameter decodes as.
const C = struct {
    codec: []const u8,
    zt: []const u8,
};

fn unsupported(g: *Gen, comptime f: []const u8, args: anytype) Error {
    g.why = std.fmt.allocPrint(g.a, f, args) catch "out of memory";
    return error.Unsupported;
}

const Scalar = struct { zig: []const u8, size: usize };

fn scalarOf(s: []const u8) ?Scalar {
    const table = .{
        .{ "bool", "bool", 1 }, .{ "i8", "i8", 1 },   .{ "u8", "u8", 1 },   .{ "i16", "i16", 2 },
        .{ "u16", "u16", 2 },   .{ "i32", "i32", 4 }, .{ "u32", "u32", 4 }, .{ "i53", "i64", 8 },
        .{ "u53", "u64", 8 },   .{ "i64", "i64", 8 }, .{ "u64", "u64", 8 }, .{ "f32", "f32", 4 },
        .{ "f64", "f64", 8 },
    };
    inline for (table) |t| if (eql(s, t[0])) return .{ .zig = t[1], .size = t[2] };
    return null;
}

fn opt(g: *Gen, r: Value, t: []const u8) ![]const u8 {
    if (!nullable(r) or eql(t, "anytype")) return t;
    return std.fmt.allocPrint(g.a, "?{s}", .{t});
}

fn codec(g: *Gen, r: Value, pos: Pos, T: ?[]const u8) Error!C {
    const a = g.a;
    const n = nullable(r);
    const k = kind(r);
    if (eql(k, "unit")) return .{ .codec = "rt.Unit", .zt = "void" };
    if (eql(k, "scalar")) {
        const s = scalarOf(str(r, "scalar")) orelse return g.unsupported("scalar {s}", .{str(r, "scalar")});
        if (!n) return .{ .codec = try std.fmt.allocPrint(a, "rt.Scalar({s})", .{s.zig}), .zt = s.zig };
        const niche = if (get(r, "niche")) |x| try std.fmt.allocPrint(a, "{d}", .{x.integer}) else "null";
        return .{ .codec = try std.fmt.allocPrint(a, "rt.OptScalar({s}, {s})", .{ s.zig, niche }), .zt = try opt(g, r, s.zig) };
    }
    if (eql(k, "str")) return .{ .codec = if (n) "rt.OptStr" else "rt.Str", .zt = if (n) "?[]const u8" else "[]const u8" };
    if (eql(k, "enum")) {
        const L = get(r, "enum").?;
        const p = str(L, "path");
        if (std.mem.endsWith(u8, p, "??")) return g.unsupported("T??", .{});
        const name = try g.useEnum(L);
        const shape = str(get(L, "shape").?, "kind");
        if (eql(shape, "index")) return .{ .codec = try std.fmt.allocPrint(a, "rt.{s}({s})", .{ if (n) "OptEnum" else "Enum", name }), .zt = try opt(g, r, name) };
        if (eql(shape, "carrier")) {
            if (n) return g.unsupported("a nullable carrier enum", .{});
            return .{ .codec = try std.fmt.allocPrint(a, "rt.Carrier({s})", .{name}), .zt = name };
        }
        return .{ .codec = try std.fmt.allocPrint(a, "rt.{s}({s})", .{ if (n) "OptPayload" else "Payload", name }), .zt = try opt(g, r, name) };
    }
    if (eql(k, "host")) {
        const of = str(r, "of");
        if (eql(of, "class") or eql(of, "interface")) {
            const name = if (g.isClassLike(str(r, "path"))) try g.typeName(str(r, "path")) else "rt.Object";
            return .{ .codec = try std.fmt.allocPrint(a, "rt.{s}({s})", .{ if (n) "OptHost" else "Host", name }), .zt = try opt(g, r, name) };
        }
        if (eql(of, "box")) {
            if (get(r, "inner")) |inner| if (isKind(inner, "str"))
                return .{ .codec = if (n) "rt.OptStrBox" else "rt.StrBox", .zt = if (n) "?[]const u8" else "[]const u8" };
            return g.dyn(r, pos, null);
        }
        if (eql(of, "any")) return g.dyn(r, pos, null);
        if (eql(of, "future")) {
            if (pos == .in) return .{ .codec = try std.fmt.allocPrint(a, "rt.{s}(rt.Object)", .{if (n) "OptHost" else "Host"}), .zt = try opt(g, r, "rt.Object") };
            return g.unsupported("a future in a nested position", .{});
        }
        return g.unsupported("host {s}", .{of});
    }
    if (eql(k, "erased")) return g.dyn(r, pos, T);
    if (eql(k, "array")) {
        const e = try g.elemCodec(get(r, "elem").?, pos, T);
        const zt = if (eql(e.zt, "anytype")) "anytype" else try opt(g, r, try std.fmt.allocPrint(a, "[]const {s}", .{e.zt}));
        return .{ .codec = try std.fmt.allocPrint(a, "rt.{s}({s})", .{ if (n) "OptArr" else "Arr", e.codec }), .zt = zt };
    }
    if (eql(k, "vec")) {
        const s = scalarOf(str(r, "elem")) orelse return g.unsupported("vec {s}", .{str(r, "elem")});
        if (boolean(r, "writeback")) return g.unsupported("a writeback sequence", .{});
        return .{ .codec = try std.fmt.allocPrint(a, "rt.{s}({s})", .{ if (n) "OptVec" else "Vec", s.zig }), .zt = try opt(g, r, try std.fmt.allocPrint(a, "[]const {s}", .{s.zig})) };
    }
    if (eql(k, "tuple")) {
        if (n) return g.unsupported("a nullable tuple", .{});
        var cs: std.ArrayList(u8) = .empty;
        var zs: std.ArrayList(u8) = .empty;
        var any = false;
        for (items(get(r, "elems")), 0..) |el, i| {
            const c = try g.codec(el, pos, T);
            if (i > 0) {
                try cs.appendSlice(a, ", ");
                try zs.appendSlice(a, ", ");
            }
            try cs.appendSlice(a, c.codec);
            try zs.appendSlice(a, c.zt);
            if (eql(c.zt, "anytype")) any = true;
        }
        return .{ .codec = try std.fmt.allocPrint(a, "rt.Tuple(.{{ {s} }})", .{cs.items}), .zt = if (any) "anytype" else try std.fmt.allocPrint(a, "struct {{ {s} }}", .{zs.items}) };
    }
    if (eql(k, "fn")) {
        if (pos == .out) return g.unsupported("a JS function as a result", .{});
        const name = try g.useCallback(r);
        if (n) return .{ .codec = try std.fmt.allocPrint(a, "rt.OptCallback({s})", .{name}), .zt = try std.fmt.allocPrint(a, "?{s}", .{name}) };
        return .{ .codec = name, .zt = name };
    }
    return g.unsupported("{s}", .{k});
}

/// `Any`, an erased type parameter or a box: anytype in, `rt.Any` out, or
/// T when the member decodes its result as a comptime type.
fn dyn(g: *Gen, r: Value, pos: Pos, T: ?[]const u8) !C {
    const n = nullable(r);
    if (pos == .in) return .{ .codec = if (n) "rt.OptDyn" else "rt.Dyn", .zt = "anytype" };
    if (T) |t| return .{
        .codec = try std.fmt.allocPrint(g.a, "rt.{s}({s})", .{ if (n) "OptErased" else "Erased", t }),
        .zt = if (n) try std.fmt.allocPrint(g.a, "?{s}", .{t}) else t,
    };
    return .{ .codec = if (n) "rt.OptDyn" else "rt.Dyn", .zt = if (n) "?rt.Any" else "rt.Any" };
}

/// An `arr<T>` element: what has a memory and table layout (IR.md §11).
fn elemCodec(g: *Gen, r: Value, pos: Pos, T: ?[]const u8) Error!C {
    const k = kind(r);
    if (eql(k, "str")) {
        if (nullable(r)) return g.unsupported("str? in arr", .{});
        return g.codec(r, pos, T);
    }
    if (eql(k, "scalar")) {
        if (nullable(r)) return g.unsupported("a nullable scalar in arr", .{});
        return g.codec(r, pos, T);
    }
    if (eql(k, "enum")) {
        const L = get(r, "enum").?;
        if (!eql(str(get(L, "shape").?, "kind"), "index") or nullable(r)) return g.unsupported("arr of {s}", .{str(r, "ty")});
        return g.codec(r, pos, T);
    }
    if (eql(k, "host")) {
        const of = str(r, "of");
        if (eql(of, "box")) if (get(r, "inner")) |inner| if (isKind(inner, "str")) return g.unsupported("Str in arr", .{});
        if (eql(of, "class") or eql(of, "interface") or eql(of, "any") or eql(of, "box")) return g.codec(r, pos, T);
        return g.unsupported("arr of {s}", .{str(r, "ty")});
    }
    if (eql(k, "erased")) return g.codec(r, pos, T);
    if (eql(k, "tuple") and !nullable(r)) {
        for (items(get(r, "elems"))) |el| _ = try g.elemCodec(el, pos, T);
        return g.codec(r, pos, T);
    }
    return g.unsupported("arr of {s}", .{str(r, "ty")});
}

// ---- the shim's imports ---------------------------------------------------

fn importOp(g: *Gen, module: []const u8, name: []const u8, params: []const []const u8, results: []const []const u8, throws: ?Tag) ![]const u8 {
    const c = try std.fmt.allocPrint(g.a, "tsgen:{s} {s}", .{ module, name });
    const e = try g.imports.getOrPut(g.a, c);
    if (!e.found_existing) e.value_ptr.* = .{ .c = c, .module = module, .name = name, .params = params, .results = results, .throws = throws };
    return c;
}

fn wireZig(w: []const u8) []const u8 {
    return if (eql(w, "externref")) "i32" else w;
}

/// The extern declaration of an import through the shim: slots for
/// externrefs, and a return area pointer when it throws or has more than
/// one result, in which case a throw returns a status.
fn externDecl(g: *Gen, e: Import) ![]const u8 {
    var ps: std.ArrayList(u8) = .empty;
    for (e.params, 0..) |w, i| {
        if (i > 0) try ps.appendSlice(g.a, ", ");
        try ps.print(g.a, "__p{d}: {s}", .{ i, wireZig(w) });
    }
    const use_ret = e.throws != null or e.results.len > 1;
    if (use_ret) try ps.print(g.a, "{s}__ret: i32", .{if (e.params.len > 0) ", " else ""});
    const ret = if (e.throws != null) "i32" else if (e.results.len == 1) wireZig(e.results[0]) else "void";
    return std.fmt.allocPrint(g.a, "    extern \"shim\" fn @\"{s}\"({s}) {s};\n", .{ try esc(g.a, e.c), ps.items, ret });
}

fn tagOf(g: *Gen, throws: ?Value) !?Tag {
    const t = throws orelse return null;
    const tag = get(t, "tag").?;
    const L = get(t, "enum").?;
    return .{ .module = str(tag, "module"), .name = str(tag, "name"), .params = try g.enumWire(L) };
}

fn enumWire(g: *Gen, L: Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(g.a, "i32");
    for (items(get(get(L, "shape").?, "slots"))) |s| try out.append(g.a, s.string);
    return out.items;
}

// ---- enums ----------------------------------------------------------------

fn useEnum(g: *Gen, L: Value) Error![]const u8 {
    const p = str(L, "path");
    if (g.bad_enums.get(p)) |why| return g.unsupported("{s}", .{why});
    if (!g.enums.contains(p)) {
        try g.enums.put(g.a, p, L);
        // An enum the bindings can't declare takes its users with it.
        g.checkEnum(L) catch |e| switch (e) {
            error.Unsupported => {
                const why = try std.fmt.allocPrint(g.a, "enum {s}: {s}", .{ p, g.why });
                try g.bad_enums.put(g.a, p, why);
                _ = g.enums.orderedRemove(p);
                g.why = why;
                return e;
            },
            else => return e,
        };
    }
    return g.typeName(p);
}

fn checkEnum(g: *Gen, L: Value) Error!void {
    const shape = get(L, "shape").?;
    const sk = str(shape, "kind");
    if (eql(sk, "carrier")) {
        const s = scalarOf(str(shape, "scalar")) orelse return g.unsupported("carrier {s}", .{str(shape, "scalar")});
        if (s.zig[0] == 'f' or eql(s.zig, "bool")) return g.unsupported("carrier {s}", .{s.zig});
    }
    if (!eql(sk, "payload")) return;
    for (items(get(L, "arms"))) |arm| for (items(get(arm, "payload"))) |p| {
        const c = try g.codec(p, if (isKind(p, "fn")) .in else .out, null);
        if (eql(c.zt, "anytype")) return g.unsupported("enum arm {s}", .{str(arm, "name")});
    };
}

fn throwType(g: *Gen, L: Value) ![]const u8 {
    try g.throw_enums.put(g.a, str(L, "path"), {});
    return g.useEnum(L);
}

fn emitEnum(g: *Gen, L: Value, as_error: bool) !void {
    const a = g.a;
    const name = try g.typeName(str(L, "path"));
    const shape = get(L, "shape").?;
    const sk = str(shape, "kind");
    var o: std.ArrayList(u8) = .empty;
    var fields: std.StringHashMapUnmanaged(void) = .empty;
    const arms = items(get(L, "arms"));
    var names: std.ArrayList([]const u8) = .empty;
    for (arms) |arm| {
        var f = try snake(a, str(arm, "name"));
        while (fields.contains(f)) f = try std.fmt.allocPrint(a, "{s}_", .{f});
        try fields.put(a, f, {});
        try names.append(a, f);
    }
    try o.print(a, "/// `{s}`\n", .{str(L, "path")});
    if (eql(sk, "index")) {
        try o.print(a, "pub const {s} = enum(i32) {{\n", .{name});
        for (arms, names.items) |arm, f| try o.print(a, "    {s} = {d},\n", .{ try ident(a, f), int(arm, "index") });
        try o.appendSlice(a, "};\n");
    } else if (eql(sk, "carrier")) {
        const s = scalarOf(str(shape, "scalar")) orelse return g.unsupported("carrier {s}", .{str(shape, "scalar")});
        if (s.zig[0] == 'f' or eql(s.zig, "bool")) return g.unsupported("carrier {s}", .{s.zig});
        try o.print(a, "pub const {s} = enum({s}) {{\n", .{ name, s.zig });
        for (arms, names.items) |arm, f| try o.print(a, "    {s} = {d},\n", .{ try ident(a, f), int(arm, "index") });
        try o.appendSlice(a, "    _,\n};\n");
    } else {
        var arm_codecs: std.ArrayList(u8) = .empty;
        var all_str = true;
        try o.print(a, "pub const {s} = union(enum(i32)) {{\n", .{name});
        for (arms, names.items) |arm, f| {
            const payload = items(get(arm, "payload"));
            var zt: []const u8 = "void";
            var cd: []const u8 = "rt.Unit";
            if (payload.len == 1) {
                const p = payload[0];
                const c = try g.codec(p, if (isKind(p, "fn")) .in else .out, null);
                zt = c.zt;
                cd = c.codec;
                if (!eql(cd, "rt.StrBox")) all_str = false;
            } else if (payload.len > 1) {
                all_str = false;
                var cs: std.ArrayList(u8) = .empty;
                var zs: std.ArrayList(u8) = .empty;
                for (payload, 0..) |p, i| {
                    const c = try g.codec(p, if (isKind(p, "fn")) .in else .out, null);
                    if (i > 0) {
                        try cs.appendSlice(a, ", ");
                        try zs.appendSlice(a, ", ");
                    }
                    try cs.appendSlice(a, c.codec);
                    try zs.appendSlice(a, c.zt);
                }
                cd = try std.fmt.allocPrint(a, "rt.Tuple(.{{ {s} }})", .{cs.items});
                zt = try std.fmt.allocPrint(a, "struct {{ {s} }}", .{zs.items});
            } else all_str = false;
            if (eql(zt, "anytype")) return g.unsupported("enum arm {s}", .{str(arm, "name")});
            try o.print(a, "    {s}: {s} = {d},\n", .{ try ident(a, f), zt, int(arm, "index") });
            var sl: std.ArrayList(u8) = .empty;
            for (items(get(arm, "slots")), 0..) |s, i| try sl.print(a, "{s}{d}", .{ if (i > 0) ", " else "", s.integer });
            try arm_codecs.print(a, "        .{{ .codec = {s}, .slots = &.{{{s}}} }},\n", .{ cd, sl.items });
        }
        var slots: std.ArrayList(u8) = .empty;
        for (items(get(shape, "slots")), 0..) |s, i| try slots.print(a, "{s}{s}", .{ if (i > 0) ", " else "", wireZig(s.string) });
        try o.print(a, "\n    pub const tw_slots = [_]type{{{s}}};\n    pub const tw_arms = [_]rt.Arm{{\n{s}    }};\n", .{ slots.items, arm_codecs.items });
        if (as_error) {
            var es: std.ArrayList(u8) = .empty;
            var en: std.ArrayList(u8) = .empty;
            var fallback: []const u8 = names.items[names.items.len - 1];
            for (arms, names.items, 0..) |arm, f, i| {
                const sep = if (i > 0) ", " else "";
                try es.print(a, "{s}{s}", .{ sep, try ident(a, str(arm, "name")) });
                try en.print(a, "{s}\"{s}\"", .{ sep, str(arm, "name") });
                if (boolean(arm, "fallback")) fallback = f;
            }
            try o.print(a,
                \\
                \\    /// The arms as Zig errors: what a call that throws this returns.
                \\    pub const Error = error{{ {s} }};
                \\    pub const tw_errors = [_][]const u8{{ {s} }};
                \\    pub const tw_fallback = "{s}";
                \\
                \\    /// The payload of the last of these errors, until the request ends.
                \\    pub fn last() ?{s} {{
                \\        return rt.lastError({s});
                \\    }}
                \\
            , .{ es.items, en.items, fallback, name, name });
            if (all_str) try o.print(a,
                \\
                \\    /// The error's message.
                \\    pub fn message(self: {s}) []const u8 {{
                \\        return switch (self) {{
                \\            inline else => |m| m,
                \\        }};
                \\    }}
                \\
            , .{name});
        }
        try o.appendSlice(a, "};\n");
    }
    try g.out.appendSlice(a, o.items);
    try g.out.append(a, '\n');
}

// ---- callbacks ------------------------------------------------------------

/// The Callback type of a function type the app provides, emitted with its
/// trampoline when first used.
fn useCallback(g: *Gen, r: Value) Error![]const u8 {
    const a = g.a;
    const ty = str(r, "ty");
    // One Callback per trampoline: the bridge calls it by that name.
    const key = str(r, "trampoline");
    if (key.len == 0) return g.unsupported("callback {s} has no trampoline", .{ty});
    if (g.callbacks.get(key)) |n| return n orelse g.unsupported("callback {s}", .{ty});
    try g.callbacks.put(a, key, null);
    const trampoline = key;
    const op = get(r, "op") orelse return g.unsupported("callback {s} has no trampoline", .{ty});
    var name = try g.callbackName(key["tw:call:".len..]);
    while (g.top_names.contains(name) or g.used_type_names.contains(name)) name = try std.fmt.allocPrint(a, "{s}_", .{name});
    try g.used_type_names.put(a, name, {});
    // The parameters as the app's function receives them.
    var ps: std.ArrayList(u8) = .empty;
    var wires: std.ArrayList(u8) = .empty;
    var args: std.ArrayList(u8) = .empty;
    try wires.appendSlice(a, "__env: i32");
    var nw: usize = 0;
    for (items(get(r, "params")), 0..) |p, i| {
        const c = try g.codec(p, .out, null);
        try ps.print(a, "{s}{s}", .{ if (i > 0) ", " else "", c.codec });
        for (items(get(p, "wire"))) |w| {
            try wires.print(a, ", __a{d}: {s}", .{ nw, wireZig(w.string) });
            try args.print(a, "{s}__a{d}", .{ if (nw > 0) ", " else "", nw });
            nw += 1;
        }
    }
    const res = get(r, "result").?;
    const results = try strs(a, get(get(op, "core").?, "results"));
    if (results.len > 1) return g.unsupported("callback {s} with several results", .{ty});
    var rc: []const u8 = undefined;
    if (isKind(res, "unit")) {
        rc = "rt.Unit";
    } else if (isHost(res, "future")) {
        if (!nullable(res)) return g.unsupported("a callback returning a future", .{});
        rc = "rt.NoFuture";
    } else rc = (try g.codec(res, .in, null)).codec;
    const rw = if (results.len == 1) wireZig(results[0]) else "void";
    const tramp = try std.fmt.allocPrint(a, "tramp {s}", .{name});
    try g.callback_code.print(a,
        \\/// A Zig function as `{s}`: `.init(ctx, f)` or `.fromFn(f)`.
        \\pub const {s} = rt.Callback(.{{ {s} }}, {s}, &@"{s}", "{s}");
        \\fn @"{s}"({s}) callconv(.c) {s} {{
        \\    return rt.tramp({s}, {s}, __env, .{{ {s} }});
        \\}}
        \\
        \\
    , .{ key["tw:call:".len..], name, ps.items, rc, tramp, try esc(a, trampoline), tramp, wires.items, rw, name, rw, args.items });
    var params: std.ArrayList([]const u8) = .empty;
    try params.append(a, "i32");
    for (items(get(r, "params"))) |p| for (items(get(p, "wire"))) |w| try params.append(a, w.string);
    try g.exports.append(a, .{ .c = try std.fmt.allocPrint(a, "tsgen:{s}", .{trampoline}), .name = trampoline, .params = params.items, .results = results, .throws = null });
    try g.callbacks.put(a, key, name);
    try g.top_names.put(a, name, {});
    return name;
}

fn callbackName(g: *Gen, ty: []const u8) ![]const u8 {
    // fn(Element)->future<unit>? : FnElement; the result is the type's
    // business, the parameters name it.
    const a = g.a;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "Fn");
    const open = std.mem.indexOfScalar(u8, ty, '(') orelse return "Fn";
    var depth: usize = 0;
    var end = open;
    for (ty[open..], open..) |c, i| {
        if (c == '(' or c == '<') depth += 1;
        if (c == ')' or c == '>') {
            depth -= 1;
            if (depth == 0) {
                end = i;
                break;
            }
        }
    }
    var word_start = true;
    for (ty[open + 1 .. end]) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try out.append(a, if (word_start) std.ascii.toUpper(c) else c);
            word_start = false;
        } else word_start = true;
    }
    return out.items;
}

// ---- members --------------------------------------------------------------

const Param = struct {
    name: []const u8,
    zt: []const u8,
    codec: []const u8,
};

const Member = struct {
    params: []const Param,
    generic: bool,
    ret: []const u8,
    body: []const u8,
    static: bool,
    throws: bool,
};

fn usesErased(r: Value) bool {
    if (isKind(r, "erased")) return true;
    if (isKind(r, "array")) return usesErased(get(r, "elem").?);
    if (isKind(r, "tuple")) {
        for (items(get(r, "elems"))) |e| if (usesErased(e)) return true;
    }
    return false;
}

fn errorSet(g: *Gen, x: ?[]const u8, y: ?[]const u8) !?[]const u8 {
    if (x == null) return if (y) |t| try std.fmt.allocPrint(g.a, "{s}.Error", .{t}) else null;
    if (y == null or eql(x.?, y.?)) return try std.fmt.allocPrint(g.a, "{s}.Error", .{x.?});
    return try std.fmt.allocPrint(g.a, "{s}.Error || {s}.Error", .{ x.?, y.? });
}

/// An imported member's Zig function, or error.Unsupported.
fn genMember(g: *Gen, m: Value, self_type: ?[]const u8, scope: *const std.StringHashMapUnmanaged(void)) Error!Member {
    const a = g.a;
    const sig = get(m, "sig").?;
    var this = false;
    var ps: std.ArrayList(Param) = .empty;
    var used: std.StringHashMapUnmanaged(void) = .empty;
    const result = if (items(get(sig, "results")).len > 0) get(items(get(sig, "results"))[0], "repr").? else Value{ .null = {} };
    const is_future = result != .null and isHost(result, "future");
    const value = if (is_future) get(result, "value").? else result;
    const generic_t = value != .null and usesErased(value);
    if (generic_t) {
        try ps.append(a, .{ .name = "T", .zt = "type", .codec = "" });
        try used.put(a, "T", {});
    }
    for (items(get(sig, "params"))) |p| {
        const role = str(p, "role");
        if (eql(role, "this")) {
            this = true;
            continue;
        }
        if (!eql(role, "param")) return g.unsupported("a {s} parameter", .{role});
        const repr = get(p, "repr").?;
        const meta = items(get(m, "params"));
        const idx: usize = @intCast(int(p, "index"));
        const raw = if (idx < meta.len) str(meta[idx], "name") else "";
        var name = try snake(a, if (raw.len > 0) raw else "p");
        while (!validIdent(name) or scope.contains(name) or g.top_names.contains(name) or used.contains(name) or eql(name, "self") or eql(name, "rt") or eql(name, "std") or eql(name, "shim"))
            name = try std.fmt.allocPrint(a, "{s}_", .{name});
        try used.put(a, name, {});
        const c = try g.codec(repr, .in, null);
        try ps.append(a, .{ .name = name, .zt = c.zt, .codec = c.codec });
    }
    if (this and self_type == null) return g.unsupported("an instance member without its class", .{});
    const th = get(sig, "throws");
    const thr_t: ?[]const u8 = if (th) |t| try g.throwType(get(t, "enum").?) else null;
    var res_codec: []const u8 = "rt.Unit";
    var ret: []const u8 = "void";
    const core = get(sig, "core").?;
    const core_params = try strs(a, get(core, "params"));
    const core_results = try strs(a, get(core, "results"));
    const tag = try g.tagOf(th);
    if (is_future) {
        const rej = get(result, "rejection").?;
        const rej_t = try g.throwType(rej);
        const v = if (isKind(value, "unit")) C{ .codec = "rt.Unit", .zt = "void" } else try g.codec(value, .out, if (generic_t) "T" else null);
        const take = get(result, "take").?;
        const err_op = get(result, "errorOp").?;
        const take_c = try g.importOp(str(take, "module"), str(take, "name"), &.{"externref"}, try strs(a, get(value, "wire")), null);
        const err_c = try g.importOp(str(err_op, "module"), str(err_op, "name"), &.{"externref"}, try g.enumWire(rej), null);
        res_codec = try std.fmt.allocPrint(a, "rt.Future({s}, shim.@\"{s}\", shim.@\"{s}\", {s})", .{ v.codec, try esc(a, take_c), try esc(a, err_c), rej_t });
        ret = try std.fmt.allocPrint(a, "{s}!{s}", .{ (try g.errorSet(rej_t, thr_t)).?, v.zt });
    } else if (result != .null) {
        const v = try g.codec(result, .out, if (generic_t) "T" else null);
        res_codec = v.codec;
        ret = if (thr_t) |t| try std.fmt.allocPrint(a, "{s}.Error!{s}", .{ t, v.zt }) else v.zt;
    } else if (thr_t) |t| {
        ret = try std.fmt.allocPrint(a, "{s}.Error!void", .{t});
    }
    const module = optStr(m, "module") orelse "tw:js/global";
    const c = try g.importOp(module, str(m, "key"), core_params, core_results, tag);
    var codecs: std.ArrayList(u8) = .empty;
    var args: std.ArrayList(u8) = .empty;
    if (this) {
        try codecs.print(a, "rt.Host({s})", .{self_type.?});
        try args.appendSlice(a, "self");
    }
    for (ps.items) |p| {
        if (eql(p.zt, "type")) continue;
        if (codecs.items.len > 0) {
            try codecs.appendSlice(a, ", ");
            try args.appendSlice(a, ", ");
        }
        try codecs.appendSlice(a, p.codec);
        try args.appendSlice(a, p.name);
    }
    const body = try std.fmt.allocPrint(a, "return rt.call(shim.@\"{s}\", .{{ {s} }}, {s}, {s}, .{{ {s} }});", .{ try esc(a, c), codecs.items, res_codec, thr_t orelse "null", args.items });
    var generic = generic_t;
    for (ps.items) |p| if (eql(p.zt, "anytype")) {
        generic = true;
    };
    return .{ .params = ps.items, .generic = generic, .ret = ret, .body = body, .static = !this, .throws = thr_t != null or is_future };
}

fn docComment(g: *Gen, m: Value, indent: []const u8) ![]const u8 {
    const d = optStr(m, "doc") orelse return "";
    var o: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, d, '\n');
    while (it.next()) |l| {
        if (l.len == 0) try o.print(g.a, "{s}///\n", .{indent}) else try o.print(g.a, "{s}/// {s}\n", .{ indent, l });
    }
    return o.items;
}

fn fnText(g: *Gen, doc: []const u8, name: []const u8, self_type: ?[]const u8, mem: Member, indent: []const u8) ![]const u8 {
    const a = g.a;
    var ps: std.ArrayList(u8) = .empty;
    if (!mem.static) try ps.print(a, "self: {s}", .{self_type.?});
    for (mem.params) |p| {
        if (ps.items.len > 0) try ps.appendSlice(a, ", ");
        if (eql(p.zt, "type")) try ps.print(a, "comptime {s}: type", .{p.name}) else try ps.print(a, "{s}: {s}", .{ p.name, p.zt });
    }
    return std.fmt.allocPrint(a, "{s}{s}pub fn {s}({s}) {s} {{\n{s}    {s}\n{s}}}\n", .{ doc, indent, try ident(a, name), ps.items, mem.ret, indent, mem.body, indent });
}

const Scope = struct {
    /// The struct's Zig type, for an instance member's receiver.
    self_type: ?[]const u8,
    /// An interface with `@js(object) new()`: a plain object.
    object: bool = false,
    indent: []const u8 = "    ",
};

/// A struct's (or the file's) members: functions, getters and setters,
/// and for a plain object its `init` over the settable properties.
fn emitMembers(g: *Gen, ms: []const Value, sc: Scope, o: *std.ArrayList(u8), names: *std.StringHashMapUnmanaged(void)) !void {
    const a = g.a;
    // Zig names first: parameters can't shadow them.
    const Planned = struct { m: Value, name: []const u8 };
    var plan: std.ArrayList(Planned) = .empty;
    var getters: std.StringHashMapUnmanaged([]const u8) = .empty;
    var object_new: ?Value = null;
    for (ms) |m| {
        const k = str(m, "kind");
        var base: []const u8 = undefined;
        if (eql(k, "new")) {
            if (sc.object and items(get(get(m, "sig").?, "params")).len == 0) {
                object_new = m;
                continue;
            }
            const v = str(m, "variant");
            base = if (std.mem.startsWith(u8, v, "new")) try std.fmt.allocPrint(a, "init{s}", .{v[3..]}) else try memberName(a, v);
        } else if (eql(k, "get")) {
            base = try memberName(a, str(m, "name"));
        } else if (eql(k, "set")) {
            const v = optStr(m, "variant") orelse str(m, "name");
            base = try std.fmt.allocPrint(a, "set{s}", .{try upperFirst(a, try camel(a, if (eql(v, str(m, "name"))) str(m, "name") else v))});
        } else {
            base = try memberName(a, optStr(m, "variant") orelse str(m, "name"));
        }
        if (eql(base, "self")) base = "self_";
        var name = base;
        if (eql(k, "get") and names.contains(name)) name = try std.fmt.allocPrint(a, "get{s}", .{try upperFirst(a, name)});
        while (names.contains(name)) name = try std.fmt.allocPrint(a, "{s}_", .{name});
        try names.put(a, name, {});
        if (eql(k, "get")) try getters.put(a, str(m, "name"), name);
        try plan.append(a, .{ .m = m, .name = name });
    }
    if (object_new != null) try names.put(a, "init", {});
    const Prop = struct { field: []const u8, zt: []const u8, setter: []const u8, throws: bool };
    var props: std.ArrayList(Prop) = .empty;
    var prop_seen: std.StringHashMapUnmanaged(void) = .empty;
    for (plan.items) |p| {
        const mem = g.genMember(p.m, sc.self_type, names) catch |e| switch (e) {
            error.Unsupported => {
                try g.skipped.append(a, .{ str(p.m, "key"), g.why });
                continue;
            },
            else => return e,
        };
        g.emitted += 1;
        try o.appendSlice(a, try g.fnText(try g.docComment(p.m, sc.indent), p.name, sc.self_type, mem, sc.indent));
        if (sc.object and eql(str(p.m, "kind"), "set") and mem.params.len == 1 and !mem.generic and !mem.static) {
            const prop = str(p.m, "name");
            if (!prop_seen.contains(prop)) {
                try prop_seen.put(a, prop, {});
                try props.append(a, .{ .field = try snake(a, prop), .zt = mem.params[0].zt, .setter = p.name, .throws = mem.throws });
            }
        }
    }
    if (object_new) |m| {
        const mem = g.genMember(m, sc.self_type, names) catch |e| switch (e) {
            error.Unsupported => {
                try g.skipped.append(a, .{ str(m, "key"), g.why });
                return;
            },
            else => return e,
        };
        g.emitted += 1;
        var fields: std.ArrayList(u8) = .empty;
        var sets: std.ArrayList(u8) = .empty;
        for (props.items) |p| {
            const zt = if (p.zt[0] == '?') p.zt else try std.fmt.allocPrint(a, "?{s}", .{p.zt});
            try fields.print(a, " {s}: {s} = null,", .{ try ident(a, p.field), zt });
            try sets.print(a, "{s}    if (__props.{s}) |__v| __o.{s}(__v){s};\n", .{ sc.indent, try ident(a, p.field), try ident(a, p.setter), if (p.throws) " catch {}" else "" });
        }
        const new_ret = if (mem.throws) "try " else "";
        const discard = if (props.items.len == 0) try std.fmt.allocPrint(a, "{s}    _ = __props;\n", .{sc.indent}) else "";
        try o.print(a,
            \\{s}/// A plain object with the properties given.
            \\{s}pub fn init(__props: struct {{{s} }}) {s}{s} {{
            \\{s}    const __o: {s} = {s}{s};
            \\{s}{s}{s}    return __o;
            \\{s}}}
            \\
        , .{ sc.indent, sc.indent, fields.items, if (mem.throws) "!" else "", sc.self_type.?, sc.indent, sc.self_type.?, new_ret, mem.body["return ".len .. mem.body.len - 1], sets.items, discard, sc.indent, sc.indent });
    }
}

fn ancestorsInto(g: *Gen, path: []const u8, out: *std.ArrayList([]const u8)) !void {
    const d = g.decls.get(path) orelse return;
    for (items(get(d, "extends"))) |e| {
        const q = baseName(e.string);
        if (!g.decls.contains(q)) continue;
        for (out.items) |x| if (eql(x, q)) break else {} else {
            try out.append(g.a, q);
            try g.ancestorsInto(q, out);
            continue;
        }
    }
}

fn emitClass(g: *Gen, path: []const u8) !void {
    const a = g.a;
    const d = g.decls.get(path).?;
    const name = try g.typeName(path);
    var owners: std.ArrayList([]const u8) = .empty;
    try owners.append(a, path);
    try g.ancestorsInto(path, &owners);
    var ms: std.ArrayList(Value) = .empty;
    for (owners.items, 0..) |o, oi| for (g.ownerMembers(o)) |i| {
        const m = g.members.items[i];
        if (!eql(str(m, "role"), "import")) continue;
        // A parent's constructors and statics stay its own.
        if (oi > 0 and (eql(str(m, "kind"), "new") or boolean(m, "static"))) continue;
        try ms.append(a, m);
    };
    var o: std.ArrayList(u8) = .empty;
    const doc = try g.docComment(d, "");
    try o.appendSlice(a, if (doc.len > 0) doc else try std.fmt.allocPrint(a, "/// `{s}`\n", .{path}));
    try o.print(a,
        \\pub const {s} = struct {{
        \\    ref: rt.Ref,
        \\
        \\    /// Releases the JS value now rather than when the request ends.
        \\    pub fn deinit(self: {s}) void {{
        \\        self.ref.deinit();
        \\    }}
        \\    /// The JS value, kept past the end of the request.
        \\    pub fn keep(self: {s}) {s} {{
        \\        return .{{ .ref = self.ref.keep() }};
        \\    }}
        \\    /// The same JS value as another type, unchecked.
        \\    pub fn as(self: {s}, comptime T: type) T {{
        \\        return .{{ .ref = self.ref }};
        \\    }}
        \\
    , .{ name, name, name, name, name });
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for ([_][]const u8{ "ref", "deinit", "keep", "as" }) |n| try names.put(a, n, {});
    const object = eql(str(d, "kind"), "interface");
    try g.emitMembers(ms.items, .{ .self_type = name, .object = object }, &o, &names);
    try o.appendSlice(a, "};\n\n");
    try g.out.appendSlice(a, o.items);
}

fn emitGlobals(g: *Gen) !void {
    const a = g.a;
    var ms: std.ArrayList(Value) = .empty;
    for (g.ownerMembers("")) |i| if (g.global_sel.contains(i)) try ms.append(a, g.members.items[i]);
    var names: std.StringHashMapUnmanaged(void) = .empty;
    var it = g.top_names.keyIterator();
    while (it.next()) |k| if (!g.global_names.contains(k.*)) try names.put(a, k.*, {});
    for (reserved_top) |n| try names.put(a, n, {});
    var o: std.ArrayList(u8) = .empty;
    try g.emitMembers(ms.items, .{ .self_type = null, .indent = "" }, &o, &names);
    try g.out.appendSlice(a, o.items);
    try g.out.append(a, '\n');
    // JS namespaces: structs of their members.
    for (g.by_owner.keys()) |k| {
        if (!std.mem.startsWith(u8, k, "ns:")) continue;
        const ns = k[3..];
        if (!g.selected.contains(ns)) continue;
        var nms: std.ArrayList(Value) = .empty;
        for (g.ownerMembers(k)) |i| {
            const m = g.members.items[i];
            if (eql(str(m, "role"), "import")) try nms.append(a, m);
        }
        if (nms.items.len == 0) continue;
        var no: std.ArrayList(u8) = .empty;
        var nnames: std.StringHashMapUnmanaged(void) = .empty;
        try g.emitMembers(nms.items, .{ .self_type = null }, &no, &nnames);
        try g.out.print(a, "/// `namespace {s}`\npub const {s} = struct {{\n{s}}};\n\n", .{ ns, try g.typeName(ns), no.items });
    }
}

// ---- exports --------------------------------------------------------------

fn emitExports(g: *Gen) !void {
    const a = g.a;
    var fns: std.ArrayList(u8) = .empty;
    var exps: std.ArrayList(u8) = .empty;
    var drops: std.StringArrayHashMapUnmanaged(void) = .empty;
    var n: usize = 0;
    for (g.members.items) |m| {
        if (!eql(str(m, "role"), "export")) continue;
        g.emitExport(m, n, &fns, &exps) catch |e| switch (e) {
            error.Unsupported => {
                try g.skipped.append(a, .{ str(m, "key"), g.why });
                continue;
            },
            else => return e,
        };
        if (optStr(m, "owner")) |o| try drops.put(a, o, {});
        n += 1;
    }
    for (drops.keys(), 0..) |o, i| {
        try fns.print(a, "        const drop{d} = rt.dropInstance(App.{s});\n", .{ i, try ident(a, try g.rawTypeName(o)) });
        try exps.print(a, "    @export(&X.drop{d}, .{{ .name = \"tw:drop:{s}\" }});\n", .{ i, try esc(a, o) });
    }
    if (n == 0) {
        try g.export_code.appendSlice(a, "/// Exports nothing: the module exports nothing.\npub fn exports(comptime App: type) void {\n    _ = App;\n}\n");
        return;
    }
    try g.export_code.print(a,
        \\/// Exports the app's handlers for what the module exports. Call it from
        \\/// the root file: `comptime {{ bindings.exports(@This()); }}`. Each export
        \\/// of namespace `default` is a `pub fn` of the root file; another
        \\/// namespace's are in `pub const <namespace> = struct {{ ... }}`. An
        \\/// exported class C is `pub const C = struct {{ ... }}`, built by its
        \\/// `init` and dropped (its `deinit`, if it has one) when JS collects it.
        \\/// A handler may take a std.mem.Allocator (the request arena) first,
        \\/// may leave out trailing parameters, and may return an error, which
        \\/// leaves as the arm it names or as the fallback.
        \\pub fn exports(comptime App: type) void {{
        \\    const X = struct {{
        \\{s}    }};
        \\{s}}}
        \\
    , .{ fns.items, exps.items });
}

fn emitExport(g: *Gen, m: Value, n: usize, fns: *std.ArrayList(u8), exps: *std.ArrayList(u8)) !void {
    const a = g.a;
    const sig = get(m, "sig").?;
    const k = str(m, "kind");
    const is_new = eql(k, "new");
    const owner = optStr(m, "owner");
    var has_this = false;
    var has_handle = false;
    var wires: std.ArrayList(u8) = .empty;
    var args: std.ArrayList(u8) = .empty;
    var codecs: std.ArrayList(u8) = .empty;
    var nw: usize = 0;
    for (items(get(sig, "params"))) |p| {
        const role = str(p, "role");
        if (eql(role, "this")) {
            has_this = true;
            continue;
        }
        if (eql(role, "handle")) {
            has_handle = true;
            continue;
        }
        const repr = get(p, "repr").?;
        const c = try g.codec(repr, .out, null);
        try codecs.print(a, "{s}{s}", .{ if (codecs.items.len > 0) ", " else "", c.codec });
        for (items(get(repr, "wire"))) |w| {
            try wires.print(a, ", __p{d}: {s}", .{ nw, wireZig(w.string) });
            try args.print(a, "{s}__p{d}", .{ if (nw > 0) ", " else "", nw });
            nw += 1;
        }
    }
    const results = items(get(sig, "results"));
    const result = if (results.len > 0) get(results[0], "repr").? else Value{ .null = {} };
    const is_future = result != .null and isHost(result, "future");
    const value = if (is_future) get(result, "value").? else result;
    const th = get(sig, "throws");
    var thr_layout: ?Value = if (th) |t| get(t, "enum").? else null;
    if (thr_layout == null and is_future) thr_layout = get(result, "rejection").?;
    const e_t: []const u8 = if (thr_layout) |L| try g.throwType(L) else "null";
    var tag: ?Tag = try g.tagOf(th);
    if (tag == null and is_future) tag = .{ .module = "tw:tag", .name = str(thr_layout.?, "path"), .params = try g.enumWire(thr_layout.?) };
    var res_codec: []const u8 = "rt.Unit";
    var wire_results: []const []const u8 = &.{};
    if (is_new) {
        wire_results = &.{"i32"};
    } else if (is_future) {
        if (isKind(value, "unit")) {
            res_codec = "rt.NoFuture";
        } else if (isKind(value, "host") and !isHost(value, "future")) {
            res_codec = (try g.codec(value, .in, null)).codec;
        } else return g.unsupported("an export returning a future of {s}", .{str(value, "ty")});
        wire_results = try strs(a, get(result, "wire"));
    } else {
        if (result != .null) res_codec = (try g.codec(result, .in, null)).codec;
        wire_results = try strs(a, get(get(sig, "core").?, "results"));
    }
    const fails = tag != null;
    const ret = if (fails) "i32" else if (wire_results.len == 1) wireZig(wire_results[0]) else "void";
    const pre = if (has_this and has_handle) "__this: i32, __h: i32" else if (has_this) "__this: i32" else "";
    const sep = if (pre.len > 0) "" else if (wires.items.len > 0) "" else "";
    var ps = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ pre, sep, wires.items });
    if (pre.len == 0 and ps.len >= 2) ps = ps[2..];
    var call: []const u8 = undefined;
    if (owner) |o| {
        const cls = try std.fmt.allocPrint(a, "App.{s}", .{try ident(a, try g.rawTypeName(o))});
        if (is_new) {
            call = try std.fmt.allocPrint(a, "rt.serveNew({s}, .{{ {s} }}, {s}, __this, .{{ {s} }})", .{ cls, codecs.items, e_t, args.items });
        } else {
            if (!has_handle) return g.unsupported("a static export of a class", .{});
            call = try std.fmt.allocPrint(a, "rt.serveMethod({s}, \"{s}\", .{{ {s} }}, {s}, {s}, __this, __h, .{{ {s} }})", .{ cls, str(m, "name"), codecs.items, res_codec, e_t, args.items });
        }
    } else {
        var ns: std.ArrayList(u8) = .empty;
        for (items(get(m, "namespace")), 0..) |s, i| try ns.print(a, "{s}{s}", .{ if (i > 0) "." else "", s.string });
        call = try std.fmt.allocPrint(a, "rt.serve(rt.handler(App, \"{s}\", \"{s}\").f, .{{ {s} }}, {s}, {s}, .{{ {s} }})", .{ ns.items, str(m, "name"), codecs.items, res_codec, e_t, args.items });
    }
    try fns.print(a, "        fn x{d}({s}) callconv(.c) {s} {{\n            return {s};\n        }}\n", .{ n, ps, ret, call });
    const key = str(m, "key");
    try exps.print(a, "    @export(&X.x{d}, .{{ .name = \"tsgen:{s}\" }});\n", .{ n, try esc(a, key) });
    try g.exports.append(a, .{
        .c = try std.fmt.allocPrint(a, "tsgen:{s}", .{key}),
        .name = key,
        .params = try strs(a, get(get(sig, "core").?, "params")),
        .results = wire_results,
        .throws = tag,
        .async_ = is_future,
        .owner = owner,
        .member = optStr(m, "name"),
        .kind = k,
    });
}

// ---- the whole file -------------------------------------------------------

/// The file's own declarations, which no binding takes.
const reserved_top = [_][]const u8{ "std", "rt", "shim", "exports", "panic", "tsgen", "Any" };

pub fn emitAll(g: *Gen) !void {
    const a = g.a;
    // The file's names, which parameters can't shadow.
    for (g.selected.keys()) |p| if (g.isClassLike(p)) try g.top_names.put(a, try g.typeName(p), {});
    for (g.by_owner.keys()) |k| if (std.mem.startsWith(u8, k, "ns:") and g.selected.contains(k[3..])) try g.top_names.put(a, try g.typeName(k[3..]), {});
    for (g.ownerMembers("")) |i| if (g.global_sel.contains(i)) {
        const m = g.members.items[i];
        const n = try memberName(a, optStr(m, "variant") orelse str(m, "name"));
        try g.top_names.put(a, n, {});
        try g.global_names.put(a, n, {});
    };
    for (reserved_top) |n| try g.top_names.put(a, n, {});
    for (g.selected.keys()) |p| if (g.isClassLike(p)) try g.emitClass(p);
    try g.emitGlobals();
    try g.emitExports();
    // Selected enums, and those members and payloads reach.
    for (g.selected.keys()) |p| {
        const d = g.decls.get(p).?;
        if (eql(str(d, "kind"), "enum")) _ = g.useEnum(get(d, "layout").?) catch |e| switch (e) {
            error.Unsupported => {
                try g.skipped.append(a, .{ p, g.why });
                continue;
            },
            else => return e,
        };
    }
    var done: std.StringHashMapUnmanaged(void) = .empty;
    var more = true;
    while (more) {
        more = false;
        var i: usize = 0;
        while (i < g.enums.count()) : (i += 1) {
            const p = g.enums.keys()[i];
            if (done.contains(p)) continue;
            try done.put(a, p, {});
            more = true;
            g.emitEnum(g.enums.values()[i], g.throw_enums.contains(p)) catch |e| switch (e) {
                error.Unsupported => try g.skipped.append(a, .{ try std.fmt.allocPrint(a, "enum {s}", .{p}), g.why }),
                else => return e,
            };
        }
    }
}

pub fn zig(g: *Gen) ![]const u8 {
    const a = g.a;
    var o: std.ArrayList(u8) = .empty;
    try o.appendSlice(a,
        \\// Generated by zig-bindgen. Do not edit.
        \\const std = @import("std");
        \\const rt = @import("tsgen.zig");
        \\
        \\pub const tsgen = rt;
        \\pub const Any = rt.Any;
        \\pub const panic = rt.panic;
        \\
        \\
    );
    try o.appendSlice(a, g.out.items);
    try o.appendSlice(a, g.callback_code.items);
    try o.appendSlice(a, g.export_code.items);
    try o.appendSlice(a, "\n// The imports, through the shim.\nconst shim = struct {\n");
    for (g.imports.values()) |e| try o.appendSlice(a, try g.externDecl(e));
    try o.appendSlice(a, "};\n");
    return o.items;
}

fn jsonStr(o: *std.ArrayList(u8), a: Allocator, s: []const u8) !void {
    try o.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try o.appendSlice(a, "\\\""),
        '\\' => try o.appendSlice(a, "\\\\"),
        '\n' => try o.appendSlice(a, "\\n"),
        else => if (c < 0x20) try o.print(a, "\\u{x:0>4}", .{c}) else try o.append(a, c),
    };
    try o.append(a, '"');
}

fn jsonList(o: *std.ArrayList(u8), a: Allocator, l: []const []const u8) !void {
    try o.append(a, '[');
    for (l, 0..) |s, i| {
        if (i > 0) try o.append(a, ',');
        try jsonStr(o, a, s);
    }
    try o.append(a, ']');
}

fn jsonTag(o: *std.ArrayList(u8), a: Allocator, t: ?Tag) !void {
    const x = t orelse return o.appendSlice(a, "null");
    try o.appendSlice(a, "{\"module\":");
    try jsonStr(o, a, x.module);
    try o.appendSlice(a, ",\"name\":");
    try jsonStr(o, a, x.name);
    try o.appendSlice(a, ",\"params\":");
    try jsonList(o, a, x.params);
    try o.append(a, '}');
}

// The protocol imports the runtime makes itself (tsgen.zig `ops`).
const runtime_ops = [_]struct { []const u8, []const u8, []const []const u8, []const []const u8 }{
    .{ "tw:future", "drop", &.{"externref"}, &.{} },
    .{ "tw:box", "str", &.{ "i32", "i32" }, &.{"externref"} },
    .{ "tw:box", "f64", &.{"f64"}, &.{"externref"} },
    .{ "tw:box", "bool", &.{"i32"}, &.{"externref"} },
    .{ "tw:box", "arr<Any?>", &.{ "i32", "i32" }, &.{"externref"} },
    .{ "tw:unbox", "str", &.{"externref"}, &.{ "i32", "i32" } },
    .{ "tw:unbox", "f64", &.{"externref"}, &.{"f64"} },
    .{ "tw:unbox", "bool", &.{"externref"}, &.{"i32"} },
    .{ "tw:isNullish", "", &.{"externref"}, &.{"i32"} },
    .{ "tw:arr", "len", &.{"externref"}, &.{"i32"} },
    .{ "tw:arr", "get<Any?>", &.{ "externref", "i32" }, &.{"externref"} },
};

/// What the shim needs: every import and export with its wire types, and
/// the members the bindings skip.
pub fn manifest(g: *Gen) ![]const u8 {
    const a = g.a;
    for (runtime_ops) |op| _ = try g.importOp(op[0], op[1], op[2], op[3], null);
    for (g.ownerMembers("TsgenObject")) |i| {
        const m = g.members.items[i];
        const core = get(get(m, "sig").?, "core").?;
        _ = try g.importOp("tw:js/global", str(m, "key"), try strs(a, get(core, "params")), try strs(a, get(core, "results")), null);
    }
    var o: std.ArrayList(u8) = .empty;
    try o.appendSlice(a, "{\"imports\":[");
    for (g.imports.values(), 0..) |e, i| {
        if (i > 0) try o.append(a, ',');
        try o.appendSlice(a, "\n{\"c\":");
        try jsonStr(&o, a, e.c);
        try o.appendSlice(a, ",\"module\":");
        try jsonStr(&o, a, e.module);
        try o.appendSlice(a, ",\"name\":");
        try jsonStr(&o, a, e.name);
        try o.appendSlice(a, ",\"params\":");
        try jsonList(&o, a, e.params);
        try o.appendSlice(a, ",\"results\":");
        try jsonList(&o, a, e.results);
        try o.appendSlice(a, ",\"throws\":");
        try jsonTag(&o, a, e.throws);
        try o.append(a, '}');
    }
    try o.appendSlice(a, "],\n\"exports\":[");
    for (g.exports.items, 0..) |e, i| {
        if (i > 0) try o.append(a, ',');
        try o.appendSlice(a, "\n{\"c\":");
        try jsonStr(&o, a, e.c);
        try o.appendSlice(a, ",\"name\":");
        try jsonStr(&o, a, e.name);
        try o.appendSlice(a, ",\"params\":");
        try jsonList(&o, a, e.params);
        try o.appendSlice(a, ",\"results\":");
        try jsonList(&o, a, e.results);
        try o.appendSlice(a, ",\"throws\":");
        try jsonTag(&o, a, e.throws);
        if (e.async_) |as| {
            try o.print(a, ",\"async\":{s},\"owner\":", .{if (as) "true" else "false"});
            if (e.owner) |ow| try jsonStr(&o, a, ow) else try o.appendSlice(a, "null");
            try o.appendSlice(a, ",\"member\":");
            try jsonStr(&o, a, e.member orelse "");
            try o.appendSlice(a, ",\"kind\":");
            try jsonStr(&o, a, e.kind orelse "");
        }
        try o.append(a, '}');
    }
    try o.appendSlice(a, "]}\n");
    return o.items;
}

pub fn skippedText(g: *Gen) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    for (g.skipped.items) |s| try o.print(g.a, "{s}: {s}\n", .{ s[0], s[1] });
    return o.items;
}

pub fn stats(g: *Gen) ![]const u8 {
    return std.fmt.allocPrint(g.a, "{d} declarations, {d} members, {d} imports, {d} exports, {d} skipped", .{ g.selected.count(), g.emitted, g.imports.count(), g.exports.items.len, g.skipped.items.len });
}
