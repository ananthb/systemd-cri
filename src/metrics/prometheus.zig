const std = @import("std");

/// Label pair for metrics
pub const Label = struct {
    name: []const u8,
    value: []const u8,
};

/// Counter metric - monotonically increasing value
pub const Counter = struct {
    name: []const u8,
    help: []const u8,
    value: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    labels: []const Label = &.{},

    pub fn inc(self: *Counter) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    pub fn add(self: *Counter, delta: u64) void {
        _ = self.value.fetchAdd(delta, .monotonic);
    }

    pub fn get(self: *const Counter) u64 {
        return self.value.load(.monotonic);
    }
};

/// Gauge metric - value that can go up or down
pub const Gauge = struct {
    name: []const u8,
    help: []const u8,
    value: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    labels: []const Label = &.{},

    pub fn set(self: *Gauge, val: i64) void {
        self.value.store(val, .monotonic);
    }

    pub fn inc(self: *Gauge) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    pub fn dec(self: *Gauge) void {
        _ = self.value.fetchSub(1, .monotonic);
    }

    pub fn add(self: *Gauge, delta: i64) void {
        _ = self.value.fetchAdd(delta, .monotonic);
    }

    pub fn get(self: *const Gauge) i64 {
        return self.value.load(.monotonic);
    }
};

