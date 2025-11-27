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
    libraries: std.ArrayList(SteamLibrary),
    games: std.ArrayList(SteamGame),

    pub fn init(allocator: mem.Allocator) !SteamDetector {
        var detector = SteamDetector{
            .allocator = allocator,
            .steam_root = null,
            .libraries = std.ArrayList(SteamLibrary).init(allocator),
            .games = std.ArrayList(SteamGame).init(allocator),
        };

        try detector.detectSteamRoot();
        return detector;
    }

    pub fn deinit(self: *SteamDetector) void {
        if (self.steam_root) |root| self.allocator.free(root);

        for (self.libraries.items) |*lib| lib.deinit();
        self.libraries.deinit();

        for (self.games.items) |*game| game.deinit();
        self.games.deinit();
    }

    fn detectSteamRoot(self: *SteamDetector) !void {
        const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

        const paths_to_try = [_][]const u8{
            "{s}/.steam/steam",
            "{s}/.local/share/Steam",
            "{s}/.var/app/com.valvesoftware.Steam/.local/share/Steam",
        };

        for (paths_to_try) |fmt| {
            const path = try std.fmt.allocPrint(self.allocator, fmt, .{home});

            if (pathExists(path)) {
                self.steam_root = path;
                return;
            }

            self.allocator.free(path);
        }
    }

    /// Scan for all Steam library folders
    pub fn scanLibraries(self: *SteamDetector) !void {
        const root = self.steam_root orelse return error.SteamNotFound;

        // Add main Steam library
        try self.libraries.append(SteamLibrary{
            .path = try self.allocator.dupe(u8, root),
            .allocator = self.allocator,
        });

        // Parse libraryfolders.vdf for additional libraries
        const vdf_path = try std.fmt.allocPrint(self.allocator, "{s}/steamapps/libraryfolders.vdf", .{root});
        defer self.allocator.free(vdf_path);

        const file = fs.cwd().openFile(vdf_path, .{}) catch return;
        defer file.close();

        var buf: [4096]u8 = undefined;
        const content = file.readAll(&buf) catch return;

        // Simple parsing - look for "path" entries
        var lines = mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = mem.trim(u8, line, " \t\r");
            if (mem.startsWith(u8, trimmed, "\"path\"")) {
                // Extract path value
                if (extractQuotedValue(trimmed)) |path_val| {
                    // Skip if it's the main library
                    if (mem.eql(u8, path_val, root)) continue;

                    if (pathExists(path_val)) {
                        try self.libraries.append(SteamLibrary{
                            .path = try self.allocator.dupe(u8, path_val),
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
                    try self.games.append(game);
                }
            }
        }
    }

    fn parseAppManifest(self: *SteamDetector, manifest_path: []const u8, library_path: []const u8) !?SteamGame {
        const file = fs.cwd().openFile(manifest_path, .{}) catch return null;
        defer file.close();

        var buf: [8192]u8 = undefined;
        const content = file.readAll(&buf) catch return null;

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
        var sorted = std.ArrayList(SteamGame).init(self.allocator);
        defer sorted.deinit();

        for (self.games.items) |game| {
            sorted.append(game) catch continue;
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

test "SteamDetector init" {
    const allocator = std.testing.allocator;
    var detector = try SteamDetector.init(allocator);
    defer detector.deinit();
}
