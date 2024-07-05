const std = @import("std");
const print = std.debug.print;
const Timer = std.time.Timer;

const SiteChecker = struct {
    allocator: std.mem.Allocator,
    siteList: std.ArrayList([]const u8),
    timer: Timer,

    pub fn init(alloc: std.mem.Allocator) !SiteChecker {
        return SiteChecker{
            .allocator = alloc,
            .siteList = std.ArrayList([]const u8).init(alloc),
            .timer = try Timer.start(),
        };
    }

    pub fn deinit(self: *SiteChecker) void {
        self.siteList.deinit();
    }

    pub fn startCheckSiteList(self: *SiteChecker) !void {
        for (self.siteList.items) |site| {
            _ = self.checkSite(site) catch |err| switch (err) {
                error.UnknownHostName => {
                    print("Unknown hostname {s}", .{site});
                    return err;
                },
                else => return err,
            };
        }
    }

    fn checkSite(self: *SiteChecker, site_url: []const u8) !u64 {
        const start: u64 = self.timer.read();
        print("Connecting to site: {s}...", .{site_url});
        var stream = try std.net.tcpConnectToHost(self.allocator, site_url, 443);
        defer stream.close();

        const now: u64 = self.timer.lap();
        const duration_in_ms: u64 = (now - start) / NS_IN_MS;

        print("RTT: {d} ms\n", .{duration_in_ms});

        return duration_in_ms;
    }
};

// opens and closes a tcp socket to the given site_url
// returns the response time in ms

const NS_IN_MS = 1000000;
const WAIT_TIME_MS = 5000;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var siteChecker = try SiteChecker.init(allocator);
    defer siteChecker.deinit();

    try siteChecker.siteList.append("tellmewhatyouwant.lol");
    try siteChecker.siteList.append("reesep.com");

    while (true) {
        print("Checking sites....\n", .{});

        try siteChecker.startCheckSiteList();
        print("Waiting {d}ms for next check...\n", .{WAIT_TIME_MS});
        std.time.sleep(WAIT_TIME_MS * NS_IN_MS);
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
