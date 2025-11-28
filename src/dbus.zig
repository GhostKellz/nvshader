const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const fs = std.fs;
const cache = @import("cache.zig");
const steam = @import("steam.zig");
const sharing = @import("sharing.zig");
const stats = @import("stats.zig");

/// D-Bus service name for nvshader
pub const service_name = "com.nvcontrol.Shader";
pub const object_path = "/com/nvcontrol/Shader";
pub const interface_name = "com.nvcontrol.Shader";

/// Socket path for Unix domain socket IPC (fallback when D-Bus unavailable)
pub const socket_path = "/tmp/nvshader.sock";

/// IPC Message types
pub const MessageType = enum(u8) {
    status = 0x01,
    clean = 0x02,
    prewarm = 0x03,
    steam_info = 0x04,
    gpu_info = 0x05,
    response = 0x80,
    error_response = 0x81,
};

/// Status response data
pub const StatusResponse = struct {
    version: []const u8,
    total_entries: usize,
    total_size_bytes: u64,
    nvidia_size: u64,
    mesa_size: u64,
    fossilize_size: u64,
    dxvk_size: u64,
};

/// GPU info response
pub const GpuResponse = struct {
    vendor_id: u32,
    device_id: u32,
    architecture: []const u8,
    driver_version: []const u8,
};

