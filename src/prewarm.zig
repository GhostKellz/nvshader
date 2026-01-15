const std = @import("std");
const mem = std.mem;
const types = @import("types.zig");
const cache = @import("cache.zig");

const Io = std.Io;
const Dir = std.Io.Dir;

/// Get the global debug Io instance for file operations
fn getIo() Io {
    return std.Options.debug_io;
}

/// Get environment variable using libc
fn getEnv(name: [*:0]const u8) ?[]const u8 {
    const result = std.c.getenv(name);
    if (result) |ptr| {
        return std.mem.sliceTo(ptr, 0);
    }
    return null;
}

/// Pre-warming status for a cache entry
pub const PrewarmStatus = enum {
    pending,
    compiling,
    completed,
    failed,
    skipped,
};

/// Progress callback for pre-warming operations
pub const PrewarmProgress = struct {
    total: usize,
    completed: usize,
    failed: usize,
    current_file: ?[]const u8,
    status: PrewarmStatus,
};

pub const PrewarmCallback = *const fn (progress: PrewarmProgress) void;

/// Fossilize replay configuration
pub const FossilizeConfig = struct {
    /// Path to fossilize_replay binary
    replay_binary: ?[]const u8 = null,
    /// Number of parallel compilation threads
    num_threads: u32 = 4,
    /// Pipeline cache directory
    pipeline_cache_dir: ?[]const u8 = null,
    /// Timeout per shader in milliseconds
    timeout_ms: u32 = 30000,
    /// Skip validation layers
    skip_validation: bool = true,
};

