//! Peer-to-Peer Shader Cache Sharing
//!
//! Simple local network P2P for discovering and sharing shader caches
//! between machines on the same LAN with compatible GPUs.
//!
//! Protocol:
//! - UDP multicast for peer discovery (port 34789)
//! - TCP for cache transfers (port 34790)
//! - JSON messages for metadata exchange

const std = @import("std");
const posix = std.posix;
const fs = std.fs;
const mem = std.mem;
const json = std.json;

const sharing = @import("sharing.zig");
const types = @import("types.zig");

/// Default ports
pub const DISCOVERY_PORT: u16 = 34789;
pub const TRANSFER_PORT: u16 = 34790;

/// Multicast group for LAN discovery
pub const MULTICAST_GROUP = "239.255.42.99";

/// Discovery message types
pub const MessageType = enum(u8) {
    announce = 0x01,
    query = 0x02,
    offer = 0x03,
    request = 0x04,
    ack = 0x05,
};

/// Peer info
pub const PeerInfo = struct {
    address: [4]u8,
    port: u16,
    hostname: []const u8,
    gpu_arch: []const u8,
    driver_version: []const u8,
    available_caches: []CacheOffer,

    allocator: mem.Allocator,

    const CacheOffer = struct {
        game_id: []const u8,
        game_name: []const u8,
        cache_type: types.CacheType,
        size_bytes: u64,
    };

    pub fn deinit(self: *PeerInfo) void {
        self.allocator.free(self.hostname);
        self.allocator.free(self.gpu_arch);
        self.allocator.free(self.driver_version);
        for (self.available_caches) |cache| {
            self.allocator.free(cache.game_id);
            self.allocator.free(cache.game_name);
        }
        self.allocator.free(self.available_caches);
    }
};

/// IPv4 sockaddr structure
const sockaddr_in = extern struct {
    family: u16 = posix.AF.INET,
    port: u16, // Big-endian
    addr: [4]u8,
    zero: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
};

/// IP multicast request structure
const ip_mreq = extern struct {
    multiaddr: [4]u8,
    interface_addr: [4]u8,
};

