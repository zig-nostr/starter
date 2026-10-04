//! Asking relays for articles, off the window's thread.
//!
//! One worker thread per relay. Each dials, sends one subscription, stores
//! every verified event that comes back, and stops when the relay says it has
//! sent everything it had stored (EOSE). The window never waits on any of it:
//! it reads what the workers put in the store, and polls `Fetcher.version` to
//! learn that something changed.
//!
//! This is the smallest fetch that is still honest about the network. It has a
//! time limit on the connect and on the whole read, because a relay that accepts
//! a connection and then says nothing would otherwise hold its thread for the
//! life of the process.

const std = @import("std");
const nostr = @import("nostr");
const articles = @import("articles.zig");
const store_mod = @import("store.zig");

pub const Store = store_mod.Store;

/// Where to ask when nothing else is configured. Replace these, or set
/// `STARTER_RELAYS` to a comma-separated list, to ask somewhere else.
pub const default_urls = [_][]const u8{
    "wss://relay.damus.io",
    "wss://nos.lol",
    "wss://relay.primal.net",
};

/// The environment variable that overrides `default_urls`.
pub const env_name = "STARTER_RELAYS";

pub const max_relays = 8;

/// How long a relay gets to accept the connection and finish the websocket
/// handshake, and then to send everything it has.
pub const default_dial_ms: i64 = 6_000;
pub const default_read_ms: i64 = 20_000;

/// The subscription id. Only events that arrive under it are looked at.
const sub_id = "articles";

/// Where one relay's fetch stands. `done` means the relay sent its EOSE, which
/// is the only thing that counts as an answer: a relay we merely have in the
/// list has told us nothing.
pub const State = enum(u8) { idle, connecting, reading, done, failed };

pub const Tally = struct {
    total: usize = 0,
    working: usize = 0,
    answered: usize = 0,
    failed: usize = 0,
};

pub const Fetcher = struct {
    store: *store_mod.Store,
    urls: []const []const u8,
    states: [max_relays]std.atomic.Value(u8) = @splat(.init(@intFromEnum(State.idle))),
    /// Bumped whenever a worker stores something new or changes state. The
    /// window compares it with the value it last saw.
    version: std.atomic.Value(u32) = .init(0),
    dial_ms: i64 = default_dial_ms,
    read_ms: i64 = default_read_ms,

    /// `urls` must outlive the fetcher, and a fetcher must not move once
    /// `start` has been called: the workers hold a pointer to it.
    pub fn init(store: *store_mod.Store, urls: []const []const u8) Fetcher {
        return .{ .store = store, .urls = urls[0..@min(urls.len, max_relays)] };
    }

    /// Starts a worker for every relay that is not already being asked. Called
    /// from the window's thread only, which is why checking a state and then
    /// setting it needs no lock: workers only move a relay out of a working
    /// state, never into one.
    pub fn start(self: *Fetcher) void {
        for (self.urls, 0..) |_, i| {
            switch (self.state(i)) {
                .connecting, .reading => continue,
                .idle, .done, .failed => {},
            }
            self.set(i, .connecting);
            const thread = std.Thread.spawn(.{}, run, .{ self, i }) catch |err| {
                std.debug.print("starter: could not start a worker for {s}: {s}\n", .{ self.urls[i], @errorName(err) });
                self.set(i, .failed);
                continue;
            };
            thread.detach();
        }
    }

    pub fn state(self: *const Fetcher, i: usize) State {
        return @enumFromInt(self.states[i].load(.acquire));
    }

    pub fn tally(self: *const Fetcher) Tally {
        var t: Tally = .{ .total = self.urls.len };
        for (0..self.urls.len) |i| switch (self.state(i)) {
            .connecting, .reading => t.working += 1,
            .done => t.answered += 1,
            .failed => t.failed += 1,
            .idle => {},
        };
        return t;
    }

    /// Workers call this as a relay moves along. Public so the tests can set
    /// up a fetcher mid-flight without a network.
    pub fn set(self: *Fetcher, i: usize, next: State) void {
        self.states[i].store(@intFromEnum(next), .release);
        self.bump();
    }

    pub fn bump(self: *Fetcher) void {
        _ = self.version.fetchAdd(1, .release);
    }
};

/// A worker thread's whole life: ask one relay, then record how it went.
fn run(fetcher: *Fetcher, i: usize) void {
    fetchOne(fetcher, i) catch |err| {
        std.debug.print("starter: {s}: {s}\n", .{ fetcher.urls[i], @errorName(err) });
        fetcher.set(i, .failed);
        return;
    };
    fetcher.set(i, .done);
}

