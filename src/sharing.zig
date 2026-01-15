const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const posix = std.posix;
const json = std.json;
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

/// .nvcache package format version
pub const PackageVersion: u32 = 1;

/// GPU compatibility info for cache sharing
pub const GpuProfile = struct {
    vendor_id: u32,
    device_id: u32,
    driver_version: []const u8,
    architecture: []const u8,
    vram_mb: u32,

    allocator: mem.Allocator,

    pub fn deinit(self: *GpuProfile) void {
        self.allocator.free(self.driver_version);
        self.allocator.free(self.architecture);
    }

    /// Check if this profile is compatible with another
    pub fn isCompatible(self: *const GpuProfile, other: *const GpuProfile) bool {
        // Same vendor required
        if (self.vendor_id != other.vendor_id) return false;

        // For NVIDIA, same architecture is strongly recommended
        if (self.vendor_id == 0x10de) {
            if (!mem.eql(u8, self.architecture, other.architecture)) return false;
        }

        // Device ID doesn't need to match exactly for same architecture
        return true;
    }

    /// Create profile from current system
    pub fn detect(allocator: mem.Allocator) !GpuProfile {
        // Try to read from nvidia-smi or /sys
        var profile = GpuProfile{
            .vendor_id = 0x10de, // Default to NVIDIA
            .device_id = 0,
            .driver_version = try allocator.dupe(u8, "unknown"),
            .architecture = try allocator.dupe(u8, "unknown"),
            .vram_mb = 0,
            .allocator = allocator,
        };

        // Try nvidia-smi for NVIDIA GPUs
        profile.detectNvidia() catch {};

        return profile;
    }

    fn detectNvidia(self: *GpuProfile) !void {
        // Read from /proc/driver/nvidia/version
        const io = getIo();
        const version_path = "/proc/driver/nvidia/version";
        if (Dir.cwd().openFile(io, version_path, .{})) |file| {
            defer file.close(io);
            var buf: [512]u8 = undefined;
            const len = file.readPositionalAll(io, &buf, 0) catch 0;
            if (len > 0) {
                // Parse version from NVRM version line
                // Format: "NVRM version: NVIDIA UNIX ... xxx.xxx.xx ..."
                const data = buf[0..len];

                // Look for version number pattern (three numbers with dots)
                var i: usize = 0;
                while (i + 10 < len) : (i += 1) {
                    if (data[i] >= '0' and data[i] <= '9') {
                        // Check if this looks like a version (has dots)
                        var j = i;
                        var dot_count: usize = 0;
                        while (j < len and (data[j] >= '0' and data[j] <= '9' or data[j] == '.')) : (j += 1) {
                            if (data[j] == '.') dot_count += 1;
                        }
                        if (dot_count >= 2 and j - i >= 6) {
                            self.allocator.free(self.driver_version);
                            self.driver_version = try self.allocator.dupe(u8, data[i..j]);
                            break;
                        }
                    }
                }
            }
        } else |_| {}

        // Try to detect architecture from device ID ranges
        // This is a simplified heuristic
        const pci_path = "/sys/bus/pci/devices";
        var dir = Dir.cwd().openDir(io, pci_path, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            // PCI devices are symlinks
            if (entry.kind != .sym_link and entry.kind != .directory) continue;

            // Read vendor
            const vendor_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}/vendor", .{ pci_path, entry.name });
            defer self.allocator.free(vendor_path);

            if (Dir.cwd().openFile(io, vendor_path, .{})) |vfile| {
                defer vfile.close(io);
                var vbuf: [16]u8 = undefined;
                const vlen = vfile.readPositionalAll(io, &vbuf, 0) catch 0;
                if (vlen >= 6) {
                    // Format: 0x10de
                    const vendor_str = mem.trim(u8, vbuf[0..vlen], " \t\r\n");
                    if (mem.startsWith(u8, vendor_str, "0x10de")) {
                        self.vendor_id = 0x10de;

                        // Read device ID
                        const device_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}/device", .{ pci_path, entry.name });
                        defer self.allocator.free(device_path);

                        if (Dir.cwd().openFile(io, device_path, .{})) |dfile| {
                            defer dfile.close(io);
                            var dbuf: [16]u8 = undefined;
                            const dlen = dfile.readPositionalAll(io, &dbuf, 0) catch 0;
                            if (dlen >= 4) {
                                // Parse 0xNNNN format
                                const device_str = mem.trim(u8, dbuf[0..@min(dlen, 8)], " \t\r\n");
                                const hex_start = if (mem.startsWith(u8, device_str, "0x")) device_str[2..] else device_str;
                                self.device_id = std.fmt.parseInt(u32, hex_start, 16) catch 0;

                                // Determine architecture from device ID
                                self.allocator.free(self.architecture);
                                self.architecture = try self.allocator.dupe(u8, detectArchitecture(self.device_id));
                            }
                        } else |_| {}
                        break;
                    }
                }
            } else |_| {}
        }
    }
};

