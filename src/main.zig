const std = @import("std");
const print = std.debug.print;

fn checkSiteList(allocator: std.mem.Allocator, sites: std.ArrayList([]const u8)) !void {
    for (sites.items) |site| {
        _ = checkSite(allocator, site) catch |err| switch (err) {
            error.UnknownHostName => {
                print("Unknown hostname {s}", .{site});
                return err;
            },
            else => return err,
        };
    }
}

// opens and closes a tcp socket to the given site_url
// returns the response time in ms
fn checkSite(allocator: std.mem.Allocator, site_url: []const u8) !u16 {
    print("Connecting to site: {s}\n", .{site_url});
    var stream = try std.net.tcpConnectToHost(allocator, site_url, 443);
    defer stream.close();

    return 69;
}

const NS_IN_MS = 1000000;
const WAIT_TIME_MS = 5000;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var siteList = std.ArrayList([]const u8).init(allocator);
    defer siteList.deinit();

    try siteList.append("tellmewhatyouwant.lol");
    try siteList.append("reesep.com");

    while (true) {
        print("Checking sites....\n", .{});
        try checkSiteList(allocator, siteList);
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
