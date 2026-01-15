const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const json = std.json;
const steam = @import("steam.zig");

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

pub const GameSource = enum {
    steam,
    lutris,
    heroic,
    manual,

    pub fn name(self: GameSource) []const u8 {
        return switch (self) {
            .steam => "Steam",
            .lutris => "Lutris",
            .heroic => "Heroic",
            .manual => "Manual",
        };
    }
};

pub const Game = struct {
    source: GameSource,
    id: []const u8,
    name: []const u8,
    install_path: []const u8,
    cache_paths: std.ArrayListUnmanaged([]const u8) = .{},
    tags: std.ArrayListUnmanaged([]const u8) = .{},

    allocator: mem.Allocator,

    pub fn deinit(self: *Game) void {
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        self.allocator.free(self.install_path);

        for (self.cache_paths.items) |path| self.allocator.free(path);
        self.cache_paths.deinit(self.allocator);

        for (self.tags.items) |tag| self.allocator.free(tag);
        self.tags.deinit(self.allocator);
    }

    pub fn addCachePath(self: *Game, path: []const u8) !void {
        const dup = try self.allocator.dupe(u8, path);
        try self.cache_paths.append(self.allocator, dup);
    }

    pub fn addTag(self: *Game, value: []const u8) !void {
        const dup = try self.allocator.dupe(u8, value);
        try self.tags.append(self.allocator, dup);
    }
};

