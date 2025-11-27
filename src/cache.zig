const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const math = std.math;
const path_util = std.fs.path;
const paths = @import("paths.zig");
const types = @import("types.zig");

/// DXVK cache file header (v8 format)
pub const DxvkCacheHeader = extern struct {
    magic: [4]u8, // "DXVK"
    version: u32,
    entry_size: u32,
};

/// In-memory representation of a DXVK/vkd3d cache file.
pub const DxvkStateCache = struct {
    allocator: mem.Allocator,
    header: DxvkCacheHeader,
    payload: []u8,

    pub fn read(allocator: mem.Allocator, path: []const u8) !DxvkStateCache {
        const file = try fs.cwd().openFile(path, .{});
        defer file.close();

        var header: DxvkCacheHeader = undefined;
        try file.readNoEof(std.mem.asBytes(&header));

        if (!mem.eql(u8, &header.magic, "DXVK")) return error.InvalidCacheFile;
        if (header.entry_size == 0) return error.InvalidCacheFile;

        const stat = try file.stat();
        if (stat.size < @sizeOf(DxvkCacheHeader)) return error.InvalidCacheFile;

        const payload_size_u64 = stat.size - @sizeOf(DxvkCacheHeader);
        if (payload_size_u64 % header.entry_size != 0) return error.InvalidCacheFile;
        if (payload_size_u64 > math.maxInt(usize)) return error.CacheTooLarge;

        const payload_len: usize = @intCast(payload_size_u64);
        const payload = try allocator.alloc(u8, payload_len);
        errdefer allocator.free(payload);

        try file.readNoEof(payload);

        return DxvkStateCache{
            .allocator = allocator,
            .header = header,
            .payload = payload,
        };
    }

    pub fn deinit(self: *DxvkStateCache) void {
        self.allocator.free(self.payload);
    }

    pub fn entryCount(self: *const DxvkStateCache) u32 {
        if (self.header.entry_size == 0) return 0;
        const entry_size: usize = @intCast(self.header.entry_size);
        return @intCast(self.payload.len / entry_size);
    }

    pub fn write(self: *const DxvkStateCache, path: []const u8) !void {
        if (self.header.entry_size == 0) return error.InvalidCacheFile;
        const entry_size_usize: usize = @intCast(self.header.entry_size);
        if (self.payload.len % entry_size_usize != 0) return error.InvalidCacheFile;

        const file = try fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();

        try file.writeAll(std.mem.asBytes(&self.header));
        try file.writeAll(self.payload);
    }
};

pub const Vkd3dPipelineCache = DxvkStateCache;

const DxvkValidationResult = struct {
    header: DxvkCacheHeader,
    payload_size: u64,
};

/// Cache entry metadata
pub const CacheEntry = struct {
    path: []const u8,
    cache_type: types.CacheType,
    size_bytes: u64,
    modified_time: i128,
    game_name: ?[]const u8,
    entry_count: ?u32,
    is_directory: bool,

    allocator: mem.Allocator,

    pub fn deinit(self: *CacheEntry) void {
        self.allocator.free(self.path);
        if (self.game_name) |name| self.allocator.free(name);
    }

    pub fn sizeMb(self: *const CacheEntry) f64 {
        const size_f: f64 = @floatFromInt(self.size_bytes);
        return size_f / (1024.0 * 1024.0);
    }
};

pub const CacheValidation = struct {
    checked: u32,
    invalid: u32,
};

