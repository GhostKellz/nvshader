const std = @import("std");
const nvshader = @import("lib.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len <= 1) {
        return commandStatus(allocator);
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "status")) {
        return commandStatus(allocator);
    } else if (std.mem.eql(u8, command, "clean")) {
        return commandClean(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "validate")) {
        return commandValidate(allocator);
    } else if (std.mem.eql(u8, command, "scan")) {
        return commandStatus(allocator);
    } else if (std.mem.eql(u8, command, "prewarm")) {
        return commandPrewarm(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "watch")) {
        return commandWatch(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "export")) {
        return commandExport(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "import")) {
        return commandImport(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "pack")) {
        return commandPack(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "gpu")) {
        return commandGpu(allocator);
    } else if (std.mem.eql(u8, command, "games")) {
        return commandGames(allocator);
    } else if (std.mem.eql(u8, command, "steam")) {
        return commandSteam(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "daemon")) {
        return commandDaemon(allocator);
    } else if (std.mem.eql(u8, command, "json")) {
        return commandJson(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
        return;
    } else if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        std.debug.print("nvshader {s}\n", .{nvshader.version});
        return;
    }

    std.debug.print("Unknown command: {s}\n", .{command});
    printUsage();
}

fn commandStatus(allocator: std.mem.Allocator) void {
    var manager = nvshader.cache.CacheManager.init(allocator) catch {
        std.debug.print("Failed to initialize cache manager\n", .{});
        return;
    };
    defer manager.deinit();

    manager.scan() catch {
        std.debug.print("Failed to scan caches\n", .{});
        return;
    };

    const stats = manager.getStats();

    std.debug.print("\nnvshader v{s} - Shader Cache Manager\n", .{nvshader.version});
    std.debug.print("=====================================\n\n", .{});
    std.debug.print("Detected entries: {d}\n", .{manager.entries.items.len});
    nvshader.stats.printBreakdown(stats);

    if (stats.oldest_entry) |oldest| {
        const now_ts = std.posix.clock_gettime(.REALTIME) catch return;
        const now_ns: i128 = @as(i128, now_ts.sec) * 1_000_000_000 + now_ts.nsec;
        const age_days = @divTrunc(now_ns - oldest, 86400_000_000_000);
        std.debug.print("\nOldest cache: {d} days old\n", .{age_days});
    }
}

fn commandValidate(allocator: std.mem.Allocator) void {
    var manager = nvshader.cache.CacheManager.init(allocator) catch {
        std.debug.print("Failed to initialize cache manager\n", .{});
        return;
    };
    defer manager.deinit();

    manager.scan() catch {
        std.debug.print("Failed to scan caches\n", .{});
        return;
    };

    const report = manager.validate();

    std.debug.print("Validated {d} caches\n", .{report.checked});
    if (report.invalid == 0) {
        std.debug.print("All caches look good!\n", .{});
    } else {
        std.debug.print("Found {d} invalid cache entries\n", .{report.invalid});
    }
}

fn commandClean(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    var manager = nvshader.cache.CacheManager.init(allocator) catch {
        std.debug.print("Failed to initialize cache manager\n", .{});
        return;
    };
    defer manager.deinit();

    manager.scan() catch {
        std.debug.print("Failed to scan caches\n", .{});
        return;
    };

    var removed_total: u32 = 0;

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--older-than")) {
            if (i + 1 >= args.len) return error.MissingCleanValue;
            const days = try std.fmt.parseInt(u32, args[i + 1], 10);
            removed_total += try manager.cleanOlderThan(days);
            i += 2;
            continue;
        } else if (std.mem.eql(u8, arg, "--max-size")) {
            if (i + 1 >= args.len) return error.MissingCleanValue;
            const max_bytes = try parseByteSize(args[i + 1]);
            removed_total += try manager.shrinkToSize(max_bytes);
            i += 2;
            continue;
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("Usage: nvshader clean [--older-than DAYS] [--max-size SIZE]\n", .{});
            return;
        } else {
            return error.UnknownCleanOption;
        }
    }

    if (removed_total == 0) {
        std.debug.print("No entries removed.\n", .{});
    } else {
        std.debug.print("Removed {d} cache entries.\n", .{removed_total});
    }

    manager.scan() catch {};
    commandStatus(allocator);
}

