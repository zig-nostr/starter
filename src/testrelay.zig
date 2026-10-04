//! A relay for tests, and for nothing else: it listens on loopback, answers
//! the websocket upgrade, and then does what its mode says. It is real enough
//! to dial: the client side of every test that uses it is the same
//! `nostr.relay.dial` a user's run goes through, over a real socket.

const std = @import("std");
const nostr = @import("nostr");

const Io = std.Io;
const ws = nostr.websocket;

pub const Mode = enum {
    /// Answers a REQ with every event in `serving`, then EOSE.
    serve,
    /// Answers the upgrade and then never sends another byte.
    silent,
    /// Answers the upgrade, then closes the connection.
    hang_up,
};

/// The allocator a test hands to anything that dials.
///
/// Still leak-checked, but it captures no stack traces. On macOS capturing one
/// takes a lock that notices a pending cancel and swallows it, so a dial that
/// is cancelled while it allocates never finds out and never returns, and the
/// test hangs instead of failing. `std.testing.allocator` captures them.
pub const DialAllocator = std.heap.DebugAllocator(.{ .stack_trace_frames = 0 });

/// A loopback listener on a port the kernel picks.
pub fn listen(io: Io) !Io.net.Server {
    var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    return address.listen(io, .{ .reuse_address = true });
}

/// `ws://127.0.0.1:<port>`, written into `buf`.
pub fn url(buf: []u8, port: u16) ![]const u8 {
    return std.fmt.bufPrint(buf, "ws://127.0.0.1:{d}", .{port});
}

pub const Relay = struct {
    server: Io.net.Server,
    mode: Mode,
    /// Event JSON the `serve` mode sends in answer to a REQ.
    serving: []const []const u8,
    task: Io.Future(void),

    /// Starts serving in the background. `self` must not move until `stop`.
    pub fn start(self: *Relay, io: Io, mode: Mode, serving: []const []const u8) !void {
        self.* = .{ .server = try listen(io), .mode = mode, .serving = serving, .task = undefined };
        errdefer self.server.deinit(io);
        self.task = try io.concurrent(serve, .{ self, io });
    }

    pub fn stop(self: *Relay, io: Io) void {
        self.task.cancel(io);
        self.server.deinit(io);
    }

    pub fn port(self: *const Relay) u16 {
        return self.server.socket.address.ip4.port;
    }

    /// One connection, then done. A loop back to `accept` would be the one
    /// place a cancel could be lost: once a task has seen its cancel, a
    /// blocking call it makes afterwards can no longer be woken, so `stop`
    /// would wait on that `accept` forever.
    fn serve(self: *Relay, io: Io) void {
        const conn = self.server.accept(io) catch return;
        defer conn.close(io);
        self.handle(io, conn) catch {};
    }

    fn handle(self: *Relay, io: Io, conn: Io.net.Stream) !void {
        // Not `std.testing.allocator`, for the reason `DialAllocator` gives.
        const gpa = std.heap.page_allocator;
        var rbuf: [8192]u8 = undefined;
        var wbuf: [8192]u8 = undefined;
        var r = conn.reader(io, &rbuf);
        var w = conn.writer(io, &wbuf);

        // The upgrade request, up to its blank line.
        var head: std.ArrayList(u8) = .empty;
        defer head.deinit(gpa);
        while (std.mem.indexOf(u8, head.items, "\r\n\r\n") == null) {
            try r.interface.fillMore();
            const got = r.interface.buffered();
            try head.appendSlice(gpa, got);
            r.interface.toss(got.len);
        }
        const prefix = "Sec-WebSocket-Key: ";
        const key_at = (std.mem.indexOf(u8, head.items, prefix) orelse return error.NoKey) + prefix.len;
        const key_end = std.mem.indexOfPos(u8, head.items, key_at, "\r\n") orelse return error.NoKey;
        const accept_key = ws.acceptKey(head.items[key_at..key_end]);
        try w.interface.print("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{&accept_key});
        try w.interface.flush();

        switch (self.mode) {
            .hang_up => return,
            .silent => while (true) try io.sleep(.fromMilliseconds(1000), .awake),
            .serve => {},
        }

        // Frames from the client, until it closes.
        var frames: std.ArrayList(u8) = .empty;
        defer frames.deinit(gpa);
        while (true) {
            r.interface.fillMore() catch return;
            const available = r.interface.buffered();
            try frames.appendSlice(gpa, available);
            r.interface.toss(available.len);
            while (try ws.decodeFrame(frames.items)) |frame| {
                if (frame.opcode == .close) return;
                if (frame.opcode == .text) try self.answer(gpa, &w.interface, frame.payload);
                const used = frame.frame_len;
                std.mem.copyForwards(u8, frames.items, frames.items[used..]);
                frames.shrinkRetainingCapacity(frames.items.len - used);
            }
        }
    }

    fn answer(self: *Relay, gpa: std.mem.Allocator, w: *Io.Writer, payload: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, payload, .{});
        defer parsed.deinit();
        const items = parsed.value.array.items;
        if (!std.mem.eql(u8, items[0].string, "REQ")) return;
        const sub = items[1].string;
        for (self.serving) |event_json| {
            const frame = try std.fmt.allocPrint(gpa, "[\"EVENT\",\"{s}\",{s}]", .{ sub, event_json });
            defer gpa.free(frame);
            try sendText(w, frame);
        }
        const eose = try std.fmt.allocPrint(gpa, "[\"EOSE\",\"{s}\"]", .{sub});
        defer gpa.free(eose);
        try sendText(w, eose);
    }
};

/// One unmasked server text frame.
fn sendText(w: *Io.Writer, text: []const u8) !void {
    if (text.len < 126) {
        try w.writeAll(&.{ 0x81, @intCast(text.len) });
    } else if (text.len < 65536) {
        try w.writeAll(&.{ 0x81, 126, @intCast(text.len >> 8), @intCast(text.len & 0xff) });
    } else {
        try w.writeAll(&.{ 0x81, 127 });
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, &len, text.len, .big);
        try w.writeAll(&len);
    }
    try w.writeAll(text);
    try w.flush();
}
