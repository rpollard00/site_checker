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
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,

    pub fn init(allocator: std.mem.Allocator) Controller {
        const mutex = std.Thread.Mutex{};
        return Controller{
            .allocator = allocator,
            .results = queue.Queue(ActionResult).init(allocator, mutex),
            .alerter = alerter.AlertListeners.init(allocator),
            .mutex = mutex,
            .cond = std.Thread.Condition{},
        };
    }

    pub fn deinit(self: *Controller) void {
        self.alerter.deinit();
        self.results.deinit();
        self.* = undefined;
    }

    pub fn dispatch(self: *Controller, result: ActionResult) !void {
        try self.results.enqueue(result);

        self.cond.signal();
    }

    pub fn resultHandler(self: *Controller) void {
        while (true) {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.results.peek() == null) {
                self.cond.wait(&self.mutex);
            }

            const currentResult = self.results.dequeue() catch {
                continue;
            };

            if (currentResult == null) {
                continue;
            }

            print("HANDLED: {s}: {}\n", .{ currentResult.?.who, currentResult.?.what });
        }
    }
};

const SiteChecker = struct {
    allocator: mem.Allocator,
    site: Site,
    timer: Timer,
    result_handler: *Controller,
    terminate: *std.atomic.Value(bool),

    pub fn init(
        alloc: mem.Allocator,
        site: Site,
        result_handler: *Controller,
        terminate: *std.atomic.Value(bool),
    ) !SiteChecker {
        return SiteChecker{
            .allocator = alloc,
            .site = site,
            .result_handler = result_handler,
            .timer = try Timer.start(),
            .terminate = terminate,
        };
    }

    pub fn deinit(self: *SiteChecker) void {
        self.allocator.destroy(self.result_handler);
    }

    fn checkSite(self: *SiteChecker) !?u64 {
        const start: u64 = self.timer.read();

        // print("Polling {s}...", .{self.site.name});
        // errdefer print("\n", .{});

        var stream = net.tcpConnectToHost(self.allocator, self.site.name, self.site.port) catch |err| {
            if (NetworkError.errorClassifier(err)) |_| {
                // print("Polling {s}...ERROR: {!}\n", .{ self.site.name, recoverable_error });
                try self.result_handler.dispatch(ActionResult{ .who = self.site.name, .what = PollingResult.Error });
                return @as(usize, 0);
                // try self.sendSiteAlert(site, recoverable_error);
            } else {
                return err;
            }
        };

        defer stream.close();

        const now: u64 = self.timer.lap();
        const duration_in_ms: u64 = (now - start) / NS_IN_MS;

        try self.result_handler.dispatch(ActionResult{ .who = self.site.name, .what = PollingResult.Ok });
        // print("Polling {s}...Success [RTT {d}ms]\n", .{ self.site.name, duration_in_ms });

        return duration_in_ms;
    }

    fn poll(self: *SiteChecker) !void {
        while (self.terminate.load(.seq_cst) == false) {
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

    var controller = Controller.init(allocator);
    defer controller.deinit();

    var siteCheckers: ArrayList(SiteChecker) = ArrayList(SiteChecker).init(allocator);
    defer siteCheckers.deinit();

    var terminate = std.atomic.Value(bool).init(false);

    for (config.sites) |site| {
        const currentSite: SiteChecker = try SiteChecker.init(
            allocator,
            site,
            &controller,
            &terminate,
        );
        try siteCheckers.append(currentSite);
    }

    const controller_thread = try std.Thread.spawn(.{}, Controller.resultHandler, .{&controller});

    var worker_threads = try ArrayList(std.Thread).initCapacity(allocator, siteCheckers.items.len);
    defer worker_threads.deinit();

    for (siteCheckers.items) |*checker| {
        const current_thread = try std.Thread.spawn(.{}, SiteChecker.poll, .{&checker.*});
        try worker_threads.append(current_thread);
    }

    defer {
        controller_thread.join();

        for (worker_threads.items) |thread| {
            thread.join();
        }
    }
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
