const std = @import("std");
const builtin = @import("builtin");
const Rpc = @import("rpc");

const Lbp = @import("lbp.zig");
const Api = @import("api");
const c = @import("c.zig").c;
const Config = @import("config.zig");

pub const std_options = struct {
    pub fn logFn(
        comptime message_level: std.log.Level,
        comptime scope: @Type(.EnumLiteral),
        comptime format: []const u8,
        args: anytype,
    ) void {
        const esc_code = std.ascii.control_code.esc;

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

        nosuspend stderr.print("{c}" ++ color ++ level_txt ++ prefix2 ++ format ++ "{c}[0m\n", .{esc_code} ++ args ++ .{esc_code}) catch return;
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

fn failOnApiError(response: anytype) Api.Error!@TypeOf(response.response.data) {
    switch (response.response) {
        .data => |data| return data,
        .error_response => |err| {
            std.log.err("Got error {s} with message \"{s}\"!", .{ @errorName(err.api_error), err.message });
            return err.api_error;
        },
    }
}

pub fn runApp(allocator: std.mem.Allocator) !void {
    const config = try Config.getConfig(allocator);
    defer config.deinit(allocator);

    var uri = try std.Uri.parse(config.instance_url);

    var instance_info_response = try Api.getInstanceInformation(allocator, uri);
    defer instance_info_response.deinit();

    const instance_info = try failOnApiError(instance_info_response);

    std.log.info("Connected to instance {s}", .{instance_info.instanceName});

    var user_info_response = try Api.getUserByUsername(allocator, uri, config.username);
    defer user_info_response.deinit();

    var user = switch (user_info_response.response) {
        .data => |data| data,
        .error_response => |err| {
            if (err.api_error != Api.Error.ApiNotFoundError) {
                std.log.err("Got unexpected error {s} while getting user! message: {s}", .{ @errorName(err.api_error), err.message });
                return err.api_error;
            }

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
        },
    };

    std.log.info("Found user {s} with id {s}", .{
        user.username,
        user.userId,
    });

    var profile_url = std.ArrayList(u8).init(allocator);
    defer profile_url.deinit();

    try uri.format(":+", .{}, profile_url.writer());
    try std.fmt.format(profile_url.writer(), "/user/{s}", .{config.username});

    const useApplicationAssets = instance_info.richPresenceConfiguration.assetConfiguration.useApplicationAssets;

    //Qualify the fallback asset
    var qualified_fallback_asset: ?[]const u8 = null;
    defer if (qualified_fallback_asset) |asset| allocator.free(asset);
    if (instance_info.richPresenceConfiguration.assetConfiguration.fallbackAsset) |fallback_asset|
        qualified_fallback_asset = try Lbp.qualifyAsset(allocator, uri, fallback_asset, useApplicationAssets);

    //Qualify the pod asset
    var qualified_pod_asset: ?[]const u8 = null;
    defer if (qualified_pod_asset) |asset| allocator.free(asset);
    if (instance_info.richPresenceConfiguration.assetConfiguration.podAsset) |pod_asset|
        qualified_pod_asset = try Lbp.qualifyAsset(allocator, uri, pod_asset, useApplicationAssets);

    //Qualify the moon asset
    var qualified_moon_asset: ?[]const u8 = null;
    defer if (qualified_moon_asset) |asset| allocator.free(asset);
    if (instance_info.richPresenceConfiguration.assetConfiguration.moonAsset) |moon_asset|
        qualified_moon_asset = try Lbp.qualifyAsset(allocator, uri, moon_asset, useApplicationAssets);

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
            var level_response = try Api.getLevelById(_allocator, _uri, id);
            defer level_response.deinit();

            std.log.debug("updating level info {d}", .{id});

            switch (level_response.response) {
                .data => |level| {
                    return @This(){
                        .id = id,
                        .name = Rpc.Packet.ArrayString(128).create(level.title),
                        .publisher_username = Rpc.Packet.ArrayString(128).create(level.publisher.username),
                        .icon_hash = Rpc.Packet.ArrayString(256).create(level.iconHash),
                        .site_url = blk: {
                            var str: Rpc.Packet.ArrayString(256) = undefined;
                            var stream = std.io.fixedBufferStream(&str.buf);
                            try _uri.format(":+", .{}, stream.writer());
                            try std.fmt.format(stream.writer(), "/level/{d}", .{id});
                            str.len = stream.pos;
                            break :blk str;
                        },
                    };
                },
                .error_response => |err| {
                    if (err.api_error != Api.Error.ApiNotFoundError) {
                        std.log.err("Got unexpected error {s} while getting user room! message: {s}", .{ @errorName(err.api_error), err.message });
                        return err.api_error;
                    }

                    //When we get an ApiNotFoundError, return null
                    return null;
                },
            }
        }
    };

    var last_level_info: ?LevelInfo = null;

    while (true) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var room_response = try Api.getRoomByUsername(arena.allocator(), uri, config.username);
        defer room_response.deinit();

        switch (room_response.response) {
            .data => |room| {
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
                            instance_info.richPresenceConfiguration.applicationId,
                        },
                    );

                    //Wait until we are connected
                    while (rpc_client.state != .connected) {
                        std.time.sleep(std.time.ns_per_s);
                    }
                }

                var presence = Rpc.Packet.Presence{
                    .buttons = undefined,
                    .details = Rpc.Packet.ArrayString(128).create(switch (room.levelType) {
                        .story => "Playing a story level",
                        .online => "Playing a level",
                        // .remote_moon => "Creating on a remote Moon",
                        // .moon_group => "Moon group",
                        // .story_group => "Story group",
                        // .dlc_level => "Playing a DLC level",
                        // .dlc_pack => "Playing a DLC pack",
                        // .playlist => "Playing a playlist",
                        // .story_adventure => "Story adventure",
                        // .story_adventure_planet => "Story adventure planet",
                        // .story_aventure_area => "Story adventure area",
                        // .adventure_planet_published => "Adventure planet published",
                        // .adventure_planet_local => "Adventure planet local",
                        // .adventure_level_local => "Adventure level local",
                        // .adventure_area_level => "Adventure area level",
                        // .fake => "On a fake level",
                        .moon => "Creating a level",
                        .pod => "In the pod",
                        else => "Ingame", //Fallback to generic when theres an unknown value
                    }),
                    .state = Rpc.Packet.ArrayString(128).create(switch (room.game) {
                        .little_big_planet_1 => "Playing LittleBigPlanet 1",
                        .little_big_planet_2 => "Playing LittleBigPlanet 2",
                        .little_big_planet_3 => "Playing LittleBigPlanet 3",
                        .little_big_planet_vita => "Playing LittleBigPlanet on Vita",
                        .little_big_planet_psp => "Playing LittleBigPlanet on PSP",
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
                        .id = Rpc.Packet.ArrayString(128).create(room.roomId),
                        .privacy = Rpc.Packet.Presence.Party.Privacy.private,
                        .size = &[2]i32{ @intCast(room.playerIds.len), 4 },
                    },
                };

                switch (room.levelType) {
                    .online => {
                        //If there was a level previously,
                        if (last_level_info) |last_level| {
                            //And the level id is different,
                            if (room.levelId != last_level.id) {
                                //Update the last level info
                                last_level_info = try LevelInfo.create(arena.allocator(), uri, room.levelId);
                            }
                        } else {
                            //Update the last level info
                            last_level_info = try LevelInfo.create(arena.allocator(), uri, room.levelId);
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
                                try uri.format(":+", .{}, large_image_stream.writer());
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
                    std.log.debug("level button url {s}\n", .{level_info.site_url.slice()});
                    presence.buttons = &.{
                        Rpc.Packet.Presence.Button{
                            .label = try Rpc.Packet.ArrayString(128).create_from_format("View {s}'s Profile", .{user.username}),
                            .url = Rpc.Packet.ArrayString(256).create(profile_url.items),
                        },
                        Rpc.Packet.Presence.Button{
                            .label = Rpc.Packet.ArrayString(128).create("View Level's Page"),
                            .url = level_info.site_url,
                        },
                    };
                } else {
                    std.log.debug("level button url {s}", .{profile_url.items});
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
            },
            .error_response => |err| {
                if (err.api_error != Api.Error.ApiNotFoundError) {
                    std.log.err("Got unexpected error {s} while getting user room! message: {s}", .{ @errorName(err.api_error), err.message });
                    return err.api_error;
                }

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
            },
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
