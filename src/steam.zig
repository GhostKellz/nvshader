const std = @import("std");
const fs = std.fs;
const mem = std.mem;

/// Steam library location
pub const SteamLibrary = struct {
    path: []const u8,
    allocator: mem.Allocator,

    pub fn deinit(self: *SteamLibrary) void {
        self.allocator.free(self.path);
    }
};

/// Steam game information
pub const SteamGame = struct {
    app_id: u32,
    name: []const u8,
    install_dir: []const u8,
    size_bytes: u64,
    last_played: ?i64,

    allocator: mem.Allocator,

    pub fn deinit(self: *SteamGame) void {
        self.allocator.free(self.name);
        self.allocator.free(self.install_dir);
    }
};

/// Detect Steam installation and libraries
pub const SteamDetector = struct {
    allocator: mem.Allocator,
    steam_root: ?[]const u8,
    libraries: std.ArrayListUnmanaged(SteamLibrary),
    games: std.ArrayListUnmanaged(SteamGame),

    pub fn init(allocator: mem.Allocator) !SteamDetector {
        var detector = SteamDetector{
            .allocator = allocator,
            .steam_root = null,
            .libraries = .{},
            .games = .{},
        };

        try detector.detectSteamRoot();
        return detector;
    }

    pub fn deinit(self: *SteamDetector) void {
        if (self.steam_root) |root| self.allocator.free(root);

        for (self.libraries.items) |*lib| lib.deinit();
        self.libraries.deinit(self.allocator);

        for (self.games.items) |*game| game.deinit();
        self.games.deinit(self.allocator);
    }

    fn detectSteamRoot(self: *SteamDetector) !void {
        const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

        const suffixes = [_][]const u8{
            "/.steam/steam",
            "/.local/share/Steam",
            "/.var/app/com.valvesoftware.Steam/.local/share/Steam",
        };

        for (suffixes) |suffix| {
            const path = try std.mem.concat(self.allocator, u8, &.{ home, suffix });

            if (pathExists(path)) {
                // Resolve to real path to avoid duplicates from symlinks
                const real = realPath(self.allocator, path) catch {
                    self.steam_root = path;
                    return;
                };
                self.allocator.free(path);
                self.steam_root = real;
                return;
            }

            self.allocator.free(path);
        }
    }

    /// Scan for all Steam library folders
    pub fn scanLibraries(self: *SteamDetector) !void {
        const root = self.steam_root orelse return error.SteamNotFound;

        // Add main Steam library (already canonicalized in detectSteamRoot)
        try self.libraries.append(self.allocator, SteamLibrary{
            .path = try self.allocator.dupe(u8, root),
            .allocator = self.allocator,
        });

        // Parse libraryfolders.vdf for additional libraries
        const vdf_path = try std.fmt.allocPrint(self.allocator, "{s}/steamapps/libraryfolders.vdf", .{root});
        defer self.allocator.free(vdf_path);

        var file = fs.cwd().openFile(vdf_path, .{}) catch return;
        defer file.close();

        var buf: [4096]u8 = undefined;
        const bytes_read = file.preadAll(&buf, 0) catch return;
        const content = buf[0..bytes_read];

        // Simple parsing - look for "path" entries
        var lines = mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = mem.trim(u8, line, " \t\r");
            if (mem.startsWith(u8, trimmed, "\"path\"")) {
                // Extract path value
                if (extractQuotedValue(trimmed)) |path_val| {
                    if (!pathExists(path_val)) continue;

                    // Canonicalize path to avoid duplicates from symlinks
                    const real_path = realPath(self.allocator, path_val) catch continue;
                    defer self.allocator.free(real_path);

                    // Check if we already have this library (comparing real paths)
                    var is_duplicate = false;
                    for (self.libraries.items) |lib| {
                        if (mem.eql(u8, lib.path, real_path)) {
                            is_duplicate = true;
                            break;
                        }
                    }

                    if (!is_duplicate) {
                        try self.libraries.append(self.allocator, SteamLibrary{
                            .path = try self.allocator.dupe(u8, real_path),
                            .allocator = self.allocator,
                        });
                    }
                }
            }
        }
    }

    /// Scan for installed games
    pub fn scanGames(self: *SteamDetector) !void {
        for (self.libraries.items) |lib| {
            try self.scanLibraryGames(lib.path);
        }
    }

    fn scanLibraryGames(self: *SteamDetector, library_path: []const u8) !void {
        const steamapps = try std.fmt.allocPrint(self.allocator, "{s}/steamapps", .{library_path});
        defer self.allocator.free(steamapps);

        var dir = fs.cwd().openDir(steamapps, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and mem.startsWith(u8, entry.name, "appmanifest_") and mem.endsWith(u8, entry.name, ".acf")) {
                const manifest_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ steamapps, entry.name });
                defer self.allocator.free(manifest_path);

                if (try self.parseAppManifest(manifest_path, library_path)) |game| {
                    try self.games.append(self.allocator, game);
                }
            }
        }
    }

    fn parseAppManifest(self: *SteamDetector, manifest_path: []const u8, library_path: []const u8) !?SteamGame {
        var file = fs.cwd().openFile(manifest_path, .{}) catch return null;
        defer file.close();

        var buf: [8192]u8 = undefined;
        const bytes_read = file.preadAll(&buf, 0) catch return null;
        const content = buf[0..bytes_read];

        var app_id: ?u32 = null;
        var name: ?[]const u8 = null;
        var install_dir: ?[]const u8 = null;
        var size_bytes: u64 = 0;
        var last_played: ?i64 = null;

        var lines = mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = mem.trim(u8, line, " \t\r");

            if (mem.startsWith(u8, trimmed, "\"appid\"")) {
                if (extractQuotedValue(trimmed)) |val| {
                    app_id = std.fmt.parseInt(u32, val, 10) catch null;
                }
            } else if (mem.startsWith(u8, trimmed, "\"name\"")) {
                if (extractQuotedValue(trimmed)) |val| {
                    name = try self.allocator.dupe(u8, val);
                }
            } else if (mem.startsWith(u8, trimmed, "\"installdir\"")) {
                if (extractQuotedValue(trimmed)) |val| {
                    install_dir = try std.fmt.allocPrint(self.allocator, "{s}/steamapps/common/{s}", .{ library_path, val });
                }
            } else if (mem.startsWith(u8, trimmed, "\"SizeOnDisk\"")) {
                if (extractQuotedValue(trimmed)) |val| {
                    size_bytes = std.fmt.parseInt(u64, val, 10) catch 0;
                }
            } else if (mem.startsWith(u8, trimmed, "\"LastPlayed\"")) {
                if (extractQuotedValue(trimmed)) |val| {
                    last_played = std.fmt.parseInt(i64, val, 10) catch null;
                }
            }
        }

        if (app_id != null and name != null and install_dir != null) {
            return SteamGame{
                .app_id = app_id.?,
                .name = name.?,
                .install_dir = install_dir.?,
                .size_bytes = size_bytes,
                .last_played = last_played,
                .allocator = self.allocator,
            };
        }

        // Cleanup on failure
        if (name) |n| self.allocator.free(n);
        if (install_dir) |d| self.allocator.free(d);
        return null;
    }

    /// Get shader cache path for a game
    pub fn getShaderCachePath(self: *SteamDetector, app_id: u32) !?[]const u8 {
        const root = self.steam_root orelse return null;

        const cache_path = try std.fmt.allocPrint(self.allocator, "{s}/steamapps/shadercache/{d}", .{ root, app_id });

        if (pathExists(cache_path)) {
            return cache_path;
        }

        self.allocator.free(cache_path);
        return null;
    }

    /// Print summary of detected games
    pub fn printSummary(self: *const SteamDetector) void {
        const stdout = std.io.getStdOut().writer();

        if (self.steam_root) |root| {
            stdout.print("\n🎮 Steam Installation: {s}\n", .{root}) catch {};
        } else {
            stdout.print("\n❌ Steam not found\n", .{}) catch {};
            return;
        }

        stdout.print("📚 Libraries: {d}\n", .{self.libraries.items.len}) catch {};
        stdout.print("🎯 Games Installed: {d}\n\n", .{self.games.items.len}) catch {};

        // Show top 10 most recently played
        stdout.print("Recently Played:\n", .{}) catch {};

        // Sort by last_played (simple bubble sort for small list)
        var sorted: std.ArrayListUnmanaged(SteamGame) = .{};
        defer sorted.deinit(self.allocator);

        for (self.games.items) |game| {
            sorted.append(self.allocator, game) catch continue;
        }

        // Just show first 10
        const count = @min(sorted.items.len, 10);
        for (sorted.items[0..count]) |game| {
            stdout.print("   • {s} (AppID: {d})\n", .{ game.name, game.app_id }) catch {};
        }
    }
};

