const std = @import("std");
const c = @cImport({
    @cInclude("systemd/sd-bus.h");
    @cInclude("errno.h");
});

pub const BusError = error{
    ConnectionFailed,
    CallFailed,
    MessageFailed,
    InvalidReply,
    OutOfMemory,
    SystemError,
};

/// Wrapper around sd_bus_error for safe error handling
pub const Error = struct {
    inner: c.sd_bus_error,

    pub fn init() Error {
        return .{
            .inner = .{
                .name = null,
                .message = null,
                ._need_free = 0,
            },
        };
    }

    pub fn deinit(self: *Error) void {
        c.sd_bus_error_free(&self.inner);
    }

    pub fn isSet(self: *const Error) bool {
        return c.sd_bus_error_is_set(&self.inner) != 0;
    }

    pub fn getMessage(self: *const Error) ?[]const u8 {
        if (self.inner.message) |msg| {
            return std.mem.span(msg);
        }
        return null;
    }

    pub fn getName(self: *const Error) ?[]const u8 {
        if (self.inner.name) |name| {
            return std.mem.span(name);
        }
        return null;
    }
};

/// Wrapper around sd_bus_message for safe message handling
pub const Message = struct {
    inner: ?*c.sd_bus_message,

    pub fn init() Message {
        return .{ .inner = null };
    }

    pub fn deinit(self: *Message) void {
        if (self.inner) |msg| {
            _ = c.sd_bus_message_unref(msg);
            self.inner = null;
        }
    }

    /// Read a string from the message
    pub fn readString(self: *Message) BusError![]const u8 {
        var str: [*c]const u8 = null;
        const r = c.sd_bus_message_read(self.inner, "s", &str);
        if (r < 0) {
            return BusError.MessageFailed;
        }
        if (str) |s| {
            return std.mem.span(s);
        }
        return BusError.InvalidReply;
    }

    /// Read an object path from the message
    pub fn readObjectPath(self: *Message) BusError![]const u8 {
        var path: [*c]const u8 = null;
        const r = c.sd_bus_message_read(self.inner, "o", &path);
        if (r < 0) {
            return BusError.MessageFailed;
        }
        if (path) |p| {
            return std.mem.span(p);
        }
        return BusError.InvalidReply;
    }

    /// Enter a container (array, struct, variant, dict entry)
    pub fn enterContainer(self: *Message, container_type: u8, contents: ?[*:0]const u8) BusError!void {
        const r = c.sd_bus_message_enter_container(self.inner, container_type, contents);
        if (r < 0) {
            return BusError.MessageFailed;
        }
    }

    /// Exit a container
    pub fn exitContainer(self: *Message) BusError!void {
        const r = c.sd_bus_message_exit_container(self.inner);
        if (r < 0) {
            return BusError.MessageFailed;
        }
    }

    /// Skip the current element
    pub fn skip(self: *Message, types: ?[*:0]const u8) BusError!bool {
        const r = c.sd_bus_message_skip(self.inner, types);
        if (r < 0) {
            return BusError.MessageFailed;
        }
        return r > 0;
    }

    /// Peek at the next element type
    pub fn peekType(self: *Message) ?u8 {
        var type_char: u8 = 0;
        var contents: [*c]const u8 = null;
        const r = c.sd_bus_message_peek_type(self.inner, &type_char, &contents);
        if (r <= 0) {
            return null;
        }
        return type_char;
    }
};

/// D-Bus connection wrapper
pub const Bus = struct {
    inner: ?*c.sd_bus,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Open a connection to the system bus
    pub fn openSystem(allocator: std.mem.Allocator) BusError!Self {
        var bus: ?*c.sd_bus = null;
        const r = c.sd_bus_open_system(&bus);
        if (r < 0) {
            return BusError.ConnectionFailed;
        }
        return Self{
            .inner = bus,
            .allocator = allocator,
        };
    }

    /// Open a connection with a description
    pub fn openWithDescription(allocator: std.mem.Allocator, description: [*:0]const u8) BusError!Self {
        var bus: ?*c.sd_bus = null;
        const r = c.sd_bus_open_system_with_description(&bus, description);
        if (r < 0) {
            return BusError.ConnectionFailed;
        }
        return Self{
            .inner = bus,
            .allocator = allocator,
        };
    }

    /// Close and cleanup the bus connection
    pub fn deinit(self: *Self) void {
        if (self.inner) |bus| {
            _ = c.sd_bus_flush_close_unref(bus);
            self.inner = null;
        }
    }

    /// Call a method on the bus
    pub fn call(
        self: *Self,
        destination: [*:0]const u8,
        path: [*:0]const u8,
        interface: [*:0]const u8,
        member: [*:0]const u8,
        err: *Error,
        reply: *Message,
        types: ?[*:0]const u8,
    ) BusError!void {
        const r = c.sd_bus_call_method(
            self.inner,
            destination,
            path,
            interface,
            member,
            &err.inner,
            &reply.inner,
            types,
        );
        if (r < 0) {
            return BusError.CallFailed;
        }
    }

    /// Call a method with variadic arguments (for complex signatures)
    pub fn callMethodRaw(
        self: *Self,
        destination: [*:0]const u8,
        path: [*:0]const u8,
        interface: [*:0]const u8,
        member: [*:0]const u8,
    ) BusError!*c.sd_bus_message {
        var msg: ?*c.sd_bus_message = null;
        const r = c.sd_bus_message_new_method_call(
            self.inner,
            &msg,
            destination,
            path,
            interface,
            member,
        );
        if (r < 0 or msg == null) {
            return BusError.MessageFailed;
        }
        return msg.?;
    }

    /// Send a message and wait for reply
    pub fn callMessage(self: *Self, msg: *c.sd_bus_message, err: *Error) BusError!Message {
        var reply: ?*c.sd_bus_message = null;
        const r = c.sd_bus_call(self.inner, msg, 0, &err.inner, &reply);
        if (r < 0) {
            return BusError.CallFailed;
        }
        return Message{ .inner = reply };
    }

    /// Get a property from an object
    pub fn getProperty(
        self: *Self,
        destination: [*:0]const u8,
        path: [*:0]const u8,
        interface: [*:0]const u8,
        property: [*:0]const u8,
        err: *Error,
        prop_type: [*:0]const u8,
    ) BusError!Message {
        var reply = Message.init();
        const r = c.sd_bus_get_property(
            self.inner,
            destination,
            path,
            interface,
            property,
            &err.inner,
            &reply.inner,
            prop_type,
        );
        if (r < 0) {
            return BusError.CallFailed;
        }
        return reply;
    }

    /// Get the unique name of this connection
    pub fn getUniqueName(self: *Self) BusError![]const u8 {
        var name: [*c]const u8 = null;
        const r = c.sd_bus_get_unique_name(self.inner, &name);
        if (r < 0) {
            return BusError.SystemError;
        }
        if (name) |n| {
            return std.mem.span(n);
        }
        return BusError.InvalidReply;
    }
};

// Re-export the C library for use in other modules that need raw access
pub const raw = c;

test "Bus connection" {
    // This test requires a running systemd, so it's more of an integration test
    // Skip in normal test runs
    if (true) return error.SkipZigTest;

    var bus = try Bus.openSystem(std.testing.allocator);
    defer bus.deinit();

    const name = try bus.getUniqueName();
    try std.testing.expect(name.len > 0);
}
