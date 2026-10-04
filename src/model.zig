//! YOUR APP'S INTERFACE: REPLACE IT.
//!
//! The state of this example's two screens (a list and a reading view) and the
//! one function that changes it. It is here to show how an interface reads the
//! plumbing, through `plumbing/data.zig` and nothing else. Design your own
//! screens from scratch: change the model, the messages and `app.native`
//! together, and keep the calls to `Data` as they are.
//!
//! The Native SDK runs an Elm-style loop. The window shows whatever the view
//! (`app.native`) makes of the `Model`. A press or a timer becomes a `Msg`,
//! `update` changes the model, and the view is rebuilt from it. Nothing else
//! writes to the model, which is why a press can be tested by calling
//! `update` and looking at the result.
//!
//! The model never holds a relay or a socket. The worker threads in
//! `plumbing/relays.zig` write into the store, and `poll` reads it back
//! (through `Data`) when a tick notices that they did.

const std = @import("std");
const native_sdk = @import("native_sdk");
const data_mod = @import("plumbing/data.zig");
const display = @import("display.zig");

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
    rows: [display.list_cap]display.Row = @splat(.{}),
    row_count: usize = 0,

    // The article being read, if any. It is held whole (it owns its memory),
    // and `reading_row` is the same article's heading.
    reading: ?data_mod.Opened = null,
    reading_row: display.Row = .{},
    pages: display.Pages = .{},
    page: usize = 0,

    // The seam to the plumbing. Set once in `main`, before the window opens,
    // and null in the tests that need neither a database nor a network.
    data: ?*data_mod.Data = null,
    /// `Data.changes` when the list was last read.
    seen_changes: u32 = 0,

    // Everything above is state, and none of it is bound directly by the
    // markup: the view reads the functions below. `native check` would
    // otherwise warn that this state is unused.
    pub const view_unbound = .{
        "rows",  "row_count", "reading", "reading_row",
        "pages", "page",      "data",    "seen_changes",
    };

    // -- what the view reads ------------------------------------------------

    pub fn visible(model: *const Model) []const display.Row {
        return model.rows[0..model.row_count];
    }

    pub fn isReading(model: *const Model) bool {
        return model.reading != null;
    }

    /// The whole title, from the article itself. The row's copy is cut to
    /// fit a line of the list, and the reader has room to wrap.
    pub fn readTitle(model: *const Model) []const u8 {
        const opened = model.reading orelse return "";
        return if (opened.article.title.len > 0) opened.article.title else model.reading_row.title();
    }

    pub fn readAuthor(model: *const Model) []const u8 {
        return model.reading_row.author();
    }

    pub fn readPublished(model: *const Model) i64 {
        return model.reading_row.published;
    }

    /// The part of the article on screen: one page of its markdown.
    pub fn pageText(model: *const Model) []const u8 {
        const opened = model.reading orelse return "";
        return model.pages.slice(opened.article.content, model.page);
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

    /// One line at the bottom of the window: how many articles the list
    /// holds, and how the relays are doing. The count is the list's, which
    /// stops at `display.list_cap`, not the database's, which can hold more.
    /// "Answered" counts relays that sent their stored events, not relays
    /// that are merely in the list.
    pub fn status(model: *const Model, arena: std.mem.Allocator) []const u8 {
        const listed = model.row_count;
        const noun = if (listed == 1) "article" else "articles";
        const only_listed = std.fmt.allocPrint(arena, "{d} {s} listed", .{ listed, noun }) catch "";
        const data = model.data orelse return only_listed;
        const tally = data.progress();
        // No relays to ask, so there is nothing to report about them.
        if (tally.total == 0) return only_listed;
        if (tally.working > 0) {
            return std.fmt.allocPrint(arena, "{d} {s} listed | asking relays, {d} of {d} answered", .{ listed, noun, tally.answered, tally.total }) catch "";
        }
        if (tally.failed > 0) {
            return std.fmt.allocPrint(arena, "{d} {s} listed | {d} of {d} relays answered, {d} unreachable", .{ listed, noun, tally.answered, tally.total, tally.failed }) catch "";
        }
        return std.fmt.allocPrint(arena, "{d} {s} listed | {d} of {d} relays answered", .{ listed, noun, tally.answered, tally.total }) catch "";
    }

    pub fn isFetching(model: *const Model) bool {
        const data = model.data orelse return false;
        return data.progress().working > 0;
    }

    // -- changes the update function makes ----------------------------------

    /// Fills the list from the saved articles, newest published first (that
    /// order is `Data.articles`' to give).
    pub fn reload(model: *Model) void {
        const data = model.data orelse return;
        var list = data.articles(std.heap.page_allocator, display.list_cap) catch |err| {
            std.debug.print("starter: could not read the saved articles: {s}\n", .{@errorName(err)});
            return;
        };
        defer list.deinit();

        for (list.items, 0..) |article, i| {
            model.rows[i] = display.Row.from(article);
            model.rows[i].index = i;
        }
        model.row_count = list.items.len;
    }

    /// Re-reads the list if a relay worker has stored something, or changed
    /// state, since the last look.
    fn poll(model: *Model) void {
        const data = model.data orelse return;
        const changes = data.changes();
        if (changes == model.seen_changes) return;
        model.seen_changes = changes;
        model.reload();
    }

    fn openArticle(model: *Model, index: usize) void {
        if (index >= model.row_count) return;
        const data = model.data orelse return;
        const row = model.rows[index];
        const opened = data.article(std.heap.page_allocator, row.id) catch |err| {
            std.debug.print("starter: could not read the article: {s}\n", .{@errorName(err)});
            return;
        } orelse return;

        model.closeArticle();
        model.reading = opened;
        model.reading_row = row;
        model.pages = display.Pages.split(opened.article.content);
        model.page = 0;
    }

    pub fn closeArticleForTest(model: *Model) void {
        model.closeArticle();
    }

    fn closeArticle(model: *Model) void {
        if (model.reading) |*opened| opened.deinit();
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
        .refresh => if (model.data) |data| data.refresh(),
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
    if (model.data) |data| data.refresh();
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
