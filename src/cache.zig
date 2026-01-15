const std = @import("std");
const mem = std.mem;
const math = std.math;
const path_util = std.fs.path;
const paths = @import("paths.zig");
const types = @import("types.zig");
const games = @import("games.zig");

const Io = std.Io;
const Dir = std.Io.Dir;

/// Get the global debug Io instance for file operations
fn getIo() Io {
    return std.Options.debug_io;
}

fn nowNanoseconds() i128 {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch return 0;
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

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
        const io = getIo();
        const file = try Dir.cwd().openFile(io, path, .{});
        defer file.close(io);

        var header: DxvkCacheHeader = undefined;
        const header_bytes = std.mem.asBytes(&header);
        const header_read = try file.readPositionalAll(io, header_bytes, 0);
        if (header_read < header_bytes.len) return error.InvalidCacheFile;

        if (!mem.eql(u8, &header.magic, "DXVK")) return error.InvalidCacheFile;
        if (header.entry_size == 0) return error.InvalidCacheFile;

        const stat = try file.stat(io);
        if (stat.size < @sizeOf(DxvkCacheHeader)) return error.InvalidCacheFile;

        const payload_size_u64 = stat.size - @sizeOf(DxvkCacheHeader);
        if (payload_size_u64 % header.entry_size != 0) return error.InvalidCacheFile;
        if (payload_size_u64 > math.maxInt(usize)) return error.CacheTooLarge;

        const payload_len: usize = @intCast(payload_size_u64);
        const payload = try allocator.alloc(u8, payload_len);
        errdefer allocator.free(payload);

        const payload_read = try file.readPositionalAll(io, payload, @sizeOf(DxvkCacheHeader));
        if (payload_read < payload_len) {
            allocator.free(payload);
            return error.InvalidCacheFile;
        }

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
        const io = getIo();
        if (self.header.entry_size == 0) return error.InvalidCacheFile;
        const entry_size_usize: usize = @intCast(self.header.entry_size);
        if (self.payload.len % entry_size_usize != 0) return error.InvalidCacheFile;

        const file = try Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer file.close(io);

        try file.writeAll(io, std.mem.asBytes(&self.header));
        try file.writeAll(io, self.payload);
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
    game_id: ?[]const u8,
    game_source: ?games.GameSource,
    entry_count: ?u32,
    is_directory: bool,

    allocator: mem.Allocator,

    pub fn deinit(self: *CacheEntry) void {
        self.allocator.free(self.path);
        if (self.game_name) |name| self.allocator.free(name);
        if (self.game_id) |id| self.allocator.free(id);
    }

    pub fn sizeMb(self: *const CacheEntry) f64 {
        const size_f: f64 = @floatFromInt(self.size_bytes);
        return size_f / (1024.0 * 1024.0);
    }

    pub fn assignGame(self: *CacheEntry, game: *const games.Game) !void {
        const target_id = game.id;
        const target_name = game.name;
        const same_id = if (self.game_id) |existing| mem.eql(u8, existing, target_id) else false;

        if (!same_id) {
            if (self.game_id) |existing| self.allocator.free(existing);
            if (self.game_name) |existing| self.allocator.free(existing);

            const id_copy = try self.allocator.dupe(u8, target_id);
            errdefer self.allocator.free(id_copy);
            const name_copy = try self.allocator.dupe(u8, target_name);

            self.game_id = id_copy;
            self.game_name = name_copy;
        } else {
            const needs_name_update = if (self.game_name) |existing|
                !mem.eql(u8, existing, target_name)
            else
                true;

            if (needs_name_update) {
                if (self.game_name) |existing| self.allocator.free(existing);
                const name_copy = try self.allocator.dupe(u8, target_name);
                self.game_name = name_copy;
            }
        }

        self.game_source = game.source;
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
        const io = getIo();
        var dir = Dir.cwd().openDir(io, base_path, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind == .file and mem.endsWith(u8, entry.name, ".dxvk-cache")) {
                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_path, entry.name });
                errdefer self.allocator.free(full_path);

                const stat = dir.statFile(io, entry.name, .{}) catch {
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
                    .modified_time = timestampToNanoseconds(stat.mtime),
                    .game_name = game_name,
                    .game_id = null,
                    .game_source = null,
                    .entry_count = entry_count,
                    .is_directory = false,
                    .allocator = self.allocator,
                });
            }
        }
    }

    fn scanVkd3dCaches(self: *CacheManager, base_path: []const u8) !void {
        const io = getIo();
        var dir = Dir.cwd().openDir(io, base_path, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind == .file and mem.endsWith(u8, entry.name, ".dxvk-cache")) {
                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_path, entry.name });
                errdefer self.allocator.free(full_path);

                const stat = dir.statFile(io, entry.name, .{}) catch {
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
                    .modified_time = timestampToNanoseconds(stat.mtime),
                    .game_name = game_name,
                    .game_id = null,
                    .game_source = null,
                    .entry_count = entry_count,
                    .is_directory = false,
                    .allocator = self.allocator,
                });
            }
        }
    }

    fn scanFossilizeCaches(self: *CacheManager, base_path: []const u8) !void {
        const io = getIo();
        var dir = Dir.cwd().openDir(io, base_path, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            switch (entry.kind) {
                .file => {
                    if (!mem.endsWith(u8, entry.name, ".foz")) continue;

                    const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_path, entry.name });
                    errdefer self.allocator.free(full_path);

                    const stat = dir.statFile(io, entry.name, .{}) catch {
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
                        .modified_time = timestampToNanoseconds(stat.mtime),
                        .game_name = game_name,
                        .game_id = null,
                        .game_source = null,
                        .entry_count = null,
                        .is_directory = false,
                        .allocator = self.allocator,
                    });
                },
                .directory => {
                    const dir_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_path, entry.name });
                    errdefer self.allocator.free(dir_path);

                    const stat = dir.statFile(io, entry.name, .{}) catch {
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
                        .modified_time = timestampToNanoseconds(stat.mtime),
                        .game_name = label,
                        .game_id = null,
                        .game_source = null,
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
        const io = getIo();
        var dir = Dir.cwd().openDir(io, base_path, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var iter = dir.iterate();
        var found_any = false;

        while (try iter.next(io)) |entry| {
            if (entry.kind != .directory) continue;

            const sub_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_path, entry.name });
            errdefer self.allocator.free(sub_path);

            const stat = dir.statFile(io, entry.name, .{}) catch {
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
                .modified_time = timestampToNanoseconds(stat.mtime),
                .game_name = label,
                .game_id = null,
                .game_source = null,
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
            const mtime = blk: {
                var dir_stat = Dir.openDirAbsolute(io, base_path, .{}) catch break :blk nowNanoseconds();
                defer dir_stat.close(io);
                const status = dir_stat.stat(io) catch break :blk nowNanoseconds();
                break :blk timestampToNanoseconds(status.mtime);
            };

            try self.entries.append(self.allocator, CacheEntry{
                .path = try self.allocator.dupe(u8, base_path),
                .cache_type = .nvidia,
                .size_bytes = size,
                .modified_time = mtime,
                .game_name = try self.allocator.dupe(u8, "NVIDIA Driver Cache"),
                .game_id = null,
                .game_source = null,
                .entry_count = count,
                .is_directory = true,
                .allocator = self.allocator,
            });
        }
    }

    fn scanMesaCache(self: *CacheManager, base_path: []const u8) !void {
        const io = getIo();
        const size = paths.getDirSize(self.allocator, base_path) catch 0;
        if (size == 0) return;

        const count = paths.countFiles(self.allocator, base_path) catch 0;
        const mtime = blk: {
            var dir_stat = Dir.openDirAbsolute(io, base_path, .{}) catch break :blk nowNanoseconds();
            defer dir_stat.close(io);
            const status = dir_stat.stat(io) catch break :blk nowNanoseconds();
            break :blk timestampToNanoseconds(status.mtime);
        };

        try self.entries.append(self.allocator, CacheEntry{
            .path = try self.allocator.dupe(u8, base_path),
            .cache_type = .mesa,
            .size_bytes = size,
            .modified_time = mtime,
            .game_name = try self.allocator.dupe(u8, "Mesa Shader Cache"),
            .game_id = null,
            .game_source = null,
            .entry_count = count,
            .is_directory = true,
            .allocator = self.allocator,
        });
    }

    fn scanSteamShaderCache(self: *CacheManager, base_path: []const u8) !void {
        const io = getIo();
        var dir = Dir.cwd().openDir(io, base_path, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind != .directory) continue;

            const app_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_path, entry.name });
            errdefer self.allocator.free(app_path);

            const stat = dir.statFile(io, entry.name, .{}) catch {
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

            const modified_time = timestampToNanoseconds(stat.mtime);

            try self.entries.append(self.allocator, CacheEntry{
                .path = app_path,
                .cache_type = .fossilize,
                .size_bytes = size,
                .modified_time = modified_time,
                .game_name = label,
                .game_id = null,
                .game_source = null,
                .entry_count = count,
                .is_directory = true,
                .allocator = self.allocator,
            });
        }
    }

    pub fn associateGames(self: *CacheManager, catalog: *const games.GameCatalog) !void {
        for (self.entries.items) |*entry| {
            if (entry.game_id) |id| {
                if (findGameById(catalog, id)) |game| {
                    try entry.assignGame(game);
                    continue;
                }
            }

            var matched: ?*const games.Game = null;

            if (entry.game_name) |name| {
                matched = findGameByName(catalog, name);
            }

            if (matched == null) {
                matched = findGameByHints(catalog, entry.path);
            }

            if (matched) |game| {
                try entry.assignGame(game);
            }
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
        const cutoff_ns = nowNanoseconds() - (days_i128 * seconds_per_day * ns_per_s_i128);

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

fn findGameById(catalog: *const games.GameCatalog, id: []const u8) ?*const games.Game {
    for (catalog.games.items) |*game| {
        if (mem.eql(u8, game.id, id)) return game;
    }
    return null;
}

fn findGameByName(catalog: *const games.GameCatalog, name: []const u8) ?*const games.Game {
    for (catalog.games.items) |*game| {
        if (std.ascii.eqlIgnoreCase(game.name, name)) return game;
    }

    for (catalog.games.items) |*game| {
        if (containsIgnoreCase(name, game.name)) return game;
    }

    return null;
}

fn findGameByHints(catalog: *const games.GameCatalog, entry_path: []const u8) ?*const games.Game {
    var best: ?*const games.Game = null;
    var best_score: usize = 0;

    for (catalog.games.items) |*game| {
        for (game.cache_paths.items) |hint| {
            const score = hintMatchScore(entry_path, hint);
            if (score > best_score) {
                best = game;
                best_score = score;
            }
        }

        const install_score = hintMatchScore(entry_path, game.install_path);
        if (install_score > best_score) {
            best = game;
            best_score = install_score;
        }

        const steam_score = steamMatchScore(entry_path, game);
        if (steam_score > best_score) {
            best = game;
            best_score = steam_score;
        }
    }

    return best;
}

fn hintMatchScore(entry_path: []const u8, raw_hint: []const u8) usize {
    const hint = trimTrailingSeparators(raw_hint);
    if (hint.len == 0 or hint.len > entry_path.len) return 0;
    if (!mem.startsWith(u8, entry_path, hint)) return 0;
    if (entry_path.len == hint.len) return hint.len;
    const next = entry_path[hint.len];
    if (!isPathSeparator(next)) return 0;
    return hint.len;
}

fn trimTrailingSeparators(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0) : (end -= 1) {
        const ch = value[end - 1];
        if (!(ch == '/' or ch == '\\')) break;
    }
    return value[0..end];
}

fn steamMatchScore(entry_path: []const u8, game: *const games.Game) usize {
    if (game.source != .steam) return 0;
    const sep = mem.indexOfScalar(u8, game.id, ':') orelse return 0;
    if (sep + 1 >= game.id.len) return 0;
    const app_id = game.id[sep + 1 ..];
    if (pathContainsSegment(entry_path, app_id)) {
        return app_id.len;
    }
    return 0;
}

fn pathContainsSegment(path: []const u8, segment: []const u8) bool {
    if (segment.len == 0 or segment.len > path.len) return false;
    var idx: usize = 0;
    const limit = path.len - segment.len;
    while (idx <= limit) : (idx += 1) {
        if (!mem.eql(u8, path[idx .. idx + segment.len], segment)) continue;
        const before_ok = idx == 0 or isPathSeparator(path[idx - 1]);
        const after_index = idx + segment.len;
        const after_ok = after_index == path.len or isPathSeparator(path[after_index]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

fn isPathSeparator(ch: u8) bool {
    return ch == '/' or ch == '\\';
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var offset: usize = 0;
    const limit = haystack.len - needle.len;
    while (offset <= limit) : (offset += 1) {
        var matched = true;
        var i: usize = 0;
        while (i < needle.len) : (i += 1) {
            if (std.ascii.toLower(haystack[offset + i]) != std.ascii.toLower(needle[i])) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn validateDxvkFile(path: []const u8) !DxvkValidationResult {
    const io = getIo();
    const file = try Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var header: DxvkCacheHeader = undefined;
    const header_bytes = std.mem.asBytes(&header);
    const header_read = try file.readPositionalAll(io, header_bytes, 0);
    if (header_read < header_bytes.len) return error.InvalidCacheFile;

    if (!mem.eql(u8, &header.magic, "DXVK")) return error.InvalidCacheFile;
    if (header.entry_size == 0) return error.InvalidCacheFile;

    const stat = try file.stat(io);
    if (stat.size < @sizeOf(DxvkCacheHeader)) return error.InvalidCacheFile;
    const payload_size = stat.size - @sizeOf(DxvkCacheHeader);

    if (payload_size % header.entry_size != 0) return error.InvalidCacheFile;

    return .{ .header = header, .payload_size = payload_size };
}

fn timestampToNanoseconds(ts: std.Io.Timestamp) i128 {
    return ts.toNanoseconds();
}

fn deletePath(path_str: []const u8, is_directory: bool) void {
    const io = getIo();
    if (path_util.isAbsolute(path_str)) {
        const dir_path = path_util.dirname(path_str) orelse path_str;
        const base_name = path_util.basename(path_str);
        var dir = Dir.openDirAbsolute(io, dir_path, .{}) catch return;
        defer dir.close(io);

        if (is_directory) {
            dir.deleteTree(io, base_name) catch {};
        } else {
            dir.deleteFile(io, base_name) catch {};
        }
    } else {
        if (is_directory) {
            Dir.cwd().deleteTree(io, path_str) catch {};
        } else {
            Dir.cwd().deleteFile(io, path_str) catch {};
        }
    }
}

fn pathExists(path_str: []const u8) bool {
    Dir.cwd().access(getIo(), path_str, .{}) catch return false;
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
