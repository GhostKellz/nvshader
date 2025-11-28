const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const json = std.json;
const cache = @import("cache.zig");
const types = @import("types.zig");

pub const ExportReport = struct {
    entries: usize,
    files_copied: usize,
    bytes_copied: u64,
};

pub const ImportReport = struct {
    entries: usize,
    files_restored: usize,
    bytes_restored: u64,
};

pub const ProgressKind = enum {
    entry_start,
    entry_done,
};

pub const ProgressEvent = struct {
    kind: ProgressKind,
    index: usize,
    total: usize,
    path: []const u8,
};

pub const ProgressHook = struct {
    context: ?*anyopaque = null,
    callback: ?*const fn (context: ?*anyopaque, event: ProgressEvent) anyerror!void = null,

    pub fn emit(self: *const ProgressHook, event: ProgressEvent) !void {
        if (self.callback) |cb| try cb(self.context, event);
    }
};

const ManifestVersion: u32 = 1;

const ManifestEntry = struct {
    cache_type: types.CacheType,
    original_path: []const u8,
    stored_path: []const u8,
    is_directory: bool,
    size_bytes: u64,
};

pub fn exportSelection(
    allocator: mem.Allocator,
    manager: *cache.CacheManager,
    indices: []const usize,
    destination: []const u8,
    game_hint: ?[]const u8,
    progress: ProgressHook,
) !ExportReport {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    fs.cwd().makePath(destination) catch {};
    var dest_dir = try fs.cwd().openDir(destination, .{ .iterate = true });
    defer dest_dir.close();

    try dest_dir.makePath("cache");

    var manifest_entries: std.ArrayListUnmanaged(ManifestEntry) = .{};
    defer {
        for (manifest_entries.items) |entry| {
            allocator.free(entry.stored_path);
            allocator.free(entry.original_path);
        }
        manifest_entries.deinit(allocator);
    }

    var files_copied: usize = 0;
    var bytes_copied: u64 = 0;

    for (indices, 0..) |entry_index, idx| {
        const entry = manager.entries.items[entry_index];
        try progress.emit(.{
            .kind = .entry_start,
            .index = idx,
            .total = indices.len,
            .path = entry.path,
        });
        const stored_rel = try std.fmt.allocPrint(allocator, "{d}_{s}", .{ idx, fs.path.basename(entry.path) });
        errdefer allocator.free(stored_rel);

        const dest_path = try fs.path.join(arena_alloc, &.{ "cache", stored_rel });
        const full_dest = try fs.path.join(arena_alloc, &.{ destination, dest_path });

        if (entry.is_directory) {
            try copyDirectory(arena_alloc, entry.path, full_dest);
        } else {
            try copyFile(entry.path, full_dest);
        }

        const size = if (entry.is_directory)
            try dirSize(arena_alloc, entry.path)
        else
            entry.size_bytes;

        files_copied += 1;
        bytes_copied += size;

        try manifest_entries.append(allocator, .{
            .cache_type = entry.cache_type,
            .original_path = try allocator.dupe(u8, entry.path),
            .stored_path = stored_rel,
            .is_directory = entry.is_directory,
            .size_bytes = size,
        });

        try progress.emit(.{
            .kind = .entry_done,
            .index = idx,
            .total = indices.len,
            .path = entry.path,
        });

        _ = arena.reset(.retain_capacity);
    }

    const manifest_path = try fs.path.join(arena_alloc, &.{ destination, "manifest.json" });
    try writeManifest(manifest_path, manifest_entries.items, game_hint);

    return ExportReport{
        .entries = indices.len,
        .files_copied = files_copied,
        .bytes_copied = bytes_copied,
    };
}

