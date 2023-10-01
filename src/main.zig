const std = @import("std");
const builtin = @import("builtin");
const Rpc = @import("rpc");

const Lbp = @import("lbp.zig");
const c = @import("c.zig").c;
const Config = @import("config.zig");

pub const std_options = struct {
    pub fn logFn(
        comptime message_level: std.log.Level,
        comptime scope: @Type(.EnumLiteral),
        comptime format: []const u8,
        args: anytype,
    ) void {
        const color = switch (message_level) {
            .err => "[1;31m",
            .warn => "[1;93m",
            .debug => "[1;35m",
            .info => "[1;37m",
        };
        const level_txt = comptime message_level.asText();
        const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
        const stderr = std.io.getStdErr().writer();
        std.debug.getStderrMutex().lock();
        defer std.debug.getStderrMutex().unlock();
        nosuspend stderr.print("{c}" ++ color ++ level_txt ++ prefix2 ++ format ++ "{c}[0m\n", .{std.ascii.control_code.esc} ++ args ++ .{std.ascii.control_code.esc}) catch return;
    }

    pub const log_level = if (builtin.mode == .Debug) .debug else .info;
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("MEMORY LEAK");
    var allocator = gpa.allocator();

    runApp(allocator) catch |err| {
        var text = std.ArrayList(u8).init(allocator);
        defer text.deinit();

        try std.fmt.format(text.writer(), "Unhandled error {s}!\x00", .{@errorName(err)});

        _ = c.boxerShow(
            text.items.ptr,
            "Unhandled Error!",
            c.BoxerStyleError,
            c.BoxerButtonsQuit,
        );

        return err;
    };
}