/// Main cache manager
pub const CacheManager = struct {
    allocator: mem.Allocator,
    cache_paths: paths.CachePaths,
    entries: std.ArrayListUnmanaged(CacheEntry),

    pub fn init(allocator: mem.Allocator) !CacheManager {
        return CacheManager{
            .allocator = allocator,
            .cache_paths = try paths.CachePaths.detect(allocator),
            .entries = .{},
        };
    }

    pub fn deinit(self: *CacheManager) void {
        for (self.entries.items) |*entry| {
            entry.deinit();
        }
        self.entries.deinit(self.allocator);
        self.cache_paths.deinit();
    }

    /// Scan all cache locations and populate entries
    pub fn scan(self: *CacheManager) !void {
        for (self.entries.items) |*entry| entry.deinit();
        self.entries.clearRetainingCapacity();

        if (self.cache_paths.dxvk) |dxvk_path| {
            try self.scanDxvkCaches(dxvk_path);
        }

        if (self.cache_paths.vkd3d) |vkd3d_path| {
            try self.scanVkd3dCaches(vkd3d_path);
        }

        if (self.cache_paths.nvidia) |nvidia_path| {
            try self.scanNvidiaCache(nvidia_path);
        }

        if (self.cache_paths.mesa) |mesa_path| {
            try self.scanMesaCache(mesa_path);
        }

        if (self.cache_paths.fossilize) |fossilize_path| {
            try self.scanFossilizeCaches(fossilize_path);
        }

        if (self.cache_paths.steam_shadercache) |steam_path| {
            try self.scanSteamShaderCache(steam_path);
        }
    }

    fn scanDxvkCaches(self: *CacheManager, base_path: []const u8) !void {
        var dir = fs.cwd().openDir(base_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and mem.endsWith(u8, entry.name, ".dxvk-cache")) {
                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_path, entry.name });
                errdefer self.allocator.free(full_path);

                const stat = dir.statFile(entry.name) catch {
                    self.allocator.free(full_path);
                    continue;
                };

                const entry_count = self.countDxvkEntries(full_path) catch {
                    self.allocator.free(full_path);
                    continue;
                };

                const game_name = extractGameName(self.allocator, entry.name, ".dxvk-cache") catch null;
                if (game_name) |name_ptr| {
                    errdefer self.allocator.free(name_ptr);
                }

                try self.entries.append(self.allocator, CacheEntry{
                    .path = full_path,
                    .cache_type = .dxvk,
                    .size_bytes = stat.size,
                    .modified_time = stat.mtime,
                    .game_name = game_name,
                    .entry_count = entry_count,
                    .is_directory = false,
                    .allocator = self.allocator,
                });
            }
        }
    }

    fn scanVkd3dCaches(self: *CacheManager, base_path: []const u8) !void {
        var dir = fs.cwd().openDir(base_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and mem.endsWith(u8, entry.name, ".dxvk-cache")) {
                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_path, entry.name });
                errdefer self.allocator.free(full_path);

                const stat = dir.statFile(entry.name) catch {
                    self.allocator.free(full_path);
                    continue;
                };

                const entry_count = self.countDxvkEntries(full_path) catch {
                    self.allocator.free(full_path);
                    continue;
                };

                const game_name = extractGameName(self.allocator, entry.name, ".dxvk-cache") catch null;
                if (game_name) |name_ptr| {
                    errdefer self.allocator.free(name_ptr);
                }

                try self.entries.append(self.allocator, CacheEntry{
                    .path = full_path,
                    .cache_type = .vkd3d,
                    .size_bytes = stat.size,
                    .modified_time = stat.mtime,
                    .game_name = game_name,
                    .entry_count = entry_count,
                    .is_directory = false,
                    .allocator = self.allocator,
                });
            }
        }
    }

    fn scanFossilizeCaches(self: *CacheManager, base_path: []const u8) !void {
        var dir = fs.cwd().openDir(base_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            switch (entry.kind) {
                .file => {
                    if (!mem.endsWith(u8, entry.name, ".foz")) continue;

                    const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_path, entry.name });
                    errdefer self.allocator.free(full_path);

                    const stat = dir.statFile(entry.name) catch {
                        self.allocator.free(full_path);
                        continue;
                    };

                    const game_name = extractGameName(self.allocator, entry.name, ".foz") catch null;
                    if (game_name) |name_ptr| {
                        errdefer self.allocator.free(name_ptr);
                    }

                    try self.entries.append(self.allocator, CacheEntry{
                        .path = full_path,
                        .cache_type = .fossilize,
                        .size_bytes = stat.size,
                        .modified_time = stat.mtime,
                        .game_name = game_name,
                        .entry_count = null,
                        .is_directory = false,
                        .allocator = self.allocator,
                    });
                },
                .directory => {
                    const dir_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_path, entry.name });
                    errdefer self.allocator.free(dir_path);

                    const stat = dir.statFile(entry.name) catch {
                        self.allocator.free(dir_path);
                        continue;
                    };

                    const size = paths.getDirSize(self.allocator, dir_path) catch {
                        self.allocator.free(dir_path);
                        continue;
                    };

                    if (size == 0) {
                        self.allocator.free(dir_path);
                        continue;
                    }

                    const count = paths.countFiles(self.allocator, dir_path) catch 0;
                    const label = try std.fmt.allocPrint(self.allocator, "Fossilize Cache {s}", .{entry.name});
                    errdefer self.allocator.free(label);

                    try self.entries.append(self.allocator, CacheEntry{
                        .path = dir_path,
                        .cache_type = .fossilize,
                        .size_bytes = size,
                        .modified_time = stat.mtime,
                        .game_name = label,
                        .entry_count = count,
                        .is_directory = true,
                        .allocator = self.allocator,
                    });
                },
                else => {},
            }
        }
    }

    fn scanNvidiaCache(self: *CacheManager, base_path: []const u8) !void {
        var dir = fs.cwd().openDir(base_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        var found_any = false;

        while (try iter.next()) |entry| {
            if (entry.kind != .directory) continue;

            const sub_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_path, entry.name });
            errdefer self.allocator.free(sub_path);

            const stat = dir.statFile(entry.name) catch {
                self.allocator.free(sub_path);
                continue;
            };

            const size = paths.getDirSize(self.allocator, sub_path) catch {
                self.allocator.free(sub_path);
                continue;
            };

            if (size == 0) {
                self.allocator.free(sub_path);
                continue;
            }

            const count = paths.countFiles(self.allocator, sub_path) catch 0;
            const label = try std.fmt.allocPrint(self.allocator, "Compute Cache {s}", .{entry.name});
            errdefer self.allocator.free(label);

            try self.entries.append(self.allocator, CacheEntry{
                .path = sub_path,
                .cache_type = .nvidia,
                .size_bytes = size,
                .modified_time = stat.mtime,
                .game_name = label,
                .entry_count = count,
                .is_directory = true,
                .allocator = self.allocator,
            });

            found_any = true;
        }

        if (!found_any) {
            const size = paths.getDirSize(self.allocator, base_path) catch 0;
            if (size == 0) return;
            const count = paths.countFiles(self.allocator, base_path) catch 0;
            const stat = fs.cwd().statFileAbsolute(base_path) catch null;
            const mtime = if (stat) |s| s.mtime else std.time.nanoTimestamp();

            try self.entries.append(self.allocator, CacheEntry{
                .path = try self.allocator.dupe(u8, base_path),
                .cache_type = .nvidia,
                .size_bytes = size,
                .modified_time = mtime,
                .game_name = try self.allocator.dupe(u8, "NVIDIA Driver Cache"),
                .entry_count = count,
                .is_directory = true,
                .allocator = self.allocator,
            });
        }
    }

    fn scanMesaCache(self: *CacheManager, base_path: []const u8) !void {
        const size = paths.getDirSize(self.allocator, base_path) catch 0;
        if (size == 0) return;

        const count = paths.countFiles(self.allocator, base_path) catch 0;
        const stat = fs.cwd().statFileAbsolute(base_path) catch null;
        const mtime = if (stat) |s| s.mtime else std.time.nanoTimestamp();

        try self.entries.append(self.allocator, CacheEntry{
            .path = try self.allocator.dupe(u8, base_path),
            .cache_type = .mesa,
            .size_bytes = size,
            .modified_time = mtime,
            .game_name = try self.allocator.dupe(u8, "Mesa Shader Cache"),
            .entry_count = count,
            .is_directory = true,
            .allocator = self.allocator,
        });
    }

    fn scanSteamShaderCache(self: *CacheManager, base_path: []const u8) !void {
        var dir = fs.cwd().openDir(base_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .directory) continue;

            const app_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_path, entry.name });
            errdefer self.allocator.free(app_path);

            const stat = dir.statFile(entry.name) catch {
                self.allocator.free(app_path);
                continue;
            };

            const size = paths.getDirSize(self.allocator, app_path) catch {
                self.allocator.free(app_path);
                continue;
            };

            if (size == 0) {
                self.allocator.free(app_path);
                continue;
            }

            const count = paths.countFiles(self.allocator, app_path) catch 0;
            const label = try std.fmt.allocPrint(self.allocator, "Steam AppID {s}", .{entry.name});
            errdefer self.allocator.free(label);

            try self.entries.append(self.allocator, CacheEntry{
                .path = app_path,
                .cache_type = .fossilize,
                .size_bytes = size,
                .modified_time = stat.mtime,
                .game_name = label,
                .entry_count = count,
                .is_directory = true,
                .allocator = self.allocator,
            });
        }
    }

    fn countDxvkEntries(self: *CacheManager, path: []const u8) !u32 {
        _ = self;
        const info = try validateDxvkFile(path);
        if (info.header.entry_size == 0) return 0;
        return @intCast(info.payload_size / info.header.entry_size);
    }

    /// Get total statistics
    pub fn getStats(self: *const CacheManager) types.CacheStats {
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

        for (self.entries.items) |entry| {
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

    /// Clean old cache entries
    pub fn cleanOlderThan(self: *CacheManager, days: u32) !u32 {
        const seconds_per_day: i128 = 24 * 60 * 60;
        const ns_per_s_i128: i128 = @intCast(std.time.ns_per_s);
        const days_i128: i128 = @intCast(days);
        const cutoff_ns = std.time.nanoTimestamp() - (days_i128 * seconds_per_day * ns_per_s_i128);

        var removed: u32 = 0;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].modified_time < cutoff_ns) {
                self.removeEntryAt(i);
                removed += 1;
            } else {
                i += 1;
            }
        }

        return removed;
    }

    pub fn shrinkToSize(self: *CacheManager, max_bytes: u64) !u32 {
        var current_total = self.getStats().total_size_bytes;
        if (current_total <= max_bytes) return 0;

        var removed: u32 = 0;
        while (current_total > max_bytes and self.entries.items.len > 0) {
            var oldest_index: usize = 0;
            var oldest_time = self.entries.items[0].modified_time;

            var idx: usize = 1;
            while (idx < self.entries.items.len) : (idx += 1) {
                if (self.entries.items[idx].modified_time < oldest_time) {
                    oldest_index = idx;
                    oldest_time = self.entries.items[idx].modified_time;
                }
            }

            const removed_size = self.entries.items[oldest_index].size_bytes;
            self.removeEntryAt(oldest_index);
            current_total -= removed_size;
            removed += 1;
        }

        return removed;
    }

    pub fn validate(self: *CacheManager) CacheValidation {
        var report = CacheValidation{ .checked = 0, .invalid = 0 };

        for (self.entries.items) |entry| {
            report.checked += 1;

            switch (entry.cache_type) {
                .dxvk, .vkd3d => {
                    if (validateDxvkFile(entry.path)) |_| {
                        // valid
                    } else |_| {
                        report.invalid += 1;
                    }
                },
                .nvidia, .mesa, .fossilize => {
                    if (!pathExists(entry.path)) {
                        report.invalid += 1;
                    }
                },
            }
        }

        return report;
    }

    fn removeEntryAt(self: *CacheManager, index: usize) void {
        const entry = &self.entries.items[index];
        deletePath(entry.path, entry.is_directory);
        entry.deinit();
        _ = self.entries.swapRemove(index);
    }
};

