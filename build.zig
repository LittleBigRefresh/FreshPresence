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
    const module = refresh_api_zig.module("refresh-api-zig");

    const exe = b.addExecutable(.{
        .name = "FreshPresence",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    if (b.option(bool, "use_llvm", "Use the LLVM backend")) |use_llvm| {
        exe.use_lld = use_llvm;
        exe.use_llvm = use_llvm;
    }
    exe.root_module.addImport("api", module);
    //If we are on MacOS, we need to import the xcode frameworks
    if (target.result.isDarwin()) {
        @import("xcode_frameworks").addPaths(exe);
    }
    if (optimize == .ReleaseSmall) {
        exe.root_module.strip = true;
    }
    exe.linkLibrary(zboxer_lib);
    try exe.root_module.include_dirs.appendSlice(b.allocator, zboxer_lib.root_module.include_dirs.items);
    exe.linkLibC();
    exe.root_module.addImport("rpc", b.dependency("zig-discord", .{}).module("rpc"));
    exe.root_module.addImport("zini", b.dependency("zini", .{}).module("zini"));
    exe.root_module.addImport("known-folders", b.dependency("known_folders", .{}).module("known-folders"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
