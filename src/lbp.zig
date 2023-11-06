const std = @import("std");

pub fn qualifyAsset(allocator: std.mem.Allocator, uri: std.Uri, asset: []const u8, use_application_asset: bool) ![]const u8 {
    var qualified_asset = std.ArrayList(u8).init(allocator);

    //If the asset length matches a SHA1 hex string,
    if (!use_application_asset) {
        //Assume it is a server asset
        try uri.format(":+", .{}, qualified_asset.writer());
        try std.fmt.format(qualified_asset.writer(), "/api/v3/assets/{s}/image", .{asset});
    } else {
        //Assume it is a discord asset
        try qualified_asset.appendSlice(asset);
    }

    return try qualified_asset.toOwnedSlice();
}