pub const GameCatalog = struct {
    allocator: mem.Allocator,
    games: std.ArrayListUnmanaged(Game),

    pub fn init(allocator: mem.Allocator) GameCatalog {
        return GameCatalog{
            .allocator = allocator,
            .games = .{},
        };
    }

    pub fn deinit(self: *GameCatalog) void {
        for (self.games.items) |*game| game.deinit();
        self.games.deinit(self.allocator);
    }

    pub fn detectAll(self: *GameCatalog) !void {
        try self.detectSteam();
        try self.detectLutris();
        try self.detectHeroic();
        try self.loadManual();
    }

    pub fn detectSteam(self: *GameCatalog) !void {
        var detector = try steam.SteamDetector.init(self.allocator);
        defer detector.deinit();

        detector.scanLibraries() catch return;
        detector.scanGames() catch return;

        for (detector.games.items) |game_info| {
            const id = try std.fmt.allocPrint(self.allocator, "steam:{d}", .{game_info.app_id});
            const name = try self.allocator.dupe(u8, game_info.name);
            const install_path = try self.allocator.dupe(u8, game_info.install_dir);

            var game = Game{
                .source = .steam,
                .id = id,
                .name = name,
                .install_path = install_path,
                .allocator = self.allocator,
            };

            if (detector.getShaderCachePath(game_info.app_id) catch null) |cache_path| {
                game.addCachePath(cache_path) catch {};
                self.allocator.free(cache_path);
            }

            if (game_info.last_played) |last_played| {
                const last_string = std.fmt.allocPrint(self.allocator, "last-played:{d}", .{last_played}) catch null;
                if (last_string) |value| {
                    game.addTag(value) catch {};
                    self.allocator.free(value);
                }
            }

            try self.games.append(self.allocator, game);
        }
    }

    fn detectLutris(self: *GameCatalog) !void {
        const home = getEnv("HOME") orelse return;
        const io = getIo();
        const suffixes = [_][]const u8{
            "/.local/share/lutris/games",
            "/.config/lutris/games",
        };

        for (suffixes) |suffix| {
            const dir_path = std.mem.concat(self.allocator, u8, &.{ home, suffix }) catch continue;
            defer self.allocator.free(dir_path);

            var dir = Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
            defer dir.close(io);

            var iter = dir.iterate();
            while (iter.next(io) catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!mem.endsWith(u8, entry.name, ".yml")) continue;

                const file_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
                defer self.allocator.free(file_path);

                if (parseLutrisYaml(self.allocator, file_path)) |parsed| {
                    defer parsed.deinit();

                    const id = std.fmt.allocPrint(self.allocator, "lutris:{s}", .{parsed.slug}) catch continue;
                    const name = self.allocator.dupe(u8, parsed.name) catch {
                        self.allocator.free(id);
                        continue;
                    };
                    const install_path = self.allocator.dupe(u8, parsed.install_dir) catch {
                        self.allocator.free(id);
                        self.allocator.free(name);
                        continue;
                    };

                    var game = Game{
                        .source = .lutris,
                        .id = id,
                        .name = name,
                        .install_path = install_path,
                        .allocator = self.allocator,
                    };

                    if (parsed.cache_hint) |hint| game.addCachePath(hint) catch {};
                    if (parsed.runner) |runner| game.addTag(runner) catch {};

                    try self.games.append(self.allocator, game);
                }
            }
        }
    }

    fn detectHeroic(self: *GameCatalog) !void {
        const home = getEnv("HOME") orelse return;

        // Heroic stores installed games in ~/.config/heroic/gog_store/installed.json
        // and ~/.config/heroic/legendary/installed.json (for Epic)
        const paths = [_]struct { path: []const u8, prefix: []const u8 }{
            .{ .path = "/.config/heroic/gog_store/installed.json", .prefix = "heroic-gog" },
            .{ .path = "/.config/heroic/legendary/installed.json", .prefix = "heroic-epic" },
            .{ .path = "/.config/heroic/sideload_apps/library.json", .prefix = "heroic-sideload" },
        };

        for (paths) |entry| {
            const full_path = std.mem.concat(self.allocator, u8, &.{ home, entry.path }) catch continue;
            defer self.allocator.free(full_path);

            self.parseHeroicJson(full_path, entry.prefix) catch continue;
        }
    }

    fn parseHeroicJson(self: *GameCatalog, path: []const u8, id_prefix: []const u8) !void {
        const data = Dir.cwd().readFileAlloc(getIo(), path, self.allocator, .unlimited) catch return;
        defer self.allocator.free(data);

        var parsed = json.parseFromSlice(json.Value, self.allocator, data, .{}) catch return;
        defer parsed.deinit();

        const root = parsed.value;

        // Handle both array format (installed.json) and object format (library.json)
        const games_iter: ?json.ObjectMap.Iterator = switch (root) {
            .object => |obj| obj.iterator(),
            .array => null,
            else => return,
        };

        if (root == .array) {
            // Array format: each item is a game object
            for (root.array.items) |item| {
                if (item != .object) continue;
                self.addHeroicGame(item.object, id_prefix) catch continue;
            }
        } else if (games_iter) |_| {
            // Object format: keys are app names, values are game objects
            var iter = root.object.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.* != .object) continue;
                self.addHeroicGame(entry.value_ptr.object, id_prefix) catch continue;
            }
        }
    }

    fn addHeroicGame(self: *GameCatalog, obj: json.ObjectMap, id_prefix: []const u8) !void {
        // Try different field names used by Heroic
        const app_name = obj.get("app_name") orelse obj.get("appName") orelse obj.get("title") orelse return;
        const title = obj.get("title") orelse obj.get("app_name") orelse return;
        const install_path_val = obj.get("install_path") orelse obj.get("installPath") orelse obj.get("folder_name") orelse return;

        const app_name_str = if (app_name == .string) app_name.string else return;
        const title_str = if (title == .string) title.string else return;
        const install_str = if (install_path_val == .string) install_path_val.string else return;

        const id = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ id_prefix, app_name_str });
        errdefer self.allocator.free(id);

        const name = try self.allocator.dupe(u8, title_str);
        errdefer self.allocator.free(name);

        const install_path = try self.allocator.dupe(u8, install_str);
        errdefer self.allocator.free(install_path);

        var game = Game{
            .source = .heroic,
            .id = id,
            .name = name,
            .install_path = install_path,
            .allocator = self.allocator,
        };

        // Add platform tag if available
        if (obj.get("platform")) |plat| {
            if (plat == .string) {
                game.addTag(plat.string) catch {};
            }
        }

        try self.games.append(self.allocator, game);
    }

    fn loadManual(self: *GameCatalog) !void {
        const home = getEnv("HOME") orelse return;
        const config_path = std.mem.concat(self.allocator, u8, &.{ home, "/.config/nvshader/games.json" }) catch return;
        defer self.allocator.free(config_path);

        const data = Dir.cwd().readFileAlloc(getIo(), config_path, self.allocator, .unlimited) catch return;
        defer self.allocator.free(data);

        var parsed = json.parseFromSlice(json.Value, self.allocator, data, .{}) catch return;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return;

        const games_val = root.object.get("games") orelse return;
        if (games_val != .array) return;

        for (games_val.array.items) |item| {
            if (item != .object) continue;

            const name_val = item.object.get("name") orelse continue;
            const path_val = item.object.get("install_path") orelse continue;

            if (name_val != .string or path_val != .string) continue;

            const id = std.fmt.allocPrint(self.allocator, "manual:{s}", .{fs.path.basename(path_val.string)}) catch continue;
            errdefer self.allocator.free(id);

            const name = self.allocator.dupe(u8, name_val.string) catch {
                self.allocator.free(id);
                continue;
            };
            errdefer self.allocator.free(name);

            const install_path = self.allocator.dupe(u8, path_val.string) catch {
                self.allocator.free(id);
                self.allocator.free(name);
                continue;
            };

            var game = Game{
                .source = .manual,
                .id = id,
                .name = name,
                .install_path = install_path,
                .allocator = self.allocator,
            };

            // Load cache paths if present
            if (item.object.get("cache_paths")) |cache_arr| {
                if (cache_arr == .array) {
                    for (cache_arr.array.items) |cache_item| {
                        if (cache_item == .string) {
                            game.addCachePath(cache_item.string) catch {};
                        }
                    }
                }
            }

            self.games.append(self.allocator, game) catch {
                game.deinit();
                continue;
            };
        }
    }

    pub fn saveManual(self: *GameCatalog) !void {
        const io = getIo();
        const home = getEnv("HOME") orelse return error.NoHomeDir;
        const config_dir = try std.mem.concat(self.allocator, u8, &.{ home, "/.config/nvshader" });
        defer self.allocator.free(config_dir);

        Dir.cwd().createDirPath(io, config_dir) catch {};

        const config_path = try std.mem.concat(self.allocator, u8, &.{ config_dir, "/games.json" });
        defer self.allocator.free(config_path);

        const file = try Dir.cwd().createFile(io, config_path, .{ .truncate = true });
        defer file.close(io);

        var writer = file.writer();
        try writer.writeAll("{\n  \"games\": [\n");

        var first = true;
        for (self.games.items) |game| {
            if (game.source != .manual) continue;

            if (!first) try writer.writeAll(",\n");
            first = false;

            try writer.writeAll("    {\n");
            try writer.print("      \"name\": \"{s}\",\n", .{game.name});
            try writer.print("      \"install_path\": \"{s}\"", .{game.install_path});

            if (game.cache_paths.items.len > 0) {
                try writer.writeAll(",\n      \"cache_paths\": [");
                var cache_first = true;
                for (game.cache_paths.items) |cache_path| {
                    if (!cache_first) try writer.writeAll(", ");
                    cache_first = false;
                    try writer.print("\"{s}\"", .{cache_path});
                }
                try writer.writeAll("]");
            }

            try writer.writeAll("\n    }");
        }

        try writer.writeAll("\n  ]\n}\n");
    }

    pub fn addManualGame(self: *GameCatalog, name: []const u8, install_path: []const u8, cache_paths: [][]const u8) !void {
        const id = try std.fmt.allocPrint(self.allocator, "manual:{s}", .{std.fs.path.basename(install_path)});
        var game = Game{
            .source = .manual,
            .id = id,
            .name = try self.allocator.dupe(u8, name),
            .install_path = try self.allocator.dupe(u8, install_path),
            .allocator = self.allocator,
        };

        for (cache_paths) |path| game.addCachePath(path) catch {};
        try self.games.append(self.allocator, game);
    }
};