/// Pre-warming engine for shader caches
pub const PrewarmEngine = struct {
    allocator: mem.Allocator,
    config: FossilizeConfig,
    fossilize_path: ?[]const u8,

    pub fn init(allocator: mem.Allocator, config: FossilizeConfig) !PrewarmEngine {
        var engine = PrewarmEngine{
            .allocator = allocator,
            .config = config,
            .fossilize_path = null,
        };

        // Find fossilize_replay binary
        engine.fossilize_path = try engine.findFossilize();
        return engine;
    }

    pub fn deinit(self: *PrewarmEngine) void {
        if (self.fossilize_path) |path| {
            self.allocator.free(path);
        }
    }

    fn findFossilize(self: *PrewarmEngine) !?[]const u8 {
        // Check explicit config first
        if (self.config.replay_binary) |path| {
            if (pathExists(path)) {
                return try self.allocator.dupe(u8, path);
            }
        }

        // Check common locations
        const locations = [_][]const u8{
            "/usr/bin/fossilize_replay",
            "/usr/local/bin/fossilize_replay",
            "/opt/fossilize/fossilize_replay",
        };

        for (locations) |loc| {
            if (pathExists(loc)) {
                return try self.allocator.dupe(u8, loc);
            }
        }

        // Check Steam's bundled fossilize
        const home = getEnv("HOME") orelse return null;
        const steam_paths = [_][]const u8{
            "/.steam/steam/ubuntu12_32/fossilize_replay",
            "/.local/share/Steam/ubuntu12_32/fossilize_replay",
        };

        for (steam_paths) |suffix| {
            const full = try mem.concat(self.allocator, u8, &.{ home, suffix });
            defer self.allocator.free(full);
            if (pathExists(full)) {
                return try self.allocator.dupe(u8, full);
            }
        }

        return null;
    }

    /// Check if pre-warming is available (fossilize found)
    pub fn isAvailable(self: *const PrewarmEngine) bool {
        return self.fossilize_path != null;
    }

    /// Pre-warm a single Fossilize cache file
    pub fn prewarmFossilize(
        self: *PrewarmEngine,
        foz_path: []const u8,
        callback: ?PrewarmCallback,
    ) !PrewarmStatus {
        const replay_path = self.fossilize_path orelse return error.FossilizeNotFound;

        if (callback) |cb| {
            cb(.{
                .total = 1,
                .completed = 0,
                .failed = 0,
                .current_file = foz_path,
                .status = .compiling,
            });
        }

        // Build fossilize_replay command
        var args = std.ArrayListUnmanaged([]const u8){};
        defer args.deinit(self.allocator);

        try args.append(self.allocator, replay_path);
        try args.append(self.allocator, "--spirv-val");
        try args.append(self.allocator, "0");

        // Add thread count
        var thread_buf: [16]u8 = undefined;
        const thread_str = try std.fmt.bufPrint(&thread_buf, "{d}", .{self.config.num_threads});
        try args.append(self.allocator, "--num-threads");
        try args.append(self.allocator, thread_str);

        // Add pipeline cache dir if specified
        if (self.config.pipeline_cache_dir) |cache_dir| {
            try args.append(self.allocator, "--pipeline-cache");
            try args.append(self.allocator, cache_dir);
        }

        try args.append(self.allocator, foz_path);

        // Execute fossilize_replay
        const io = getIo();
        var child = try std.process.spawn(io, .{
            .argv = args.items,
            .stderr = .ignore,
            .stdout = .ignore,
        });
        const result = try child.wait(io);

        const status: PrewarmStatus = switch (result) {
            .exited => |code| if (code == 0) .completed else .failed,
            else => .failed,
        };

        if (callback) |cb| {
            cb(.{
                .total = 1,
                .completed = if (status == .completed) 1 else 0,
                .failed = if (status == .failed) 1 else 0,
                .current_file = foz_path,
                .status = status,
            });
        }

        return status;
    }

    /// Pre-warm all Fossilize caches in a directory
    pub fn prewarmDirectory(
        self: *PrewarmEngine,
        dir_path: []const u8,
        callback: ?PrewarmCallback,
    ) !struct { completed: usize, failed: usize } {
        const io = getIo();
        var dir = Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return .{ .completed = 0, .failed = 0 };
        defer dir.close(io);

        var foz_files = std.ArrayListUnmanaged([]const u8){};
        defer {
            for (foz_files.items) |f| self.allocator.free(f);
            foz_files.deinit(self.allocator);
        }

        // Collect .foz files
        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind == .file and mem.endsWith(u8, entry.name, ".foz")) {
                const full_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
                try foz_files.append(self.allocator, full_path);
            }
        }

        var completed: usize = 0;
        var failed: usize = 0;

        for (foz_files.items, 0..) |foz_path, i| {
            if (callback) |cb| {
                cb(.{
                    .total = foz_files.items.len,
                    .completed = completed,
                    .failed = failed,
                    .current_file = foz_path,
                    .status = .compiling,
                });
            }

            const status = self.prewarmFossilize(foz_path, null) catch .failed;
            if (status == .completed) {
                completed += 1;
            } else {
                failed += 1;
            }

            if (callback) |cb| {
                cb(.{
                    .total = foz_files.items.len,
                    .completed = completed,
                    .failed = failed,
                    .current_file = foz_path,
                    .status = if (i == foz_files.items.len - 1) .completed else .compiling,
                });
            }
        }

        return .{ .completed = completed, .failed = failed };
    }

    /// Pre-warm caches from CacheManager entries
    pub fn prewarmFromManager(
        self: *PrewarmEngine,
        manager: *cache.CacheManager,
        callback: ?PrewarmCallback,
    ) !struct { completed: usize, failed: usize, skipped: usize } {
        var completed: usize = 0;
        var failed: usize = 0;
        var skipped: usize = 0;

        const total = manager.entries.items.len;

        for (manager.entries.items, 0..) |entry, i| {
            // Only pre-warm Fossilize caches
            if (entry.cache_type != .fossilize) {
                skipped += 1;
                continue;
            }

            if (callback) |cb| {
                cb(.{
                    .total = total,
                    .completed = completed,
                    .failed = failed,
                    .current_file = entry.path,
                    .status = .compiling,
                });
            }

            if (entry.is_directory) {
                const result = try self.prewarmDirectory(entry.path, null);
                completed += result.completed;
                failed += result.failed;
            } else {
                const status = self.prewarmFossilize(entry.path, null) catch .failed;
                if (status == .completed) {
                    completed += 1;
                } else {
                    failed += 1;
                }
            }

            if (callback) |cb| {
                cb(.{
                    .total = total,
                    .completed = completed,
                    .failed = failed,
                    .current_file = entry.path,
                    .status = if (i == total - 1) .completed else .compiling,
                });
            }
        }

        return .{ .completed = completed, .failed = failed, .skipped = skipped };
    }
};

fn pathExists(path: []const u8) bool {
    Dir.cwd().access(getIo(), path, .{}) catch return false;
    return true;
}

test "PrewarmEngine init" {
    const allocator = std.testing.allocator;
    var engine = try PrewarmEngine.init(allocator, .{});
    defer engine.deinit();
}
