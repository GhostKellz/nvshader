const std = @import("std");
const types = @import("types.zig");
const cache = @import("cache.zig");

/// Summarize a slice of cache entries into aggregate statistics.
pub fn summarize(entries: []const cache.CacheEntry) types.CacheStats {
    var stats = types.CacheStats{
        .total_size_bytes = 0,
        .file_count = 0,
        .game_count = 0,
        .oldest_entry = null,
        .newest_entry = null,
        .dxvk_size = 0,
        .vkd3d_size = 0,
        .nvidia_size = 0,
        .mesa_size = 0,
        .fossilize_size = 0,
    };

    for (entries) |entry| {
        stats.total_size_bytes += entry.size_bytes;
        stats.file_count += 1;

        if (entry.game_name != null) {
            stats.game_count += 1;
        }

        switch (entry.cache_type) {
            .dxvk => stats.dxvk_size += entry.size_bytes,
            .vkd3d => stats.vkd3d_size += entry.size_bytes,
            .nvidia => stats.nvidia_size += entry.size_bytes,
            .mesa => stats.mesa_size += entry.size_bytes,
            .fossilize => stats.fossilize_size += entry.size_bytes,
        }

        if (stats.oldest_entry) |oldest| {
            if (entry.modified_time < oldest) stats.oldest_entry = entry.modified_time;
        } else {
            stats.oldest_entry = entry.modified_time;
        }

        if (stats.newest_entry) |newest| {
            if (entry.modified_time > newest) stats.newest_entry = entry.modified_time;
        } else {
            stats.newest_entry = entry.modified_time;
        }
    }

    return stats;
}

/// Render a short human-readable breakdown for CLI status output.
pub fn printBreakdown(stats: types.CacheStats) void {
    const total_mb = stats.totalSizeMb();
    std.debug.print("Total cache size: {d:.2} MiB ({d} files)\n", .{ total_mb, stats.file_count });

    // Print each non-zero cache type
    if (stats.dxvk_size > 0) {
        const mb: f64 = @as(f64, @floatFromInt(stats.dxvk_size)) / (1024.0 * 1024.0);
        std.debug.print("  • DXVK: {d:.2} MiB\n", .{mb});
    }
    if (stats.vkd3d_size > 0) {
        const mb: f64 = @as(f64, @floatFromInt(stats.vkd3d_size)) / (1024.0 * 1024.0);
        std.debug.print("  • vkd3d-proton: {d:.2} MiB\n", .{mb});
    }
    if (stats.nvidia_size > 0) {
        const mb: f64 = @as(f64, @floatFromInt(stats.nvidia_size)) / (1024.0 * 1024.0);
        std.debug.print("  • NVIDIA: {d:.2} MiB\n", .{mb});
    }
    if (stats.mesa_size > 0) {
        const mb: f64 = @as(f64, @floatFromInt(stats.mesa_size)) / (1024.0 * 1024.0);
        std.debug.print("  • Mesa: {d:.2} MiB\n", .{mb});
    }
    if (stats.fossilize_size > 0) {
        const mb: f64 = @as(f64, @floatFromInt(stats.fossilize_size)) / (1024.0 * 1024.0);
        std.debug.print("  • Fossilize: {d:.2} MiB\n", .{mb});
    }
}
