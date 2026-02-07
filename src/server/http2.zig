const std = @import("std");
const c = @cImport({
    @cInclude("nghttp2/nghttp2.h");
});

pub const Http2Error = error{
    SessionError,
    StreamError,
    FrameError,
    HeaderError,
    ProtocolError,
    ConnectionError,
    OutOfMemory,
};

/// HTTP/2 frame types
pub const FrameType = enum(u8) {
    data = 0x0,
    headers = 0x1,
    priority = 0x2,
    rst_stream = 0x3,
    settings = 0x4,
    push_promise = 0x5,
    ping = 0x6,
    goaway = 0x7,
    window_update = 0x8,
    continuation = 0x9,
};

/// HTTP/2 frame flags
pub const FrameFlags = struct {
    pub const END_STREAM: u8 = 0x1;
    pub const END_HEADERS: u8 = 0x4;
    pub const PADDED: u8 = 0x8;
    pub const PRIORITY: u8 = 0x20;
};

/// gRPC message prefix (5 bytes: 1 byte compression + 4 bytes length)
pub const GrpcPrefix = packed struct {
    compressed: u8,
    length: u32,

    pub fn parse(data: []const u8) ?GrpcPrefix {
        if (data.len < 5) return null;
        return .{
            .compressed = data[0],
            .length = std.mem.readInt(u32, data[1..5], .big),
        };
    }

    pub fn encode(compressed: bool, length: u32) [5]u8 {
        var buf: [5]u8 = undefined;
        buf[0] = if (compressed) 1 else 0;
        std.mem.writeInt(u32, buf[1..5], length, .big);
        return buf;
    }
};

/// Parsed gRPC request
pub const GrpcRequest = struct {
    method: []const u8, // e.g., "/runtime.v1.RuntimeService/Version"
    content_type: []const u8,
    data: []const u8, // protobuf message
    stream_id: i32,

    pub fn getServiceMethod(self: *const GrpcRequest) ?struct { service: []const u8, method: []const u8 } {
        // Parse "/runtime.v1.RuntimeService/Version"
        if (self.method.len < 2 or self.method[0] != '/') return null;

        const path = self.method[1..];
        const slash_idx = std.mem.lastIndexOf(u8, path, "/") orelse return null;

        return .{
            .service = path[0..slash_idx],
            .method = path[slash_idx + 1 ..],
        };
    }
};

