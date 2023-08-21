const std = @import("std");

const c = @import("c.zig").c;

const Self = @This();

instance_url: []const u8 = "https://refresh.jvyden.xyz/",
username: []const u8 = "Username",
close_upon_game_exit: bool = false,

pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
    allocator.free(self.instance_url);
    allocator.free(self.username);
}

/// Checks for an existing config, returns `true` if there is a config, `false` if not
/// Writes a default config if missing
pub fn getConfig(allocator: std.mem.Allocator) !Self {
    var cwd = std.fs.cwd();

    const config_path = "fresh_presence_config.json";

    var file = cwd.openFile(config_path, .{}) catch |err| {
        if (err == std.fs.File.OpenError.FileNotFound) {
            const default_config = Self{};

            var file = try cwd.createFile(config_path, .{});
            defer file.close();

            var buffered_writer = std.io.bufferedWriter(file.writer());
            try std.json.stringify(default_config, .{}, buffered_writer.writer());
            try buffered_writer.flush();

            _ = c.boxerShow(
                "Config created at " ++ config_path ++ "! Please check your config!",
                "Update Config!",
                c.BoxerStyleInfo,
                c.BoxerButtonsQuit,
            );

            std.os.exit(0);
        } else {
            return err;
        }
    };
    defer file.close();

    var buffered_reader = std.io.bufferedReader(file.reader());

    var reader = std.json.reader(allocator, buffered_reader.reader());
    defer reader.deinit();

    const temp_config = try std.json.parseFromTokenSource(Self, allocator, &reader, .{});
    defer temp_config.deinit();

    return Self{
        .username = try allocator.dupe(u8, temp_config.value.username),
        .instance_url = try allocator.dupe(u8, temp_config.value.instance_url),
        .close_upon_game_exit = temp_config.value.close_upon_game_exit,
    };
}