fn commandPrewarm(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    var config = nvshader.prewarm.FossilizeConfig{};

    // Parse args
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--threads")) {
            if (i + 1 >= args.len) return error.MissingValue;
            config.num_threads = try std.fmt.parseInt(u32, args[i + 1], 10);
            i += 2;
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("Usage: nvshader prewarm [--threads N]\n", .{});
            std.debug.print("\nPre-compiles Fossilize shader caches to reduce in-game stuttering.\n", .{});
            return;
        } else {
            i += 1;
        }
    }

    var engine = nvshader.prewarm.PrewarmEngine.init(allocator, config) catch {
        std.debug.print("Failed to initialize pre-warm engine\n", .{});
        return;
    };
    defer engine.deinit();

    if (!engine.isAvailable()) {
        std.debug.print("Fossilize not found. Install fossilize_replay or ensure Steam is installed.\n", .{});
        return;
    }

    std.debug.print("Pre-warming shader caches...\n", .{});

    var manager = nvshader.cache.CacheManager.init(allocator) catch {
        std.debug.print("Failed to initialize cache manager\n", .{});
        return;
    };
    defer manager.deinit();

    manager.scan() catch {};

    const result = engine.prewarmFromManager(&manager, prewarmCallback) catch {
        std.debug.print("Pre-warming failed\n", .{});
        return;
    };

    std.debug.print("\nPre-warming complete!\n", .{});
    std.debug.print("  Compiled: {d}\n", .{result.completed});
    std.debug.print("  Failed: {d}\n", .{result.failed});
    std.debug.print("  Skipped: {d}\n", .{result.skipped});
}

fn prewarmCallback(progress: nvshader.prewarm.PrewarmProgress) void {
    if (progress.current_file) |file| {
        const basename = std.fs.path.basename(file);
        std.debug.print("\r[{d}/{d}] {s}...", .{ progress.completed + progress.failed, progress.total, basename });
    }
}

fn commandWatch(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    _ = args;

    var watcher = nvshader.watch.CacheWatcher.init(allocator) catch {
        std.debug.print("Failed to initialize watcher (inotify not available?)\n", .{});
        return;
    };
    defer watcher.deinit();

    watcher.addDefaultWatches() catch {
        std.debug.print("Failed to add watch directories\n", .{});
        return;
    };

    watcher.setCallback(watchCallback);

    std.debug.print("Watching shader caches... (Ctrl+C to stop)\n", .{});
    std.debug.print("Directories: {d}\n\n", .{watcher.watch_descriptors.count()});

    // Run watch loop with manual interrupt check
    var iterations: u64 = 0;
    while (iterations < 36000) { // ~1 hour max
        watcher.poll() catch {};
        std.posix.nanosleep(0, 100_000_000);
        iterations += 1;
    }

    std.debug.print("\n", .{});
    watcher.printStats();
}

fn watchCallback(event: nvshader.watch.WatchEventData) void {
    const event_str = switch (event.event) {
        .created => "CREATED",
        .modified => "MODIFIED",
        .deleted => "DELETED",
        .compilation_start => "COMPILING",
        .compilation_end => "COMPILED",
    };
    const type_str = if (event.cache_type) |t| t.shortName() else "unknown";
    const basename = std.fs.path.basename(event.path);
    std.debug.print("[{s}] {s}: {s}\n", .{ type_str, event_str, basename });
}

fn commandExport(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 1) {
        std.debug.print("Usage: nvshader export <output_dir> [--game NAME]\n", .{});
        return;
    }

    const output_dir = args[0];
    var game_hint: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--game") and i + 1 < args.len) {
            game_hint = args[i + 1];
            i += 2;
        } else {
            i += 1;
        }
    }

    var manager = nvshader.cache.CacheManager.init(allocator) catch {
        std.debug.print("Failed to initialize cache manager\n", .{});
        return;
    };
    defer manager.deinit();

    manager.scan() catch {};

    // Export all entries
    var indices = std.ArrayListUnmanaged(usize){};
    defer indices.deinit(allocator);

    for (manager.entries.items, 0..) |_, idx| {
        try indices.append(allocator, idx);
    }

    const progress = nvshader.archive.ProgressHook{};
    const report = nvshader.archive.exportSelection(allocator, &manager, indices.items, output_dir, game_hint, progress) catch {
        std.debug.print("Export failed\n", .{});
        return;
    };

    std.debug.print("Exported {d} entries ({d} files, {d:.2} MB)\n", .{
        report.entries,
        report.files_copied,
        @as(f64, @floatFromInt(report.bytes_copied)) / (1024 * 1024),
    });
}

