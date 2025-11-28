const std = @import("std");

/// Cache types supported by nvshader.
pub const CacheType = enum {
    dxvk,
    vkd3d,
    nvidia,
    mesa,
    fossilize,

    pub fn name(self: CacheType) []const u8 {
        return switch (self) {
            .dxvk => "DXVK State Cache",
            .vkd3d => "vkd3d-proton Pipeline Cache",
            .nvidia => "NVIDIA Compute Cache",
            .mesa => "Mesa Shader Cache",
            .fossilize => "Fossilize/Steam Cache",
        };
    }

    pub fn shortName(self: CacheType) []const u8 {
        return switch (self) {
            .dxvk => "dxvk",
            .vkd3d => "vkd3d",
            .nvidia => "nvidia",
            .mesa => "mesa",
            .fossilize => "fossilize",
        };
    }

    pub fn fromString(raw: []const u8) ?CacheType {
        if (std.ascii.eqlIgnoreCase(raw, "dxvk")) return .dxvk;
        if (std.ascii.eqlIgnoreCase(raw, "vkd3d")) return .vkd3d;
        if (std.ascii.eqlIgnoreCase(raw, "nvidia")) return .nvidia;
        if (std.ascii.eqlIgnoreCase(raw, "mesa")) return .mesa;
        if (std.ascii.eqlIgnoreCase(raw, "fossilize")) return .fossilize;
        return null;
    }

    pub fn extension(self: CacheType) []const u8 {
        return switch (self) {
            .dxvk => ".dxvk-cache",
            .vkd3d => ".dxvk-cache", // vkd3d uses same layout
            .nvidia => "", // directory based cache
            .mesa => "", // directory based cache
            .fossilize => ".foz",
        };
    }
};

/// GPU information for cache compatibility.
pub const GpuInfo = struct {
    vendor_id: u32,
    device_id: u32,
    driver_version: []const u8,
    architecture: []const u8,

    pub fn isNvidia(self: *const GpuInfo) bool {
        return self.vendor_id == 0x10de;
    }
};

/// Aggregated statistics across caches.
pub const CacheStats = struct {
    total_size_bytes: u64,
    file_count: u32,
    game_count: u32,
    oldest_entry: ?i128,
    newest_entry: ?i128,

    dxvk_size: u64,
    vkd3d_size: u64,
    nvidia_size: u64,
    mesa_size: u64,
    fossilize_size: u64,

    pub fn totalSizeMb(self: *const CacheStats) f64 {
        const size_f: f64 = @floatFromInt(self.total_size_bytes);
        return size_f / (1024.0 * 1024.0);
    }
};
