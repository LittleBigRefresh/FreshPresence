const std = @import("std");
const builtin = @import("builtin");
const zini = @import("zini");
const known_folders = @import("known-folders");

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
    const cwd = std.fs.cwd();

    var config_dir: ?std.fs.Dir = try known_folders.open(allocator, .local_configuration, .{});
    defer if (config_dir) |*dir| dir.close();

    const config_filename = "fresh_presence_config.ini";

    var file = (config_dir orelse cwd).openFile(config_filename, .{}) catch |err| {
        if (err == std.fs.File.OpenError.FileNotFound) {
            const default_config = Self{};

            var file = try (config_dir orelse cwd).createFile(config_filename, .{});
            defer file.close();

            var buffered_writer = std.io.bufferedWriter(file.writer());
            try zini.stringify(buffered_writer.writer(), default_config);
            try buffered_writer.flush();

            //Get the full path of the config
            var full_path = try (config_dir orelse cwd).realpathAlloc(allocator, config_filename);
            defer allocator.free(full_path);

            std.debug.print("created config at {s}\n", .{full_path});

            //Create a list to store the message we will display
            var msg = std.ArrayList(u8).init(allocator);
            defer msg.deinit();
            //Write out the message
            try std.fmt.format(msg.writer(), "Config created at {s}!\nWould you like to open the config in your default text editor?\x00", .{full_path});

            //Display the message to the user
            if (c.boxerShow(
                msg.items.ptr,
                "Update Config!",
                c.BoxerStyleInfo,
                c.BoxerButtonsYesNo,
            ) == c.BoxerSelectionYes) {
                var child_process = std.ChildProcess.init(
                    switch (builtin.os.tag) {
                        .windows => &.{full_path},
                        .linux => &.{ "xdg-open", full_path },
                        .macos => &.{ "open", full_path },
                        else => @compileError("Unknown platform!"),
                    },
                    allocator,
                );
                try child_process.spawn();
                _ = try child_process.wait();
            }

            std.os.exit(0);
        } else {
            return err;
        }
    };
    defer file.close();

    //Get the full path of the config
    var full_path = try (config_dir orelse cwd).realpathAlloc(allocator, config_filename);
    defer allocator.free(full_path);

    std.debug.print("using config from {s}\n", .{full_path});

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
