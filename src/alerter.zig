const std = @import("std");
const NetworkError = @import("network_error.zig");

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
        std.debug.print("Invoked the discord alerter\n", .{});
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const alert_message = .{ .content = event.message };

        var payload = std.ArrayList(u8).init(arena.allocator());
        try std.json.stringify(alert_message, .{}, payload.writer());

        var client = std.http.Client{ .allocator = arena.allocator() };

        const result = try std.http.Client.fetch(
            &client,
            .{
                .location = .{ .url = self.webhook },
                .headers = .{ .content_type = .{ .override = "application/json" } },
                .method = .POST,
                .payload = payload.items,
            },
        );

        if (@intFromEnum(result.status) > 400 and @intFromEnum(result.status) < 599) {
            std.debug.print("Failed to send discord alert. Http status code {d}\n", .{result.status});
        }
    }
};
// dispatcher queue/loop
// result queue/loop -> send alerts, log events, output
//   -> this stuff should run on the alert listener thread then yea?
// thread per poller -> pull from dispatch queue, write to result queue

// you are moving the collected alertListeners to their own struct

// this is both building the alert and dispatching, i think we need to move building the alert to its own thing
// we need to pick results off of the result queue, they should contain the resultAction, site, and nullable errorMessage
pub const AlertListeners = struct {
    allocator: std.mem.Allocator,
    alert_listeners: std.ArrayList(AlertListener),

    pub fn init(allocator: std.mem.Allocator) AlertListeners {
        return AlertListeners{
            .allocator = allocator,
            .alert_listeners = std.ArrayList(AlertListener).init(allocator),
        };
    }

    pub fn deinit(self: *AlertListeners) void {
        for (self.alert_listeners.items) |listener| listener.deinit();
        self.alert_listeners.deinit();
    }

    pub fn addAlertListener(self: *AlertListeners, listener: anytype) !void {
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
    fn sendSiteAlert(self: *AlertListeners, site_name: []const u8, err: NetworkError.Recoverable) !void {
        const MAX_MESSAGE_LEN = 1024;
        var buf: [MAX_MESSAGE_LEN]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var alertMessage = try std.ArrayList(u8).initCapacity(fba.allocator(), MAX_MESSAGE_LEN);
        defer alertMessage.deinit();

        const writer = alertMessage.writer();
        writer.print("ALERT! {s}: {s}\n", .{ site_name, NetworkError.toString(err) }) catch |e| switch (e) {
            error.OutOfMemory => {
                try writer.print("Alert message exceeded buffer.\n", .{});
            },
            else => return e,
        };

        std.debug.print("{s}", .{alertMessage.items});
        // invoke the alert listeners here
        for (self.alert_listeners.items) |listener| try listener.invoke(AlertEvent{ .message = alertMessage.items });
    }
};
