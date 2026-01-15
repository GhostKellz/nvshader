//! nvshader C API
//!
//! C-compatible API for shader cache management.
//! This module exports functions with C ABI for FFI integration with
//! Rust (nvproton), C++, and other languages.

const std = @import("std");
const cache = @import("cache.zig");
const prewarm = @import("prewarm.zig");
const types = @import("types.zig");
const paths = @import("paths.zig");
const steam = @import("steam.zig");

const Io = std.Io;
const Dir = std.Io.Dir;

/// Get the global debug Io instance for file operations
fn getIo() Io {
    return std.Options.debug_io;
}

// =============================================================================
// Types
// =============================================================================

/// Opaque context handle for C consumers
pub const nvshader_ctx_t = ?*anyopaque;

/// Result codes
pub const nvshader_result_t = enum(c_int) {
    success = 0,
    error_invalid_handle = -1,
    error_scan_failed = -2,
    error_prewarm_failed = -3,
    error_not_available = -4,
    error_game_not_found = -5,
    error_invalid_param = -6,
    error_out_of_memory = -7,
    error_unknown = -99,
};

/// Cache type enum for C
pub const nvshader_cache_type_t = enum(c_int) {
    dxvk = 0,
    vkd3d = 1,
    nvidia = 2,
    mesa = 3,
    fossilize = 4,
};

/// Cache statistics structure for C
pub const nvshader_stats_t = extern struct {
    total_size_bytes: u64,
    file_count: u32,
    game_count: u32,
    dxvk_size: u64,
    vkd3d_size: u64,
    nvidia_size: u64,
    mesa_size: u64,
    fossilize_size: u64,
    oldest_days: u32,
    newest_days: u32,
};

/// Pre-warm result structure for C
pub const nvshader_prewarm_result_t = extern struct {
    completed: u32,
    failed: u32,
    skipped: u32,
    total: u32,
};

/// Cache entry info for C
pub const nvshader_entry_t = extern struct {
    path: [*:0]const u8,
    cache_type: nvshader_cache_type_t,
    size_bytes: u64,
    game_name: [*:0]const u8,
    game_id: [*:0]const u8,
    entry_count: u32,
    is_directory: bool,
};

// =============================================================================
// Internal Context
// =============================================================================

const Context = struct {
    allocator: std.mem.Allocator,
    manager: cache.CacheManager,
    prewarm_engine: ?prewarm.PrewarmEngine,
    last_error: ?[]const u8,

    // Buffers for C string returns
    path_buffer: [4096]u8,
    name_buffer: [256]u8,
    id_buffer: [64]u8,

    fn create() !*Context {
        const allocator = std.heap.c_allocator;
        const ctx = try allocator.create(Context);
        errdefer allocator.destroy(ctx);

        ctx.* = .{
            .allocator = allocator,
            .manager = try cache.CacheManager.init(allocator),
            .prewarm_engine = null,
            .last_error = null,
            .path_buffer = undefined,
            .name_buffer = undefined,
            .id_buffer = undefined,
        };

        // Initialize prewarm engine
        ctx.prewarm_engine = prewarm.PrewarmEngine.init(allocator, .{}) catch null;

        return ctx;
    }

    fn destroy(self: *Context) void {
        if (self.prewarm_engine) |*engine| {
            engine.deinit();
        }
        self.manager.deinit();
        if (self.last_error) |err| {
            self.allocator.free(err);
        }
        self.allocator.destroy(self);
    }

    fn setError(self: *Context, msg: []const u8) void {
        if (self.last_error) |err| {
            self.allocator.free(err);
        }
        self.last_error = self.allocator.dupe(u8, msg) catch null;
    }
};

// =============================================================================
// Exported C API Functions
// =============================================================================

/// Initialize nvshader context
/// Returns: context handle or null on failure
export fn nvshader_init() nvshader_ctx_t {
    const ctx = Context.create() catch return null;
    return @ptrCast(ctx);
}

/// Destroy nvshader context and free resources
export fn nvshader_destroy(ctx: nvshader_ctx_t) void {
    if (ctx) |ptr| {
        const context: *Context = @ptrCast(@alignCast(ptr));
        context.destroy();
    }
}

