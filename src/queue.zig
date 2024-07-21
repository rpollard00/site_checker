const std = @import("std");
const Mutex = std.Thread.Mutex;

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        head: ?*Node,
        tail: ?*Node,
        mutex: Mutex,
        length: usize,

        const Node = struct {
            data: T,
            next: ?*Node,
        };

        pub fn init(alloc: std.mem.Allocator) Self {
            return Self{
                .allocator = alloc,
                .mutex = Mutex{},
                .head = null,
                .tail = null,
                .length = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();

            var current = self.head;

            while (current) |node| {
                current = node.next;
                self.allocator.destroy(node);
            }

            self.mutex.unlock();

            self.* = undefined;
        }

        pub fn enqueue(self: *Self, data: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const node = try self.allocator.create(Node);
            node.* = .{
                .data = data,
                .next = null,
            };

            self.length += 1;

            if (self.tail == null) {
                self.tail = node;
                self.head = self.tail;
                return;
            }

            self.tail.?.next = node;
            self.tail = node;
        }

        pub fn dequeue(self: *Self) !T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.head == null or self.head == undefined) {
                return error.DequeuedEmptyQueue;
            }

            const data = self.head.?.data;
            const old_head = self.head;

            defer self.allocator.destroy(old_head.?);

            if (self.head != self.tail) {
                self.head = self.head.?.next;
            } else {
                self.head = null;
                self.tail = null;
            }

            self.length -= 1;

            return data;
        }

        pub fn peek(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.head == null) return null;

            return self.head.?.data;
        }
    };
}

test "can make a queue" {
    var queue = Queue(u16).init(std.testing.allocator);
    defer queue.deinit();
}

test "can dequeue one node" {
    var queue = Queue(u16).init(std.testing.allocator);
    defer queue.deinit();

    const uhh1: u16 = 5;

    try queue.enqueue(uhh1);

    const val1 = try queue.dequeue();
    try std.testing.expect(val1 == 5);
}

test "can queue simple data" {
    var queue = Queue(u16).init(std.testing.allocator);
    defer queue.deinit();

    const uhh1: u16 = 5;
    const uhh2: u16 = 10;
    const uhh3: u16 = 3;

    try queue.enqueue(uhh1);
    try queue.enqueue(uhh2);
    try queue.enqueue(uhh3);

    const val1 = try queue.dequeue();
    try std.testing.expect(val1 == 5);

    const val2 = try queue.dequeue();
    try std.testing.expect(val2 == 10);

    const val3 = try queue.dequeue();
    try std.testing.expect(val3 == 3);
}

test "can empty and refill queue and empty again" {
    var queue = Queue(u16).init(std.testing.allocator);
    defer queue.deinit();

    try queue.enqueue(5);
    try queue.enqueue(7);

    const val1 = try queue.dequeue();
    const val2 = try queue.dequeue();

    try std.testing.expect(val1 == 5);
    try std.testing.expect(val2 == 7);

    try queue.enqueue(4);
    try queue.enqueue(8);

    const val3 = try queue.dequeue();
    const val4 = try queue.dequeue();

    try std.testing.expect(val3 == 4);
    try std.testing.expect(val4 == 8);
}

test "expect length to be 5 after adding 5 elements" {
    var queue = Queue(u16).init(std.testing.allocator);
    defer queue.deinit();

    try queue.enqueue(1);
    try queue.enqueue(2);
    try queue.enqueue(3);
    try queue.enqueue(4);
    try queue.enqueue(5);

    try std.testing.expect(queue.length == 5);
}

test "expect length to be 3 after adding 5 elements and removing 2" {
    var queue = Queue(u16).init(std.testing.allocator);
    defer queue.deinit();

    try queue.enqueue(1);
    try queue.enqueue(2);
    try queue.enqueue(3);
    try queue.enqueue(4);
    try queue.enqueue(5);

    _ = try queue.dequeue();
    _ = try queue.dequeue();

    try std.testing.expect(queue.length == 3);
}

test "can peek in the queue" {
    var queue = Queue(u16).init(std.testing.allocator);
    defer queue.deinit();

    try queue.enqueue(1);
    try queue.enqueue(2);
    try queue.enqueue(3);
    try queue.enqueue(4);
    try queue.enqueue(5);

    const peeked_val = try queue.peek();

    try std.testing.expect(peeked_val == 1);

    _ = try queue.dequeue();

    const peek_again = try queue.peek();

    try std.testing.expect(peek_again == 2);
}

test "multiple threads can access the queue" {
    const ThreadContext = struct {
        queue: *Queue(u32),
        start_value: u32,
        count: u32,
    };

    const thread_count = 4;
    const operations_per_thread = 1000;

    var queue = Queue(u32).init(std.testing.allocator);
    defer queue.deinit();

    var threads: [thread_count]std.Thread = undefined;
    var contexts: [thread_count]ThreadContext = undefined;

    const Runner = struct {
        fn run(context: *ThreadContext) void {
            var i: u32 = 0;
            while (i < context.count) : (i += 1) {
                const value: u32 = @intCast(context.start_value + i);
                context.queue.enqueue(value) catch unreachable;
            }

            i = 0;
            while (i < context.count) : (i += 1) {
                _ = context.queue.dequeue() catch unreachable;
            }
        }
    };

    for (&threads, 0..) |*thread, i| {
        contexts[i] = ThreadContext{
            .queue = &queue,
            .start_value = @intCast(i * operations_per_thread),
            .count = operations_per_thread,
        };

        thread.* = try std.Thread.spawn(.{}, Runner.run, .{&contexts[i]});
    }

    for (threads) |thread| {
        thread.join();
    }

    try std.testing.expectEqual(0, queue.length);
    try std.testing.expectError(error.DequeuedEmptyQueue, queue.dequeue());
}