fn validateDxvkFile(path: []const u8) !DxvkValidationResult {
    const file = try fs.cwd().openFile(path, .{});
    defer file.close();

    var header: DxvkCacheHeader = undefined;
    try file.readNoEof(std.mem.asBytes(&header));

    if (!mem.eql(u8, &header.magic, "DXVK")) return error.InvalidCacheFile;
    if (header.entry_size == 0) return error.InvalidCacheFile;

    const stat = try file.stat();
    if (stat.size < @sizeOf(DxvkCacheHeader)) return error.InvalidCacheFile;
    const payload_size = stat.size - @sizeOf(DxvkCacheHeader);

    if (payload_size % header.entry_size != 0) return error.InvalidCacheFile;

    return .{ .header = header, .payload_size = payload_size };
}

fn deletePath(path_str: []const u8, is_directory: bool) void {
    if (path_util.isAbsolute(path_str)) {
        const dir_path = path_util.dirname(path_str) orelse path_str;
        const base_name = path_util.basename(path_str);
        var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return;
        defer dir.close();

        if (is_directory) {
            dir.deleteTree(base_name) catch {};
        } else {
            dir.deleteFile(base_name) catch {};
        }
    } else {
        if (is_directory) {
            fs.cwd().deleteTree(path_str) catch {};
        } else {
            fs.cwd().deleteFile(path_str) catch {};
        }
    }
}

fn pathExists(path_str: []const u8) bool {
    fs.cwd().access(path_str, .{}) catch return false;
    return true;
}

fn extractGameName(allocator: mem.Allocator, filename: []const u8, suffix: []const u8) ![]const u8 {
    if (mem.endsWith(u8, filename, suffix)) {
        const base = filename[0 .. filename.len - suffix.len];
        return try allocator.dupe(u8, base);
    }
    return try allocator.dupe(u8, filename);
}

test "CacheManager init" {
    const allocator = std.testing.allocator;
    var manager = try CacheManager.init(allocator);
    defer manager.deinit();
}