fn commandImport(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 1) {
        std.debug.print("Usage: nvshader import <source_dir> [--dest DIR]\n", .{});
        return;
    }

    const source_dir = args[0];
    var dest_override: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--dest") and i + 1 < args.len) {
            dest_override = args[i + 1];
            i += 2;
        } else {
            i += 1;
        }
    }

    const progress = nvshader.archive.ProgressHook{};
    const report = nvshader.archive.importDirectory(allocator, source_dir, dest_override, progress) catch {
        std.debug.print("Import failed\n", .{});
        return;
    };

    std.debug.print("Imported {d} entries ({d} files, {d:.2} MB)\n", .{
        report.entries,
        report.files_restored,
        @as(f64, @floatFromInt(report.bytes_restored)) / (1024 * 1024),
    });
}

fn commandPack(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 1) {
        std.debug.print("Usage: nvshader pack <output.nvcache> [--game NAME]\n", .{});
        return;
    }

    const output_path = args[0];
    var game_name: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--game") and i + 1 < args.len) {
            game_name = args[i + 1];
            i += 2;
        } else {
            i += 1;
        }
    }

    var manager = nvshader.cache.CacheManager.init(allocator) catch {
        std.debug.print("Failed to initialize cache manager\n", .{});
        return;
    };
    defer manager.deinit();

    manager.scan() catch {};

    var builder = nvshader.sharing.PackageBuilder.init(allocator);
    defer builder.deinit();

    if (game_name) |name| {
        try builder.setGame(name, null);
    }

    // Add all Fossilize entries
    for (manager.entries.items) |entry| {
        if (entry.cache_type == .fossilize) {
            try builder.addEntry(entry.path, entry.cache_type);
        }
    }

    builder.build(output_path) catch |err| {
        std.debug.print("Failed to create package: {any}\n", .{err});
        return;
    };

    std.debug.print("Created package: {s}\n", .{output_path});
    std.debug.print("Entries: {d}\n", .{builder.entries.items.len});
}

fn commandGpu(allocator: std.mem.Allocator) void {
    var profile = nvshader.sharing.GpuProfile.detect(allocator) catch {
        std.debug.print("Failed to detect GPU\n", .{});
        return;
    };
    defer profile.deinit();

    std.debug.print("\nGPU Profile\n", .{});
    std.debug.print("===========\n", .{});
    std.debug.print("Vendor ID: 0x{x:0>4}\n", .{profile.vendor_id});
    std.debug.print("Device ID: 0x{x:0>4}\n", .{profile.device_id});
    std.debug.print("Architecture: {s}\n", .{profile.architecture});
    std.debug.print("Driver: {s}\n", .{profile.driver_version});
}

fn commandGames(allocator: std.mem.Allocator) void {
    var catalog = nvshader.games.GameCatalog.init(allocator);
    defer catalog.deinit();

    catalog.detectAll() catch {
        std.debug.print("Failed to detect games\n", .{});
        return;
    };

    std.debug.print("\nDetected Games\n", .{});
    std.debug.print("==============\n", .{});

    if (catalog.games.items.len == 0) {
        std.debug.print("No games detected.\n", .{});
        return;
    }

    for (catalog.games.items) |game| {
        std.debug.print("\n{s} [{s}]\n", .{ game.name, game.source.name() });
        std.debug.print("  ID: {s}\n", .{game.id});
        std.debug.print("  Path: {s}\n", .{game.install_path});
        if (game.cache_paths.items.len > 0) {
            std.debug.print("  Cache paths: {d}\n", .{game.cache_paths.items.len});
        }
    }

    std.debug.print("\nTotal: {d} games\n", .{catalog.games.items.len});
}

fn parseByteSize(raw: []const u8) !u64 {
    if (raw.len == 0) return error.InvalidSize;

    var multiplier: u64 = 1;
    var digits = raw;
    const suffix = raw[raw.len - 1];

    switch (suffix) {
        'k', 'K' => {
            multiplier = 1024;
            digits = raw[0 .. raw.len - 1];
        },
        'm', 'M' => {
            multiplier = 1024 * 1024;
            digits = raw[0 .. raw.len - 1];
        },
        'g', 'G' => {
            multiplier = 1024 * 1024 * 1024;
            digits = raw[0 .. raw.len - 1];
        },
        't', 'T' => {
            multiplier = 1024 * 1024 * 1024 * 1024;
            digits = raw[0 .. raw.len - 1];
        },
        else => {},
    }

    const base = try std.fmt.parseInt(u64, digits, 10);
    return try std.math.mul(u64, base, multiplier);
}