/// Get library version
export fn nvshader_get_version() u32 {
    // Version 0.1.0 = 0x000100
    return 0x000100;
}

/// Scan for shader caches
export fn nvshader_scan(ctx: nvshader_ctx_t) nvshader_result_t {
    const context: *Context = @ptrCast(@alignCast(ctx orelse return .error_invalid_handle));

    context.manager.scan() catch |err| {
        context.setError(@errorName(err));
        return .error_scan_failed;
    };

    return .success;
}

/// Get cache statistics
export fn nvshader_get_stats(ctx: nvshader_ctx_t, out_stats: ?*nvshader_stats_t) nvshader_result_t {
    const context: *Context = @ptrCast(@alignCast(ctx orelse return .error_invalid_handle));
    const stats_ptr = out_stats orelse return .error_invalid_param;

    const stats = context.manager.getStats();

    // Calculate age in days using realtime clock
    const ts = std.posix.clock_gettime(.REALTIME) catch return .error_unknown;
    const now_ns: i128 = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
    const ns_per_day: i128 = 24 * 60 * 60 * 1_000_000_000;

    var oldest_days: u32 = 0;
    var newest_days: u32 = 0;

    if (stats.oldest_entry) |oldest| {
        const age_ns = now_ns - oldest;
        if (age_ns > 0) {
            oldest_days = @intCast(@divFloor(age_ns, ns_per_day));
        }
    }

    if (stats.newest_entry) |newest| {
        const age_ns = now_ns - newest;
        if (age_ns > 0) {
            newest_days = @intCast(@divFloor(age_ns, ns_per_day));
        }
    }

    stats_ptr.* = .{
        .total_size_bytes = stats.total_size_bytes,
        .file_count = stats.file_count,
        .game_count = stats.game_count,
        .dxvk_size = stats.dxvk_size,
        .vkd3d_size = stats.vkd3d_size,
        .nvidia_size = stats.nvidia_size,
        .mesa_size = stats.mesa_size,
        .fossilize_size = stats.fossilize_size,
        .oldest_days = oldest_days,
        .newest_days = newest_days,
    };

    return .success;
}

/// Get number of cache entries
export fn nvshader_get_entry_count(ctx: nvshader_ctx_t) c_int {
    const context: *Context = @ptrCast(@alignCast(ctx orelse return -1));
    return @intCast(context.manager.entries.items.len);
}

/// Pre-warm shader cache for a specific game ID
/// game_id: Steam AppID or other game identifier (null-terminated)
export fn nvshader_prewarm_game(
    ctx: nvshader_ctx_t,
    game_id: [*:0]const u8,
    out_result: ?*nvshader_prewarm_result_t,
) nvshader_result_t {
    const context: *Context = @ptrCast(@alignCast(ctx orelse return .error_invalid_handle));
    const engine = &(context.prewarm_engine orelse return .error_not_available);

    const id_slice = std.mem.span(game_id);
    if (id_slice.len == 0) return .error_invalid_param;

    // Find cache entries matching this game ID
    var found = false;
    var total_completed: u32 = 0;
    var total_failed: u32 = 0;
    var total_skipped: u32 = 0;
    var total_count: u32 = 0;

    for (context.manager.entries.items) |entry| {
        const matches = blk: {
            if (entry.game_id) |eid| {
                if (std.mem.eql(u8, eid, id_slice)) break :blk true;
            }
            // Also check if path contains the game ID (for Steam AppIDs)
            if (std.mem.indexOf(u8, entry.path, id_slice) != null) break :blk true;
            break :blk false;
        };

        if (matches) {
            found = true;
            total_count += 1;

            if (entry.cache_type != .fossilize) {
                total_skipped += 1;
                continue;
            }

            if (entry.is_directory) {
                const result = engine.prewarmDirectory(entry.path, null) catch {
                    total_failed += 1;
                    continue;
                };
                total_completed += @intCast(result.completed);
                total_failed += @intCast(result.failed);
            } else {
                const status = engine.prewarmFossilize(entry.path, null) catch {
                    total_failed += 1;
                    continue;
                };
                if (status == .completed) {
                    total_completed += 1;
                } else {
                    total_failed += 1;
                }
            }
        }
    }

    if (!found) return .error_game_not_found;

    if (out_result) |result| {
        result.* = .{
            .completed = total_completed,
            .failed = total_failed,
            .skipped = total_skipped,
            .total = total_count,
        };
    }

    return .success;
}

