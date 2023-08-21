const std = @import("std");
const zini = @import("zini");

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

    const config_path = "fresh_presence_config.ini";

    var file = cwd.openFile(config_path, .{}) catch |err| {
        if (err == std.fs.File.OpenError.FileNotFound) {
            const default_config = Self{};

            var file = try cwd.createFile(config_path, .{});
            defer file.close();

            var buffered_writer = std.io.bufferedWriter(file.writer());
            try zini.stringify(buffered_writer.writer(), default_config);
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

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const temp_config = try zini.readStruct(buffered_reader.reader(), Self, arena.allocator());

    return Self{
        .username = try allocator.dupe(u8, temp_config.username),
        .instance_url = try allocator.dupe(u8, temp_config.instance_url),
        .close_upon_game_exit = temp_config.close_upon_game_exit,
    };
}
