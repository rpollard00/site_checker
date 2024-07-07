const std = @import("std");
const print = std.debug.print;
const json = std.json;
const Timer = std.time.Timer;
const TcpConnectToHostError = std.net.TcpConnectToHostError;

const Site = struct {
    name: []const u8,
    port: u16 = 443, // use 443 as a default
};

const Config = struct {
    sites: []Site,
    pollingIntervalMs: u64,
};

pub fn loadConfigFile(alloc: std.mem.Allocator, config_file: []const u8) !std.json.Parsed(Config) {
    const max_config_size = 2000;

    const file = try std.fs.cwd().openFile(config_file, .{});
    defer file.close();

    const contents = try file.reader().readAllAlloc(alloc, max_config_size);
    defer alloc.free(contents);

    return try std.json.parseFromSlice(Config, alloc, contents, .{ .allocate = .alloc_always });
}

const SiteChecker = struct {
    allocator: std.mem.Allocator,
    sites: std.ArrayList(Site),
    timer: Timer,

    pub fn init(alloc: std.mem.Allocator) !SiteChecker {
        return SiteChecker{
            .allocator = alloc,
            .sites = std.ArrayList(Site).init(alloc),
            .timer = try Timer.start(),
        };
    }

    pub fn deinit(self: *SiteChecker) void {
        self.sites.deinit();
    }

    pub fn pollSites(self: *SiteChecker) !void {
        for (self.sites.items) |site| {
            _ = self.checkSite(site.name, site.port) catch |err| {
                if (recoverableNetworkErrorClassifier(err)) |recoverable_error| {
                    try handleRecoverableNetworkError(site.name, recoverable_error);
                } else {
                    return err;
                }
            };
        }
    }

    fn handleRecoverableNetworkError(site: []const u8, err: RecoverableNetworkError) !void {
        switch (err) {
            RecoverableNetworkError.UnknownHostName => {
                print("Unknown hostname {s}\n", .{site});
            },
            RecoverableNetworkError.ConnectionRefused => {
                print("Connection refused by {s}\n", .{site});
            },
            RecoverableNetworkError.ConnectionTimedOut => {
                print("Connection to {s} timed out\n", .{site});
            },
            RecoverableNetworkError.ConnectionResetByPeer => {
                print("Connection to {s} reset by peer\n", .{site});
            },
            RecoverableNetworkError.NameServerFailure, RecoverableNetworkError.TemporaryNameServerFailure => {
                print("Name Server Failure when resolving {s}\n", .{site});
            },
            RecoverableNetworkError.NetworkUnreachable => {
                print("Received Network Unreachable error when connecting to {s}\n", .{site});
            },
        }
    }

    fn checkSite(self: *SiteChecker, site_url: []const u8, site_port: u16) !u64 {
        const start: u64 = self.timer.read();
        print("Polling {s}...", .{site_url});
        errdefer print("\n", .{});

        var stream = try std.net.tcpConnectToHost(self.allocator, site_url, site_port);

        defer stream.close();

        const now: u64 = self.timer.lap();
        const duration_in_ms: u64 = (now - start) / NS_IN_MS;

        print("Success [RTT {d}ms]\n", .{duration_in_ms});

        return duration_in_ms;
    }
};

const RecoverableNetworkError = error{
    ConnectionRefused,
    NetworkUnreachable,
    ConnectionTimedOut,
    ConnectionResetByPeer,

    UnknownHostName,
    // check that these are what I think they are
    TemporaryNameServerFailure,
    NameServerFailure,
};

pub fn recoverableNetworkErrorClassifier(err: anyerror) ?RecoverableNetworkError {
    return switch (err) {
        error.ConnectionRefused => RecoverableNetworkError.ConnectionRefused,
        error.NetworkUnreachable => RecoverableNetworkError.NetworkUnreachable,
        error.ConnectionTimedOut => RecoverableNetworkError.ConnectionTimedOut,
        error.ConnectionResetByPeer => RecoverableNetworkError.ConnectionResetByPeer,
        error.UnknownHostName => RecoverableNetworkError.UnknownHostName,
        error.TemporaryNameServerFailure => RecoverableNetworkError.TemporaryNameServerFailure,
        error.NameServerFailure => RecoverableNetworkError.NameServerFailure,
        else => null,
    };
}

// opens and closes a tcp socket to the given site_url
// returns the response time in ms

const NS_IN_MS = 1000000;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