fn detectArchitecture(device_id: u32) []const u8 {
    // NVIDIA device ID ranges (approximate)
    const id_upper = device_id >> 8;
    return switch (id_upper) {
        0x2a, 0x2b, 0x2c, 0x2d => "Blackwell", // RTX 50 series
        0x27, 0x28, 0x29 => "Ada Lovelace", // RTX 40 series
        0x24, 0x25, 0x26 => "Ampere", // RTX 30 series
        0x20, 0x21, 0x22 => "Turing", // RTX 20 series
        0x1d, 0x1e, 0x1f => "Volta/Turing",
        0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c => "Pascal", // GTX 10 series
        0x13, 0x14, 0x15, 0x16 => "Maxwell", // GTX 9/7 series
        0x10, 0x11, 0x12 => "Kepler",
        else => "unknown",
    };
}

/// Package metadata for .nvcache files
pub const PackageMetadata = struct {
    version: u32,
    created_at: i64,
    game_name: ?[]const u8,
    game_id: ?[]const u8,
    gpu_profile: GpuProfile,
    cache_types: []types.CacheType,
    total_size: u64,
    file_count: u32,
    checksum: []const u8,

    allocator: mem.Allocator,

    pub fn deinit(self: *PackageMetadata) void {
        if (self.game_name) |name| self.allocator.free(name);
        if (self.game_id) |id| self.allocator.free(id);
        self.allocator.free(self.cache_types);
        self.allocator.free(self.checksum);
        self.gpu_profile.deinit();
    }
};

