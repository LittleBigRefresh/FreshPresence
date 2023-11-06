const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zboxer = b.dependency("zBoxer", .{
        .target = target,
        .optimize = optimize,
    });
    const zboxer_lib = zboxer.artifact("boxer");

    const refresh_api_zig = b.dependency("refresh_api", .{});

    const exe = b.addExecutable(.{
        .name = "FreshPresence",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("api", refresh_api_zig.module("refresh-api-zig"));
    //If we are on MacOS, we need to import the xcode frameworks
    if (target.getOsTag() == .macos) {
        @import("xcode_frameworks").addPaths(exe);
    }
    if (optimize == .ReleaseSmall) {
        exe.strip = true;
    }
    exe.linkLibrary(zboxer_lib);
    try exe.include_dirs.appendSlice(zboxer_lib.include_dirs.items);
    exe.linkLibC();
    exe.addModule("rpc", b.dependency("zig-discord", .{}).module("rpc"));
    exe.addModule("zini", b.dependency("zini", .{}).module("zini"));
    exe.addModule("known-folders", b.dependency("known_folders", .{}).module("known-folders"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
