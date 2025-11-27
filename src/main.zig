const std = @import("std");
const nvshader = @import("lib.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var manager = try nvshader.cache.CacheManager.init(allocator);
    defer manager.deinit();

    try manager.scan();

    if (args.len <= 1) {
        return try commandStatus(&manager);
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "status")) {
        return try commandStatus(&manager);
    } else if (std.mem.eql(u8, command, "clean")) {
        return try commandClean(&manager, args[2..]);
    } else if (std.mem.eql(u8, command, "validate")) {
        return try commandValidate(&manager);
    } else if (std.mem.eql(u8, command, "scan")) {
        try manager.scan();
        return try commandStatus(&manager);
    } else if (std.mem.eql(u8, command, "help")) {
        try printUsage();
        return;
    }

    std.log.err("Unknown command: {s}", .{command});
    try printUsage();
}

fn commandStatus(manager: *nvshader.cache.CacheManager) !void {
    const stdout = std.io.getStdOut().writer();
    const stats = manager.getStats();

    try stdout.print("nvshader cache overview\n=======================\n", .{});
    try stdout.print("Detected entries: {d}\n", .{manager.entries.items.len});
    try nvshader.stats.printBreakdown(stdout, stats);

    if (stats.oldest_entry) |oldest| {
        try stdout.print("Oldest entry ns: {d}\n", .{oldest});
    }
    if (stats.newest_entry) |newest| {
        try stdout.print("Newest entry ns: {d}\n", .{newest});
    }
}

fn commandValidate(manager: *nvshader.cache.CacheManager) !void {
    const stdout = std.io.getStdOut().writer();
    const report = manager.validate();

    try stdout.print("Validated {d} caches\n", .{report.checked});
    if (report.invalid == 0) {
        try stdout.print("All caches look good!\n", .{});
    } else {
        try stdout.print("Found {d} invalid cache entries\n", .{report.invalid});
    }
}

fn commandClean(manager: *nvshader.cache.CacheManager, args: [][]const u8) !void {
    const stdout = std.io.getStdOut().writer();
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
            try stdout.print("Usage: nvshader clean [--older-than DAYS] [--max-size SIZE]\n", .{});
            return;
        } else {
            return error.UnknownCleanOption;
        }
    }

    if (removed_total == 0) {
        try stdout.print("No entries removed.\n", .{});
    } else {
        try stdout.print("Removed {d} cache entries.\n", .{removed_total});
    }

    try manager.scan();
    try commandStatus(manager);
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

fn printUsage() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        "Usage: nvshader <command> [options]\n\n" ++
            "Commands:\n" ++
            "  status                Show cache summary (default)\n" ++
            "  clean [options]       Remove cache entries by policy\n" ++
            "     --older-than DAYS  Remove entries older than DAYS\n" ++
            "     --max-size SIZE    Shrink caches to SIZE (supports K/M/G/T)\n" ++
            "  validate              Check cache integrity\n" ++
            "  scan                  Rescan caches and show status\n" ++
            "  help                  Print this message\n",
        .{},
    );
}
