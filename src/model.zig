//! The app's state and the one function that changes it.
//!
//! The Native SDK runs an Elm-style loop. The window shows whatever the view
//! (`app.native`) makes of the `Model`. A press or a timer becomes a `Msg`,
//! `update` changes the model, and the view is rebuilt from it. Nothing else
//! writes to the model, which is why a press can be tested by calling
//! `update` and looking at the result.
//!
//! The model never holds a relay or a socket. The worker threads in
//! `relays.zig` write into the store, and `poll` reads the store back when a
//! tick notices that they did.

const std = @import("std");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const articles = @import("articles.zig");
const relays = @import("relays.zig");
const store_mod = @import("store.zig");

pub const Effects = native_sdk.Effects(Msg);

/// How often the window looks at what the relay workers have stored.
pub const tick_ms = 500;
const tick_key: u64 = 1;

pub const Msg = union(enum) {
    /// The repeating timer. Nothing in the markup sends it.
    tick: native_sdk.EffectTimer,
    /// Ask the relays again.
    refresh,
    /// Open the article in row `index` of the list.
    open: usize,
    /// Back to the list.
    close,
    next_page,
    prev_page,
    /// A link inside an article was pressed.
    open_url: []const u8,

    pub const view_unbound = .{"tick"};
};

pub const Model = struct {
    // The list.
    rows: [articles.list_cap]articles.Row = @splat(.{}),
    row_count: usize = 0,

    // The article being read, if any. The event is held whole (it owns an
    // arena), and `reading_row` is the same article's heading.
    reading: ?nostr.store.StoredEvent = null,
    reading_row: articles.Row = .{},
    pages: articles.Pages = .{},
    page: usize = 0,

    // Set once in `main`, before the window opens. Both stay null in the tests
    // that do not need a database or a network.
    store: ?*store_mod.Store = null,
    fetcher: ?*relays.Fetcher = null,
    /// The fetcher's `version` when the list was last read from the store.
    seen_version: u32 = 0,

    // Everything above is state, and none of it is bound directly by the
    // markup: the view reads the functions below. `native check` would
    // otherwise warn that this state is unused.
    pub const view_unbound = .{
        "rows",         "row_count", "reading", "reading_row",
        "pages",        "page",      "store",   "fetcher",
        "seen_version",
    };

    // -- what the view reads ------------------------------------------------

    pub fn visible(model: *const Model) []const articles.Row {
        return model.rows[0..model.row_count];
    }

    pub fn isReading(model: *const Model) bool {
        return model.reading != null;
    }

    pub fn readTitle(model: *const Model) []const u8 {
        return model.reading_row.title();
    }

    pub fn readAuthor(model: *const Model) []const u8 {
        return model.reading_row.author();
    }

    pub fn readPublished(model: *const Model) i64 {
        return model.reading_row.published;
    }

    /// The part of the article on screen: one page of its markdown.
    pub fn pageText(model: *const Model) []const u8 {
        const event = model.reading orelse return "";
        return model.pages.slice(event.event.content, model.page);
    }

    pub fn pageNumber(model: *const Model) usize {
        return model.page + 1;
    }

    pub fn pageCount(model: *const Model) usize {
        return model.pages.count;
    }

    pub fn hasPrev(model: *const Model) bool {
        return model.page > 0;
    }

    pub fn hasNext(model: *const Model) bool {
        return model.page + 1 < model.pages.count;
    }

    pub fn hasPages(model: *const Model) bool {
        return model.pages.count > 1;
    }

    /// One line at the bottom of the window: what is saved, and how the
    /// relays are doing. "Answered" counts relays that sent their stored
    /// events, not relays that are merely in the list.
    pub fn status(model: *const Model, arena: std.mem.Allocator) []const u8 {
        const saved = model.row_count;
        const noun = if (saved == 1) "article" else "articles";
        const fetcher = model.fetcher orelse return std.fmt.allocPrint(arena, "{d} {s} saved", .{ saved, noun }) catch "";
        const tally = fetcher.tally();
        if (tally.working > 0) {
            return std.fmt.allocPrint(arena, "{d} {s} saved | asking relays, {d} of {d} answered", .{ saved, noun, tally.answered, tally.total }) catch "";
        }
        if (tally.failed > 0) {
            return std.fmt.allocPrint(arena, "{d} {s} saved | {d} of {d} relays answered, {d} unreachable", .{ saved, noun, tally.answered, tally.total, tally.failed }) catch "";
        }
        return std.fmt.allocPrint(arena, "{d} {s} saved | {d} of {d} relays answered", .{ saved, noun, tally.answered, tally.total }) catch "";
    }

    pub fn isFetching(model: *const Model) bool {
        const fetcher = model.fetcher orelse return false;
        return fetcher.tally().working > 0;
    }

    // -- changes the update function makes ----------------------------------

    /// Fills the list from the store: the newest articles, shown by the date
    /// they were first published.
    pub fn reload(model: *Model) void {
        const store = model.store orelse return;
        var result = store_mod.newest(store, std.heap.page_allocator, articles.list_cap) catch |err| {
            std.debug.print("starter: could not read the store: {s}\n", .{@errorName(err)});
            return;
        };
        defer result.deinit();

        var count: usize = 0;
        for (result.events) |ev| {
            if (!articles.worthListing(ev)) continue;
            model.rows[count] = articles.Row.from(ev);
            count += 1;
        }
        std.mem.sort(articles.Row, model.rows[0..count], {}, articles.newerFirst);
        for (model.rows[0..count], 0..) |*row, i| row.index = i;
        model.row_count = count;
    }

    /// Re-reads the list if a relay worker has stored something, or changed
    /// state, since the last look.
    fn poll(model: *Model) void {
        const fetcher = model.fetcher orelse return;
        const version = fetcher.version.load(.acquire);
        if (version == model.seen_version) return;
        model.seen_version = version;
        model.reload();
    }

    fn openArticle(model: *Model, index: usize) void {
        if (index >= model.row_count) return;
        const store = model.store orelse return;
        const row = model.rows[index];
        const stored = store.getEvent(std.heap.page_allocator, row.id) catch |err| {
            std.debug.print("starter: could not read the article: {s}\n", .{@errorName(err)});
            return;
        } orelse return;

        model.closeArticle();
        model.reading = stored;
        model.reading_row = row;
        model.pages = articles.Pages.split(stored.event.content);
        model.page = 0;
    }

    pub fn closeArticleForTest(model: *Model) void {
        model.closeArticle();
    }

    fn closeArticle(model: *Model) void {
        if (model.reading) |*stored| stored.deinit();
        model.reading = null;
        model.pages = .{};
        model.page = 0;
    }
};

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .tick => |timer| {
            if (timer.outcome != .fired) return;
            model.poll();
        },
        .refresh => if (model.fetcher) |fetcher| fetcher.start(),
        .open => |index| model.openArticle(index),
        .close => model.closeArticle(),
        .next_page => if (model.hasNext()) {
            model.page += 1;
        },
        .prev_page => if (model.hasPrev()) {
            model.page -= 1;
        },
        .open_url => |url| openExternally(fx, url),
    }
}

/// Runs once before the first frame. The list is read from disk right here, so
/// a returning reader sees their saved articles immediately, then the relays
/// are asked and the timer starts watching for what they bring.
pub fn boot(model: *Model, fx: *Effects) void {
    model.reload();
    if (model.fetcher) |fetcher| fetcher.start();
    fx.startTimer(.{
        .key = tick_key,
        .interval_ms = tick_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.tick),
    });
}

// -- links ------------------------------------------------------------------

/// An article's links are written by a stranger, so only plain web links are
/// opened: `http` or `https`, with no space or control byte anywhere. Anything
/// else (`file:`, `javascript:`, an app's own scheme) is dropped.
pub fn isSafeExternalUrl(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return false;
    if (url.len > link_buffer.len) return false;
    for (url) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return false;
    }
    return true;
}

/// The link text lives in the view's arena, which is gone by the time the host
/// acts on the request, so it is copied somewhere that stays.
var link_buffer: [1024]u8 = undefined;

fn openExternally(fx: *Effects, url: []const u8) void {
    if (!isSafeExternalUrl(url)) return;
    @memcpy(link_buffer[0..url.len], url);
    fx.hostSend("native-sdk.os.openUrl", link_buffer[0..url.len]);
}
