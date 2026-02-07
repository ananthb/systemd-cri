const std = @import("std");

/// UUID v4 (random) generator
pub const UUID = struct {
    bytes: [16]u8,

    const Self = @This();

    /// Generate a new random UUID v4
    pub fn generate() Self {
        var uuid: Self = undefined;

        // Fill with random bytes
        std.crypto.random.bytes(&uuid.bytes);

        // Set version to 4 (random)
        uuid.bytes[6] = (uuid.bytes[6] & 0x0f) | 0x40;

        // Set variant to RFC 4122
        uuid.bytes[8] = (uuid.bytes[8] & 0x3f) | 0x80;

        return uuid;
    }

    /// Format UUID as a string (lowercase hex with dashes)
    pub fn format(self: *const Self, buf: *[36]u8) void {
        const hex = "0123456789abcdef";
        var pos: usize = 0;

        for (self.bytes, 0..) |byte, i| {
            buf[pos] = hex[byte >> 4];
            pos += 1;
            buf[pos] = hex[byte & 0x0f];
            pos += 1;

            // Add dashes at positions 4, 6, 8, 10 (after bytes 4, 6, 8, 10)
            if (i == 3 or i == 5 or i == 7 or i == 9) {
                buf[pos] = '-';
                pos += 1;
            }
        }
    }

    /// Return UUID as a heap-allocated string
    pub fn toString(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        var buf = try allocator.alloc(u8, 36);
        self.format(buf[0..36]);
        return buf;
    }

    /// Format for use with std.fmt
    pub fn formatFmt(self: *const Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        var buf: [36]u8 = undefined;
        self.format(&buf);
        try writer.writeAll(&buf);
    }

    pub const fmtFn = formatFmt;
};

/// Generate a new UUID and return it as a string
pub fn generateString(allocator: std.mem.Allocator) ![]u8 {
    const uuid = UUID.generate();
    return uuid.toString(allocator);
}

/// Generate a short ID (first 12 characters of UUID, no dashes)
pub fn generateShortId(buf: *[12]u8) void {
    const uuid = UUID.generate();
    const hex = "0123456789abcdef";
    for (uuid.bytes[0..6], 0..) |byte, i| {
        buf[i * 2] = hex[byte >> 4];
        buf[i * 2 + 1] = hex[byte & 0x0f];
    }
}

test "UUID generation" {
    const uuid1 = UUID.generate();
    const uuid2 = UUID.generate();

    // UUIDs should be different
    try std.testing.expect(!std.mem.eql(u8, &uuid1.bytes, &uuid2.bytes));

    // Check version (byte 6, upper nibble should be 4)
    try std.testing.expect((uuid1.bytes[6] & 0xf0) == 0x40);

    // Check variant (byte 8, upper 2 bits should be 10)
    try std.testing.expect((uuid1.bytes[8] & 0xc0) == 0x80);
}

test "UUID formatting" {
    const uuid = UUID.generate();
    var buf: [36]u8 = undefined;
    uuid.format(&buf);

    // Check dashes are in correct positions
    try std.testing.expectEqual(@as(u8, '-'), buf[8]);
    try std.testing.expectEqual(@as(u8, '-'), buf[13]);
    try std.testing.expectEqual(@as(u8, '-'), buf[18]);
    try std.testing.expectEqual(@as(u8, '-'), buf[23]);

    // Check length
    try std.testing.expectEqual(@as(usize, 36), buf.len);
}

test "short ID generation" {
    var buf: [12]u8 = undefined;
    generateShortId(&buf);

    // Should be 12 hex characters
    for (buf) |char| {
        const is_hex = (char >= '0' and char <= '9') or (char >= 'a' and char <= 'f');
        try std.testing.expect(is_hex);
    }
}
