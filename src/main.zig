const std = @import("std");
const NetworkError = @import("network_error.zig");
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
};

const SiteState = struct {
    is_failed: bool,
    current_failures: u16,
};

const Config = struct {
    sites: []Site,
    pollingIntervalMs: u64,
};

const AlertEvent = struct {
    // site: []const u8,
    // err: NetworkError.Recoverable,
    message: []const u8,
};

const AlertListener = union(enum) {
    discordListener: DiscordListener,

    pub fn invoke(self: AlertListener, event: AlertEvent) !void {
        switch (self) {
            inline else => |*listener| try listener.invoke(event),
        }
    }

    pub fn deinit(self: AlertListener) void {
        switch (self) {
            inline else => |*listener| listener.deinit(),
        }
    }
};

const DiscordListener = struct {
    allocator: std.mem.Allocator,
    webhook: []const u8,

    pub fn init(allocator: std.mem.Allocator) !DiscordListener {
        return DiscordListener{
            .allocator = allocator,
            .webhook = try std.process.getEnvVarOwned(allocator, "DISCORD_WEBHOOK"),
        };
    }

    pub fn deinit(self: *const DiscordListener) void {
        self.allocator.destroy(&self.webhook);
    }

    pub fn invoke(self: *const DiscordListener, event: AlertEvent) !void {
        print("Invoked the discord alerter\n", .{});
        var arena = std.heap.ArenaAllocator.init(heap.page_allocator);
        defer arena.deinit();

        const alert_message = .{ .content = event.message };

        var payload = ArrayList(u8).init(arena.allocator());
        try json.stringify(alert_message, .{}, payload.writer());

        var client = http.Client{ .allocator = arena.allocator() };

        const result = try http.Client.fetch(
            &client,
            .{
                .location = .{ .url = self.webhook },
                .headers = .{ .content_type = .{ .override = "application/json" } },
                .method = .POST,
                .payload = payload.items,
            },
        );

        if (@intFromEnum(result.status) > 400 and @intFromEnum(result.status) < 599) {
            print("Failed to send discord alert. Http status code {d}\n", .{result.status});
        }
    }
};

pub fn loadConfigFile(alloc: mem.Allocator, config_file: []const u8) !json.Parsed(Config) {
    const max_config_size = 2000;

    const file = try fs.cwd().openFile(config_file, .{});
    defer file.close();

    const contents = try file.reader().readAllAlloc(alloc, max_config_size);
    defer alloc.free(contents);

    return try json.parseFromSlice(Config, alloc, contents, .{ .allocate = .alloc_always });
}

const SiteChecker = struct {
    allocator: mem.Allocator,
    sites: ArrayList(Site),
    timer: Timer,
    alert_listeners: ArrayList(AlertListener),
    sites_state: std.StringHashMap(SiteState),

    pub fn init(alloc: mem.Allocator) !SiteChecker {
        return SiteChecker{
            .allocator = alloc,
            .sites = ArrayList(Site).init(alloc),
            .alert_listeners = ArrayList(AlertListener).init(alloc),
            .sites_state = std.StringHashMap(SiteState).init(alloc),
            .timer = try Timer.start(),
        };
    }

    pub fn addAlertListener(self: *SiteChecker, listener: anytype) !void {
        const listener_type = @TypeOf(listener);
        const listener_enum_fields = @typeInfo(AlertListener).Union.fields;

        inline for (listener_enum_fields) |field| {
            if (field.type == listener_type) {
                try self.alert_listeners.append(@unionInit(AlertListener, field.name, listener));
                return;
            }
        }

        @compileError("Unsupported listener type: " ++ @typeName(listener_type));
    }

    pub fn deinit(self: *SiteChecker) void {
        self.sites.deinit();
        for (self.alert_listeners.items) |listener| listener.deinit();
        self.alert_listeners.deinit();
    }

    pub fn pollSites(self: *SiteChecker) !void {
        for (self.sites.items) |site| {
            const siteState: *SiteState = self.sites_state.getPtr(site.name) orelse return error.NullPointerReference;

            const rtt = self.checkSite(site.name, site.port) catch |err| {
                if (NetworkError.errorClassifier(err)) |recoverable_error| {
                    siteState.*.current_failures += 1;
                    if (siteState.*.current_failures > site.threshold) {
                        try self.sendSiteAlert(site, recoverable_error);
                    }
                    break;
                } else {
                    return err;
                }
            };

            if (rtt != null) {
                siteState.*.current_failures = 0;
            }
        }
    }

    fn sendSiteAlert(self: *SiteChecker, site: Site, err: NetworkError.Recoverable) !void {
        const MAX_MESSAGE_LEN = 1024;
        var buf: [MAX_MESSAGE_LEN]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var alertMessage = try ArrayList(u8).initCapacity(fba.allocator(), MAX_MESSAGE_LEN);
        defer alertMessage.deinit();

        const writer = alertMessage.writer();
        writer.print("ALERT! {s}: {s}\n", .{ site.name, NetworkError.toString(err) }) catch |e| switch (e) {
            error.OutOfMemory => {
                try writer.print("Alert message exceeded buffer.\n", .{});
            },
            else => return e,
        };

        print("{s}", .{alertMessage.items});
        // invoke the alert listeners here
        for (self.alert_listeners.items) |listener| try listener.invoke(AlertEvent{ .message = alertMessage.items });
    }

    fn checkSite(self: *SiteChecker, site_addr: []const u8, site_port: u16) !?u64 {
        const start: u64 = self.timer.read();

        print("Polling {s}...", .{site_addr});
        errdefer print("\n", .{});

        var stream = try net.tcpConnectToHost(self.allocator, site_addr, site_port);

        defer stream.close();

        const now: u64 = self.timer.lap();
        const duration_in_ms: u64 = (now - start) / NS_IN_MS;

        print("Success [RTT {d}ms]\n", .{duration_in_ms});

        return duration_in_ms;
    }
};

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parsedConfig = try loadConfigFile(allocator, "config.json");
    defer parsedConfig.deinit();

    const config = parsedConfig.value;

    var siteChecker = try SiteChecker.init(allocator);
    defer siteChecker.deinit();

    const discordListener = try DiscordListener.init(allocator);
    try siteChecker.addAlertListener(discordListener);

    for (config.sites) |site| {
        try siteChecker.sites.append(site);
        try siteChecker.sites_state.put(site.name, SiteState{
            .current_failures = 0,
            .is_failed = false,
        });
    }

    print("Starting site checker with an interval of {d}ms\n", .{config.pollingIntervalMs});
    while (true) {
        try siteChecker.pollSites();
        std.time.sleep(config.pollingIntervalMs * NS_IN_MS);
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