/// HTTP/2 server session using nghttp2
pub const Http2Session = struct {
    allocator: std.mem.Allocator,
    session: ?*c.nghttp2_session,
    // Buffer for incoming data per stream
    stream_data: std.AutoHashMap(i32, StreamData),
    // Pending requests ready for processing
    pending_requests: std.ArrayList(GrpcRequest),
    // Output buffer
    output_buffer: std.ArrayList(u8),
    // Connection state
    connected: bool,

    const StreamData = struct {
        method: []const u8,
        content_type: []const u8,
        data: std.ArrayList(u8),
        headers_complete: bool,
        allocator: std.mem.Allocator,

        fn deinit(self: *StreamData) void {
            self.data.deinit(self.allocator);
        }
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        var self = Self{
            .allocator = allocator,
            .session = null,
            .stream_data = std.AutoHashMap(i32, StreamData).init(allocator),
            .pending_requests = .empty,
            .output_buffer = .empty,
            .connected = false,
        };

        // Create nghttp2 session callbacks
        var callbacks: ?*c.nghttp2_session_callbacks = null;
        if (c.nghttp2_session_callbacks_new(&callbacks) != 0) {
            return Http2Error.SessionError;
        }
        defer c.nghttp2_session_callbacks_del(callbacks);

        // Set callbacks
        c.nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, onFrameRecv);
        c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, onDataChunkRecv);
        c.nghttp2_session_callbacks_set_on_header_callback(callbacks, onHeader);
        c.nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, onStreamClose);
        c.nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, onBeginHeaders);
        c.nghttp2_session_callbacks_set_send_callback(callbacks, onSend);

        // Create server session with null user_data initially
        if (c.nghttp2_session_server_new(&self.session, callbacks, null) != 0) {
            return Http2Error.SessionError;
        }

        return self;
    }

    /// Update the user_data pointer after the struct is in stable memory
    /// MUST be called immediately after init when the struct is at its final location
    pub fn fixUserData(self: *Self) void {
        if (self.session) |session| {
            c.nghttp2_session_set_user_data(session, self);
        }
    }

    pub fn deinit(self: *Self) void {
        if (self.session) |session| {
            c.nghttp2_session_del(session);
        }

        // Clean up stream data
        var it = self.stream_data.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.method);
            self.allocator.free(entry.value_ptr.content_type);
            entry.value_ptr.deinit();
        }
        self.stream_data.deinit();

        for (self.pending_requests.items) |*req| {
            self.allocator.free(req.method);
            self.allocator.free(req.content_type);
            self.allocator.free(req.data);
        }
        self.pending_requests.deinit(self.allocator);

        self.output_buffer.deinit(self.allocator);
    }

    /// Send the HTTP/2 connection preface (server settings)
    pub fn sendServerPreface(self: *Self) !void {
        const session = self.session orelse return Http2Error.SessionError;

        // Send SETTINGS frame
        if (c.nghttp2_submit_settings(session, c.NGHTTP2_FLAG_NONE, null, 0) != 0) {
            return Http2Error.FrameError;
        }

        // Flush output
        try self.flushSession();
    }

    /// Process incoming data
    pub fn processInput(self: *Self, data: []const u8) !void {
        const session = self.session orelse return Http2Error.SessionError;

        const rv = c.nghttp2_session_mem_recv(session, data.ptr, data.len);
        if (rv < 0) {
            const err_str = c.nghttp2_strerror(@intCast(rv));
            if (err_str != null) {
                std.debug.print("nghttp2 error: {s}\n", .{std.mem.span(err_str)});
            }
            return Http2Error.ProtocolError;
        }

        // Send any pending output
        try self.flushSession();
    }

    /// Get pending output data
    pub fn getOutput(self: *Self) []const u8 {
        return self.output_buffer.items;
    }

    /// Clear output buffer after sending
    pub fn clearOutput(self: *Self) void {
        self.output_buffer.clearRetainingCapacity();
    }

    /// Get next pending request
    pub fn nextRequest(self: *Self) ?GrpcRequest {
        if (self.pending_requests.items.len > 0) {
            return self.pending_requests.orderedRemove(0);
        }
        return null;
    }

    /// Send a gRPC response
    pub fn sendResponse(self: *Self, stream_id: i32, data: []const u8, status: u32) !void {
        const session = self.session orelse return Http2Error.SessionError;

        // Build initial response headers (without grpc-status - that goes in trailers)
        var headers: [2]c.nghttp2_nv = undefined;
        headers[0] = makeNv(":status", "200");
        headers[1] = makeNv("content-type", "application/grpc");

        // Submit headers (without END_STREAM since data follows)
        var rv = c.nghttp2_submit_headers(
            session,
            c.NGHTTP2_FLAG_NONE, // No END_STREAM, no END_HEADERS (nghttp2 adds it)
            stream_id,
            null, // No priority
            &headers,
            headers.len,
            null, // No stream user data
        );
        if (rv < 0) {
            return Http2Error.FrameError;
        }

        // Flush headers
        try self.flushSession();

        // Create gRPC message with length prefix
        const prefix = GrpcPrefix.encode(false, @intCast(data.len));
        var full_message = try self.allocator.alloc(u8, 5 + data.len);
        defer self.allocator.free(full_message);
        @memcpy(full_message[0..5], &prefix);
        @memcpy(full_message[5..], data);

        // Write DATA frame manually (without END_STREAM - trailers follow)
        var data_frame_header: [9]u8 = undefined;
        const msg_len: u24 = @intCast(full_message.len);
        data_frame_header[0] = @intCast((msg_len >> 16) & 0xFF);
        data_frame_header[1] = @intCast((msg_len >> 8) & 0xFF);
        data_frame_header[2] = @intCast(msg_len & 0xFF);
        data_frame_header[3] = 0x00; // DATA frame type
        data_frame_header[4] = 0x00; // No flags (trailers will have END_STREAM)
        std.mem.writeInt(u32, data_frame_header[5..9], @intCast(stream_id), .big);

        try self.output_buffer.appendSlice(self.allocator, &data_frame_header);
        try self.output_buffer.appendSlice(self.allocator, full_message);

        // Build trailers with grpc-status
        var status_buf: [16]u8 = undefined;
        const status_str = std.fmt.bufPrint(&status_buf, "{d}", .{status}) catch "0";
        var trailers: [1]c.nghttp2_nv = undefined;
        trailers[0] = makeNv("grpc-status", status_str);

        // Submit trailers (with END_STREAM)
        rv = c.nghttp2_submit_trailer(session, stream_id, &trailers, trailers.len);
        if (rv != 0) {
            return Http2Error.FrameError;
        }

        // Flush trailers
        try self.flushSession();
    }

    /// Send gRPC error response
    pub fn sendError(self: *Self, stream_id: i32, grpc_status: u32, message: []const u8) !void {
        const session = self.session orelse return Http2Error.SessionError;

        var headers: [4]c.nghttp2_nv = undefined;

        headers[0] = makeNv(":status", "200");
        headers[1] = makeNv("content-type", "application/grpc");

        var status_buf: [16]u8 = undefined;
        const status_str = std.fmt.bufPrint(&status_buf, "{d}", .{grpc_status}) catch "0";
        headers[2] = makeNv("grpc-status", status_str);
        headers[3] = makeNv("grpc-message", message);

        const rv = c.nghttp2_submit_response(session, stream_id, &headers, headers.len, null);
        if (rv != 0) {
            return Http2Error.FrameError;
        }

        try self.flushSession();
    }

    fn flushSession(self: *Self) !void {
        const session = self.session orelse return;

        while (true) {
            var data_ptr: [*c]const u8 = undefined;
            const len = c.nghttp2_session_mem_send(session, &data_ptr);
            if (len < 0) {
                return Http2Error.SessionError;
            }
            if (len == 0) break;

            try self.output_buffer.appendSlice(self.allocator, data_ptr[0..@intCast(len)]);
        }
    }

    fn makeNv(name: []const u8, value: []const u8) c.nghttp2_nv {
        return .{
            .name = @constCast(name.ptr),
            .value = @constCast(value.ptr),
            .namelen = name.len,
            .valuelen = value.len,
            .flags = c.NGHTTP2_NV_FLAG_NONE,
        };
    }

    // nghttp2 callbacks
    fn onBeginHeaders(
        session: ?*c.nghttp2_session,
        frame: [*c]const c.nghttp2_frame,
        user_data: ?*anyopaque,
    ) callconv(.c) c_int {
        _ = session;
        const self: *Self = @ptrCast(@alignCast(user_data));

        if (frame.*.hd.type != c.NGHTTP2_HEADERS) return 0;
        if (frame.*.headers.cat != c.NGHTTP2_HCAT_REQUEST) return 0;

        const stream_id = frame.*.hd.stream_id;

        // Initialize stream data
        self.stream_data.put(stream_id, .{
            .method = "",
            .content_type = "",
            .data = .empty,
            .headers_complete = false,
            .allocator = self.allocator,
        }) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;

        return 0;
    }

    fn onHeader(
        session: ?*c.nghttp2_session,
        frame: [*c]const c.nghttp2_frame,
        name: [*c]const u8,
        namelen: usize,
        value: [*c]const u8,
        valuelen: usize,
        flags: u8,
        user_data: ?*anyopaque,
    ) callconv(.c) c_int {
        _ = session;
        _ = flags;
        const self: *Self = @ptrCast(@alignCast(user_data));

        if (frame.*.hd.type != c.NGHTTP2_HEADERS) return 0;

        const stream_id = frame.*.hd.stream_id;
        const entry = self.stream_data.getPtr(stream_id) orelse return 0;

        const name_slice = name[0..namelen];
        const value_slice = value[0..valuelen];

        if (std.mem.eql(u8, name_slice, ":path")) {
            entry.method = self.allocator.dupe(u8, value_slice) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
        } else if (std.mem.eql(u8, name_slice, "content-type")) {
            entry.content_type = self.allocator.dupe(u8, value_slice) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
        }

        return 0;
    }

    fn onFrameRecv(
        session: ?*c.nghttp2_session,
        frame: [*c]const c.nghttp2_frame,
        user_data: ?*anyopaque,
    ) callconv(.c) c_int {
        _ = session;
        const self: *Self = @ptrCast(@alignCast(user_data));

        const stream_id = frame.*.hd.stream_id;

        // Check for end of stream (request complete)
        if ((frame.*.hd.flags & c.NGHTTP2_FLAG_END_STREAM) != 0) {
            if (self.stream_data.getPtr(stream_id)) |entry| {
                // Skip the 5-byte gRPC prefix to get the protobuf message
                var data_slice: []const u8 = entry.data.items;
                if (data_slice.len >= 5) {
                    data_slice = data_slice[5..];
                }

                // Create request
                self.pending_requests.append(self.allocator, .{
                    .method = entry.method,
                    .content_type = entry.content_type,
                    .data = self.allocator.dupe(u8, data_slice) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE,
                    .stream_id = stream_id,
                }) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;

                // Clear stream data (but don't free method/content_type - they're now owned by request)
                entry.data.deinit(self.allocator);
                _ = self.stream_data.remove(stream_id);
            }
        }

        return 0;
    }

    fn onDataChunkRecv(
        session: ?*c.nghttp2_session,
        flags: u8,
        stream_id: i32,
        data: [*c]const u8,
        len: usize,
        user_data: ?*anyopaque,
    ) callconv(.c) c_int {
        _ = session;
        _ = flags;
        const self: *Self = @ptrCast(@alignCast(user_data));

        if (self.stream_data.getPtr(stream_id)) |entry| {
            entry.data.appendSlice(self.allocator, data[0..len]) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
        }

        return 0;
    }

    fn onStreamClose(
        session: ?*c.nghttp2_session,
        stream_id: i32,
        error_code: u32,
        user_data: ?*anyopaque,
    ) callconv(.c) c_int {
        _ = session;
        _ = error_code;
        const self: *Self = @ptrCast(@alignCast(user_data));

        // Clean up stream data if still present
        if (self.stream_data.fetchRemove(stream_id)) |kv| {
            self.allocator.free(kv.value.method);
            self.allocator.free(kv.value.content_type);
            var stream_d = kv.value;
            stream_d.deinit();
        }

        return 0;
    }

    fn onSend(
        session: ?*c.nghttp2_session,
        data: [*c]const u8,
        length: usize,
        flags: c_int,
        user_data: ?*anyopaque,
    ) callconv(.c) isize {
        _ = session;
        _ = flags;
        const self: *Self = @ptrCast(@alignCast(user_data));

        self.output_buffer.appendSlice(self.allocator, data[0..length]) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
        return @intCast(length);
    }
};