/// Cache package builder
pub const PackageBuilder = struct {
    allocator: mem.Allocator,
    entries: std.ArrayListUnmanaged(PackageEntry),
    game_name: ?[]const u8,
    game_id: ?[]const u8,

    const PackageEntry = struct {
        source_path: []const u8,
        cache_type: types.CacheType,
        relative_path: []const u8,
    };

    pub fn init(allocator: mem.Allocator) PackageBuilder {
        return .{
            .allocator = allocator,
            .entries = .{},
            .game_name = null,
            .game_id = null,
        };
    }

    pub fn deinit(self: *PackageBuilder) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.source_path);
            self.allocator.free(entry.relative_path);
        }
        self.entries.deinit(self.allocator);
        if (self.game_name) |name| self.allocator.free(name);
        if (self.game_id) |id| self.allocator.free(id);
    }

    pub fn setGame(self: *PackageBuilder, name: []const u8, id: ?[]const u8) !void {
        if (self.game_name) |old| self.allocator.free(old);
        self.game_name = try self.allocator.dupe(u8, name);

        if (id) |game_id| {
            if (self.game_id) |old| self.allocator.free(old);
            self.game_id = try self.allocator.dupe(u8, game_id);
        }
    }

    pub fn addEntry(self: *PackageBuilder, path: []const u8, cache_type: types.CacheType) !void {
        const basename = fs.path.basename(path);
        try self.entries.append(self.allocator, .{
            .source_path = try self.allocator.dupe(u8, path),
            .cache_type = cache_type,
            .relative_path = try self.allocator.dupe(u8, basename),
        });
    }

    pub fn addFromManager(self: *PackageBuilder, manager: *cache.CacheManager, indices: []const usize) !void {
        for (indices) |idx| {
            const entry = manager.entries.items[idx];
            try self.addEntry(entry.path, entry.cache_type);
        }
    }

    /// Build the .nvcache package
    pub fn build(self: *PackageBuilder, output_path: []const u8) !void {
        const io = getIo();
        // Create output directory
        const dir_path = fs.path.dirname(output_path) orelse ".";
        Dir.cwd().createDirPath(io, dir_path) catch {};

        // Create the package as a directory with manifest + cache files
        Dir.cwd().createDirPath(io, output_path) catch {};

        var out_dir = try Dir.cwd().openDir(io, output_path, .{});
        defer out_dir.close(io);

        // Create cache subdirectory
        try out_dir.createDirPath(io, "cache");

        // Copy cache files
        var total_size: u64 = 0;
        for (self.entries.items) |entry| {
            const dest = try fs.path.join(self.allocator, &.{ output_path, "cache", entry.relative_path });
            defer self.allocator.free(dest);

            try copyPath(self.allocator, entry.source_path, dest);

            // Get size
            const stat = Dir.cwd().statFile(io, entry.source_path, .{}) catch continue;
            total_size += stat.size;
        }

        // Detect GPU profile
        var gpu_profile = try GpuProfile.detect(self.allocator);
        defer gpu_profile.deinit();

        // Write manifest
        const manifest_path = try fs.path.join(self.allocator, &.{ output_path, "manifest.json" });
        defer self.allocator.free(manifest_path);

        try self.writeManifest(manifest_path, total_size, &gpu_profile);
    }

    fn writeManifest(self: *PackageBuilder, path: []const u8, total_size: u64, gpu: *const GpuProfile) !void {
        const io = getIo();
        const file = try Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer file.close(io);

        var buf: [8192]u8 = undefined;
        var pos: usize = 0;

        const ts = std.posix.clock_gettime(.REALTIME) catch std.os.linux.timespec{ .sec = 0, .nsec = 0 };

        pos += (std.fmt.bufPrint(buf[pos..], "{{\n  \"version\": {d},\n  \"created_at\": {d},\n", .{ PackageVersion, ts.sec }) catch return error.BufferOverflow).len;

        if (self.game_name) |name| {
            pos += (std.fmt.bufPrint(buf[pos..], "  \"game_name\": \"{s}\",\n", .{name}) catch return error.BufferOverflow).len;
        }
        if (self.game_id) |id| {
            pos += (std.fmt.bufPrint(buf[pos..], "  \"game_id\": \"{s}\",\n", .{id}) catch return error.BufferOverflow).len;
        }

        pos += (std.fmt.bufPrint(buf[pos..], "  \"gpu\": {{\n    \"vendor_id\": {d},\n    \"device_id\": {d},\n    \"driver_version\": \"{s}\",\n    \"architecture\": \"{s}\"\n  }},\n", .{ gpu.vendor_id, gpu.device_id, gpu.driver_version, gpu.architecture }) catch return error.BufferOverflow).len;

        pos += (std.fmt.bufPrint(buf[pos..], "  \"total_size\": {d},\n  \"file_count\": {d},\n  \"entries\": [\n", .{ total_size, self.entries.items.len }) catch return error.BufferOverflow).len;

        var first = true;
        for (self.entries.items) |entry| {
            if (!first) {
                pos += (std.fmt.bufPrint(buf[pos..], ",\n", .{}) catch return error.BufferOverflow).len;
            }
            first = false;
            pos += (std.fmt.bufPrint(buf[pos..], "    {{\n      \"path\": \"{s}\",\n      \"type\": \"{s}\"\n    }}", .{ entry.relative_path, entry.cache_type.shortName() }) catch return error.BufferOverflow).len;
        }

        pos += (std.fmt.bufPrint(buf[pos..], "\n  ]\n}}\n", .{}) catch return error.BufferOverflow).len;

        _ = try file.writePositionalAll(io, buf[0..pos], 0);
    }
};