pub fn importDirectory(
    allocator: mem.Allocator,
    source: []const u8,
    destination_override: ?[]const u8,
    progress: ProgressHook,
) !ImportReport {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const manifest_path = try fs.path.join(arena_alloc, &.{ source, "manifest.json" });

    const manifest_data = try fs.cwd().readFileAlloc(manifest_path, allocator, .unlimited);
    defer allocator.free(manifest_data);

    var parsed = json.parseFromSlice(json.Value, allocator, manifest_data, .{}) catch return error.InvalidManifest;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidManifest;

    const version_val = root.object.get("version") orelse return error.InvalidManifest;
    const version: i64 = if (version_val == .integer) version_val.integer else return error.InvalidManifest;
    if (version != ManifestVersion) return error.UnsupportedManifest;

    const entries_val = root.object.get("entries") orelse return error.InvalidManifest;
    if (entries_val != .array) return error.InvalidManifest;

    const total_entries = entries_val.array.items.len;
    var files_restored: usize = 0;
    var bytes_restored: u64 = 0;

    for (entries_val.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;

        const stored = obj.get("stored_path") orelse continue;
        const original = obj.get("original_path") orelse continue;
        const dir_flag = obj.get("is_directory") orelse continue;
        const size_node = obj.get("size_bytes") orelse continue;

        const stored_str = if (stored == .string) stored.string else continue;
        const original_str = if (original == .string) original.string else continue;
        const is_directory = if (dir_flag == .bool) dir_flag.bool else false;
        const size_bytes: i64 = if (size_node == .integer) size_node.integer else 0;

        const current_index = files_restored;
        try progress.emit(.{
            .kind = .entry_start,
            .index = current_index,
            .total = total_entries,
            .path = original_str,
        });

        const src_path = try fs.path.join(arena_alloc, &.{ source, "cache", stored_str });
        var owned_target: ?[]const u8 = null;
        const target_base = if (destination_override) |override| blk: {
            break :blk try fs.path.join(arena_alloc, &.{ override, fs.path.basename(original_str) });
        } else blk: {
            const dup = try allocator.dupe(u8, original_str);
            owned_target = dup;
            break :blk dup;
        };
        defer if (owned_target) |buf| allocator.free(buf);

        if (is_directory) {
            try copyDirectory(arena_alloc, src_path, target_base);
        } else {
            try copyFile(src_path, target_base);
        }

        files_restored += 1;
        bytes_restored += @intCast(size_bytes);

        try progress.emit(.{
            .kind = .entry_done,
            .index = current_index,
            .total = total_entries,
            .path = original_str,
        });

        _ = arena.reset(.retain_capacity);
    }

    return ImportReport{
        .entries = files_restored,
        .files_restored = files_restored,
        .bytes_restored = bytes_restored,
    };
}

fn dirSize(allocator: mem.Allocator, path: []const u8) !u64 {
    var total: u64 = 0;
    var dir = try fs.openDirAbsolute(path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const child = try fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child);
        switch (entry.kind) {
            .file => {
                const stat = try dir.statFile(entry.name);
                total += stat.size;
            },
            .directory => total += try dirSize(allocator, child),
            else => {},
        }
    }
    return total;
}

fn writeManifest(path: []const u8, entries: []const ManifestEntry, game_hint: ?[]const u8) !void {
    const file = try fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    var buf: [65536]u8 = undefined;
    var pos: usize = 0;

    const ts = std.posix.clock_gettime(.REALTIME) catch std.os.linux.timespec{ .sec = 0, .nsec = 0 };

    pos += (std.fmt.bufPrint(buf[pos..], "{{\n  \"version\": {d},\n  \"created_at\": {d},\n", .{ ManifestVersion, ts.sec }) catch return error.BufferOverflow).len;

    if (game_hint) |hint| {
        pos += (std.fmt.bufPrint(buf[pos..], "  \"game\": \"{s}\",\n", .{hint}) catch return error.BufferOverflow).len;
    }
    pos += (std.fmt.bufPrint(buf[pos..], "  \"entries\": [\n", .{}) catch return error.BufferOverflow).len;

    var first = true;
    for (entries) |entry| {
        if (!first) {
            pos += (std.fmt.bufPrint(buf[pos..], ",\n", .{}) catch return error.BufferOverflow).len;
        }
        first = false;
        pos += (std.fmt.bufPrint(buf[pos..], "    {{\n      \"cache_type\": \"{s}\",\n      \"original_path\": \"{s}\",\n      \"stored_path\": \"{s}\",\n      \"is_directory\": {s},\n      \"size_bytes\": {d}\n    }}", .{
            entry.cache_type.name(),
            entry.original_path,
            entry.stored_path,
            if (entry.is_directory) "true" else "false",
            entry.size_bytes,
        }) catch return error.BufferOverflow).len;
    }

    pos += (std.fmt.bufPrint(buf[pos..], "\n  ]\n}}\n", .{}) catch return error.BufferOverflow).len;

    _ = try file.pwrite(buf[0..pos], 0);
}

fn copyFile(src_path: []const u8, dest_path: []const u8) !void {
    const dest_parent = fs.path.dirname(dest_path) orelse ".";
    fs.cwd().makePath(dest_parent) catch {};

    const src_file = try fs.cwd().openFile(src_path, .{});
    defer src_file.close();

    const dest_file = try fs.cwd().createFile(dest_path, .{ .truncate = true });
    defer dest_file.close();

    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const read_bytes = src_file.pread(&buffer, offset) catch break;
        if (read_bytes == 0) break;
        _ = dest_file.pwrite(buffer[0..read_bytes], offset) catch break;
        offset += read_bytes;
    }
}

fn copyDirectory(allocator: mem.Allocator, src_path: []const u8, dest_path: []const u8) !void {
    fs.cwd().makePath(dest_path) catch {};
    var dir = try fs.openDirAbsolute(src_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const from = try fs.path.join(allocator, &.{ src_path, entry.name });
        defer allocator.free(from);
        const to = try fs.path.join(allocator, &.{ dest_path, entry.name });
        defer allocator.free(to);

        switch (entry.kind) {
            .file => try copyFile(from, to),
            .directory => try copyDirectory(allocator, from, to),
            else => {},
        }
    }
}