/// Pre-warm all Fossilize caches
export fn nvshader_prewarm_all(
    ctx: nvshader_ctx_t,
    out_result: ?*nvshader_prewarm_result_t,
) nvshader_result_t {
    const context: *Context = @ptrCast(@alignCast(ctx orelse return .error_invalid_handle));
    var engine = &(context.prewarm_engine orelse return .error_not_available);

    const result = engine.prewarmFromManager(&context.manager, null) catch |err| {
        context.setError(@errorName(err));
        return .error_prewarm_failed;
    };

    if (out_result) |out| {
        out.* = .{
            .completed = @intCast(result.completed),
            .failed = @intCast(result.failed),
            .skipped = @intCast(result.skipped),
            .total = @intCast(context.manager.entries.items.len),
        };
    }

    return .success;
}

/// Check if pre-warming is available (fossilize_replay found)
export fn nvshader_prewarm_available(ctx: nvshader_ctx_t) bool {
    const context: *Context = @ptrCast(@alignCast(ctx orelse return false));
    if (context.prewarm_engine) |engine| {
        return engine.isAvailable();
    }
    return false;
}

/// Clean caches older than specified days
export fn nvshader_clean_older_than(ctx: nvshader_ctx_t, days: u32) c_int {
    const context: *Context = @ptrCast(@alignCast(ctx orelse return -1));
    const removed = context.manager.cleanOlderThan(days) catch return -1;
    return @intCast(removed);
}

/// Shrink caches to fit within size limit (bytes)
export fn nvshader_shrink_to_size(ctx: nvshader_ctx_t, max_bytes: u64) c_int {
    const context: *Context = @ptrCast(@alignCast(ctx orelse return -1));
    const removed = context.manager.shrinkToSize(max_bytes) catch return -1;
    return @intCast(removed);
}

/// Validate all cache entries
/// Returns: number of invalid entries, or -1 on error
export fn nvshader_validate(ctx: nvshader_ctx_t) c_int {
    const context: *Context = @ptrCast(@alignCast(ctx orelse return -1));
    const report = context.manager.validate();
    return @intCast(report.invalid);
}

/// Get last error message (null-terminated)
export fn nvshader_get_last_error(ctx: nvshader_ctx_t) [*:0]const u8 {
    const context: *Context = @ptrCast(@alignCast(ctx orelse return "invalid context"));
    if (context.last_error) |err| {
        // Copy to static buffer and null-terminate
        const len = @min(err.len, context.name_buffer.len - 1);
        @memcpy(context.name_buffer[0..len], err[0..len]);
        context.name_buffer[len] = 0;
        return @ptrCast(&context.name_buffer);
    }
    return "no error";
}

/// Check if NVIDIA GPU is present
export fn nvshader_is_nvidia_gpu() bool {
    Dir.cwd().access(getIo(), "/proc/driver/nvidia/version", .{}) catch return false;
    return true;
}

// =============================================================================
// Tests
// =============================================================================

test "C API context lifecycle" {
    const ctx = nvshader_init();
    try std.testing.expect(ctx != null);
    defer nvshader_destroy(ctx);

    try std.testing.expectEqual(@as(u32, 0x000100), nvshader_get_version());
}

test "C API scan and stats" {
    const ctx = nvshader_init();
    try std.testing.expect(ctx != null);
    defer nvshader_destroy(ctx);

    const result = nvshader_scan(ctx);
    try std.testing.expectEqual(nvshader_result_t.success, result);

    var stats: nvshader_stats_t = undefined;
    const stats_result = nvshader_get_stats(ctx, &stats);
    try std.testing.expectEqual(nvshader_result_t.success, stats_result);
}
