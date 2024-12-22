const std = @import("std");
const libsystemd = @cImport({
    @cInclude("systemd/sd-bus.h");
});

pub fn main() !void {
    var bus = libsystemd.bus{};
    const bus_open_result = libsystemd.sd_bus_open_with_description(&bus, "systemd-cri", null);

    if (bus_open_result < 0) {
        std.debug.print("failed to open systemd bus: {}\n", .{bus_open_result});
        return;
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
