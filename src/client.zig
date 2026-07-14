const std = @import("std");
const shared = @import("shared.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const ip: std.Io.net.IpAddress = .{ .ip4 = .unspecified(shared.port) };

    var server = try ip.listen(io, .{});
    defer server.deinit(io);

    var list: std.ArrayList(u8) = .empty;

    while (true) {
        const stream = try server.accept(io);
        defer stream.close(io);

        var reader = stream.reader(io, &.{});
        try reader.interface.appendRemaining(arena, &list, .unlimited);

        _ = try std.process.spawn(io, .{ .argv = &.{list.items} });
        list.clearRetainingCapacity();
    }
}
