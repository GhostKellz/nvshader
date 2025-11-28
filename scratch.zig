const std = @import("std");

pub fn main() !void {
    const now = try std.time.Instant.now();
    const ts = now.timestamp;
    inline for (@typeInfo(@TypeOf(ts)).Struct.fields) |field| {
        std.debug.print("field: {s}\n", .{field.name});
    }
}