const LutrisParse = struct {
    slug: []const u8,
    name: []const u8,
    install_dir: []const u8,
    cache_hint: ?[]const u8,
    runner: ?[]const u8,
    allocator: mem.Allocator,

    fn deinit(self: LutrisParse) void {
        self.allocator.free(self.slug);
        self.allocator.free(self.name);
        self.allocator.free(self.install_dir);
        if (self.cache_hint) |path| self.allocator.free(path);
        if (self.runner) |r| self.allocator.free(r);
    }
};

fn parseLutrisYaml(allocator: mem.Allocator, path: []const u8) ?LutrisParse {
    const io = getIo();
    var file = Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    var buf: [16384]u8 = undefined;
    const len = file.readPositionalAll(io, &buf, 0) catch return null;
    const data = buf[0..len];

    var name: ?[]const u8 = null;
    var slug: ?[]const u8 = null;
    var install_dir: ?[]const u8 = null;
    var cache_hint: ?[]const u8 = null;
    var runner: ?[]const u8 = null;

    var lines = mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line_raw| {
        const line = mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (mem.startsWith(u8, line, "name:")) {
            name = mem.trim(u8, line[5..], " \t");
        } else if (mem.startsWith(u8, line, "slug:")) {
            slug = mem.trim(u8, line[5..], " \t");
        } else if (mem.startsWith(u8, line, "directory:")) {
            install_dir = mem.trim(u8, line[10..], " \t");
        } else if (mem.startsWith(u8, line, "cache:")) {
            cache_hint = mem.trim(u8, line[6..], " \t");
        } else if (mem.startsWith(u8, line, "runner:")) {
            runner = mem.trim(u8, line[7..], " \t");
        }
    }

    if (name == null or slug == null or install_dir == null) return null;

    const slug_copy = allocator.dupe(u8, trimQuotes(slug.?)) catch return null;
    const name_copy = allocator.dupe(u8, trimQuotes(name.?)) catch {
        allocator.free(slug_copy);
        return null;
    };
    const dir_copy = allocator.dupe(u8, trimQuotes(install_dir.?)) catch {
        allocator.free(slug_copy);
        allocator.free(name_copy);
        return null;
    };

    const cache_copy = if (cache_hint) |value|
        allocator.dupe(u8, trimQuotes(value)) catch {
            allocator.free(slug_copy);
            allocator.free(name_copy);
            allocator.free(dir_copy);
            return null;
        }
    else
        null;

    const runner_copy = if (runner) |value| allocator.dupe(u8, trimQuotes(value)) catch null else null;

    return LutrisParse{
        .slug = slug_copy,
        .name = name_copy,
        .install_dir = dir_copy,
        .cache_hint = cache_copy,
        .runner = runner_copy,
        .allocator = allocator,
    };
}

fn trimQuotes(value: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = value.len;
    if (end == 0) return value;
    if (value[0] == '"') start += 1;
    if (end > start and value[end - 1] == '"') end -= 1;
    return value[start..end];
}