/// Import a .nvcache package
pub fn importPackage(
    allocator: mem.Allocator,
    package_path: []const u8,
    destination: ?[]const u8,
) !struct { imported: usize, skipped: usize } {
    const io = getIo();
    // Read manifest
    const manifest_path = try fs.path.join(allocator, &.{ package_path, "manifest.json" });
    defer allocator.free(manifest_path);

    const manifest_data = try Dir.cwd().readFileAlloc(io, manifest_path, allocator, .unlimited);
    defer allocator.free(manifest_data);

    var parsed = try json.parseFromSlice(json.Value, allocator, manifest_data, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidPackage;

    // Check GPU compatibility
    var local_gpu = try GpuProfile.detect(allocator);
    defer local_gpu.deinit();

    if (root.object.get("gpu")) |gpu_obj| {
        if (gpu_obj == .object) {
            const vendor = gpu_obj.object.get("vendor_id");
            if (vendor) |v| {
                if (v == .integer) {
                    const pkg_vendor: u32 = @intCast(v.integer);
                    if (pkg_vendor != local_gpu.vendor_id) {
                        std.debug.print("Warning: Package GPU vendor mismatch\n", .{});
                    }
                }
            }
        }
    }

    // Import entries
    const entries_val = root.object.get("entries") orelse return error.InvalidPackage;
    if (entries_val != .array) return error.InvalidPackage;

    var imported: usize = 0;
    var skipped: usize = 0;

    for (entries_val.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;

        const path_val = obj.get("path") orelse continue;
        const type_val = obj.get("type") orelse continue;

        if (path_val != .string or type_val != .string) continue;

        const cache_type = types.CacheType.fromString(type_val.string) orelse {
            skipped += 1;
            continue;
        };

        // Determine destination
        const dest_dir = destination orelse getDefaultCacheDir(allocator, cache_type) catch {
            skipped += 1;
            continue;
        };
        defer if (destination == null) allocator.free(dest_dir);

        const src = try fs.path.join(allocator, &.{ package_path, "cache", path_val.string });
        defer allocator.free(src);

        const dest = try fs.path.join(allocator, &.{ dest_dir, path_val.string });
        defer allocator.free(dest);

        copyPath(allocator, src, dest) catch {
            skipped += 1;
            continue;
        };

        imported += 1;
    }

    return .{ .imported = imported, .skipped = skipped };
}

fn getDefaultCacheDir(allocator: mem.Allocator, cache_type: types.CacheType) ![]const u8 {
    const home = getEnv("HOME") orelse return error.NoHomeDir;

    const suffix = switch (cache_type) {
        .dxvk => "/.cache/dxvk",
        .vkd3d => "/.cache/vkd3d-proton",
        .nvidia => "/.nv/ComputeCache",
        .mesa => "/.cache/mesa_shader_cache",
        .fossilize => "/.steam/steam/steamapps/shadercache",
    };

    return try mem.concat(allocator, u8, &.{ home, suffix });
}

fn copyPath(allocator: mem.Allocator, src: []const u8, dest: []const u8) !void {
    const io = getIo();
    const stat = try Dir.cwd().statFile(io, src, .{});

    if (stat.kind == .directory) {
        try copyDirectory(allocator, src, dest);
    } else {
        try copyFile(src, dest);
    }
}

fn copyFile(src: []const u8, dest: []const u8) !void {
    const io = getIo();
    const dest_dir = fs.path.dirname(dest) orelse ".";
    Dir.cwd().createDirPath(io, dest_dir) catch {};

    const src_file = try Dir.cwd().openFile(io, src, .{});
    defer src_file.close(io);

    const dest_file = try Dir.cwd().createFile(io, dest, .{ .truncate = true });
    defer dest_file.close(io);

    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = src_file.readPositionalAll(io, &buffer, offset) catch break;
        if (n == 0) break;
        _ = dest_file.writePositionalAll(io, buffer[0..n], offset) catch break;
        offset += n;
    }
}

fn copyDirectory(allocator: mem.Allocator, src: []const u8, dest: []const u8) !void {
    const io = getIo();
    Dir.cwd().createDirPath(io, dest) catch {};

    var dir = try Dir.cwd().openDir(io, src, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const from = try fs.path.join(allocator, &.{ src, entry.name });
        defer allocator.free(from);
        const to = try fs.path.join(allocator, &.{ dest, entry.name });
        defer allocator.free(to);

        switch (entry.kind) {
            .file => try copyFile(from, to),
            .directory => try copyDirectory(allocator, from, to),
            else => {},
        }
    }
}

test "GpuProfile detect" {
    const allocator = std.testing.allocator;
    var profile = try GpuProfile.detect(allocator);
    defer profile.deinit();
}