fn fetchOne(fetcher: *Fetcher, i: usize) !void {
    // Each worker has its own `Io`, and uses the page allocator: a dial that
    // gets cancelled must not allocate through a debug allocator (see `dialWithin`).
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A signer owns a libsecp256k1 context. One per thread.
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const relay = try dialWithin(gpa, io, fetcher.urls[i], fetcher.dial_ms);
    defer relay.deinit();
    fetcher.set(i, .reading);

    try relay.subscribe(sub_id, &.{articles.wanted});

    const give_up_at = std.Io.Timestamp.now(io, .awake).toMilliseconds() + fetcher.read_ms;
    while (true) {
        const left = give_up_at - std.Io.Timestamp.now(io, .awake).toMilliseconds();
        if (left <= 0) return error.ReadTimedOut;

        // Wake at least once a second, so the time limit above is checked even
        // when the relay says nothing. A timeout consumes nothing.
        const wait: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(@min(left, 1_000)), .clock = .awake } };
        var msg = (relay.receiveTimeout(wait) catch |err| switch (err) {
            error.Timeout => continue,
            else => |e| return e,
        }) orelse return error.ConnectionClosed;
        defer msg.deinit();

        switch (msg.value) {
            .event => |e| {
                if (!std.mem.eql(u8, e.subscription_id, sub_id)) continue;
                // `accept` verifies the signature, so a bad event is a value
                // (`.invalid`), not an error: dropped and the loop goes on.
                const result = store_mod.accept(fetcher.store, gpa, signer, e.event) catch |err| {
                    std.debug.print("starter: could not store an event: {s}\n", .{@errorName(err)});
                    continue;
                };
                switch (result) {
                    .added, .replaced => fetcher.bump(),
                    .duplicate, .stale, .invalid, .ephemeral, .deleted => {},
                }
            },
            .eose => |eose| if (std.mem.eql(u8, eose.subscription_id, sub_id)) {
                // Everything the relay had is in. Close the subscription
                // politely; the connection closes when this function returns.
                relay.unsubscribe(sub_id) catch {};
                return;
            },
            .closed => |closed| if (std.mem.eql(u8, closed.subscription_id, sub_id)) {
                std.debug.print("starter: {s} closed the subscription: {s}\n", .{ fetcher.urls[i], closed.message });
                return error.SubscriptionClosed;
            },
            .ok, .notice, .auth => {},
        }
    }
}

// -- dialing under a time limit -----------------------------------------------

const DialResult = @typeInfo(@TypeOf(nostr.relay.dial)).@"fn".return_type.?;

fn dialOnce(gpa: std.mem.Allocator, io: std.Io, url: []const u8) DialResult {
    return nostr.relay.dial(gpa, io, url);
}

/// `nostr.relay.dial` has no time limit of its own. This runs it beside a timer
/// and cancels it if the timer wins. A cancelled dial stops where it is and
/// frees what it allocated.
///
/// Three things that look optional are not. It must be `concurrent`, not
/// `async`, because past its limit `async` runs the task inline and an inline
/// dial is the unbounded wait. The `Select` needs room for both tasks, or
/// `cancel` deadlocks. And the allocator must not be the testing allocator,
/// whose stack capture swallows the cancel on macOS.
fn dialWithin(gpa: std.mem.Allocator, io: std.Io, url: []const u8, timeout_ms: i64) !*nostr.relay.Relay {
    const Arrival = union(enum) {
        dial: DialResult,
        timer: std.Io.Cancelable!void,
    };
    var buffer: [2]Arrival = undefined;
    var select = std.Io.Select(Arrival).init(io, &buffer);

    try select.concurrent(.dial, dialOnce, .{ gpa, io, url });
    // If the timer cannot start the dial is only as bounded as it was before.
    select.concurrent(.timer, std.Io.sleep, .{ io, .fromMilliseconds(timeout_ms), .awake }) catch {};

    var connected: ?*nostr.relay.Relay = null;
    var timed_out = false;
    var failure: anyerror = error.DialFailed;
    var arrival: ?Arrival = select.await() catch |err| blk: {
        failure = err;
        break :blk null;
    };
    // Whatever is still running is cancelled. A dial that finished in the same
    // instant as the timer is kept rather than thrown away.
    while (true) {
        if (arrival) |a| switch (a) {
            .dial => |result| if (result) |relay| {
                connected = relay;
            } else |err| {
                failure = err;
            },
            // A timer that ran to the end means the dial did not finish in
            // time. One that was cancelled means the dial finished first.
            .timer => |result| if (result) |_| {
                timed_out = true;
            } else |_| {},
        };
        arrival = select.cancel() orelse break;
    }
    if (connected) |relay| return relay;
    // The dial a timeout cancelled reports whatever error the cancel caused,
    // which says nothing useful.
    return if (timed_out) error.DialTimedOut else failure;
}

