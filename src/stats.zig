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
pub fn printBreakdown(writer: anytype, stats: types.CacheStats) !void {
    const total_mb = stats.totalSizeMb();
    try writer.print("Total cache size: {d:.2} MiB ({d} files)\n", .{ total_mb, stats.file_count });
    inline for (.{
        .{ "DXVK", stats.dxvk_size },
        .{ "vkd3d-proton", stats.vkd3d_size },
        .{ "NVIDIA", stats.nvidia_size },
        .{ "Mesa", stats.mesa_size },
        .{ "Fossilize", stats.fossilize_size },
    }) |entry| {
        const label = entry[0];
        const size_bytes: u64 = entry[1];
        if (size_bytes == 0) continue;
        const size_float: f64 = @floatFromInt(size_bytes);
        const size_mb = size_float / (1024.0 * 1024.0);
        try writer.print("  • {s}: {d:.2} MiB\n", .{ label, size_mb });
    }
}
