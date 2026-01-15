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
const mem = std.mem;
const json = std.json;

const sharing = @import("sharing.zig");
const types = @import("types.zig");

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
const AF_INET: u16 = 2;
const SOCK_DGRAM: u32 = 2;
const SOCK_STREAM: u32 = 1;
const SOCK_CLOEXEC: u32 = 0x80000;
const SOCK_NONBLOCK: u32 = 0x800;
const SOL_SOCKET: u32 = 1;
const SO_REUSEADDR: u32 = 2;
const IPPROTO_IP: u32 = 0;
const IP_ADD_MEMBERSHIP: u32 = 35;
const MSG_DONTWAIT: u32 = 0x40;

const sockaddr_in = extern struct {
    family: u16 = AF_INET,
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
        const udp_result = std.os.linux.socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
        const udp_signed: isize = @bitCast(udp_result);
        if (udp_signed < 0) return error.SocketCreateFailed;
        self.discovery_socket = @intCast(udp_result);

        // Enable address reuse
        const opt_val: u32 = 1;
        const setsockopt_result1 = std.os.linux.setsockopt(
            @intCast(self.discovery_socket.?),
            SOL_SOCKET,
            SO_REUSEADDR,
            std.mem.asBytes(&opt_val),
            @sizeOf(@TypeOf(opt_val)),
        );
        const setsockopt_signed1: isize = @bitCast(setsockopt_result1);
        if (setsockopt_signed1 < 0) return error.SetSockOptFailed;

        // Bind to discovery port
        var bind_addr = sockaddr_in{
            .port = mem.nativeToBig(u16, DISCOVERY_PORT),
            .addr = .{ 0, 0, 0, 0 },
        };
        const bind_result1 = std.os.linux.bind(
            @intCast(self.discovery_socket.?),
            @ptrCast(&bind_addr),
            @sizeOf(sockaddr_in),
        );
        const bind_signed1: isize = @bitCast(bind_result1);
        if (bind_signed1 < 0) return error.BindFailed;

        // Join multicast group
        const mcast_addr = try parseIp4(MULTICAST_GROUP);
        const mreq = ip_mreq{
            .multiaddr = mcast_addr,
            .interface_addr = .{ 0, 0, 0, 0 },
        };

        const setsockopt_result2 = std.os.linux.setsockopt(
            @intCast(self.discovery_socket.?),
            IPPROTO_IP,
            IP_ADD_MEMBERSHIP,
            std.mem.asBytes(&mreq),
            @sizeOf(ip_mreq),
        );
        const setsockopt_signed2: isize = @bitCast(setsockopt_result2);
        if (setsockopt_signed2 < 0) return error.SetSockOptFailed;

        // Create TCP socket for transfers
        const tcp_result = std.os.linux.socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
        const tcp_signed: isize = @bitCast(tcp_result);
        if (tcp_signed < 0) return error.SocketCreateFailed;
        self.transfer_socket = @intCast(tcp_result);

        const setsockopt_result3 = std.os.linux.setsockopt(
            @intCast(self.transfer_socket.?),
            SOL_SOCKET,
            SO_REUSEADDR,
            std.mem.asBytes(&opt_val),
            @sizeOf(@TypeOf(opt_val)),
        );
        const setsockopt_signed3: isize = @bitCast(setsockopt_result3);
        if (setsockopt_signed3 < 0) return error.SetSockOptFailed;

        var tcp_addr = sockaddr_in{
            .port = mem.nativeToBig(u16, self.port),
            .addr = .{ 0, 0, 0, 0 },
        };
        const bind_result2 = std.os.linux.bind(
            @intCast(self.transfer_socket.?),
            @ptrCast(&tcp_addr),
            @sizeOf(sockaddr_in),
        );
        const bind_signed2: isize = @bitCast(bind_result2);
        if (bind_signed2 < 0) return error.BindFailed;

        const listen_result = std.os.linux.listen(@intCast(self.transfer_socket.?), 5);
        const listen_signed: isize = @bitCast(listen_result);
        if (listen_signed < 0) return error.ListenFailed;

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
        const hostname = getEnv("HOSTNAME") orelse "unknown";
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
        _ = std.os.linux.sendto(
            @intCast(self.discovery_socket.?),
            &msg_buf,
            pos,
            0,
            @ptrCast(&dest),
            @sizeOf(sockaddr_in),
        );

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
        const io = getIo();
        const stat = Dir.cwd().statFile(io, path, .{}) catch return error.FileNotFound;

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
        const len = std.fmt.bufPrint(
            &msg_buf,
            "NVCACHE\x02{{\"type\":\"query\",\"game_id\":\"{s}\",\"arch\":\"{s}\"}}",
            .{ game_id, self.gpu_profile.architecture },
        ) catch return;

        const mcast_addr = try parseIp4(MULTICAST_GROUP);
        var dest = sockaddr_in{
            .port = mem.nativeToBig(u16, DISCOVERY_PORT),
            .addr = mcast_addr,
        };
        _ = std.os.linux.sendto(
            @intCast(self.discovery_socket.?),
            &msg_buf,
            len.len,
            0,
            @ptrCast(&dest),
            @sizeOf(sockaddr_in),
        );
    }

    /// Process incoming discovery messages
    pub fn pollDiscovery(self: *P2PNode) !?DiscoveryEvent {
        if (!self.running or self.discovery_socket == null) return null;

        var buf: [2048]u8 = undefined;
        var sender: sockaddr_in = undefined;
        var sender_len: u32 = @sizeOf(sockaddr_in);

        // Non-blocking receive
        const recv_result = std.os.linux.recvfrom(
            @intCast(self.discovery_socket.?),
            &buf,
            buf.len,
            MSG_DONTWAIT,
            @ptrCast(&sender),
            &sender_len,
        );
        const recv_signed: isize = @bitCast(recv_result);
        if (recv_signed <= 0) return null;
        const n: usize = @intCast(recv_result);

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
        const sock_result = std.os.linux.socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
        const sock_signed: isize = @bitCast(sock_result);
        if (sock_signed < 0) return error.SocketCreateFailed;
        const sock: i32 = @intCast(sock_result);
        defer posix.close(sock);

        var addr = sockaddr_in{
            .port = mem.nativeToBig(u16, peer_port),
            .addr = peer_addr,
        };
        const connect_result = std.os.linux.connect(sock, @ptrCast(&addr), @sizeOf(sockaddr_in));
        const connect_signed: isize = @bitCast(connect_result);
        if (connect_signed < 0) return error.ConnectFailed;

        // Send header with metadata
        var header: [256]u8 = undefined;
        const header_len = std.fmt.bufPrint(
            &header,
            "NVCACHE_TRANSFER\n{s}\n{s}\n{d}\n",
            .{ cache.game_id, cache.game_name, cache.size_bytes },
        ) catch return error.BufferOverflow;
        const send_result1 = std.os.linux.sendto(sock, &header, header_len.len, 0, null, 0);
        const send_signed1: isize = @bitCast(send_result1);
        if (send_signed1 < 0) return error.SendFailed;

        // Send file
        const io = getIo();
        var file = try Dir.cwd().openFile(io, cache.path, .{});
        defer file.close(io);

        var file_buf: [64 * 1024]u8 = undefined;
        var offset: u64 = 0;
        while (true) {
            const bytes_read = file.readPositionalAll(io, &file_buf, offset) catch break;
            if (bytes_read == 0) break;
            const send_result2 = std.os.linux.sendto(sock, &file_buf, bytes_read, 0, null, 0);
            const send_signed2: isize = @bitCast(send_result2);
            if (send_signed2 < 0) return error.SendFailed;
            offset += bytes_read;
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

    /// Respond to a cache query with an offer if we have matching cache
    pub fn respondToQuery(self: *P2PNode, game_id: []const u8, requester_arch: []const u8) !void {
        if (!self.running or self.discovery_socket == null) return;

        // Check if architectures are compatible (same GPU arch)
        if (!mem.eql(u8, requester_arch, self.gpu_profile.architecture)) {
            // Incompatible GPU architecture, don't offer
            return;
        }

        // Find matching cache
        for (self.local_caches.items) |cache| {
            if (mem.eql(u8, cache.game_id, game_id)) {
                // Found matching cache, send offer
                var msg_buf: [1024]u8 = undefined;
                const len = std.fmt.bufPrint(
                    &msg_buf,
                    "NVCACHE\x03{{\"type\":\"offer\",\"game_id\":\"{s}\",\"game_name\":\"{s}\",\"size\":{d},\"port\":{d}}}",
                    .{ cache.game_id, cache.game_name, cache.size_bytes, self.port },
                ) catch return;

                const mcast_addr = try parseIp4(MULTICAST_GROUP);
                var dest = sockaddr_in{
                    .port = mem.nativeToBig(u16, DISCOVERY_PORT),
                    .addr = mcast_addr,
                };
                _ = std.os.linux.sendto(
                    @intCast(self.discovery_socket.?),
                    &msg_buf,
                    len.len,
                    0,
                    @ptrCast(&dest),
                    @sizeOf(sockaddr_in),
                );

                std.debug.print("Sent cache offer for {s} ({d} bytes)\n", .{ cache.game_name, cache.size_bytes });
                return;
            }
        }
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
                        // Respond with offer if we have matching cache
                        self.node.respondToQuery(query.game_id, query.arch) catch |err| {
                            std.debug.print("Failed to respond to query: {}\n", .{err});
                        };
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
            var ts = std.os.linux.timespec{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
            _ = std.os.linux.nanosleep(&ts, null);
        }
    }
};

fn getTimestamp() i64 {
    const ts = std.posix.clock_gettime(.REALTIME) catch return 0;
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
