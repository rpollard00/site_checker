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
};

const Config = struct {
    sites: []Site,
    pollingIntervalMs: u64,
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
    discordWebhook: []const u8,

    pub fn init(alloc: mem.Allocator) !SiteChecker {
        const webhook = try std.process.getEnvVarOwned(alloc, "DISCORD_WEBHOOK");
        print("Webhook is {s}\n", .{webhook});

        return SiteChecker{
            .allocator = alloc,
            .sites = ArrayList(Site).init(alloc),
            .timer = try Timer.start(),
            .discordWebhook = webhook,
        };
    }

    pub fn deinit(self: *SiteChecker) void {
        self.sites.deinit();
    }

    pub fn pollSites(self: *SiteChecker) !void {
        for (self.sites.items) |site| {
            _ = self.checkSite(site.name, site.port) catch |err| {
                if (NetworkError.errorClassifier(err)) |recoverable_error| {
                    try self.handleSiteError(site.name, recoverable_error);
                } else {
                    return err;
                }
            };
        }
    }

    fn handleSiteError(self: *SiteChecker, site: []const u8, err: NetworkError.Recoverable) !void {
        const MAX_MESSAGE_LEN = 1024;
        var buf: [MAX_MESSAGE_LEN]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var discordMessage = try ArrayList(u8).initCapacity(fba.allocator(), MAX_MESSAGE_LEN);
        defer discordMessage.deinit();

        const writer = discordMessage.writer();
        writer.print("ALERT! {s}: {s}\n", .{ site, NetworkError.toString(err) }) catch |e| switch (e) {
            error.OutOfMemory => {
                try writer.print("Alert message exceeded buffer.\n", .{});
            },
            else => return e,
        };

        print("{s}", .{discordMessage.items});
        try sendDiscordAlert(self.discordWebhook, discordMessage.items);
    }

    fn checkSite(self: *SiteChecker, site_addr: []const u8, site_port: u16) !u64 {
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

pub fn sendDiscordAlert(url: []const u8, message: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();

    const discordMessage = .{ .content = message };

    var payload = ArrayList(u8).init(arena.allocator());
    try json.stringify(discordMessage, .{}, payload.writer());

    var client = http.Client{ .allocator = arena.allocator() };

    _ = try http.Client.fetch(
        &client,
        .{
            .location = .{ .url = url },
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .method = .POST,
            .payload = payload.items,
        },
    );
}

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parsedConfig = try loadConfigFile(allocator, "config.json");
    defer parsedConfig.deinit();

    const config = parsedConfig.value;

    var siteChecker = try SiteChecker.init(allocator);
    defer siteChecker.deinit();

    for (config.sites) |site| try siteChecker.sites.append(site);

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