/// HTTP/2 connection preface that client sends
pub const CLIENT_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

/// Check if data starts with HTTP/2 client preface
pub fn isHttp2Preface(data: []const u8) bool {
    return data.len >= CLIENT_PREFACE.len and
        std.mem.eql(u8, data[0..CLIENT_PREFACE.len], CLIENT_PREFACE);
}

/// gRPC status codes
pub const GrpcStatus = struct {
    pub const OK: u32 = 0;
    pub const CANCELLED: u32 = 1;
    pub const UNKNOWN: u32 = 2;
    pub const INVALID_ARGUMENT: u32 = 3;
    pub const DEADLINE_EXCEEDED: u32 = 4;
    pub const NOT_FOUND: u32 = 5;
    pub const ALREADY_EXISTS: u32 = 6;
    pub const PERMISSION_DENIED: u32 = 7;
    pub const RESOURCE_EXHAUSTED: u32 = 8;
    pub const FAILED_PRECONDITION: u32 = 9;
    pub const ABORTED: u32 = 10;
    pub const OUT_OF_RANGE: u32 = 11;
    pub const UNIMPLEMENTED: u32 = 12;
    pub const INTERNAL: u32 = 13;
    pub const UNAVAILABLE: u32 = 14;
    pub const DATA_LOSS: u32 = 15;
    pub const UNAUTHENTICATED: u32 = 16;
};
