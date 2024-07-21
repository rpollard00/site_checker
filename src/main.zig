const std = @import("std");
const NetworkError = @import("network_error.zig");
const queue = @import("queue.zig");
const alerter = @import("alerter.zig");
const json = std.json;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const net = std.net;
const heap = std.heap;
const http = std.http;

const print = std.debug.print;

const ArrayList = std.ArrayList;
const Timer = std.time.Timer;
const TcpConnectToHostError = std.net.TcpConnectToHostError;

const NS_IN_MS = 1000000;

const Site = struct {
    name: []const u8,
    port: u16 = 443, // use 443 as a default
    threshold: u16 = 10,
    current_failures: u16 = 0,
    polling_interval: u64 = 5000, // interval in ms
};

const SiteState = struct {
    is_failed: bool,
    current_failures: u16,
};

const Config = struct {
    sites: []Site,
    pollingIntervalMs: u64,
};

const ActionResult = struct {
    who: []const u8,
    what: PollingResult,
};

const Event = struct {
    action: EventAction,
    site_ptr: *Site,
};

const EventAction = enum {
    Poll,
};

const PollingResult = enum {
    Ok,
    Error,
};

pub fn loadConfigFile(alloc: mem.Allocator, config_file: []const u8) !json.Parsed(Config) {
    const max_config_size = 2000;

    const file = try fs.cwd().openFile(config_file, .{});
    defer file.close();

    const contents = try file.reader().readAllAlloc(alloc, max_config_size);
    defer alloc.free(contents);

    return try json.parseFromSlice(Config, alloc, contents, .{ .allocate = .alloc_always });
}

const Controller = struct {
    allocator: std.mem.Allocator,
    results: queue.Queue(ActionResult),
    alerter: alerter.AlertListeners,

    pub fn init(allocator: std.mem.Allocator) Controller {
        return Controller{
            .allocator = allocator,
            .results = queue.Queue(ActionResult).init(allocator),
            .alerter = alerter.AlertListeners.init(allocator),
        };
    }

    pub fn deinit(self: *Controller) void {
        self.alerter.deinit();
        self.results.deinit();
        self.* = undefined;
    }

    pub fn receiveResult(self: *Controller, result: ActionResult) !void {
        try self.results.enqueue(result);
        self.resultHandler();
    }

    pub fn resultHandler(self: *Controller) void {
        // print("I'm doing something\n" .{});
        if (self.results.peek() != null) {
            const currentResult = self.results.dequeue() catch {
                return;
            };
            print("HANDLED: {s}: {}\n", .{ currentResult.who, currentResult.what });
        }
        std.time.sleep(1000 * NS_IN_MS);
    }
};

const SiteChecker = struct {
    allocator: mem.Allocator,
    site: Site,
    timer: Timer,
    result_handler: *Controller,
    // do we need a pointer to the result queue
    // do we handle our own timing here

    pub fn init(
        alloc: mem.Allocator,
        site: Site,
        result_handler: *Controller,
    ) !SiteChecker {
        return SiteChecker{
            .allocator = alloc,
            .site = site,
            .result_handler = result_handler,
            .timer = try Timer.start(),
        };
    }

    pub fn deinit(self: *SiteChecker) void {
        self.allocator.destroy(self.result_handler);
    }

    fn checkSite(self: *SiteChecker) !?u64 {
        const start: u64 = self.timer.read();

        // print("Polling {s}...", .{self.site.name});
        errdefer print("\n", .{});

        var stream = net.tcpConnectToHost(self.allocator, self.site.name, self.site.port) catch |err| {
            if (NetworkError.errorClassifier(err)) |recoverable_error| {
                print("Polling {s}...ERROR: {!}\n", .{ self.site.name, recoverable_error });
                try self.result_handler.receiveResult(ActionResult{ .who = self.site.name, .what = PollingResult.Error });
                return @as(usize, 0);
                // TODO: dispatch result with error
                // try self.sendSiteAlert(site, recoverable_error);
            } else {
                return err;
            }
        };

        defer stream.close();

        const now: u64 = self.timer.lap();
        const duration_in_ms: u64 = (now - start) / NS_IN_MS;

        // TODO: dispatch successful result

        try self.result_handler.receiveResult(ActionResult{ .who = self.site.name, .what = PollingResult.Ok });
        print("Polling {s}...Success [RTT {d}ms]\n", .{ self.site.name, duration_in_ms });

        return duration_in_ms;
    }

    fn poll(self: *SiteChecker) !void {
        while (true) {
            _ = try self.checkSite();
            std.time.sleep(self.site.polling_interval * NS_IN_MS);
        }
    }
};

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parsedConfig = try loadConfigFile(allocator, "config.json");
    defer parsedConfig.deinit();

    const config = parsedConfig.value;

    // var resultQueue = queue.Queue(ActionResult).init(allocator);
    // defer resultQueue.deinit();
    var controller = Controller.init(allocator);
    defer controller.deinit();

    var siteCheckers: ArrayList(SiteChecker) = ArrayList(SiteChecker).init(allocator);
    defer siteCheckers.deinit();

    for (config.sites) |site| {
        const currentSite: SiteChecker = try SiteChecker.init(
            allocator,
            site,
            &controller,
        );
        try siteCheckers.append(currentSite);
    }

    _ = try std.Thread.spawn(.{}, Controller.resultHandler, .{&controller});

    try siteCheckers.items[0].poll();

    //

    // var terminate = std.atomic.Value(bool);
    //

    std.time.sleep(10000 * NS_IN_MS);

    // const ThreadContext = struct {
    //     queue: *Queue(u32),
    //     start_value: u32,
    //     count: u32,
    // };

    // const thread_count = 4;
    // const operations_per_thread = 1000;

    // var queue = Queue(u32).init(std.testing.allocator);
    // defer queue.deinit();

    // var threads: [thread_count]std.Thread = undefined;
    // var contexts: [thread_count]ThreadContext = undefined;
    // for (siteCheckers.items) |*sc| {
    // const Runner = struct {
    //     fn run(context: *ThreadContext) void {
    //         var i: u32 = 0;
    //         while (i < context.count) : (i += 1) {
    //             const value: u32 = @intCast(context.start_value + i);
    //             context.queue.enqueue(value) catch unreachable;
    //         }

    //         i = 0;
    //         while (i < context.count) : (i += 1) {
    //             _ = context.queue.dequeue() catch unreachable;
    //         }
    //     }
    // };

    // for (&threads, 0..) |*thread, i| {
    //     contexts[i] = ThreadContext{
    //         .queue = &queue,
    //         .start_value = @intCast(i * operations_per_thread),
    //         .count = operations_per_thread,
    //     };

    //     thread.* = try std.Thread.spawn(.{}, Runner.run, .{&contexts[i]});
    // }

    // for (threads) |thread| {
    //     thread.join();
    // }
    //     _ = try sc.*.checkSite();
    // }
}

const expect = std.testing.expect;

test "fba truncates and doesnt crash" {
    var buf: [16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var msg = try ArrayList(u8).initCapacity(fba.allocator(), 16);
    defer msg.deinit();

    const writer = msg.writer();
    writer.print("Message should truncate\n", .{}) catch |err| switch (err) {
        error.OutOfMemory => {
            try writer.writeAll("Too long........");
            print("Msg len is {d}\n", .{msg.items.len});
        },
        else => return err,
    };

    print("{s}\n", .{msg.items});
}