/// P2P Node for cache sharing
pub const P2PNode = struct {
    allocator: mem.Allocator,
    gpu_profile: sharing.GpuProfile,

    // Network state
    discovery_socket: ?posix.socket_t,
    transfer_socket: ?posix.socket_t,
    port: u16,

    // Known peers
    peers: std.ArrayListUnmanaged(PeerInfo),

    // Local caches available for sharing
    local_caches: std.ArrayListUnmanaged(LocalCache),

    // State
    running: bool,
    last_announce: i64,

    const LocalCache = struct {
        game_id: []const u8,
        game_name: []const u8,
        cache_type: types.CacheType,
        path: []const u8,
        size_bytes: u64,
    };

    pub fn init(allocator: mem.Allocator) !P2PNode {
        const gpu = try sharing.GpuProfile.detect(allocator);

        return .{
            .allocator = allocator,
            .gpu_profile = gpu,
            .discovery_socket = null,
            .transfer_socket = null,
            .port = TRANSFER_PORT,
            .peers = .{},
            .local_caches = .{},
            .running = false,
            .last_announce = 0,
        };
    }

    pub fn deinit(self: *P2PNode) void {
        self.stop();
        self.gpu_profile.deinit();

        for (self.peers.items) |*peer| {
            peer.deinit();
        }
        self.peers.deinit(self.allocator);

        for (self.local_caches.items) |cache| {
            self.allocator.free(cache.game_id);
            self.allocator.free(cache.game_name);
            self.allocator.free(cache.path);
        }
        self.local_caches.deinit(self.allocator);
    }

    /// Start the P2P node
    pub fn start(self: *P2PNode) !void {
        if (self.running) return;

        // Create UDP socket for discovery (multicast)
        self.discovery_socket = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);

        // Enable address reuse
        const opt_val: u32 = 1;
        try posix.setsockopt(
            self.discovery_socket.?,
            posix.SOL.SOCKET,
            posix.SO.REUSEADDR,
            std.mem.asBytes(&opt_val),
        );

        // Bind to discovery port
        var bind_addr = sockaddr_in{
            .port = mem.nativeToBig(u16, DISCOVERY_PORT),
            .addr = .{ 0, 0, 0, 0 },
        };
        try posix.bind(
            self.discovery_socket.?,
            @ptrCast(&bind_addr),
            @sizeOf(sockaddr_in),
        );

        // Join multicast group
        const mcast_addr = try parseIp4(MULTICAST_GROUP);
        const mreq = ip_mreq{
            .multiaddr = mcast_addr,
            .interface_addr = .{ 0, 0, 0, 0 },
        };

        try posix.setsockopt(
            self.discovery_socket.?,
            posix.IPPROTO.IP,
            12, // IP_ADD_MEMBERSHIP
            std.mem.asBytes(&mreq),
        );

        // Create TCP socket for transfers
        self.transfer_socket = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);

        try posix.setsockopt(
            self.transfer_socket.?,
            posix.SOL.SOCKET,
            posix.SO.REUSEADDR,
            std.mem.asBytes(&opt_val),
        );

        var tcp_addr = sockaddr_in{
            .port = mem.nativeToBig(u16, self.port),
            .addr = .{ 0, 0, 0, 0 },
        };
        try posix.bind(
            self.transfer_socket.?,
            @ptrCast(&tcp_addr),
            @sizeOf(sockaddr_in),
        );
        try posix.listen(self.transfer_socket.?, 5);

        self.running = true;

        // Send initial announce
        try self.announce();
    }

    /// Stop the P2P node
    pub fn stop(self: *P2PNode) void {
        if (!self.running) return;

        if (self.discovery_socket) |sock| {
            posix.close(sock);
            self.discovery_socket = null;
        }

        if (self.transfer_socket) |sock| {
            posix.close(sock);
            self.transfer_socket = null;
        }

        self.running = false;
    }

    /// Announce this node to the network
    pub fn announce(self: *P2PNode) !void {
        if (!self.running or self.discovery_socket == null) return;

        var msg_buf: [1024]u8 = undefined;
        var pos: usize = 0;

        // Build announce message
        pos += (std.fmt.bufPrint(msg_buf[pos..], "NVCACHE\x01", .{}) catch return).len;

        // Add JSON payload
        const hostname = posix.getenv("HOSTNAME") orelse "unknown";
        pos += (std.fmt.bufPrint(
            msg_buf[pos..],
            "{{\"type\":\"announce\",\"hostname\":\"{s}\",\"port\":{d},\"arch\":\"{s}\",\"driver\":\"{s}\",\"caches\":{d}}}",
            .{ hostname, self.port, self.gpu_profile.architecture, self.gpu_profile.driver_version, self.local_caches.items.len },
        ) catch return).len;

        // Send to multicast group
        const mcast_addr = try parseIp4(MULTICAST_GROUP);
        var dest = sockaddr_in{
            .port = mem.nativeToBig(u16, DISCOVERY_PORT),
            .addr = mcast_addr,
        };
        _ = posix.sendto(
            self.discovery_socket.?,
            msg_buf[0..pos],
            0,
            @ptrCast(&dest),
            @sizeOf(sockaddr_in),
        ) catch {};

        self.last_announce = getTimestamp();
    }

    /// Register a local cache for sharing
    pub fn addLocalCache(
        self: *P2PNode,
        game_id: []const u8,
        game_name: []const u8,
        cache_type: types.CacheType,
        path: []const u8,
    ) !void {
        // Get size
        const stat = fs.cwd().statFile(path) catch return error.FileNotFound;

        try self.local_caches.append(self.allocator, .{
            .game_id = try self.allocator.dupe(u8, game_id),
            .game_name = try self.allocator.dupe(u8, game_name),
            .cache_type = cache_type,
            .path = try self.allocator.dupe(u8, path),
            .size_bytes = stat.size,
        });
    }

    /// Query network for caches of a specific game
    pub fn queryForGame(self: *P2PNode, game_id: []const u8) !void {
        if (!self.running or self.discovery_socket == null) return;

        var msg_buf: [512]u8 = undefined;
        const len = try std.fmt.bufPrint(
            &msg_buf,
            "NVCACHE\x02{{\"type\":\"query\",\"game_id\":\"{s}\",\"arch\":\"{s}\"}}",
            .{ game_id, self.gpu_profile.architecture },
        );

        const mcast_addr = try parseIp4(MULTICAST_GROUP);
        var dest = sockaddr_in{
            .port = mem.nativeToBig(u16, DISCOVERY_PORT),
            .addr = mcast_addr,
        };
        _ = posix.sendto(
            self.discovery_socket.?,
            len,
            0,
            @ptrCast(&dest),
            @sizeOf(sockaddr_in),
        ) catch {};
    }

    /// Process incoming discovery messages
    pub fn pollDiscovery(self: *P2PNode) !?DiscoveryEvent {
        if (!self.running or self.discovery_socket == null) return null;

        var buf: [2048]u8 = undefined;
        var sender: posix.sockaddr = undefined;
        var sender_len: posix.socklen_t = @sizeOf(posix.sockaddr);

        // Non-blocking receive
        const n = posix.recvfrom(
            self.discovery_socket.?,
            &buf,
            posix.MSG.DONTWAIT,
            &sender,
            &sender_len,
        ) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };

        if (n < 8) return null;

        // Check header
        if (!mem.startsWith(u8, buf[0..n], "NVCACHE")) return null;

        const msg_type: MessageType = @enumFromInt(buf[7]);
        const payload = buf[8..n];

        // Parse JSON payload
        const parsed = json.parseFromSlice(json.Value, self.allocator, payload, .{}) catch return null;
        defer parsed.deinit();

        const obj = parsed.value.object;

        return switch (msg_type) {
            .announce => DiscoveryEvent{
                .peer_announce = .{
                    .hostname = obj.get("hostname").?.string,
                    .port = @intCast(obj.get("port").?.integer),
                    .arch = obj.get("arch").?.string,
                    .cache_count = @intCast(obj.get("caches").?.integer),
                },
            },
            .query => DiscoveryEvent{
                .cache_query = .{
                    .game_id = obj.get("game_id").?.string,
                    .arch = obj.get("arch").?.string,
                },
            },
            .offer => DiscoveryEvent{
                .cache_offer = .{
                    .game_id = obj.get("game_id").?.string,
                    .game_name = obj.get("game_name").?.string,
                    .size = @intCast(obj.get("size").?.integer),
                    .port = @intCast(obj.get("port").?.integer),
                },
            },
            else => null,
        };
    }

    /// Transfer a cache to a requesting peer
    pub fn sendCache(self: *P2PNode, cache_idx: usize, peer_addr: [4]u8, peer_port: u16) !void {
        if (cache_idx >= self.local_caches.items.len) return error.InvalidIndex;

        const cache = &self.local_caches.items[cache_idx];

        // Connect to peer
        const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        defer posix.close(sock);

        var addr = sockaddr_in{
            .port = mem.nativeToBig(u16, peer_port),
            .addr = peer_addr,
        };
        try posix.connect(sock, @ptrCast(&addr), @sizeOf(sockaddr_in));

        // Send header with metadata
        var header: [256]u8 = undefined;
        const header_len = try std.fmt.bufPrint(
            &header,
            "NVCACHE_TRANSFER\n{s}\n{s}\n{d}\n",
            .{ cache.game_id, cache.game_name, cache.size_bytes },
        );
        _ = try posix.send(sock, header_len, 0);

        // Send file
        const file = try fs.cwd().openFile(cache.path, .{});
        defer file.close();

        var file_buf: [64 * 1024]u8 = undefined;
        while (true) {
            const bytes_read = try file.read(&file_buf);
            if (bytes_read == 0) break;
            _ = try posix.send(sock, file_buf[0..bytes_read], 0);
        }
    }

    /// Get list of discovered peers
    pub fn getPeers(self: *const P2PNode) []const PeerInfo {
        return self.peers.items;
    }

    /// Get local caches
    pub fn getLocalCaches(self: *const P2PNode) []const LocalCache {
        return self.local_caches.items;
    }
};

