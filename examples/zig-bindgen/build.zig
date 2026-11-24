//! `zig build` builds zig-bindgen into zig-out/bin.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "zig-bindgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe }),
        }),
    });
    b.installArtifact(exe);
}
