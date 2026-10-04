//! THE SEAM between the plumbing and your app's interface.
//!
//! Everything the interface may ask of the relays, the store and the NIP-23
//! parser is in this file, and the interface imports nothing else from
//! `plumbing/`. Five questions:
//!
//!   - `articles`: what is saved, newest first
//!   - `article`: one saved article, whole
//!   - `refresh`: ask the relays again
//!   - `changes`: has anything arrived since I last looked
//!   - `progress`: how are the relays doing
//!
//! Nothing here draws, holds a screen's state or knows what a window is. If
//! your app needs another kind of event, add a question here and keep the
//! interface on this side of the line.
//!
//! None of these calls waits on the network. The relay threads write into the
//! store as events arrive; `articles` and `article` read what is there.

const std = @import("std");
const nostr = @import("nostr");
const nip23 = @import("nip23.zig");
const relays = @import("relays.zig");
const store_mod = @import("store.zig");

/// One article, as the interface reads it. See `nip23.Article` for the fields.
pub const Article = nip23.Article;

/// How the relays are doing: how many there are, how many are being asked now,
/// how many have sent everything they had, and how many could not be reached.
/// "Answered" counts relays that finished, not relays that are in the list.
pub const Progress = relays.Tally;

pub const Data = struct {
    store: *store_mod.Store,
    fetcher: *relays.Fetcher,

    pub fn init(store: *store_mod.Store, fetcher: *relays.Fetcher) Data {
        return .{ .store = store, .fetcher = fetcher };
    }

    /// Asks every relay that is not already being asked. Returns at once: the
    /// answers arrive on worker threads, and `changes` moves when they do.
    pub fn refresh(self: *Data) void {
        self.fetcher.start();
    }

    /// A number that changes whenever the relay workers have stored something
    /// or moved to a new state. Compare it with the value from your last look:
    /// when it differs, call `articles` and `progress` again.
    pub fn changes(self: *const Data) u32 {
        return self.fetcher.version.load(.acquire);
    }

    pub fn progress(self: *const Data) Progress {
        return self.fetcher.tally();
    }

    /// Up to `limit` saved articles that have something in them, newest first
    /// by the date they were published (not the date they were last edited).
    /// The result owns its memory: call `deinit`.
    pub fn articles(self: *Data, gpa: std.mem.Allocator, limit: u32) !Articles {
        var result = try self.store.query(gpa, .{ .kinds = &[_]u16{nip23.kind}, .limit = limit });
        errdefer result.deinit();

        const buffer = try gpa.alloc(Article, result.events.len);
        errdefer gpa.free(buffer);
        var count: usize = 0;
        for (result.events) |ev| {
            if (!nip23.worthListing(ev)) continue;
            buffer[count] = Article.from(ev);
            count += 1;
        }
        std.mem.sort(Article, buffer[0..count], {}, nip23.newerFirst);
        return .{ .items = buffer[0..count], .buffer = buffer, .result = result, .gpa = gpa };
    }

    /// The saved article with this event id, or null if it is not saved. The
    /// result owns its memory: call `deinit`.
    pub fn article(self: *Data, gpa: std.mem.Allocator, id: [32]u8) !?Opened {
        const stored = (try self.store.getEvent(gpa, id)) orelse return null;
        return .{ .stored = stored, .article = Article.from(stored.event) };
    }
};

/// A list of articles. The strings in each one point into memory this owns.
pub const Articles = struct {
    items: []const Article,
    buffer: []Article,
    result: nostr.store.QueryResult,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Articles) void {
        self.gpa.free(self.buffer);
        self.result.deinit();
    }
};

/// One article with the memory behind it.
pub const Opened = struct {
    stored: nostr.store.StoredEvent,
    article: Article,

    pub fn deinit(self: *Opened) void {
        self.stored.deinit();
    }
};

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const Fixture = @import("testkit.zig").Fixture;

fn dataFor(fx: *Fixture, fetcher: *relays.Fetcher) Data {
    return Data.init(&fx.store, fetcher);
}

test "articles come back newest published first, not newest edited first" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    // The older article was edited most recently, so it is newest by
    // created_at and not by when it was first published.
    _ = try fx.save(fx.alice, .{ .d = "old", .title = "Edited old essay", .created_at = 5_000_000_000, .published_at = "1000000000" });
    _ = try fx.save(fx.bob, .{ .d = "new", .title = "Fresh essay", .created_at = 1_700_000_000, .published_at = "1700000000" });

    var fetcher = relays.Fetcher.init(&fx.store, &.{}, nip23.wanted);
    var data = dataFor(&fx, &fetcher);
    var list = try data.articles(testing.allocator, 10);
    defer list.deinit();

    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("Fresh essay", list.items[0].title);
    try testing.expectEqualStrings("Edited old essay", list.items[1].title);
    try testing.expectEqual(@as(i64, 1_700_000_000), list.items[0].published);
}

test "an empty article is left out, and an edited one is listed once as its newest version" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    _ = try fx.save(fx.alice, .{ .d = "blank", .title = "Nothing in it", .content = "  " });
    _ = try fx.save(fx.alice, .{ .d = "real", .title = "Draft title", .created_at = 1_000 });
    _ = try fx.save(fx.alice, .{ .d = "real", .title = "Final title", .created_at = 2_000 });
    // A relay that is behind sends the draft again.
    _ = try fx.save(fx.alice, .{ .d = "real", .title = "Draft title", .created_at = 1_000 });

    var fetcher = relays.Fetcher.init(&fx.store, &.{}, nip23.wanted);
    var data = dataFor(&fx, &fetcher);
    var list = try data.articles(testing.allocator, 10);
    defer list.deinit();

    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqualStrings("Final title", list.items[0].title);
}

test "articles never returns more than the limit" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var buf: [16]u8 = undefined;
    for (0..8) |i| {
        const d = try std.fmt.bufPrint(&buf, "essay-{d}", .{i});
        _ = try fx.save(fx.alice, .{ .d = try fx.arena.allocator().dupe(u8, d), .created_at = 1_000 + @as(i64, @intCast(i)) });
    }

    var fetcher = relays.Fetcher.init(&fx.store, &.{}, nip23.wanted);
    var data = dataFor(&fx, &fetcher);
    var list = try data.articles(testing.allocator, 5);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 5), list.items.len);
}

test "an article is opened whole by its id, and an unknown id is null" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    _ = try fx.save(fx.alice, .{ .title = "Worth reading", .content = "First paragraph.\n\nSecond paragraph." });

    var fetcher = relays.Fetcher.init(&fx.store, &.{}, nip23.wanted);
    var data = dataFor(&fx, &fetcher);
    var list = try data.articles(testing.allocator, 10);
    defer list.deinit();

    var opened = (try data.article(testing.allocator, list.items[0].id)).?;
    defer opened.deinit();
    try testing.expectEqualStrings("Worth reading", opened.article.title);
    try testing.expectEqualStrings("First paragraph.\n\nSecond paragraph.", opened.article.content);

    try testing.expect((try data.article(testing.allocator, @splat(0xee))) == null);
}

test "changes moves when the workers do, and progress counts relays by what they did" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const urls = [_][]const u8{ "ws://a:1", "ws://b:1" };
    var fetcher = relays.Fetcher.init(&fx.store, &urls, nip23.wanted);
    var data = dataFor(&fx, &fetcher);

    const before = data.changes();
    fetcher.set(0, .done);
    try testing.expect(data.changes() != before);
    try testing.expectEqual(Progress{ .total = 2, .answered = 1 }, data.progress());
}