/// Histogram bucket
pub const HistogramBucket = struct {
    le: f64, // upper bound
    count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

/// Histogram metric - distribution of values
pub const Histogram = struct {
    name: []const u8,
    help: []const u8,
    buckets: []HistogramBucket,
    sum: std.atomic.Value(u64) = std.atomic.Value(u64).init(0), // sum * 1000 for precision
    count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    labels: []const Label = &.{},

    /// Default bucket boundaries (in seconds)
    pub const default_buckets = [_]f64{ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0 };

    pub fn observe(self: *Histogram, value: f64) void {
        // Update buckets
        for (self.buckets) |*bucket| {
            if (value <= bucket.le) {
                _ = bucket.count.fetchAdd(1, .monotonic);
            }
        }
        // Update sum (store as microseconds for precision)
        const micros: u64 = @intFromFloat(value * 1_000_000);
        _ = self.sum.fetchAdd(micros, .monotonic);
        _ = self.count.fetchAdd(1, .monotonic);
    }

    pub fn getSum(self: *const Histogram) f64 {
        const micros = self.sum.load(.monotonic);
        return @as(f64, @floatFromInt(micros)) / 1_000_000.0;
    }

    pub fn getCount(self: *const Histogram) u64 {
        return self.count.load(.monotonic);
    }
};

/// Labeled counter - counter with dynamic labels
pub const LabeledCounter = struct {
    name: []const u8,
    help: []const u8,
    label_names: []const []const u8,
    counters: std.StringHashMap(u64),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, name: []const u8, help: []const u8, label_names: []const []const u8) LabeledCounter {
        return .{
            .name = name,
            .help = help,
            .label_names = label_names,
            .counters = std.StringHashMap(u64).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LabeledCounter) void {
        var it = self.counters.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.counters.deinit();
    }

    pub fn inc(self: *LabeledCounter, label_values: []const []const u8) void {
        self.add(label_values, 1);
    }

    pub fn add(self: *LabeledCounter, label_values: []const []const u8, delta: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = self.makeKey(label_values) catch return;

        if (self.counters.getPtr(key)) |val| {
            val.* += delta;
            self.allocator.free(key);
        } else {
            self.counters.put(key, delta) catch {
                self.allocator.free(key);
            };
        }
    }

    fn makeKey(self: *LabeledCounter, label_values: []const []const u8) ![]u8 {
        var size: usize = 0;
        for (label_values) |v| {
            size += v.len + 1;
        }
        var key = try self.allocator.alloc(u8, size);
        var pos: usize = 0;
        for (label_values) |v| {
            @memcpy(key[pos .. pos + v.len], v);
            pos += v.len;
            key[pos] = 0;
            pos += 1;
        }
        return key;
    }
};

/// Labeled gauge - gauge with dynamic labels
pub const LabeledGauge = struct {
    name: []const u8,
    help: []const u8,
    label_names: []const []const u8,
    gauges: std.StringHashMap(i64),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, name: []const u8, help: []const u8, label_names: []const []const u8) LabeledGauge {
        return .{
            .name = name,
            .help = help,
            .label_names = label_names,
            .gauges = std.StringHashMap(i64).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LabeledGauge) void {
        var it = self.gauges.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.gauges.deinit();
    }

    pub fn set(self: *LabeledGauge, label_values: []const []const u8, value: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = self.makeKey(label_values) catch return;

        if (self.gauges.getPtr(key)) |val| {
            val.* = value;
            self.allocator.free(key);
        } else {
            self.gauges.put(key, value) catch {
                self.allocator.free(key);
            };
        }
    }

    fn makeKey(self: *LabeledGauge, label_values: []const []const u8) ![]u8 {
        var size: usize = 0;
        for (label_values) |v| {
            size += v.len + 1;
        }
        var key = try self.allocator.alloc(u8, size);
        var pos: usize = 0;
        for (label_values) |v| {
            @memcpy(key[pos .. pos + v.len], v);
            pos += v.len;
            key[pos] = 0;
            pos += 1;
        }
        return key;
    }
};

/// Global metrics registry
pub const Registry = struct {
    allocator: std.mem.Allocator,

    // Pod metrics
    pods_created_total: Counter,
    pods_removed_total: Counter,
    pods_running: Gauge,

    // Container metrics
    containers_created_total: Counter,
    containers_started_total: Counter,
    containers_stopped_total: Counter,
    containers_removed_total: Counter,
    containers_running: Gauge,

    // Image metrics
    images_pulled_total: Counter,
    images_removed_total: Counter,
    images_total: Gauge,
    image_pull_duration_seconds: Histogram,

    // gRPC metrics
    grpc_requests_total: LabeledCounter,
    grpc_request_duration_seconds: Histogram,

    // Runtime metrics
    runtime_ready: Gauge,
    network_ready: Gauge,

    // Histogram buckets storage
    pull_duration_buckets: [11]HistogramBucket,
    grpc_duration_buckets: [11]HistogramBucket,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        var self: Self = undefined;
        self.allocator = allocator;

        // Initialize histogram buckets
        inline for (0..11) |i| {
            self.pull_duration_buckets[i] = .{ .le = Histogram.default_buckets[i] };
            self.grpc_duration_buckets[i] = .{ .le = Histogram.default_buckets[i] };
        }

        // Pod metrics
        self.pods_created_total = .{
            .name = "systemd_cri_pods_created_total",
            .help = "Total number of pods created",
        };
        self.pods_removed_total = .{
            .name = "systemd_cri_pods_removed_total",
            .help = "Total number of pods removed",
        };
        self.pods_running = .{
            .name = "systemd_cri_pods_running",
            .help = "Number of currently running pods",
        };

        // Container metrics
        self.containers_created_total = .{
            .name = "systemd_cri_containers_created_total",
            .help = "Total number of containers created",
        };
        self.containers_started_total = .{
            .name = "systemd_cri_containers_started_total",
            .help = "Total number of containers started",
        };
        self.containers_stopped_total = .{
            .name = "systemd_cri_containers_stopped_total",
            .help = "Total number of containers stopped",
        };
        self.containers_removed_total = .{
            .name = "systemd_cri_containers_removed_total",
            .help = "Total number of containers removed",
        };
        self.containers_running = .{
            .name = "systemd_cri_containers_running",
            .help = "Number of currently running containers",
        };

        // Image metrics
        self.images_pulled_total = .{
            .name = "systemd_cri_images_pulled_total",
            .help = "Total number of images pulled",
        };
        self.images_removed_total = .{
            .name = "systemd_cri_images_removed_total",
            .help = "Total number of images removed",
        };
        self.images_total = .{
            .name = "systemd_cri_images_total",
            .help = "Total number of images in store",
        };
        self.image_pull_duration_seconds = .{
            .name = "systemd_cri_image_pull_duration_seconds",
            .help = "Duration of image pull operations in seconds",
            .buckets = undefined, // Set by fixBucketPointers after stable address
        };

        // gRPC metrics
        self.grpc_requests_total = LabeledCounter.init(
            allocator,
            "systemd_cri_grpc_requests_total",
            "Total number of gRPC requests",
            &.{ "method", "status" },
        );
        self.grpc_request_duration_seconds = .{
            .name = "systemd_cri_grpc_request_duration_seconds",
            .help = "Duration of gRPC requests in seconds",
            .buckets = undefined, // Set by fixBucketPointers after stable address
        };

        // Runtime metrics
        self.runtime_ready = .{
            .name = "systemd_cri_runtime_ready",
            .help = "Whether the runtime is ready (1 = ready, 0 = not ready)",
        };
        self.network_ready = .{
            .name = "systemd_cri_network_ready",
            .help = "Whether the network is ready (1 = ready, 0 = not ready)",
        };

        return self;
    }

    /// Fix bucket pointers after Registry is at stable memory address
    /// Must be called after allocating Registry on heap
    pub fn fixBucketPointers(self: *Self) void {
        self.image_pull_duration_seconds.buckets = &self.pull_duration_buckets;
        self.grpc_request_duration_seconds.buckets = &self.grpc_duration_buckets;
    }

    pub fn deinit(self: *Self) void {
        self.grpc_requests_total.deinit();
    }

    /// Export all metrics in Prometheus text format
    pub fn render(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        // Use a fixed buffer first, then copy to allocated slice
        var buf: [16384]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();

        // Pod metrics
        try self.writeCounter(writer, &self.pods_created_total);
        try self.writeCounter(writer, &self.pods_removed_total);
        try self.writeGauge(writer, &self.pods_running);

        // Container metrics
        try self.writeCounter(writer, &self.containers_created_total);
        try self.writeCounter(writer, &self.containers_started_total);
        try self.writeCounter(writer, &self.containers_stopped_total);
        try self.writeCounter(writer, &self.containers_removed_total);
        try self.writeGauge(writer, &self.containers_running);

        // Image metrics
        try self.writeCounter(writer, &self.images_pulled_total);
        try self.writeCounter(writer, &self.images_removed_total);
        try self.writeGauge(writer, &self.images_total);
        try self.writeHistogram(writer, &self.image_pull_duration_seconds);

        // gRPC metrics
        try self.writeLabeledCounter(writer, &self.grpc_requests_total);
        try self.writeHistogram(writer, &self.grpc_request_duration_seconds);

        // Runtime metrics
        try self.writeGauge(writer, &self.runtime_ready);
        try self.writeGauge(writer, &self.network_ready);

        // Copy to allocated slice
        const written = fbs.getWritten();
        const result = try allocator.alloc(u8, written.len);
        @memcpy(result, written);
        return result;
    }

    fn writeCounter(self: *Self, writer: anytype, counter: *const Counter) !void {
        _ = self;
        try writer.print("# HELP {s} {s}\n", .{ counter.name, counter.help });
        try writer.print("# TYPE {s} counter\n", .{counter.name});
        try writer.print("{s} {d}\n\n", .{ counter.name, counter.get() });
    }

    fn writeGauge(self: *Self, writer: anytype, gauge: *const Gauge) !void {
        _ = self;
        try writer.print("# HELP {s} {s}\n", .{ gauge.name, gauge.help });
        try writer.print("# TYPE {s} gauge\n", .{gauge.name});
        try writer.print("{s} {d}\n\n", .{ gauge.name, gauge.get() });
    }

    fn writeHistogram(self: *Self, writer: anytype, histogram: *const Histogram) !void {
        _ = self;
        try writer.print("# HELP {s} {s}\n", .{ histogram.name, histogram.help });
        try writer.print("# TYPE {s} histogram\n", .{histogram.name});

        var cumulative: u64 = 0;
        for (histogram.buckets) |*bucket| {
            cumulative += bucket.count.load(.monotonic);
            try writer.print("{s}_bucket{{le=\"{d:.3}\"}} {d}\n", .{
                histogram.name,
                bucket.le,
                cumulative,
            });
        }
        try writer.print("{s}_bucket{{le=\"+Inf\"}} {d}\n", .{ histogram.name, histogram.getCount() });
        try writer.print("{s}_sum {d:.6}\n", .{ histogram.name, histogram.getSum() });
        try writer.print("{s}_count {d}\n\n", .{ histogram.name, histogram.getCount() });
    }

    fn writeLabeledCounter(self: *Self, writer: anytype, counter: *LabeledCounter) !void {
        _ = self;
        try writer.print("# HELP {s} {s}\n", .{ counter.name, counter.help });
        try writer.print("# TYPE {s} counter\n", .{counter.name});

        counter.mutex.lock();
        defer counter.mutex.unlock();

        var it = counter.counters.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;

            // Parse label values from key
            try writer.print("{s}{{", .{counter.name});
            var pos: usize = 0;
            for (counter.label_names, 0..) |label_name, i| {
                if (i > 0) try writer.writeAll(",");

                // Find next null terminator
                var end = pos;
                while (end < key.len and key[end] != 0) : (end += 1) {}
                const label_value = key[pos..end];
                pos = end + 1;

                try writer.print("{s}=\"{s}\"", .{ label_name, label_value });
            }
            try writer.print("}} {d}\n", .{value});
        }
        try writer.writeAll("\n");
    }
};

