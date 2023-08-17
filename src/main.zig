const std = @import("std");
const Rpc = @import("rpc");

const Lbp = @import("lbp.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("MEMORY LEAK");
    var allocator = gpa.allocator();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var uri = try std.Uri.parse(args[1]);

    var instance_info = try Lbp.instanceInfo(allocator, uri);
    defer instance_info.deinit();

    var qualified_fallback_asset = std.ArrayList(u8).init(allocator);
    defer qualified_fallback_asset.deinit();

    if (instance_info.value.data.richPresenceConfiguration.assetConfiguration.fallbackAsset) |fallback_asset| {
        //TODO: replace this once a flag exists in the asset config
        //If the asset length matches a SHA1 hex string,
        if (fallback_asset.len == std.crypto.hash.Sha1.digest_length * 2) {
            //Assume it is a server asset
            try uri.format("+", .{}, qualified_fallback_asset.writer());
            try std.fmt.format(qualified_fallback_asset.writer(), "/api/v3/assets/{s}/image", .{fallback_asset});
        } else {
            //Assume it is a discord asset
            try qualified_fallback_asset.appendSlice(fallback_asset);
        }
    }

    std.debug.print("instanceName: {s}\n", .{instance_info.value.data.instanceName});
    std.debug.print("instanceDescription: {s}\n\n", .{instance_info.value.data.instanceDescription});
    std.debug.print("appid: {s}\n", .{instance_info.value.data.richPresenceConfiguration.applicationId});
    std.debug.print("partyIdPrefix: {s}\n\n", .{instance_info.value.data.richPresenceConfiguration.partyIdPrefix});

    var rpc_client = try Rpc.init(allocator, &ready);
    defer rpc_client.deinit();

    var rpc_thread: ?std.Thread = null;
    defer {
        if (rpc_thread) |thread| {
            thread.join();
        }
    }

    defer rpc_client.stop();

    while (true) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        if (try Lbp.getUserRoom(arena.allocator(), uri, args[2])) |player_status| {
            if (!rpc_client.run_loop.load(.SeqCst)) {
                std.debug.assert(rpc_thread == null);

                std.debug.print("starting rpc thread\n", .{});

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
                .buttons = null,
                .details = Rpc.Packet.ArrayString(128).create(switch (player_status.value.data.levelType) {
                    .story => "Playing a story level",
                    .online => "Playing a level",
                    .remote_moon => "Creating a level on someone elses Moon",
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
                    .moon => "Creating a level on the Moon",
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
                    .large_image = Rpc.Packet.ArrayString(256).create(if (instance_info.value.data.richPresenceConfiguration.assetConfiguration.fallbackAsset != null)
                        qualified_fallback_asset.items
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

            //If the user is on a level,
            if (player_status.value.data.levelType == .online) {
                //Grab the level information
                var level = try Lbp.getLevel(arena.allocator(), uri, player_status.value.data.levelId);

                //If the query returned information
                if (level) |level_info| {
                    var details_stream = std.io.fixedBufferStream(&presence.details.buf);
                    try std.fmt.format(details_stream.writer(), "Playing {s} by {s}", .{ level_info.value.data.title, level_info.value.data.publisher.username });
                    presence.details.len = details_stream.pos;

                    if (level_info.value.data.iconHash.len > 0 and level_info.value.data.iconHash[0] != 'g') {
                        presence.assets.large_image = undefined;

                        var large_image_stream = std.io.fixedBufferStream(&presence.assets.large_image.?.buf);
                        try uri.format("+", .{}, large_image_stream.writer());
                        try std.fmt.format(large_image_stream.writer(), "/api/v3/assets/{s}/image", .{level_info.value.data.iconHash});
                        presence.assets.large_image.?.len = large_image_stream.pos;
                    }

                    presence.assets.large_text = undefined;

                    var large_text_stream = std.io.fixedBufferStream(&presence.assets.large_text.?.buf);
                    try std.fmt.format(large_text_stream.writer(), "{s} by {s}", .{ level_info.value.data.title, level_info.value.data.publisher.username });
                    presence.assets.large_text.?.len = large_text_stream.pos;
                }
            }

            try rpc_client.setPresence(presence);

            std.time.sleep(std.time.ns_per_s * 20);
        } else {
            //If the loop is running,
            if (rpc_client.run_loop.load(.SeqCst)) {
                std.debug.print("ending rpc thread\n", .{});
                //Tell the RPC client to stop
                rpc_client.stop();
                //Join the thread, waiting for it to end
                rpc_thread.?.join();
                //Set the thread to null, marking it no longer exists
                rpc_thread = null;
            }

            std.time.sleep(std.time.ns_per_s * 60);
        }
    }

    rpc_client.stop();
}

fn runRpcThread(rpc_client: *Rpc, app_id: []const u8) void {
    rpc_client.run(.{
        .client_id = app_id,
    }) catch unreachable;
}

fn ready(rpc_client: *Rpc) anyerror!void {
    _ = rpc_client;
}