fn commandSteam(allocator: std.mem.Allocator, args: [][:0]u8) void {
    // Default to info subcommand
    var subcommand: []const u8 = "info";
    if (args.len > 0) {
        subcommand = args[0];
    }

    if (std.mem.eql(u8, subcommand, "info")) {
        steamInfo(allocator);
    } else if (std.mem.eql(u8, subcommand, "cache")) {
        steamCacheStatus(allocator);
    } else if (std.mem.eql(u8, subcommand, "clear")) {
        if (args.len > 1) {
            steamClearCache(allocator, args[1]);
        } else {
            std.debug.print("Usage: nvshader steam clear <appid>\n", .{});
        }
    } else if (std.mem.eql(u8, subcommand, "deck")) {
        steamDeckInfo();
    } else {
        std.debug.print("Unknown steam subcommand: {s}\n", .{subcommand});
        std.debug.print("Available: info, cache, clear <appid>, deck\n", .{});
    }
}

fn steamInfo(allocator: std.mem.Allocator) void {
    var detector = nvshader.steam.SteamDetector.init(allocator) catch {
        std.debug.print("Steam not detected\n", .{});
        return;
    };
    defer detector.deinit();

    detector.scanLibraries() catch {};
    detector.scanGames() catch {};

    std.debug.print("\nSteam Integration\n", .{});
    std.debug.print("=================\n\n", .{});

    if (detector.steam_root) |root| {
        std.debug.print("Steam Root: {s}\n", .{root});
    } else {
        std.debug.print("Steam not found\n", .{});
        return;
    }

    std.debug.print("Libraries: {d}\n", .{detector.libraries.items.len});
    std.debug.print("Games: {d}\n\n", .{detector.games.items.len});

    // Show total shader cache size
    if (detector.steam_root) |root| {
        const total_cache = nvshader.steam.getTotalShaderCacheSize(allocator, root) catch 0;
        const cache_mb = @as(f64, @floatFromInt(total_cache)) / (1024 * 1024);
        std.debug.print("Total Shader Cache: {d:.2} MB\n", .{cache_mb});
    }

    // Steam Deck status
    if (nvshader.steam.isSteamDeck()) {
        if (nvshader.steam.getSteamDeckModel()) |model| {
            std.debug.print("Device: {s}\n", .{model});
        } else {
            std.debug.print("Device: Steam Deck\n", .{});
        }
    }
}

fn steamCacheStatus(allocator: std.mem.Allocator) void {
    var detector = nvshader.steam.SteamDetector.init(allocator) catch {
        std.debug.print("Steam not detected\n", .{});
        return;
    };
    defer detector.deinit();

    detector.scanLibraries() catch {};
    detector.scanGames() catch {};

    const root = detector.steam_root orelse {
        std.debug.print("Steam not found\n", .{});
        return;
    };

    std.debug.print("\nSteam Shader Cache Status\n", .{});
    std.debug.print("=========================\n\n", .{});

    var total_size: u64 = 0;
    var games_with_cache: usize = 0;

    for (detector.games.items) |game| {
        const status = nvshader.steam.getShaderCacheStatus(allocator, root, game.app_id) catch continue;
        if (status.cache_exists) {
            games_with_cache += 1;
            total_size += status.cache_size_bytes;
            std.debug.print("{s} ({d}): {d:.2} MB ({d} foz, {d} bin)\n", .{
                game.name,
                game.app_id,
                status.cacheSizeMB(),
                status.foz_files,
                status.pipeline_files,
            });
        }
    }

    const total_mb = @as(f64, @floatFromInt(total_size)) / (1024 * 1024);
    std.debug.print("\nTotal: {d} games with cache, {d:.2} MB\n", .{ games_with_cache, total_mb });
}

