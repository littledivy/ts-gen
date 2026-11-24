//! zig-bindgen: Zig bindings from ts-gen's lowered JSON (`ts-gen-abi lower`
//! under the linear profile with `jspi = on`), and the Wasm shim that
//! adapts a Zig module to the `tw` ABI.
//!
//!   zig-bindgen bindings <lowered.json> [--lib <lib.json>]... --out <dir>
//!               [--roots A,B,...] [--runtime]
//!       writes <dir>/bindings.zig, <dir>/manifest.json and
//!       <dir>/skipped.txt, and with --runtime <dir>/tsgen.zig
//!   zig-bindgen shim <manifest.json> <module.wasm> -o <shim.wat>
//!       the shim for exactly the imports and exports the module has
//!   zig-bindgen strip <module.wasm> -o <out.wasm>
//!       drops the exports only the shim uses, after merging
//!   zig-bindgen runtime-ir
//!       prints the declarations the runtime needs, to append to the IR

const std = @import("std");
const Gen = @import("Gen.zig");
const shim = @import("shim.zig");

pub const runtime_zig = @embedFile("runtime/tsgen.zig");
pub const runtime_ir = @embedFile("runtime/runtime.ir");

const usage =
    \\usage: zig-bindgen bindings <lowered.json> [--lib <lib.json>]... --out <dir> [--roots A,B,...] [--runtime]
    \\       zig-bindgen shim <manifest.json> <module.wasm> -o <shim.wat>
    \\       zig-bindgen strip <module.wasm> -o <out.wasm>
    \\       zig-bindgen runtime-ir
    \\
;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2) fail(io, usage);
    const cmd = args[1];
    const rest = args[2..];
    const cwd = std.Io.Dir.cwd();
    if (std.mem.eql(u8, cmd, "runtime-ir")) {
        try std.Io.File.stdout().writeStreamingAll(io, runtime_ir);
        return;
    }
    if (std.mem.eql(u8, cmd, "bindings")) {
        var input: ?[]const u8 = null;
        var libs: std.ArrayList([]const u8) = .empty;
        var out: ?[]const u8 = null;
        var roots: ?[]const u8 = null;
        var with_runtime = false;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            const arg = rest[i];
            if (std.mem.eql(u8, arg, "--lib")) {
                i += 1;
                try libs.append(a, rest[i]);
            } else if (std.mem.eql(u8, arg, "--out")) {
                i += 1;
                out = rest[i];
            } else if (std.mem.eql(u8, arg, "--roots")) {
                i += 1;
                roots = rest[i];
            } else if (std.mem.eql(u8, arg, "--runtime")) {
                with_runtime = true;
            } else if (input == null) {
                input = arg;
            } else fail(io, usage);
        }
        const dir = out orelse fail(io, usage);
        var docs: std.ArrayList(std.json.Value) = .empty;
        try docs.append(a, try readJson(a, io, input orelse fail(io, usage)));
        for (libs.items) |l| try docs.append(a, try readJson(a, io, l));
        var g = Gen.init(a, docs.items) catch |e| switch (e) {
            error.Profile => fail(io, "zig-bindgen needs the linear profile with multi-value results, tags and `jspi = on` (\"all-linear, jspi = on\")\n"),
            else => return e,
        };
        var root_list: ?[]const []const u8 = null;
        if (roots) |r| {
            var list: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeScalar(u8, r, ',');
            while (it.next()) |x| try list.append(a, x);
            root_list = list.items;
        }
        try g.select(root_list);
        try g.emitAll();
        try cwd.createDirPath(io, dir);
        var d = try cwd.openDir(io, dir, .{});
        defer d.close(io);
        try d.writeFile(io, .{ .sub_path = "bindings.zig", .data = try fmt(a, try g.zig()) });
        try d.writeFile(io, .{ .sub_path = "manifest.json", .data = try g.manifest() });
        try d.writeFile(io, .{ .sub_path = "skipped.txt", .data = try g.skippedText() });
        if (with_runtime) try d.writeFile(io, .{ .sub_path = "tsgen.zig", .data = runtime_zig });
        const msg = try std.fmt.allocPrint(a, "zig-bindgen: {s}\n", .{try g.stats()});
        try std.Io.File.stderr().writeStreamingAll(io, msg);
        return;
    }
    if (std.mem.eql(u8, cmd, "shim") or std.mem.eql(u8, cmd, "strip")) {
        var pos: std.ArrayList([]const u8) = .empty;
        var out: ?[]const u8 = null;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            if (std.mem.eql(u8, rest[i], "-o")) {
                i += 1;
                out = rest[i];
            } else try pos.append(a, rest[i]);
        }
        const o = out orelse fail(io, usage);
        if (std.mem.eql(u8, cmd, "shim")) {
            if (pos.items.len != 2) fail(io, usage);
            const manifest = try readJson(a, io, pos.items[0]);
            const wasm = try cwd.readFileAlloc(io, pos.items[1], a, .unlimited);
            const text = try shim.wat(a, manifest, wasm);
            try cwd.writeFile(io, .{ .sub_path = o, .data = text });
        } else {
            if (pos.items.len != 1) fail(io, usage);
            const wasm = try cwd.readFileAlloc(io, pos.items[0], a, .unlimited);
            try cwd.writeFile(io, .{ .sub_path = o, .data = try shim.strip(a, wasm) });
        }
        return;
    }
    fail(io, usage);
}

/// `src` as `zig fmt` writes it.
fn fmt(a: std.mem.Allocator, src: []const u8) ![]const u8 {
    const tree = try std.zig.Ast.parse(a, try a.dupeSentinel(u8, src, 0), .{ .mode = .zig });
    if (tree.errors.len > 0) return src;
    return tree.renderAlloc(a);
}

fn readJson(a: std.mem.Allocator, io: std.Io, path: []const u8) !std.json.Value {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    return std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
}

fn fail(io: std.Io, msg: []const u8) noreturn {
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
    std.process.exit(2);
}
