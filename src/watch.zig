const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const posix = std.posix;
const types = @import("types.zig");
const paths = @import("paths.zig");

/// Event types for cache watching
pub const WatchEvent = enum {
    created,
    modified,
    deleted,
    compilation_start,
    compilation_end,
};

/// Watch event data
pub const WatchEventData = struct {
    event: WatchEvent,
    path: []const u8,
    cache_type: ?types.CacheType,
    size_bytes: u64,
    timestamp: i64,
};

/// Callback for watch events
pub const WatchCallback = *const fn (event: WatchEventData) void;

/// Statistics tracked during watch session
pub const WatchStats = struct {
    files_created: u64 = 0,
    files_modified: u64 = 0,
    files_deleted: u64 = 0,
    bytes_written: u64 = 0,
    compilations_detected: u64 = 0,
    start_time: i64,

    pub fn duration(self: *const WatchStats) i64 {
        const ts = std.posix.clock_gettime(.REALTIME) catch return 0;
        return ts.sec - self.start_time;
    }
};

/// Inotify-based file system watcher for shader caches
pub const CacheWatcher = struct {
    allocator: mem.Allocator,
    inotify_fd: posix.fd_t,
    watch_descriptors: std.AutoHashMapUnmanaged(i32, WatchedPath),
    stats: WatchStats,
    callback: ?WatchCallback,
    running: bool,

    const WatchedPath = struct {
        path: []const u8,
        cache_type: types.CacheType,
    };

    pub fn init(allocator: mem.Allocator) !CacheWatcher {
        // IN_CLOEXEC = 0x80000, IN_NONBLOCK = 0x800
        const fd = try posix.inotify_init1(0x80000 | 0x800);

        return CacheWatcher{
            .allocator = allocator,
            .inotify_fd = fd,
            .watch_descriptors = .{},
            .stats = .{ .start_time = blk: {
                const ts = std.posix.clock_gettime(.REALTIME) catch break :blk 0;
                break :blk ts.sec;
            } },
            .callback = null,
            .running = false,
        };
    }

    pub fn deinit(self: *CacheWatcher) void {
        self.running = false;

        // Remove all watches
        var iter = self.watch_descriptors.iterator();
        while (iter.next()) |entry| {
            _ = posix.inotify_rm_watch(self.inotify_fd, entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.path);
        }
        self.watch_descriptors.deinit(self.allocator);

        posix.close(self.inotify_fd);
    }

    /// Add a path to watch
    pub fn addWatch(self: *CacheWatcher, path: []const u8, cache_type: types.CacheType) !void {
        // IN_CREATE=0x100, IN_MODIFY=0x02, IN_DELETE=0x200, IN_CLOSE_WRITE=0x08
        const mask: u32 = 0x100 | 0x02 | 0x200 | 0x08;

        const wd = try posix.inotify_add_watch(self.inotify_fd, path, mask);

        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        try self.watch_descriptors.put(self.allocator, wd, .{
            .path = path_copy,
            .cache_type = cache_type,
        });
    }

    /// Add default cache directories to watch
    pub fn addDefaultWatches(self: *CacheWatcher) !void {
        const home = posix.getenv("HOME") orelse return error.NoHomeDir;

        // NVIDIA cache
        const nvidia_path = try mem.concat(self.allocator, u8, &.{ home, "/.nv/ComputeCache" });
        defer self.allocator.free(nvidia_path);
        if (pathExists(nvidia_path)) {
            self.addWatch(nvidia_path, .nvidia) catch {};
        }

        // Mesa cache
        const mesa_path = try mem.concat(self.allocator, u8, &.{ home, "/.cache/mesa_shader_cache" });
        defer self.allocator.free(mesa_path);
        if (pathExists(mesa_path)) {
            self.addWatch(mesa_path, .mesa) catch {};
        }

        // DXVK cache
        const dxvk_path = try mem.concat(self.allocator, u8, &.{ home, "/.cache/dxvk" });
        defer self.allocator.free(dxvk_path);
        if (pathExists(dxvk_path)) {
            self.addWatch(dxvk_path, .dxvk) catch {};
        }

        // Steam Fossilize cache
        const steam_paths = [_][]const u8{
            "/.steam/steam/steamapps/shadercache",
            "/.local/share/Steam/steamapps/shadercache",
        };

        for (steam_paths) |suffix| {
            const full = try mem.concat(self.allocator, u8, &.{ home, suffix });
            defer self.allocator.free(full);
            if (pathExists(full)) {
                self.addWatch(full, .fossilize) catch {};
                break;
            }
        }
    }

    /// Set callback for events
    pub fn setCallback(self: *CacheWatcher, callback: WatchCallback) void {
        self.callback = callback;
    }

    /// Poll for events (non-blocking)
    pub fn poll(self: *CacheWatcher) !void {
        var buffer: [4096]u8 align(8) = undefined;

        const bytes_read = posix.read(self.inotify_fd, &buffer) catch |err| {
            if (err == error.WouldBlock) return;
            return err;
        };

        if (bytes_read == 0) return;

        var offset: usize = 0;
        while (offset < bytes_read) {
            const event: *const std.os.linux.inotify_event = @ptrCast(@alignCast(&buffer[offset]));

            if (self.watch_descriptors.get(event.wd)) |watched| {
                const event_type = self.classifyEvent(event.mask);

                // Get filename if present
                var filename: []const u8 = "";
                if (event.len > 0) {
                    const name_ptr: [*:0]const u8 = @ptrCast(&buffer[offset + @sizeOf(std.os.linux.inotify_event)]);
                    filename = mem.span(name_ptr);
                }

                // Build full path
                var full_path_buf: [4096]u8 = undefined;
                const full_path = if (filename.len > 0) blk: {
                    const len = (std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ watched.path, filename }) catch break :blk watched.path).len;
                    break :blk full_path_buf[0..len];
                } else watched.path;

                // Update stats
                switch (event_type) {
                    .created => self.stats.files_created += 1,
                    .modified => self.stats.files_modified += 1,
                    .deleted => self.stats.files_deleted += 1,
                    .compilation_start => self.stats.compilations_detected += 1,
                    .compilation_end => {},
                }

                // Call callback
                if (self.callback) |cb| {
                    cb(.{
                        .event = event_type,
                        .path = full_path,
                        .cache_type = watched.cache_type,
                        .size_bytes = 0, // Could stat file for size
                        .timestamp = blk: {
                            const ts = std.posix.clock_gettime(.REALTIME) catch break :blk 0;
                            break :blk ts.sec;
                        },
                    });
                }
            }

            offset += @sizeOf(std.os.linux.inotify_event) + event.len;
        }
    }

    fn classifyEvent(self: *CacheWatcher, mask: u32) WatchEvent {
        _ = self;
        // IN_CREATE=0x100, IN_DELETE=0x200, IN_CLOSE_WRITE=0x08, IN_MODIFY=0x02
        if (mask & 0x100 != 0) return .created;
        if (mask & 0x200 != 0) return .deleted;
        if (mask & 0x08 != 0) return .compilation_end;
        if (mask & 0x02 != 0) return .modified;
        return .modified;
    }

    /// Run watch loop (blocking)
    pub fn run(self: *CacheWatcher) !void {
        self.running = true;

        while (self.running) {
            try self.poll();
            std.time.sleep(100 * std.time.ns_per_ms); // 100ms poll interval
        }
    }

    /// Stop the watch loop
    pub fn stop(self: *CacheWatcher) void {
        self.running = false;
    }

    /// Get current statistics
    pub fn getStats(self: *const CacheWatcher) WatchStats {
        return self.stats;
    }

    /// Print current statistics
    pub fn printStats(self: *const CacheWatcher) void {
        const stats = self.stats;
        const duration = stats.duration();

        std.debug.print("\n=== Watch Statistics ===\n", .{});
        std.debug.print("Duration: {d}s\n", .{duration});
        std.debug.print("Files created: {d}\n", .{stats.files_created});
        std.debug.print("Files modified: {d}\n", .{stats.files_modified});
        std.debug.print("Files deleted: {d}\n", .{stats.files_deleted});
        std.debug.print("Compilations detected: {d}\n", .{stats.compilations_detected});
        std.debug.print("Directories watched: {d}\n", .{self.watch_descriptors.count()});
    }
};

fn pathExists(path: []const u8) bool {
    fs.cwd().access(path, .{}) catch return false;
    return true;
}

test "CacheWatcher init" {
    const allocator = std.testing.allocator;
    var watcher = try CacheWatcher.init(allocator);
    defer watcher.deinit();
}