pub fn runApp(allocator: std.mem.Allocator) !void {
    const config = try Config.getConfig(allocator);
    defer config.deinit(allocator);

    var uri = try std.Uri.parse(config.instance_url);

    var instance_info = try Lbp.instanceInfo(allocator, uri);
    defer instance_info.deinit();

    std.log.info("Connected to instance {s}", .{instance_info.value.data.instanceName});

    var user_info = try Lbp.getUser(allocator, uri, config.username);
    defer if (user_info) |user|
        user.deinit();

    if (user_info) |user| {
        std.log.info("Found user {s} with id {s}", .{
            user.value.data.username,
            user.value.data.userId,
        });
    } else {
        var text = std.ArrayList(u8).init(allocator);
        defer text.deinit();

        try std.fmt.format(text.writer(), "User {s} not found! Check your config.\x00", .{config.username});

        std.log.err("No user found by the name {s}!", .{config.username});

        _ = c.boxerShow(
            text.items.ptr,
            "User Not Found!",
            c.BoxerStyleError,
            c.BoxerButtonsQuit,
        );

        return;
    }

    var profile_url = std.ArrayList(u8).init(allocator);
    defer profile_url.deinit();

    try uri.format("+", .{}, profile_url.writer());
    try std.fmt.format(profile_url.writer(), "/user/{s}", .{config.username});

    //Qualify the fallback asset
    var qualified_fallback_asset: ?[]const u8 = null;
    defer if (qualified_fallback_asset) |asset| allocator.free(asset);
    if (instance_info.value.data.richPresenceConfiguration.assetConfiguration.fallbackAsset) |fallback_asset|
        qualified_fallback_asset = try Lbp.qualifyAsset(allocator, uri, fallback_asset, instance_info.value.data.richPresenceConfiguration.assetConfiguration.useApplicationAssets);

    //Qualify the pod asset
    var qualified_pod_asset: ?[]const u8 = null;
    defer if (qualified_pod_asset) |asset| allocator.free(asset);
    if (instance_info.value.data.richPresenceConfiguration.assetConfiguration.podAsset) |pod_asset|
        qualified_pod_asset = try Lbp.qualifyAsset(allocator, uri, pod_asset, instance_info.value.data.richPresenceConfiguration.assetConfiguration.useApplicationAssets);

    //Qualify the moon asset
    var qualified_moon_asset: ?[]const u8 = null;
    defer if (qualified_moon_asset) |asset| allocator.free(asset);
    if (instance_info.value.data.richPresenceConfiguration.assetConfiguration.moonAsset) |moon_asset|
        qualified_moon_asset = try Lbp.qualifyAsset(allocator, uri, moon_asset, instance_info.value.data.richPresenceConfiguration.assetConfiguration.useApplicationAssets);

    var rpc_client = try Rpc.init(allocator, &ready);
    defer rpc_client.deinit();

    var rpc_thread: ?std.Thread = null;
    defer {
        //Stop the RPC client
        rpc_client.stop();
        //Join the RPC thread, if applicable
        if (rpc_thread) |thread|
            thread.join();
    }

    const LevelInfo = struct {
        id: i32,
        name: Rpc.Packet.ArrayString(128),
        publisher_username: Rpc.Packet.ArrayString(128),
        icon_hash: Rpc.Packet.ArrayString(256),
        site_url: Rpc.Packet.ArrayString(256),

        /// Creates a new level info struct, pulling level info from the API
        /// Returns null when the level is not found
        pub fn create(_allocator: std.mem.Allocator, _uri: std.Uri, id: i32) !?@This() {
            const level = try Lbp.getLevel(_allocator, _uri, id);

            std.log.debug("updating level info", .{});

            //If the level was found in the API, return the info, else return null
            return if (level) |level_info|
                @This(){
                    .id = id,
                    .name = Rpc.Packet.ArrayString(128).create(level_info.value.data.title),
                    .publisher_username = Rpc.Packet.ArrayString(128).create(level_info.value.data.publisher.username),
                    .icon_hash = Rpc.Packet.ArrayString(256).create(level_info.value.data.iconHash),
                    .site_url = blk: {
                        var str: Rpc.Packet.ArrayString(256) = undefined;
                        var stream = std.io.fixedBufferStream(&str.buf);
                        try _uri.format("+", .{}, stream.writer());
                        try std.fmt.format(stream.writer(), "/level/{d}", .{id});
                        str.len = stream.pos;
                        break :blk str;
                    },
                }
            else
                null;
        }
    };

    var last_level_info: ?LevelInfo = null;

    while (true) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        //Try to get the room the user is in
        if (try Lbp.getUserRoom(arena.allocator(), uri, config.username)) |player_status| {
            //If the rpc client is stopped,
            if (!rpc_client.run_loop.load(.SeqCst)) {
                std.debug.assert(rpc_thread == null);

                std.log.debug("starting rpc thread", .{});

                //Spawn the RPC thread
                rpc_thread = try std.Thread.spawn(
                    .{},
                    runRpcThread,
                    .{
                        rpc_client,
                        instance_info.value.data.richPresenceConfiguration.applicationId,
                    },
                );

                //Wait until we are connected
                while (rpc_client.state != .connected) {
                    std.time.sleep(std.time.ns_per_s);
                }
            }

            var presence = Rpc.Packet.Presence{
                .buttons = undefined,
                .details = Rpc.Packet.ArrayString(128).create(switch (player_status.value.data.levelType) {
                    .story => "Playing a story level",
                    .online => "Playing a level",
                    .remote_moon => "Creating on a remote Moon",
                    .moon_group => "Moon group",
                    .story_group => "Story group",
                    .dlc_level => "Playing a DLC level",
                    .dlc_pack => "Playing a DLC pack",
                    .playlist => "Playing a playlist",
                    .story_adventure => "Story adventure",
                    .story_adventure_planet => "Story adventure planet",
                    .story_aventure_area => "Story adventure area",
                    .adventure_planet_published => "Adventure planet published",
                    .adventure_planet_local => "Adventure planet local",
                    .adventure_level_local => "Adventure level local",
                    .adventure_area_level => "Adventure area level",
                    .fake => "On a fake level",
                    .moon => "Creating a level",
                    .pod => "In the pod",
                    else => "Ingame", //Fallback to generic when theres an unknown value
                }),
                .state = Rpc.Packet.ArrayString(128).create(switch (player_status.value.data.game) {
                    .lbp1 => "Playing LittleBigPlanet 1",
                    .lbp2 => "Playing LittleBigPlanet 2",
                    .lbp3 => "Playing LittleBigPlanet 3",
                    .lbpvita => "Playing LittleBigPlanet on Vita",
                    .lbppsp => "Playing LittleBigPlanet on PSP",
                    .website => "Joined from the website",
                    else => "Playing LittleBigPlanet", //Fallback to generic when theres an unknown value
                }),
                .timestamps = .{
                    .start = null,
                    .end = null,
                },
                .secrets = null,
                .assets = .{
                    .large_image = Rpc.Packet.ArrayString(256).create(if (qualified_fallback_asset) |asset|
                        asset
                    else
                        "refresh"),
                    .large_text = null,
                    .small_image = null,
                    .small_text = null,
                },
                .party = .{
                    .id = Rpc.Packet.ArrayString(128).create(player_status.value.data.roomId),
                    .privacy = Rpc.Packet.Presence.Party.Privacy.private,
                    .size = &[2]i32{ @intCast(player_status.value.data.playerIds.len), 4 },
                },
            };

            switch (player_status.value.data.levelType) {
                .online => {
                    //If there was a level previously,
                    if (last_level_info) |last_level| {
                        //And the level id is different,
                        if (player_status.value.data.levelId != last_level.id) {
                            //Update the last level info
                            last_level_info = try LevelInfo.create(arena.allocator(), uri, player_status.value.data.levelId);
                        }
                    } else {
                        //Update the last level info
                        last_level_info = try LevelInfo.create(arena.allocator(), uri, player_status.value.data.levelId);
                    }

                    //If we have level info
                    if (last_level_info) |last_level| {
                        presence.details = undefined;
                        var details_stream = std.io.fixedBufferStream(&presence.details.buf);
                        try std.fmt.format(details_stream.writer(), "Playing {s} by {s}", .{ last_level.name.slice(), last_level.publisher_username.slice() });
                        presence.details.len = details_stream.pos;

                        //If the icon hash is not a GUID
                        if (last_level.icon_hash.len > 0 and last_level.icon_hash.buf[0] != 'g') {
                            presence.assets.large_image = undefined;

                            //Set the asset to the URL for that asset on the API
                            var large_image_stream = std.io.fixedBufferStream(&presence.assets.large_image.?.buf);
                            try uri.format("+", .{}, large_image_stream.writer());
                            try std.fmt.format(large_image_stream.writer(), "/api/v3/assets/{s}/image", .{last_level.icon_hash.slice()});
                            presence.assets.large_image.?.len = large_image_stream.pos;
                        }

                        presence.assets.large_text = undefined;
                        var large_text_stream = std.io.fixedBufferStream(&presence.assets.large_text.?.buf);
                        try std.fmt.format(large_text_stream.writer(), "{s} by {s}", .{ last_level.name.slice(), last_level.publisher_username.slice() });
                        presence.assets.large_text.?.len = large_text_stream.pos;
                    }
                },
                .moon => {
                    //If the moon asset is qualified,
                    if (qualified_moon_asset) |asset| {
                        //Set the large image asset to the qualified moon asset
                        presence.assets.large_image = Rpc.Packet.ArrayString(256).create(asset);
                    }
                },
                .pod => {
                    //If the pod asset is qualified,
                    if (qualified_pod_asset) |asset| {
                        //Set the large image asset to the qualified pod asset
                        presence.assets.large_image = Rpc.Packet.ArrayString(256).create(asset);
                    }
                },
                else => {},
            }

            if (last_level_info) |level_info| {
                presence.buttons = &.{
                    Rpc.Packet.Presence.Button{
                        .label = try Rpc.Packet.ArrayString(128).create_from_format("View {s}'s Profile", .{user_info.?.value.data.username}),
                        .url = Rpc.Packet.ArrayString(256).create(profile_url.items),
                    },
                    Rpc.Packet.Presence.Button{
                        .label = Rpc.Packet.ArrayString(128).create("View Level's Page"),
                        .url = level_info.site_url,
                    },
                };
            } else {
                presence.buttons = &.{
                    Rpc.Packet.Presence.Button{
                        .label = Rpc.Packet.ArrayString(128).create("Profile"),
                        .url = Rpc.Packet.ArrayString(256).create(profile_url.items),
                    },
                };
            }

            //Apply the new presence
            try rpc_client.setPresence(presence);

            //Sleep for 20s
            std.time.sleep(std.time.ns_per_s * 20);
        } else {
            //If the loop is running,
            if (rpc_client.run_loop.load(.SeqCst)) {
                std.log.debug("ending rpc thread", .{});
                //Tell the RPC client to stop
                rpc_client.stop();
                //Join the thread, waiting for it to end
                rpc_thread.?.join();
                //Set the thread to null, marking it no longer exists
                rpc_thread = null;
            }

            if (config.close_upon_game_exit) {
                return;
            }

            //Sleep for 60s
            std.time.sleep(std.time.ns_per_s * 60);
        }
    }
}

fn runRpcThread(rpc_client: *Rpc, app_id: []const u8) void {
    rpc_client.run(.{
        .client_id = app_id,
    }) catch |err| {
        var text = std.ArrayList(u8).init(std.heap.c_allocator);
        defer text.deinit();

        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            std.fmt.format(text.writer(), "Unable to connect to Discord RPC!\x00", .{}) catch unreachable;
        } else std.fmt.format(text.writer(), "Unhandled error on RPC thread {s}!\x00", .{@errorName(err)}) catch unreachable;

        _ = c.boxerShow(
            text.items.ptr,
            "Unhandled Error!",
            c.BoxerStyleError,
            c.BoxerButtonsQuit,
        );

        std.log.err("rpc client err: {s}", .{@errorName(err)});

        err catch unreachable;
    };
}

fn ready(rpc_client: *Rpc) anyerror!void {
    _ = rpc_client;
}