fn steamClearCache(allocator: std.mem.Allocator, app_id_str: []const u8) void {
    const app_id = std.fmt.parseInt(u32, app_id_str, 10) catch {
        std.debug.print("Invalid app ID: {s}\n", .{app_id_str});
        return;
    };

    var detector = nvshader.steam.SteamDetector.init(allocator) catch {
        std.debug.print("Steam not detected\n", .{});
        return;
    };
    defer detector.deinit();

    const root = detector.steam_root orelse {
        std.debug.print("Steam not found\n", .{});
        return;
    };

    nvshader.steam.clearGameCache(allocator, root, app_id) catch |err| {
        std.debug.print("Failed to clear cache: {any}\n", .{err});
        return;
    };

    std.debug.print("Cleared shader cache for app {d}\n", .{app_id});
}

fn steamDeckInfo() void {
    std.debug.print("\nSteam Deck Status\n", .{});
    std.debug.print("=================\n\n", .{});

    if (nvshader.steam.isSteamDeck()) {
        if (nvshader.steam.getSteamDeckModel()) |model| {
            std.debug.print("Device: {s}\n", .{model});
        } else {
            std.debug.print("Device: Steam Deck (Unknown Model)\n", .{});
        }

        const config = nvshader.steam.getOptimalDeckConfig();
        std.debug.print("\nRecommended Settings:\n", .{});
        std.debug.print("  Pre-cache: {s}\n", .{if (config.enable_precache) "enabled" else "disabled"});
        std.debug.print("  Max cache: {d} MB\n", .{config.max_cache_mb});
        std.debug.print("  Prioritize recent: {s}\n", .{if (config.prioritize_recent) "yes" else "no"});
        std.debug.print("  Background compile: {s}\n", .{if (config.background_compile) "yes" else "no"});
    } else {
        std.debug.print("Not running on Steam Deck\n", .{});
    }
}

fn commandDaemon(allocator: std.mem.Allocator) void {
    if (nvshader.ipc.isDaemonRunning()) {
        std.debug.print("nvshader daemon is already running\n", .{});
        return;
    }

    std.debug.print("Starting nvshader daemon...\n", .{});
    std.debug.print("Socket: {s}\n", .{nvshader.ipc.socket_path});

    var server = nvshader.ipc.IpcServer.init(allocator);
    defer server.deinit();

    server.start() catch |err| {
        std.debug.print("Failed to start daemon: {any}\n", .{err});
        return;
    };

    std.debug.print("Daemon running. Press Ctrl+C to stop.\n", .{});

    // Run for up to 1 hour
    var iterations: u64 = 0;
    while (iterations < 36000) {
        server.poll() catch {};
        std.posix.nanosleep(0, 100_000_000);
        iterations += 1;
    }
}

fn commandJson(allocator: std.mem.Allocator, args: [][:0]u8) void {
    var subcommand: []const u8 = "status";
    if (args.len > 0) {
        subcommand = args[0];
    }

    if (std.mem.eql(u8, subcommand, "status")) {
        jsonStatus(allocator);
    } else if (std.mem.eql(u8, subcommand, "gpu")) {
        jsonGpu(allocator);
    } else if (std.mem.eql(u8, subcommand, "steam")) {
        jsonSteam(allocator);
    } else if (std.mem.eql(u8, subcommand, "games")) {
        jsonGames(allocator);
    } else {
        std.debug.print("{{\"error\":\"Unknown subcommand: {s}\"}}\n", .{subcommand});
    }
}

fn jsonStatus(allocator: std.mem.Allocator) void {
    var manager = nvshader.cache.CacheManager.init(allocator) catch {
        std.debug.print("{{\"error\":\"Failed to initialize\"}}\n", .{});
        return;
    };
    defer manager.deinit();

    manager.scan() catch {
        std.debug.print("{{\"error\":\"Failed to scan\"}}\n", .{});
        return;
    };

    const s = manager.getStats();

    std.debug.print(
        \\{{"version":"{s}","entries":{d},"total_bytes":{d},"nvidia_bytes":{d},"mesa_bytes":{d},"fossilize_bytes":{d},"dxvk_bytes":{d}}}
        \\
    , .{
        nvshader.version,
        manager.entries.items.len,
        s.total_size_bytes,
        s.nvidia_size,
        s.mesa_size,
        s.fossilize_size,
        s.dxvk_size,
    });
}