// -- the relay list ---------------------------------------------------------

/// Reads a relay list written as `wss://a, wss://b` (commas or whitespace).
/// Anything that is not a `ws://` or `wss://` URL is skipped, and so is a
/// repeat. The slices point into `text`, so it must outlive the result.
pub fn parseList(text: []const u8, out: *[max_relays][]const u8) []const []const u8 {
    var n: usize = 0;
    var parts = std.mem.tokenizeAny(u8, text, ", \t\r\n");
    while (parts.next()) |part| {
        if (n == max_relays) break;
        _ = nostr.relay.parseUrl(part) catch continue;
        const seen = for (out[0..n]) |url| {
            if (std.mem.eql(u8, url, part)) break true;
        } else false;
        if (seen) continue;
        out[n] = part;
        n += 1;
    }
    return out[0..n];
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "a relay list is read from commas and spaces, keeping only websocket URLs" {
    var out: [max_relays][]const u8 = undefined;
    const urls = parseList("wss://a.example, ws://127.0.0.1:7777\nhttps://not-a-relay.example  wss://a.example nonsense", &out);
    try testing.expectEqual(@as(usize, 2), urls.len);
    try testing.expectEqualStrings("wss://a.example", urls[0]);
    try testing.expectEqualStrings("ws://127.0.0.1:7777", urls[1]);
}

test "a relay list is capped" {
    var out: [max_relays][]const u8 = undefined;
    const urls = parseList("ws://a:1 ws://b:1 ws://c:1 ws://d:1 ws://e:1 ws://f:1 ws://g:1 ws://h:1 ws://i:1 ws://j:1", &out);
    try testing.expectEqual(@as(usize, max_relays), urls.len);
}

test "an empty list is empty" {
    var out: [max_relays][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), parseList("  ,, ", &out).len);
}

test "the defaults are all valid relay URLs" {
    for (default_urls) |url| _ = try nostr.relay.parseUrl(url);
}

test "a fetcher counts relays by what they did, not by being listed" {
    var store: store_mod.Store = undefined;
    const urls = [_][]const u8{ "ws://a:1", "ws://b:1", "ws://c:1", "ws://d:1" };
    var fetcher = Fetcher.init(&store, &urls);

    try testing.expectEqual(Tally{ .total = 4 }, fetcher.tally());

    fetcher.set(0, .reading);
    fetcher.set(1, .done);
    fetcher.set(2, .failed);
    try testing.expectEqual(Tally{ .total = 4, .working = 1, .answered = 1, .failed = 1 }, fetcher.tally());
}

test "every state change is visible in the version" {
    var store: store_mod.Store = undefined;
    const urls = [_][]const u8{"ws://a:1"};
    var fetcher = Fetcher.init(&store, &urls);
    const before = fetcher.version.load(.acquire);
    fetcher.set(0, .done);
    try testing.expect(fetcher.version.load(.acquire) != before);
}

const testrelay = @import("testrelay.zig");
const Fixture = @import("testkit.zig").Fixture;

/// Runs a relay worker to completion on this thread, against `url`.
fn fetchFrom(fx: *Fixture, url: []const u8, dial_ms: i64, read_ms: i64) !Fetcher {
    var fetcher = Fetcher.init(&fx.store, @as(*const [1][]const u8, &url));
    fetcher.dial_ms = dial_ms;
    fetcher.read_ms = read_ms;
    run(&fetcher, 0);
    return fetcher;
}

test "a relay's articles are stored, and a forged one and an off-topic one are not" {
    const io = testing.io;
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    const good = try fx.make(fx.alice, .{ .d = "good", .title = "From the relay" });
    var forged = try fx.make(fx.alice, .{ .d = "forged", .title = "Forged" });
    forged.sig[0] ^= 0xff;
    const off_topic = try fx.make(fx.alice, .{ .d = "bread", .title = "Bread", .topic = "sourdough" });

    var served: [3][]u8 = undefined;
    for ([_]nostr.event.Event{ good, forged, off_topic }, 0..) |ev, i| served[i] = try nostr.event.toJson(testing.allocator, ev);
    defer for (served) |json| testing.allocator.free(json);

    var relay: testrelay.Relay = undefined;
    try relay.start(io, .serve, &.{ served[0], served[1], served[2] });
    defer relay.stop(io);
    var url_buf: [40]u8 = undefined;
    const url = try testrelay.url(&url_buf, relay.port());

    const fetcher = try fetchFrom(&fx, url, 5_000, 5_000);
    try testing.expectEqual(State.done, fetcher.state(0));
    try testing.expectEqual(@as(usize, 1), try fx.store.eventCount());
    try testing.expect(try fx.store.hasEvent(good.id));
    // Three changes the window should hear about: the relay started to be
    // read, one article was stored, and the relay finished. The two that were
    // refused are not changes.
    try testing.expectEqual(@as(u32, 3), fetcher.version.load(.acquire));
}