/// Events from discovery
pub const DiscoveryEvent = union(enum) {
    peer_announce: struct {
        hostname: []const u8,
        port: u16,
        arch: []const u8,
        cache_count: usize,
    },
    cache_query: struct {
        game_id: []const u8,
        arch: []const u8,
    },
    cache_offer: struct {
        game_id: []const u8,
        game_name: []const u8,
        size: u64,
        port: u16,
    },
};

/// Simple daemon mode for background P2P
pub const P2PDaemon = struct {
    allocator: mem.Allocator,
    node: P2PNode,

    pub fn init(allocator: mem.Allocator) !P2PDaemon {
        return .{
            .allocator = allocator,
            .node = try P2PNode.init(allocator),
        };
    }

    pub fn deinit(self: *P2PDaemon) void {
        self.node.deinit();
    }

    /// Run the daemon (blocking)
    pub fn run(self: *P2PDaemon) !void {
        try self.node.start();
        defer self.node.stop();

        std.debug.print("nvshader P2P daemon started\n", .{});
        std.debug.print("  Discovery port: {d}\n", .{DISCOVERY_PORT});
        std.debug.print("  Transfer port: {d}\n", .{self.node.port});
        std.debug.print("  GPU: {s} ({s})\n", .{
            self.node.gpu_profile.architecture,
            self.node.gpu_profile.driver_version,
        });

        // Main loop
        while (true) {
            // Re-announce periodically (every 60 seconds)
            const now = getTimestamp();
            if (now - self.node.last_announce > 60) {
                self.node.announce() catch {};
            }

            // Process discovery events
            if (self.node.pollDiscovery() catch null) |event| {
                switch (event) {
                    .peer_announce => |info| {
                        std.debug.print("Peer discovered: {s} ({s}, {d} caches)\n", .{
                            info.hostname,
                            info.arch,
                            info.cache_count,
                        });
                    },
                    .cache_query => |query| {
                        std.debug.print("Cache query: {s} ({s})\n", .{
                            query.game_id,
                            query.arch,
                        });
                        // TODO: Respond with offer if we have matching cache
                    },
                    .cache_offer => |offer| {
                        std.debug.print("Cache offer: {s} ({d} bytes)\n", .{
                            offer.game_name,
                            offer.size,
                        });
                    },
                }
            }

            // Small sleep to avoid busy loop
            std.posix.nanosleep(0, 10 * std.time.ns_per_ms);
        }
    }
};

fn getTimestamp() i64 {
    const ts = posix.clock_gettime(.REALTIME) catch return 0;
    return ts.sec;
}

fn parseIp4(str: []const u8) ![4]u8 {
    var result: [4]u8 = undefined;
    var parts = mem.splitScalar(u8, str, '.');
    var i: usize = 0;
    while (parts.next()) |part| {
        if (i >= 4) return error.InvalidAddress;
        result[i] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidAddress;
        i += 1;
    }
    if (i != 4) return error.InvalidAddress;
    return result;
}

test "P2PNode init" {
    const allocator = std.testing.allocator;
    var node = try P2PNode.init(allocator);
    defer node.deinit();
}