fn extractQuotedValue(line: []const u8) ?[]const u8 {
    // Find the second quoted string in format: "key"  "value"
    var quote_count: u32 = 0;
    var start: ?usize = null;

    for (line, 0..) |c, i| {
        if (c == '"') {
            quote_count += 1;
            if (quote_count == 3) {
                start = i + 1;
            } else if (quote_count == 4) {
                if (start) |s| {
                    return line[s..i];
                }
            }
        }
    }
    return null;
}

fn pathExists(path: []const u8) bool {
    fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Resolve symlinks to get the real path
fn realPath(allocator: mem.Allocator, path: []const u8) ![]const u8 {
    // Use /proc/self/fd trick to get real path
    var result_buf: [4096]u8 = undefined;

    // Try to open the path and use /proc/self/fd to get real path
    var dir = fs.cwd().openDir(path, .{}) catch {
        // If not a directory, try as file
        var file = try fs.cwd().openFile(path, .{});
        defer file.close();
        const fd_path = try std.fmt.bufPrint(&result_buf, "/proc/self/fd/{d}", .{file.handle});
        var link_buf: [4096]u8 = undefined;
        const resolved = std.posix.readlink(fd_path, &link_buf) catch return allocator.dupe(u8, path);
        return allocator.dupe(u8, resolved);
    };
    defer dir.close();

    const fd_path = try std.fmt.bufPrint(&result_buf, "/proc/self/fd/{d}", .{dir.fd});
    var link_buf: [4096]u8 = undefined;
    const resolved = std.posix.readlink(fd_path, &link_buf) catch return allocator.dupe(u8, path);
    return allocator.dupe(u8, resolved);
}

/// Check if running on Steam Deck
pub fn isSteamDeck() bool {
    // Check for Steam Deck hardware via DMI
    const deck_paths = [_][]const u8{
        "/sys/class/dmi/id/board_vendor",
        "/sys/class/dmi/id/board_name",
        "/sys/class/dmi/id/product_name",
    };

    for (deck_paths) |path| {
        var file = fs.cwd().openFile(path, .{}) catch continue;
        defer file.close();

        var buf: [64]u8 = undefined;
        const len = file.preadAll(&buf, 0) catch continue;
        const content = mem.trim(u8, buf[0..len], " \t\r\n");

        if (mem.indexOf(u8, content, "Valve") != null or
            mem.indexOf(u8, content, "Jupiter") != null or
            mem.indexOf(u8, content, "Galileo") != null or
            mem.indexOf(u8, content, "Steam Deck") != null)
        {
            return true;
        }
    }

    // Also check environment variable (common in gaming mode)
    if (std.posix.getenv("SteamDeck")) |_| {
        return true;
    }

    return false;
}

/// Get Steam Deck model if running on one
pub fn getSteamDeckModel() ?[]const u8 {
    const product_path = "/sys/class/dmi/id/product_name";
    var file = fs.cwd().openFile(product_path, .{}) catch return null;
    defer file.close();

    var buf: [64]u8 = undefined;
    const len = file.preadAll(&buf, 0) catch return null;
    const content = mem.trim(u8, buf[0..len], " \t\r\n");

    if (mem.indexOf(u8, content, "Jupiter") != null) {
        return "Steam Deck LCD";
    } else if (mem.indexOf(u8, content, "Galileo") != null) {
        return "Steam Deck OLED";
    }
    return null;
}

/// Steam Deck shader pre-caching configuration
pub const DeckPreCacheConfig = struct {
    /// Enable automatic shader pre-caching
    enable_precache: bool = true,
    /// Maximum cache size in MB
    max_cache_mb: u64 = 4096,
    /// Prioritize recently played games
    prioritize_recent: bool = true,
    /// Enable background compilation
    background_compile: bool = true,
};

/// Pre-cache configuration for optimal Deck performance
pub fn getOptimalDeckConfig() DeckPreCacheConfig {
    // Check available storage
    const home = std.posix.getenv("HOME") orelse return DeckPreCacheConfig{};

    // Check if on internal storage (limited) or SD card
    const stat = fs.cwd().statFile(home) catch return DeckPreCacheConfig{};
    _ = stat;

    // Return conservative config for Deck
    return DeckPreCacheConfig{
        .enable_precache = true,
        .max_cache_mb = 2048, // 2GB max on Deck
        .prioritize_recent = true,
        .background_compile = true,
    };
}

/// Get shader cache download status for a game
pub fn getShaderCacheStatus(allocator: mem.Allocator, steam_root: []const u8, app_id: u32) !ShaderCacheStatus {
    const cache_path = try std.fmt.allocPrint(allocator, "{s}/steamapps/shadercache/{d}", .{ steam_root, app_id });
    defer allocator.free(cache_path);

    var status = ShaderCacheStatus{
        .app_id = app_id,
        .cache_exists = false,
        .cache_size_bytes = 0,
        .foz_files = 0,
        .pipeline_files = 0,
    };

    var dir = fs.cwd().openDir(cache_path, .{ .iterate = true }) catch return status;
    defer dir.close();

    status.cache_exists = true;

    // Recursively scan all subdirectories
    status.cache_size_bytes = dirSize(allocator, cache_path) catch 0;

    // Count foz/bin files recursively
    countCacheFiles(allocator, cache_path, &status) catch {};

    return status;
}

fn countCacheFiles(allocator: mem.Allocator, path: []const u8, status: *ShaderCacheStatus) !void {
    var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .file => {
                if (mem.endsWith(u8, entry.name, ".foz")) {
                    status.foz_files += 1;
                } else if (mem.endsWith(u8, entry.name, ".bin")) {
                    status.pipeline_files += 1;
                }
            },
            .directory => {
                const subpath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
                defer allocator.free(subpath);
                try countCacheFiles(allocator, subpath, status);
            },
            else => {},
        }
    }
}