test "a worker started by the fetcher finishes, and the version says so" {
    const io = testing.io;
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    const article = try fx.make(fx.alice, .{ .title = "Fetched" });
    const json = try nostr.event.toJson(testing.allocator, article);
    defer testing.allocator.free(json);

    var relay: testrelay.Relay = undefined;
    try relay.start(io, .serve, &.{json});
    defer relay.stop(io);
    var url_buf: [40]u8 = undefined;
    const urls = [_][]const u8{try testrelay.url(&url_buf, relay.port())};

    var fetcher = Fetcher.init(&fx.store, &urls);
    const before = fetcher.version.load(.acquire);
    fetcher.start();
    // A thread does the work, so wait for it, with a limit.
    var waited: usize = 0;
    while (fetcher.tally().answered == 0 and waited < 500) : (waited += 1) try io.sleep(.fromMilliseconds(10), .awake);

    try testing.expectEqual(State.done, fetcher.state(0));
    try testing.expect(fetcher.version.load(.acquire) != before);
    try testing.expectEqual(@as(usize, 1), try fx.store.eventCount());
}

test "a relay that is already being asked is not asked again" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const urls = [_][]const u8{"ws://127.0.0.1:1"};
    var fetcher = Fetcher.init(&fx.store, &urls);

    fetcher.set(0, .reading);
    const before = fetcher.version.load(.acquire);
    fetcher.start();
    try testing.expectEqual(State.reading, fetcher.state(0));
    try testing.expectEqual(before, fetcher.version.load(.acquire));
}

test "a relay that goes silent after the upgrade is given up on at the read time limit" {
    const io = testing.io;
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    var relay: testrelay.Relay = undefined;
    try relay.start(io, .silent, &.{});
    defer relay.stop(io);
    var url_buf: [40]u8 = undefined;
    const url = try testrelay.url(&url_buf, relay.port());

    const started = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    const fetcher = try fetchFrom(&fx, url, 5_000, 600);
    const took = std.Io.Timestamp.now(io, .awake).toMilliseconds() - started;
    try testing.expectEqual(State.failed, fetcher.state(0));
    try testing.expect(took >= 500 and took < 4_000);
}

test "a relay that hangs up before sending its stored events is a failure, not an answer" {
    const io = testing.io;
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    var relay: testrelay.Relay = undefined;
    try relay.start(io, .hang_up, &.{});
    defer relay.stop(io);
    var url_buf: [40]u8 = undefined;
    const url = try testrelay.url(&url_buf, relay.port());

    const fetcher = try fetchFrom(&fx, url, 5_000, 5_000);
    try testing.expectEqual(State.failed, fetcher.state(0));
}

test "a relay that never answers the upgrade is given up on at the dial time limit" {
    const io = testing.io;
    // Listening and never accepting: the kernel completes the TCP handshake
    // from its backlog, so the dial sends its upgrade and waits for an answer
    // that never comes.
    var silent = try testrelay.listen(io);
    defer silent.deinit(io);
    var url_buf: [40]u8 = undefined;
    const url = try testrelay.url(&url_buf, silent.socket.address.ip4.port);

    const started = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    try testing.expectError(error.DialTimedOut, dialWithin(std.heap.page_allocator, io, url, 300));
    const took = std.Io.Timestamp.now(io, .awake).toMilliseconds() - started;
    try testing.expect(took < 3_000);
}

test "a port nobody listens on fails at once" {
    const io = testing.io;
    // Bound and closed again, so nothing is listening there.
    var closed = try testrelay.listen(io);
    const port = closed.socket.address.ip4.port;
    closed.deinit(io);
    var url_buf: [40]u8 = undefined;
    const url = try testrelay.url(&url_buf, port);

    const started = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    if (dialWithin(std.heap.page_allocator, io, url, 5_000)) |relay| {
        relay.deinit();
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expect(err != error.DialTimedOut);
    }
    try testing.expect(std.Io.Timestamp.now(io, .awake).toMilliseconds() - started < 3_000);
}
