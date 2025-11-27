const std = @import("std");
const fs = std.fs;
const mem = std.mem;

/// Known cache paths for different cache types
pub const CachePaths = struct {
    dxvk: ?[]const u8,
    vkd3d: ?[]const u8,
    nvidia: ?[]const u8,
    mesa: ?[]const u8,
    fossilize: ?[]const u8,
    steam_shadercache: ?[]const u8,

    allocator: mem.Allocator,

    pub fn detect(allocator: mem.Allocator) !CachePaths {
        const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

        return CachePaths{
            .dxvk = try detectDxvkPath(allocator, home),
            .vkd3d = try detectVkd3dPath(allocator, home),
            .nvidia = try detectNvidiaPath(allocator, home),
            .mesa = try detectMesaPath(allocator, home),
            .fossilize = try detectFossilizePath(allocator, home),
            .steam_shadercache = try detectSteamShaderCache(allocator, home),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CachePaths) void {
        if (self.dxvk) |p| self.allocator.free(p);
        if (self.vkd3d) |p| self.allocator.free(p);
        if (self.nvidia) |p| self.allocator.free(p);
        if (self.mesa) |p| self.allocator.free(p);
        if (self.fossilize) |p| self.allocator.free(p);
        if (self.steam_shadercache) |p| self.allocator.free(p);
    }

    pub fn printSummary(self: *const CachePaths) void {
        const stdout = std.io.getStdOut().writer();
        stdout.print("\n📁 Cache Paths Detected:\n", .{}) catch {};

        inline for (.{
            .{ "DXVK", self.dxvk },
            .{ "vkd3d-proton", self.vkd3d },
            .{ "NVIDIA", self.nvidia },
            .{ "Mesa", self.mesa },
            .{ "Fossilize", self.fossilize },
            .{ "Steam Shader", self.steam_shadercache },
        }) |entry| {
            const name = entry[0];
            const path = entry[1];
            if (path) |p| {
                stdout.print("   ✓ {s}: {s}\n", .{ name, p }) catch {};
            } else {
                stdout.print("   ✗ {s}: not found\n", .{name}) catch {};
            }
        }
    }
};

fn detectDxvkPath(allocator: mem.Allocator, home: []const u8) !?[]const u8 {
    // Check env var first
    if (std.posix.getenv("DXVK_STATE_CACHE_PATH")) |env_path| {
        return try allocator.dupe(u8, env_path);
    }

    // Default path
    const default = try std.fmt.allocPrint(allocator, "{s}/.cache/dxvk", .{home});

    if (pathExists(default)) {
        return default;
    }

    allocator.free(default);
    return null;
}

fn detectVkd3dPath(allocator: mem.Allocator, home: []const u8) !?[]const u8 {
    // Check env var first
    if (std.posix.getenv("VKD3D_SHADER_CACHE_PATH")) |env_path| {
        return try allocator.dupe(u8, env_path);
    }

    const default = try std.fmt.allocPrint(allocator, "{s}/.cache/vkd3d-proton", .{home});

    if (pathExists(default)) {
        return default;
    }

    allocator.free(default);
    return null;
}

fn detectNvidiaPath(allocator: mem.Allocator, home: []const u8) !?[]const u8 {
    const default = try std.fmt.allocPrint(allocator, "{s}/.nv/ComputeCache", .{home});

    if (pathExists(default)) {
        return default;
    }

    allocator.free(default);
    return null;
}

fn detectMesaPath(allocator: mem.Allocator, home: []const u8) !?[]const u8 {
    // Check XDG_CACHE_HOME first
    const cache_home = std.posix.getenv("XDG_CACHE_HOME");

    const default = if (cache_home) |ch|
        try std.fmt.allocPrint(allocator, "{s}/mesa_shader_cache", .{ch})
    else
        try std.fmt.allocPrint(allocator, "{s}/.cache/mesa_shader_cache", .{home});

    if (pathExists(default)) {
        return default;
    }

    allocator.free(default);
    return null;
}

fn detectFossilizePath(allocator: mem.Allocator, home: []const u8) !?[]const u8 {
    // Fossilize caches are typically per-game in Steam
    const default = try std.fmt.allocPrint(allocator, "{s}/.local/share/Steam/steamapps/shadercache", .{home});

    if (pathExists(default)) {
        return default;
    }

    // Try flatpak Steam location
    allocator.free(default);
    const flatpak = try std.fmt.allocPrint(allocator, "{s}/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/shadercache", .{home});

    if (pathExists(flatpak)) {
        return flatpak;
    }

    allocator.free(flatpak);
    return null;
}

fn detectSteamShaderCache(allocator: mem.Allocator, home: []const u8) !?[]const u8 {
    // Standard Steam path
    const paths_to_try = [_][]const u8{
        "{s}/.steam/steam/steamapps/shadercache",
        "{s}/.local/share/Steam/steamapps/shadercache",
        "{s}/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/shadercache",
    };

    for (paths_to_try) |fmt| {
        const path = try std.fmt.allocPrint(allocator, fmt, .{home});
        if (pathExists(path)) {
            return path;
        }
        allocator.free(path);
    }

    return null;
}

fn pathExists(path: []const u8) bool {
    fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Get directory size in bytes
pub fn getDirSize(allocator: mem.Allocator, path: []const u8) !u64 {
    var total: u64 = 0;

    var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var walker = dir.walk(allocator) catch return 0;
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (entry.kind == .file) {
            const stat = entry.dir.statFile(entry.basename) catch continue;
            total += stat.size;
        }
    }

    return total;
}

/// Count files in directory
pub fn countFiles(allocator: mem.Allocator, path: []const u8) !u32 {
    var count: u32 = 0;

    var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var walker = dir.walk(allocator) catch return 0;
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (entry.kind == .file) {
            count += 1;
        }
    }

    return count;
}

test "path detection" {
    const allocator = std.testing.allocator;
    var paths = try CachePaths.detect(allocator);
    defer paths.deinit();
    // Just verify it doesn't crash
}