fn jsonGpu(allocator: std.mem.Allocator) void {
    var profile = nvshader.sharing.GpuProfile.detect(allocator) catch {
        std.debug.print("{{\"error\":\"Failed to detect GPU\"}}\n", .{});
        return;
    };
    defer profile.deinit();

    std.debug.print(
        \\{{"vendor_id":{d},"device_id":{d},"architecture":"{s}","driver":"{s}"}}
        \\
    , .{
        profile.vendor_id,
        profile.device_id,
        profile.architecture,
        profile.driver_version,
    });
}

fn jsonSteam(allocator: std.mem.Allocator) void {
    var detector = nvshader.steam.SteamDetector.init(allocator) catch {
        std.debug.print("{{\"error\":\"Steam not found\"}}\n", .{});
        return;
    };
    defer detector.deinit();

    detector.scanLibraries() catch {};
    detector.scanGames() catch {};

    const root = detector.steam_root orelse {
        std.debug.print("{{\"error\":\"Steam not installed\"}}\n", .{});
        return;
    };

    const total_cache = nvshader.steam.getTotalShaderCacheSize(allocator, root) catch 0;
    const is_deck = nvshader.steam.isSteamDeck();

    std.debug.print(
        \\{{"root":"{s}","libraries":{d},"games":{d},"cache_bytes":{d},"is_deck":{s}}}
        \\
    , .{
        root,
        detector.libraries.items.len,
        detector.games.items.len,
        total_cache,
        if (is_deck) "true" else "false",
    });
}

fn jsonGames(allocator: std.mem.Allocator) void {
    var catalog = nvshader.games.GameCatalog.init(allocator);
    defer catalog.deinit();

    catalog.detectAll() catch {
        std.debug.print("{{\"error\":\"Failed to detect games\"}}\n", .{});
        return;
    };

    std.debug.print("{{\"games\":[", .{});

    var first = true;
    for (catalog.games.items) |game| {
        if (!first) std.debug.print(",", .{});
        first = false;

        std.debug.print(
            \\{{"name":"{s}","source":"{s}","id":"{s}","path":"{s}"}}
        , .{
            game.name,
            game.source.name(),
            game.id,
            game.install_path,
        });
    }

    std.debug.print("]}}\n", .{});
}

fn printUsage() void {
    std.debug.print(
        \\nvshader v{s} - NVIDIA Shader Cache Manager
        \\
        \\Usage: nvshader <command> [options]
        \\
        \\Commands:
        \\  status              Show cache summary (default)
        \\  scan                Rescan caches and show status
        \\  clean [options]     Remove cache entries by policy
        \\     --older-than N   Remove entries older than N days
        \\     --max-size SIZE  Shrink total cache to SIZE (K/M/G/T)
        \\  validate            Check cache integrity
        \\  prewarm [options]   Pre-compile Fossilize shader caches
        \\     --threads N      Number of compilation threads (default: 4)
        \\  watch               Monitor cache changes in real-time
        \\  export <dir>        Export all caches to directory
        \\     --game NAME      Tag export with game name
        \\  import <dir>        Import caches from directory
        \\     --dest DIR       Override destination directory
        \\  pack <file>         Create .nvcache package for sharing
        \\     --game NAME      Tag package with game name
        \\  gpu                 Show GPU profile for compatibility
        \\  games               List detected games and their caches
        \\  steam [subcommand]  Steam integration commands
        \\     info             Show Steam installation info
        \\     cache            Show per-game shader cache status
        \\     clear <appid>    Clear shader cache for a game
        \\     deck             Show Steam Deck info/recommendations
        \\  json [subcommand]   Output JSON for scripting/integration
        \\     status           Cache status as JSON
        \\     gpu              GPU info as JSON
        \\     steam            Steam info as JSON
        \\     games            Games list as JSON
        \\  daemon              Start IPC daemon for nvcontrol integration
        \\  help                Print this message
        \\  version             Show version
        \\
        \\Supported cache types:
        \\  - DXVK state cache (.dxvk-cache)
        \\  - vkd3d-proton pipeline cache
        \\  - NVIDIA ComputeCache
        \\  - Mesa shader cache
        \\  - Fossilize/Steam (.foz)
        \\
        \\Examples:
        \\  nvshader status
        \\  nvshader clean --older-than 30 --max-size 10G
        \\  nvshader prewarm --threads 8
        \\  nvshader watch
        \\  nvshader steam cache
        \\  nvshader pack ~/elden-ring.nvcache --game "Elden Ring"
        \\
    , .{nvshader.version});
}