/// IPC Server for nvcontrol integration
pub const IpcServer = struct {
    allocator: mem.Allocator,
    socket_fd: ?posix.socket_t,
    running: bool,

    pub fn init(allocator: mem.Allocator) IpcServer {
        return .{
            .allocator = allocator,
            .socket_fd = null,
            .running = false,
        };
    }

    pub fn deinit(self: *IpcServer) void {
        self.stop();
    }

    /// Start the IPC server
    pub fn start(self: *IpcServer) !void {
        // Remove existing socket if present
        fs.cwd().deleteFile(socket_path) catch {};

        // Create Unix domain socket
        const sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(sock);

        // Bind to socket path
        var addr: posix.sockaddr.un = .{ .path = undefined };
        @memset(&addr.path, 0);
        const path_bytes: []const u8 = socket_path;
        @memcpy(addr.path[0..path_bytes.len], path_bytes);

        try posix.bind(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        try posix.listen(sock, 5);

        // Make socket accessible via chmod
        _ = std.posix.fchmodat(posix.AT.FDCWD, socket_path, 0o666, 0) catch {};

        self.socket_fd = sock;
        self.running = true;
    }

    /// Stop the IPC server
    pub fn stop(self: *IpcServer) void {
        self.running = false;
        if (self.socket_fd) |fd| {
            posix.close(fd);
            self.socket_fd = null;
        }
        fs.cwd().deleteFile(socket_path) catch {};
    }

    /// Accept and handle one connection (non-blocking poll)
    pub fn poll(self: *IpcServer) !void {
        const sock = self.socket_fd orelse return error.NotStarted;

        // Use raw syscall to avoid error set bug in std.posix.accept
        const SOCK_NONBLOCK: u32 = 0x800;
        const SOCK_CLOEXEC: u32 = 0x80000;
        const result = std.os.linux.accept4(sock, null, null, SOCK_NONBLOCK | SOCK_CLOEXEC);
        const errno = std.os.linux.E.init(result);
        if (errno != .SUCCESS) {
            // Non-blocking accept - EAGAIN/EWOULDBLOCK means no pending connections
            return;
        }

        const client: posix.socket_t = @intCast(result);
        defer posix.close(client);

        self.handleClient(client) catch {};
    }

    fn handleClient(self: *IpcServer, client: posix.socket_t) !void {
        var buf: [1024]u8 = undefined;
        const n = try posix.recv(client, &buf, 0);
        if (n == 0) return;

        const msg_type: MessageType = @enumFromInt(buf[0]);
        var response_buf: [8192]u8 = undefined;

        const response = switch (msg_type) {
            .status => try self.handleStatus(&response_buf),
            .gpu_info => try self.handleGpuInfo(&response_buf),
            .steam_info => try self.handleSteamInfo(&response_buf),
            else => "Unknown command",
        };

        _ = try posix.send(client, response, 0);
    }

    fn handleStatus(self: *IpcServer, buf: []u8) ![]const u8 {
        var manager = cache.CacheManager.init(self.allocator) catch return "Error initializing";
        defer manager.deinit();

        manager.scan() catch return "Error scanning";

        const s = manager.getStats();

        return std.fmt.bufPrint(buf,
            \\{{"status":"ok","version":"0.1.0","entries":{d},"total_bytes":{d},"nvidia_bytes":{d},"mesa_bytes":{d},"fossilize_bytes":{d},"dxvk_bytes":{d}}}
        , .{
            manager.entries.items.len,
            s.total_size_bytes,
            s.nvidia_size,
            s.mesa_size,
            s.fossilize_size,
            s.dxvk_size,
        }) catch return "Error formatting";
    }

    fn handleGpuInfo(self: *IpcServer, buf: []u8) ![]const u8 {
        var profile = sharing.GpuProfile.detect(self.allocator) catch return "Error detecting GPU";
        defer profile.deinit();

        return std.fmt.bufPrint(buf,
            \\{{"status":"ok","vendor_id":{d},"device_id":{d},"architecture":"{s}","driver":"{s}"}}
        , .{
            profile.vendor_id,
            profile.device_id,
            profile.architecture,
            profile.driver_version,
        }) catch return "Error formatting";
    }

    fn handleSteamInfo(self: *IpcServer, buf: []u8) ![]const u8 {
        var detector = steam.SteamDetector.init(self.allocator) catch return "{\"status\":\"error\",\"message\":\"Steam not found\"}";
        defer detector.deinit();

        detector.scanLibraries() catch {};
        detector.scanGames() catch {};

        const root = detector.steam_root orelse return "{\"status\":\"error\",\"message\":\"Steam not installed\"}";
        const total_cache = steam.getTotalShaderCacheSize(self.allocator, root) catch 0;
        const is_deck = steam.isSteamDeck();

        return std.fmt.bufPrint(buf,
            \\{{"status":"ok","root":"{s}","libraries":{d},"games":{d},"cache_bytes":{d},"is_deck":{s}}}
        , .{
            root,
            detector.libraries.items.len,
            detector.games.items.len,
            total_cache,
            if (is_deck) "true" else "false",
        }) catch return "Error formatting";
    }

    /// Run the server loop
    pub fn run(self: *IpcServer) !void {
        try self.start();
        defer self.stop();

        while (self.running) {
            self.poll() catch {};
            std.posix.nanosleep(0, 100_000_000); // 100ms
        }
    }
};

/// IPC Client for querying nvshader from nvcontrol
pub const IpcClient = struct {
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator) IpcClient {
        return .{ .allocator = allocator };
    }

    /// Query the nvshader daemon
    pub fn query(self: *IpcClient, msg_type: MessageType) ![]const u8 {
        const sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        defer posix.close(sock);

        var addr: posix.sockaddr.un = .{ .path = undefined };
        @memset(&addr.path, 0);
        const path_bytes: []const u8 = socket_path;
        @memcpy(addr.path[0..path_bytes.len], path_bytes);

        try posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

        // Send request
        const msg = [_]u8{@intFromEnum(msg_type)};
        _ = try posix.send(sock, &msg, 0);

        // Receive response
        var buf: [8192]u8 = undefined;
        const n = try posix.recv(sock, &buf, 0);
        if (n == 0) return error.NoResponse;

        return self.allocator.dupe(u8, buf[0..n]);
    }

    pub fn getStatus(self: *IpcClient) ![]const u8 {
        return self.query(.status);
    }

    pub fn getGpuInfo(self: *IpcClient) ![]const u8 {
        return self.query(.gpu_info);
    }

    pub fn getSteamInfo(self: *IpcClient) ![]const u8 {
        return self.query(.steam_info);
    }
};

/// Check if daemon is running
pub fn isDaemonRunning() bool {
    fs.cwd().access(socket_path, .{}) catch return false;

    // Try to connect
    const sock = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return false;
    defer posix.close(sock);

    var addr: posix.sockaddr.un = .{ .path = undefined };
    @memset(&addr.path, 0);
    const path_bytes: []const u8 = socket_path;
    @memcpy(addr.path[0..path_bytes.len], path_bytes);

    posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch return false;
    return true;
}

/// JSON output for CLI integration
pub fn outputJson(allocator: mem.Allocator, comptime format: []const u8, args: anytype) !void {
    const stdout = std.io.getStdOut().writer();
    var buf: [8192]u8 = undefined;
    const json_str = try std.fmt.bufPrint(&buf, format, args);
    _ = allocator;
    try stdout.writeAll(json_str);
    try stdout.writeAll("\n");
}

test "IpcServer init" {
    const allocator = std.testing.allocator;
    var server = IpcServer.init(allocator);
    defer server.deinit();
}
