//! The shim between a Zig module and the `tw` ABI. Zig can't name
//! `externref`, so the module keeps JS values in the `tw` table and passes
//! slots; the shim, a few lines of WAT merged into the module, moves values
//! between the table and the wire:
//!
//!   an import `tsgen:<module> <name>` reads its externref parameters from
//!     their slots and stores an externref result in a new one; one that
//!     throws catches the tag, stores the error in the return area and
//!     returns 1 (0 when it returned); more than one result goes to the
//!     return area too.
//!   an export `<name>` stores its externref parameters in new slots and
//!     calls the module's `tsgen:<name>`; a status of 1 throws the tag with
//!     the error the module left in the return area.
//!
//! It covers what the module imports from "shim" and exports as `tsgen:`,
//! nothing more, and the table's ranges (IR.md §14).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// The module the language side is merged as.
const lang = "zig";

const Names = struct {
    imports: std.StringHashMapUnmanaged(void) = .empty,
    exports: std.StringHashMapUnmanaged(void) = .empty,
};

fn uleb(b: []const u8, i: *usize) !u64 {
    var r: u64 = 0;
    var s: u6 = 0;
    while (true) {
        if (i.* >= b.len) return error.Truncated;
        const x = b[i.*];
        i.* += 1;
        r |= @as(u64, x & 0x7f) << s;
        if (x & 0x80 == 0) return r;
        s +%= 7;
        if (s > 63) return error.Malformed;
    }
}

fn name(b: []const u8, i: *usize) ![]const u8 {
    const n: usize = @intCast(try uleb(b, i));
    if (i.* + n > b.len) return error.Truncated;
    defer i.* += n;
    return b[i.* .. i.* + n];
}

fn limits(b: []const u8, i: *usize) !void {
    const f = b[i.*];
    i.* += 1;
    _ = try uleb(b, i);
    if (f & 1 != 0) _ = try uleb(b, i);
}

fn names(a: Allocator, wasm: []const u8) !Names {
    var out: Names = .{};
    if (wasm.len < 8 or !std.mem.eql(u8, wasm[0..4], "\x00asm")) return error.NotWasm;
    var i: usize = 8;
    while (i < wasm.len) {
        const id = wasm[i];
        i += 1;
        const size: usize = @intCast(try uleb(wasm, &i));
        const end = i + size;
        const b = wasm[0..end];
        var j = i;
        if (id == 2) {
            const n = try uleb(b, &j);
            for (0..n) |_| {
                const module = try name(b, &j);
                const field = try name(b, &j);
                const k = b[j];
                j += 1;
                switch (k) {
                    0 => _ = try uleb(b, &j),
                    1 => {
                        j += 1;
                        try limits(b, &j);
                    },
                    2 => try limits(b, &j),
                    3 => j += 2,
                    4 => {
                        j += 1;
                        _ = try uleb(b, &j);
                    },
                    else => return error.Malformed,
                }
                if (k == 0 and std.mem.eql(u8, module, "shim")) try out.imports.put(a, field, {});
            }
        } else if (id == 7) {
            const n = try uleb(b, &j);
            for (0..n) |_| {
                const field = try name(b, &j);
                j += 1;
                _ = try uleb(b, &j);
                try out.exports.put(a, field, {});
            }
        }
        i = end;
    }
    return out;
}

fn get(v: Value, k: []const u8) ?Value {
    const x = v.object.get(k) orelse return null;
    return if (x == .null) null else x;
}

fn str(v: Value, k: []const u8) []const u8 {
    return (get(v, k) orelse return "").string;
}

fn list(v: Value, k: []const u8) []const Value {
    return if (get(v, k)) |x| x.array.items else &.{};
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

/// A WAT string literal.
fn lit(a: Allocator, s: []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.append(a, '"');
    for (s) |c| {
        if (c == '"' or c == '\\' or c < 0x20 or c >= 0x7f) try o.print(a, "\\{x:0>2}", .{c}) else try o.append(a, c);
    }
    try o.append(a, '"');
    return o.items;
}

fn slotType(w: []const u8) []const u8 {
    return if (eql(w, "externref")) "i32" else w;
}

const Tags = struct {
    keys: std.StringArrayHashMapUnmanaged(Value) = .empty,

    fn id(t: *Tags, a: Allocator, tag: Value) ![]const u8 {
        const k = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ str(tag, "module"), str(tag, "name") });
        const e = try t.keys.getOrPut(a, k);
        if (!e.found_existing) e.value_ptr.* = tag;
        return std.fmt.allocPrint(a, "$tag{d}", .{e.index});
    }
};