/// Global metrics instance
pub var global: ?*Registry = null;

/// Initialize global metrics
pub fn initGlobal(allocator: std.mem.Allocator) !*Registry {
    const registry = try allocator.create(Registry);
    registry.* = Registry.init(allocator);
    registry.fixBucketPointers(); // Fix pointers now that registry is at stable address
    global = registry;
    return registry;
}

/// Get global metrics instance
pub fn getGlobal() ?*Registry {
    return global;
}

test "counter increment" {
    var counter = Counter{
        .name = "test_counter",
        .help = "Test counter",
    };

    try std.testing.expectEqual(@as(u64, 0), counter.get());
    counter.inc();
    try std.testing.expectEqual(@as(u64, 1), counter.get());
    counter.add(5);
    try std.testing.expectEqual(@as(u64, 6), counter.get());
}

test "gauge operations" {
    var gauge = Gauge{
        .name = "test_gauge",
        .help = "Test gauge",
    };

    try std.testing.expectEqual(@as(i64, 0), gauge.get());
    gauge.set(42);
    try std.testing.expectEqual(@as(i64, 42), gauge.get());
    gauge.inc();
    try std.testing.expectEqual(@as(i64, 43), gauge.get());
    gauge.dec();
    try std.testing.expectEqual(@as(i64, 42), gauge.get());
}