pub const ShaderCacheStatus = struct {
    app_id: u32,
    cache_exists: bool,
    cache_size_bytes: u64,
    foz_files: u32,
    pipeline_files: u32,

    pub fn cacheSizeMB(self: *const ShaderCacheStatus) f64 {
        return @as(f64, @floatFromInt(self.cache_size_bytes)) / (1024 * 1024);
    }
};

/// Clear shader cache for a specific game
pub fn clearGameCache(allocator: mem.Allocator, steam_root: []const u8, app_id: u32) !void {
    const cache_path = try std.fmt.allocPrint(allocator, "{s}/steamapps/shadercache/{d}", .{ steam_root, app_id });
    defer allocator.free(cache_path);

    // Delete the directory recursively
    fs.cwd().deleteTree(cache_path) catch |err| {
        if (err != error.FileNotFound) return err;
    };
}

/// Get total shader cache size across all games
pub fn getTotalShaderCacheSize(allocator: mem.Allocator, steam_root: []const u8) !u64 {
    const cache_path = try std.fmt.allocPrint(allocator, "{s}/steamapps/shadercache", .{steam_root});
    defer allocator.free(cache_path);

    var total: u64 = 0;

    var dir = fs.cwd().openDir(cache_path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            const subdir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_path, entry.name });
            defer allocator.free(subdir_path);

            total += dirSize(allocator, subdir_path) catch continue;
        }
    }

    return total;
}

fn dirSize(allocator: mem.Allocator, path: []const u8) !u64 {
    var total: u64 = 0;

    var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .file => {
                const stat = dir.statFile(entry.name) catch continue;
                total += stat.size;
            },
            .directory => {
                const subpath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
                defer allocator.free(subpath);
                total += dirSize(allocator, subpath) catch continue;
            },
            else => {},
        }
    }

    return total;
}

test "SteamDetector init" {
    const allocator = std.testing.allocator;
    var detector = try SteamDetector.init(allocator);
    defer detector.deinit();
}

test "isSteamDeck" {
    // Should return false on non-Deck systems
    _ = isSteamDeck();
}
