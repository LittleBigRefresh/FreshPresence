const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zboxer = b.dependency("zBoxer", .{
        .target = target,
        .optimize = optimize,
    });
    const zboxer_lib = zboxer.artifact("boxer");

    const exe = b.addExecutable(.{
        .name = "FreshPresence",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    if (target.getOsTag() == .macos) {
        @import("xcode_frameworks").addPaths(b, exe);
    }
    exe.linkLibrary(zboxer_lib);
    try exe.include_dirs.appendSlice(zboxer_lib.include_dirs.items);
    exe.linkLibC();
    exe.addModule("rpc", b.dependency("zig-discord", .{}).module("rpc"));
    exe.addModule("zini", b.dependency("zini", .{}).module("zini"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
