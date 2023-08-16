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

    while (true) {
        if (try Lbp.getUserRoom(allocator, uri, args[2])) |player_status| {
            defer player_status.deinit();

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
                    .online => "Online",
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
                    .large_image = Rpc.Packet.ArrayString(256).create("refresh"),
                    .large_text = Rpc.Packet.ArrayString(128).create("refresh"),
                    .small_image = null,
                    .small_text = null,
                },
                .party = .{
                    .id = Rpc.Packet.ArrayString(128).create(player_status.value.data.roomId),
                    .privacy = Rpc.Packet.Presence.Party.Privacy.private,
                    .size = &[2]i32{ @intCast(player_status.value.data.playerIds.len), 4 },
                },
            };
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
