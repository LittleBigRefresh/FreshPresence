const std = @import("std");

pub fn instanceInfo(allocator: std.mem.Allocator, uri: std.Uri) !std.json.Parsed(InstanceInfo) {
    return try makeRequestAndParse(allocator, InstanceInfo, uri, "/api/v3/instance");
}

pub const RequestError = error{
    ErrorCode404,
    UnknownHttpErrorCode,
};

fn makeRequestAndParse(allocator: std.mem.Allocator, comptime T: type, uri: std.Uri, path: []const u8) !std.json.Parsed(T) {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var new_url = uri;
    new_url.path = path;

    //Create a request to the Instance v3 API to get server info
    var request = try client.request(.GET, new_url, .{ .allocator = allocator }, .{});
    defer request.deinit();
    try request.start();

    //Wait for the response
    try request.wait();

    if (request.response.status == .not_found) {
        return RequestError.ErrorCode404;
    } else if (request.response.status != .ok) {
        return RequestError.UnknownHttpErrorCode;
    }

    var reader = request.reader();

    var json_reader = std.json.reader(allocator, reader);
    defer json_reader.deinit();
    return try std.json.parseFromTokenSource(T, allocator, &json_reader, .{});
}

pub fn ApiResponse(comptime T: type) type {
    return struct {
        success: bool,
        data: T,
    };
}

pub const InstanceInfo = ApiResponse(struct {
    instanceName: []const u8,
    instanceDescription: []const u8,
    softwareName: []const u8,
    softwareVersion: []const u8,
    softwareType: []const u8,
    registrationEnabled: bool,
    maximumAssetSafetyLevel: i32,
    announcements: []const struct {
        announcementId: []const u8,
        title: []const u8,
        text: []const u8,
        createdAt: []const u8,
    },
    richPresenceConfiguration: struct {
        applicationId: []const u8,
        partyIdPrefix: []const u8,
        assetConfiguration: struct {
            podAsset: ?[]const u8,
            moonAsset: ?[]const u8,
            remoteMoonAsset: ?[]const u8,
            developerAsset: ?[]const u8,
            developerAdventureAsset: ?[]const u8,
            dlcAsset: ?[]const u8,
            fallbackAsset: ?[]const u8,
        },
    },
    maintenanceModeEnabled: bool,
});

pub fn getUserRoom(allocator: std.mem.Allocator, uri: std.Uri, username: []const u8) !?std.json.Parsed(ApiRoom) {
    var url = std.ArrayList(u8).init(allocator);
    defer url.deinit();
    try std.fmt.format(url.writer(), "/api/v3/rooms/username/{s}", .{username});

    var parsed = makeRequestAndParse(allocator, ApiRoom, uri, url.items) catch |err| {
        if (err == RequestError.ErrorCode404) {
            return null;
        } else {
            return err;
        }
    };

    return parsed;
}

pub const ApiRoom = ApiResponse(struct {
    roomId: []const u8,
    playerIds: []const ApiRoomPlayer,
    roomState: ApiRoomState,
    roomMood: ApiRoomMood,
    levelType: ApiRoomSlotType,
    levelId: i32,
    platform: ApiPlatform,
    game: ApiGame,
});

pub const ApiPlatform = enum(i32) {
    ps3 = 0,
    rpcs3 = 1,
    vita = 2,
    website = 3,
    _,
};

pub const ApiGame = enum(i32) {
    lbp1,
    lbp2,
    lbp3,
    lbpvita,
    lbppsp,
    website,
    _,
};

pub const ApiRoomSlotType = enum(i32) {
    story = 0,
    online = 1,
    moon = 2,
    moon_group = 3,
    story_group = 4,
    pod = 5,
    fake = 6,
    remote_moon = 7,
    dlc_level = 8,
    dlc_pack = 9,
    playlist = 10,
    story_adventure = 11,
    story_adventure_planet = 12,
    story_aventure_area = 13,
    adventure_planet_published = 14,
    adventure_planet_local = 15,
    adventure_level_local = 16,
    adventure_area_level = 17,
    _,
};

pub const ApiRoomState = enum(i32) {
    idle = 0,
    loading = 1,
    diving_in = 3,
    waiting_for_players = 4,
    _,
};

pub const ApiRoomMood = enum(i32) {
    rejecting_all = 0,
    rejecting_all_but_friends = 1,
    rejecting_only_friends = 2,
    allowing_all = 3,
    _,
};

pub const ApiRoomPlayer = struct {
    username: []const u8,
    userId: ?[]const u8,
};