fn join(a: Allocator, ws: []const Value, comptime f: fn ([]const u8) []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    for (ws, 0..) |w, i| {
        if (i > 0) try o.append(a, ' ');
        try o.appendSlice(a, f(w.string));
    }
    return o.items;
}

fn same(w: []const u8) []const u8 {
    return w;
}

fn store(a: Allocator, w: []const u8, off: usize, val: []const u8) ![]const u8 {
    if (eql(w, "externref")) return std.fmt.allocPrint(a, "(i32.store offset={d} (local.get $ret) (call $stash {s}))", .{ off, val });
    return std.fmt.allocPrint(a, "({s}.store offset={d} (local.get $ret) {s})", .{ w, off, val });
}

fn load(a: Allocator, w: []const u8, off: usize) ![]const u8 {
    if (eql(w, "externref")) return std.fmt.allocPrint(a, "(call $take (i32.load offset={d} (local.get $a)))", .{off});
    return std.fmt.allocPrint(a, "({s}.load offset={d} (local.get $a))", .{ w, off });
}

pub fn wat(a: Allocator, manifest: Value, wasm: []const u8) ![]const u8 {
    const used = try names(a, wasm);
    var imports: std.ArrayList(Value) = .empty;
    var exports: std.ArrayList(Value) = .empty;
    for (list(manifest, "imports")) |e| if (used.imports.contains(str(e, "c"))) try imports.append(a, e);
    for (list(manifest, "exports")) |e| if (used.exports.contains(str(e, "c"))) try exports.append(a, e);
    var tags: Tags = .{};
    for (imports.items) |e| if (get(e, "throws")) |t| {
        _ = try tags.id(a, t);
    };
    for (exports.items) |e| if (get(e, "throws")) |t| {
        _ = try tags.id(a, t);
    };
    var o: std.ArrayList(u8) = .empty;
    try o.appendSlice(a, "(module\n");
    try o.print(a,
        \\  (import "{s}" "tsgen_ref_alloc1" (func $alloc (result i32)))
        \\  (import "{s}" "tsgen_ref_free1" (func $free (param i32)))
        \\  (import "{s}" "tsgen_ret_area" (func $retarea (result i32)))
        \\  (import "{s}" "memory" (memory 0))
        \\
    , .{ lang, lang, lang, lang });
    for (tags.keys.values(), 0..) |t, i| {
        try o.print(a, "  (import {s} {s} (tag $tag{d} (param {s})))\n", .{ try lit(a, str(t, "module")), try lit(a, str(t, "name")), i, try join(a, list(t, "params"), same) });
    }
    for (imports.items, 0..) |e, i| {
        const ps = list(e, "params");
        const rs = list(e, "results");
        try o.print(a, "  (import {s} {s} (func $f{d}", .{ try lit(a, str(e, "module")), try lit(a, str(e, "name")), i });
        if (ps.len > 0) try o.print(a, " (param {s})", .{try join(a, ps, same)});
        if (rs.len > 0) try o.print(a, " (result {s})", .{try join(a, rs, same)});
        try o.appendSlice(a, "))\n");
    }
    for (exports.items, 0..) |e, i| {
        const ps = list(e, "params");
        const rs = list(e, "results");
        try o.print(a, "  (import \"{s}\" {s} (func $x{d}", .{ lang, try lit(a, str(e, "c")), i });
        if (ps.len > 0) try o.print(a, " (param {s})", .{try join(a, ps, slotType)});
        if (get(e, "throws") != null) {
            try o.appendSlice(a, " (result i32)");
        } else if (rs.len == 1) try o.print(a, " (result {s})", .{slotType(rs[0].string)});
        try o.appendSlice(a, "))\n");
    }
    const suspends = used.imports.contains("tsgen_suspend");
    if (suspends) try o.print(a,
        \\  (import "{s}" "__stack_pointer" (global $sp (mut i32)))
        \\  (import "tw:future" "suspend" (func $suspend (param externref) (result i32)))
        \\
    , .{lang});
    try o.appendSlice(a,
        \\  (table $t (export "tw:table") 132 externref)
        \\  (global (export "tw:table/stack_base") i32 (i32.const 1))
        \\  (global (export "tw:table/const_base") i32 (i32.const 128))
        \\  (global (export "tw:table/heap_base") i32 (i32.const 132))
        \\  (func (export "tsgen_table_grow") (param i32) (result i32) (table.grow $t (ref.null extern) (local.get 0)))
        \\  (func (export "tsgen_ref_clear") (param i32 i32) (table.fill $t (local.get 0) (ref.null extern) (local.get 1)))
        \\  (func (export "tsgen_ref_copy") (param i32 i32) (table.set $t (local.get 0) (table.get $t (local.get 1))))
        \\  (func (export "tsgen_ref_is_null") (param i32) (result i32) (ref.is_null (table.get $t (local.get 0))))
        \\  (func $stash (param $v externref) (result i32) (local $s i32)
        \\    (if (ref.is_null (local.get $v)) (then (return (i32.const 0))))
        \\    (local.set $s (call $alloc))
        \\    (table.set $t (local.get $s) (local.get $v))
        \\    (local.get $s))
        \\  (func $take (param $s i32) (result externref) (local $v externref)
        \\    (if (i32.eqz (local.get $s)) (then (return (ref.null extern))))
        \\    (local.set $v (table.get $t (local.get $s)))
        \\    (call $free (local.get $s))
        \\    (local.get $v))
        \\
    );
    // A suspension (IR.md §16), for a slot. Another call can run on Zig's
    // linear-memory stack while this one is parked, so the stack pointer is
    // put back as it resumes. Zig's slots are all on its heap, so there's no
    // table stack to keep.
    if (suspends) try o.appendSlice(a,
        \\  (func (export "tsgen_suspend") (param $f i32) (result i32) (local $s i32) (local $r i32)
        \\    (local.set $s (global.get $sp))
        \\    (local.set $r (call $suspend (table.get $t (local.get $f))))
        \\    (global.set $sp (local.get $s))
        \\    (local.get $r))
        \\
    );
    for (imports.items, 0..) |e, i| {
        const ps = list(e, "params");
        const rs = list(e, "results");
        const throws = get(e, "throws");
        const use_ret = throws != null or rs.len > 1;
        var head: std.ArrayList(u8) = .empty;
        for (ps, 0..) |w, k| try head.print(a, " (param $p{d} {s})", .{ k, slotType(w.string) });
        if (use_ret) try head.appendSlice(a, " (param $ret i32)");
        if (throws != null) {
            try head.appendSlice(a, " (result i32)");
        } else if (rs.len == 1) try head.print(a, " (result {s})", .{slotType(rs[0].string)});
        for (rs, 0..) |w, k| try head.print(a, " (local $r{d} {s})", .{ k, w.string });
        var args: std.ArrayList(u8) = .empty;
        for (ps, 0..) |w, k| {
            if (eql(w.string, "externref")) try args.print(a, " (table.get $t (local.get $p{d}))", .{k}) else try args.print(a, " (local.get $p{d})", .{k});
        }
        var set_results: std.ArrayList(u8) = .empty;
        var k = rs.len;
        while (k > 0) {
            k -= 1;
            try set_results.print(a, " (local.set $r{d})", .{k});
        }
        var store_results: std.ArrayList(u8) = .empty;
        for (rs, 0..) |w, n| try store_results.print(a, "\n      {s}", .{try store(a, w.string, n * 8, try std.fmt.allocPrint(a, "(local.get $r{d})", .{n}))});
        var body: []const u8 = undefined;
        if (throws) |t| {
            const tp = list(t, "params");
            for (tp, 0..) |w, n| try head.print(a, " (local $e{d} {s})", .{ n, w.string });
            var set_errs: std.ArrayList(u8) = .empty;
            var n = tp.len;
            while (n > 0) {
                n -= 1;
                try set_errs.print(a, " (local.set $e{d})", .{n});
            }
            var store_errs: std.ArrayList(u8) = .empty;
            for (tp, 0..) |w, m| try store_errs.print(a, "\n    {s}", .{try store(a, w.string, m * 8, try std.fmt.allocPrint(a, "(local.get $e{d})", .{m}))});
            body = try std.fmt.allocPrint(a,
                \\(block $ok
                \\      (block $err (result {s})
                \\        (try_table (catch {s} $err)
                \\          (call $f{d}{s}){s}{s}
                \\          (br $ok))
                \\        (unreachable)){s}{s}
                \\      (return (i32.const 1)))
                \\    (i32.const 0)
            , .{ try join(a, tp, same), try tags.id(a, t), i, args.items, set_results.items, store_results.items, set_errs.items, store_errs.items });
        } else if (rs.len == 1) {
            body = if (eql(rs[0].string, "externref"))
                try std.fmt.allocPrint(a, "(call $stash (call $f{d}{s}))", .{ i, args.items })
            else
                try std.fmt.allocPrint(a, "(call $f{d}{s})", .{ i, args.items });
        } else {
            body = try std.fmt.allocPrint(a, "(call $f{d}{s}){s}{s}", .{ i, args.items, set_results.items, store_results.items });
        }
        try o.print(a, "  (func (export {s}){s}\n    {s})\n", .{ try lit(a, str(e, "c")), head.items, body });
    }
    for (exports.items, 0..) |e, i| {
        const ps = list(e, "params");
        const rs = list(e, "results");
        var head: std.ArrayList(u8) = .empty;
        for (ps, 0..) |w, k| try head.print(a, " (param $p{d} {s})", .{ k, w.string });
        if (rs.len > 0) try head.print(a, " (result {s})", .{try join(a, rs, same)});
        var args: std.ArrayList(u8) = .empty;
        for (ps, 0..) |w, k| {
            if (eql(w.string, "externref")) try args.print(a, " (call $stash (local.get $p{d}))", .{k}) else try args.print(a, " (local.get $p{d})", .{k});
        }
        var loads: std.ArrayList(u8) = .empty;
        for (rs, 0..) |w, k| try loads.print(a, " {s}", .{try load(a, w.string, k * 8)});
        var body: []const u8 = undefined;
        if (get(e, "throws")) |t| {
            var errs: std.ArrayList(u8) = .empty;
            for (list(t, "params"), 0..) |w, k| try errs.print(a, " {s}", .{try load(a, w.string, k * 8)});
            body = try std.fmt.allocPrint(a,
                \\(local $a i32)
                \\    (if (call $x{d}{s})
                \\      (then
                \\        (local.set $a (call $retarea))
                \\        (throw {s}{s})))
                \\    (local.set $a (call $retarea)){s}
            , .{ i, args.items, try tags.id(a, t), errs.items, loads.items });
        } else if (rs.len == 1) {
            body = if (eql(rs[0].string, "externref"))
                try std.fmt.allocPrint(a, "(call $take (call $x{d}{s}))", .{ i, args.items })
            else
                try std.fmt.allocPrint(a, "(call $x{d}{s})", .{ i, args.items });
        } else if (rs.len == 0) {
            body = try std.fmt.allocPrint(a, "(call $x{d}{s})", .{ i, args.items });
        } else {
            body = try std.fmt.allocPrint(a, "(local $a i32)\n    (call $x{d}{s})\n    (local.set $a (call $retarea)){s}", .{ i, args.items, loads.items });
        }
        try o.print(a, "  (func (export {s}){s}\n    {s})\n", .{ try lit(a, str(e, "name")), head.items, body });
    }
    try o.appendSlice(a, ")\n");
    return o.items;
}

