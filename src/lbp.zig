const std = @import("std");

pub fn qualifyAsset(writer: anytype, uri: std.Uri, asset: []const u8, use_application_asset: bool) !void {
    //If the asset length matches a SHA1 hex string,
    if (!use_application_asset) {
        //Assume it is a server asset
        try uri.format(";+", .{}, writer);
        try std.fmt.format(writer, "/api/v3/assets/{s}/image", .{asset});
    } else {
        //Assume it is a discord asset
        try writer.writeAll(asset);
    }
}