test "histogram observe" {
    var buckets = [_]HistogramBucket{
        .{ .le = 0.1 },
        .{ .le = 0.5 },
        .{ .le = 1.0 },
    };

    var histogram = Histogram{
        .name = "test_histogram",
        .help = "Test histogram",
        .buckets = &buckets,
    };

    histogram.observe(0.05);
    histogram.observe(0.3);
    histogram.observe(0.8);

    try std.testing.expectEqual(@as(u64, 3), histogram.getCount());
    try std.testing.expectApproxEqAbs(@as(f64, 1.15), histogram.getSum(), 0.001);
}

test "registry render" {
    const allocator = std.testing.allocator;

    // Use initGlobal pattern to ensure bucket pointers are fixed
    const registry = try allocator.create(Registry);
    defer allocator.destroy(registry);
    registry.* = Registry.init(allocator);
    registry.fixBucketPointers();
    defer registry.deinit();

    registry.pods_created_total.inc();
    registry.pods_running.set(5);
    registry.containers_running.set(3);

    const output = try registry.render(allocator);
    defer allocator.free(output);

    // Verify output contains expected metrics
    try std.testing.expect(output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, output, "systemd_cri_pods_created_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "systemd_cri_pods_running 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "systemd_cri_containers_running 3") != null);
}
