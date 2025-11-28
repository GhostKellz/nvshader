const std = @import("std");

pub const cache = @import("cache.zig");
pub const paths = @import("paths.zig");
pub const steam = @import("steam.zig");
pub const stats = @import("stats.zig");
pub const games = @import("games.zig");
pub const types = @import("types.zig");
pub const archive = @import("archive.zig");
pub const prewarm = @import("prewarm.zig");
pub const watch = @import("watch.zig");
pub const sharing = @import("sharing.zig");
pub const ipc = @import("dbus.zig");

/// nvshader version
pub const version = "0.1.0";

pub const CacheType = types.CacheType;
pub const CacheStats = types.CacheStats;
pub const GpuInfo = types.GpuInfo;

test "CacheType names" {
    try std.testing.expectEqualStrings("DXVK State Cache", CacheType.dxvk.name());
    try std.testing.expectEqualStrings(".dxvk-cache", CacheType.dxvk.extension());
}