/// Whether the merged module keeps an export: what the bridge calls, not
/// what only the shim and the module use between them.
fn internal(n: []const u8) bool {
    return std.mem.startsWith(u8, n, "tsgen:") or std.mem.startsWith(u8, n, "tsgen_") or eql(n, "__stack_pointer");
}

fn putUleb(a: Allocator, o: *std.ArrayList(u8), v: u64) !void {
    var x = v;
    while (true) {
        const b: u8 = @intCast(x & 0x7f);
        x >>= 7;
        if (x == 0) return o.append(a, b);
        try o.append(a, b | 0x80);
    }
}

/// The merged module without its internal exports, so an optimizer can
/// inline and drop what's behind them.
pub fn strip(a: Allocator, wasm: []const u8) ![]const u8 {
    if (wasm.len < 8 or !std.mem.eql(u8, wasm[0..4], "\x00asm")) return error.NotWasm;
    var o: std.ArrayList(u8) = .empty;
    try o.appendSlice(a, wasm[0..8]);
    var i: usize = 8;
    while (i < wasm.len) {
        const start = i;
        const id = wasm[i];
        i += 1;
        const size: usize = @intCast(try uleb(wasm, &i));
        const end = i + size;
        if (id != 7) {
            try o.appendSlice(a, wasm[start..end]);
            i = end;
            continue;
        }
        const b = wasm[0..end];
        var j = i;
        const n = try uleb(b, &j);
        var kept: std.ArrayList(u8) = .empty;
        var count: u64 = 0;
        for (0..n) |_| {
            const e = j;
            const field = try name(b, &j);
            j += 1;
            _ = try uleb(b, &j);
            if (internal(field)) continue;
            try kept.appendSlice(a, b[e..j]);
            count += 1;
        }
        var sec: std.ArrayList(u8) = .empty;
        try putUleb(a, &sec, count);
        try sec.appendSlice(a, kept.items);
        try o.append(a, 7);
        try putUleb(a, &o, sec.items.len);
        try o.appendSlice(a, sec.items);
        i = end;
    }
    return o.items;
}
