//! YOUR APP'S INTERFACE: REPLACE IT.
//!
//! How this example's interface holds what it shows. A row of the list is
//! copied out of an article into fixed-size text, so the list can be drawn
//! without keeping the store open, and a long article is cut into pages
//! because the toolkit builds markdown into widgets and one view holds only so
//! many. Both are choices of this particular interface. A different interface
//! (a grid of cards, a single column that never leaves the article, a
//! timeline) holds different things, and can drop this file.
//!
//! It reads articles through `plumbing/data.zig` and nothing else of the
//! plumbing.

const std = @import("std");
const nostr = @import("nostr");
const data = @import("plumbing/data.zig");

const whitespace = " \t\r\n";

/// The most rows the list holds.
pub const list_cap = 50;

// -- a short npub -----------------------------------------------------------

/// "npub1abcdefg…uvwxyz": enough to tell authors apart without filling a row.
/// `out` is the room for it; the slice returned lives in `out`.
pub fn shortNpub(pubkey: [32]u8, out: *[short_npub_len]u8) []const u8 {
    var scratch: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const npub = nostr.nip19.encodeNpub(fba.allocator(), pubkey) catch return "npub";
    const head = 12;
    const tail = 6;
    const ellipsis = "\u{2026}";
    @memcpy(out[0..head], npub[0..head]);
    @memcpy(out[head..][0..ellipsis.len], ellipsis);
    @memcpy(out[head + ellipsis.len ..][0..tail], npub[npub.len - tail ..]);
    return out[0 .. head + ellipsis.len + tail];
}

pub const short_npub_len = 12 + 3 + 6;

// -- text that fits a fixed place -------------------------------------------

/// A bounded copy of some text from an event. A row is copied out of the
/// store so the list can be drawn without holding the store open, and the copy
/// has to fit the row: it is cut at a character boundary, and anything that
/// would break a single line (a newline, a tab, other control bytes) becomes a
/// space. Titles are written by strangers.
pub fn Text(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        bytes: [capacity]u8 = @splat(0),
        len: usize = 0,

        pub fn set(self: *Self, text: []const u8) void {
            const kept = utf8Prefix(text, capacity);
            for (kept, 0..) |byte, i| self.bytes[i] = if (byte < 0x20 or byte == 0x7f) ' ' else byte;
            self.len = kept.len;
        }

        pub fn get(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

/// The longest prefix of `text` that is at most `max` bytes and does not end
/// in the middle of a UTF-8 sequence.
pub fn utf8Prefix(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

// -- one row of the list ----------------------------------------------------

/// What the list shows about one article. Everything is copied out of the
/// article, so a `Row` stays valid after the query that produced it is freed.
pub const Row = struct {
    /// Position in the list, which is what a press sends back.
    index: usize = 0,
    /// The event's id, to fetch the full article when it is opened.
    id: [32]u8 = @splat(0),
    published: i64 = 0,
    title_text: Text(120) = .{},
    summary_text: Text(200) = .{},
    author_text: Text(short_npub_len) = .{},

    pub fn from(article: data.Article) Row {
        var row: Row = .{ .id = article.id, .published = article.published };
        row.title_text.set(if (article.title.len > 0) article.title else "Untitled");
        row.summary_text.set(article.summary);
        var npub: [short_npub_len]u8 = undefined;
        row.author_text.set(shortNpub(article.author, &npub));
        return row;
    }

    // These are what the markup binds: `{a.title}` calls `title`.
    pub fn title(row: *const Row) []const u8 {
        return row.title_text.get();
    }
    pub fn summary(row: *const Row) []const u8 {
        return row.summary_text.get();
    }
    pub fn author(row: *const Row) []const u8 {
        return row.author_text.get();
    }
    pub fn hasSummary(row: *const Row) bool {
        return row.summary_text.len > 0;
    }
};

// -- pages of a long article ------------------------------------------------

/// The rendered markdown becomes real widgets, and one view can hold only so
/// many (1024 nodes). A long article is therefore shown a page at a time, each
/// page cut at a paragraph boundary. A page is bounded by bytes and by lines:
/// bytes alone would let a page of a thousand one-word list items through.
pub const page_bytes = 8_000;
pub const page_lines = 100;

/// More pages than any relay will hand over. Past this the rest of the
/// article is not shown.
pub const max_pages = 200;

pub const Pages = struct {
    /// Page `i` is `text[bounds[i]..bounds[i + 1]]`.
    bounds: [max_pages + 1]u32 = @splat(0),
    count: usize = 0,

    pub fn split(text: []const u8) Pages {
        var pages: Pages = .{};
        var at: usize = 0;
        while (at < text.len and pages.count < max_pages) {
            pages.bounds[pages.count] = @intCast(at);
            pages.count += 1;
            at = pageEnd(text, at);
        }
        pages.bounds[pages.count] = @intCast(at);
        return pages;
    }

    pub fn slice(pages: *const Pages, text: []const u8, page: usize) []const u8 {
        if (page >= pages.count) return "";
        return text[pages.bounds[page]..pages.bounds[page + 1]];
    }
};

/// Where the page starting at `start` ends: after the last blank line that
/// fits in the page and is not inside a fenced code block. A page with no such
/// line (one enormous paragraph, or a code block longer than a page) is cut at
/// its last newline, or failing that at a character boundary. A code block cut
/// that way continues on the next page as plain text, which is ugly and safe.
fn pageEnd(text: []const u8, start: usize) usize {
    var limit = @min(start + page_bytes, text.len);
    var in_fence = false;
    var best: ?usize = null;
    var lines: usize = 0;
    var at = start;
    while (at < limit) {
        if (lines == page_lines) {
            limit = at;
            break;
        }
        lines += 1;
        const newline = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
        const line = text[at..newline];
        const next = @min(newline + 1, text.len);
        if (isFence(line)) {
            in_fence = !in_fence;
        } else if (!in_fence and std.mem.trim(u8, line, whitespace).len == 0 and next <= limit) {
            best = next;
        }
        at = next;
    }
    // Nothing was cut: the rest of the article fits.
    if (limit == text.len) return text.len;
    if (best) |end| return end;

    if (std.mem.lastIndexOfScalar(u8, text[start..limit], '\n')) |newline| return start + newline + 1;
    return start + utf8Prefix(text[start..], page_bytes).len;
}

fn isFence(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " ");
    return std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~");
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn testArticle(title: []const u8, summary: []const u8, published: i64) data.Article {
    return .{
        .id = @splat(0x11),
        .author = @splat(0x22),
        .title = title,
        .summary = summary,
        .published = published,
        .content = "body",
    };
}

test "a short npub keeps the start and the end" {
    var buf: [short_npub_len]u8 = undefined;
    const short = shortNpub(@splat(0x22), &buf);
    try testing.expect(std.mem.startsWith(u8, short, "npub1"));
    try testing.expect(std.mem.indexOf(u8, short, "\u{2026}") != null);
    try testing.expectEqual(@as(usize, short_npub_len), short.len);

    const full = try nostr.nip19.encodeNpub(testing.allocator, @splat(0x22));
    defer testing.allocator.free(full);
    try testing.expectEqualStrings(full[0..12], short[0..12]);
    try testing.expectEqualStrings(full[full.len - 6 ..], short[short.len - 6 ..]);
}

test "text is cut at a character boundary and kept on one line" {
    var text: Text(8) = .{};
    // Four 3-byte characters would be 12 bytes; only two whole ones fit in 8.
    text.set("\u{20AC}\u{20AC}\u{20AC}\u{20AC}");
    try testing.expectEqualStrings("\u{20AC}\u{20AC}", text.get());

    text.set("a\nb\tc\x00d");
    try testing.expectEqualStrings("a b c d", text.get());
}

test "a row is copied out of the article" {
    const row = Row.from(testArticle("Hello", "A short summary.", 1_650_000_000));
    try testing.expectEqualStrings("Hello", row.title());
    try testing.expectEqualStrings("A short summary.", row.summary());
    try testing.expect(row.hasSummary());
    try testing.expectEqual(@as(i64, 1_650_000_000), row.published);
    try testing.expect(std.mem.startsWith(u8, row.author(), "npub1"));
}

test "a row with nothing to call it is Untitled" {
    const row = Row.from(testArticle("", "", 1_700_000_000));
    try testing.expectEqualStrings("Untitled", row.title());
    try testing.expect(!row.hasSummary());
}

test "a short article is one page" {
    const pages = Pages.split("one\n\ntwo\n");
    try testing.expectEqual(@as(usize, 1), pages.count);
    try testing.expectEqualStrings("one\n\ntwo\n", pages.slice("one\n\ntwo\n", 0));
}

test "an empty article has no pages" {
    const pages = Pages.split("");
    try testing.expectEqual(@as(usize, 0), pages.count);
    try testing.expectEqualStrings("", pages.slice("", 0));
}

test "pages are cut at paragraph boundaries and cover the text exactly once" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..40) |i| try text.print(testing.allocator, "Paragraph number {d} {s}\n\n", .{ i, "x" ** 700 });

    const pages = Pages.split(text.items);
    try testing.expect(pages.count > 1);

    var rebuilt: std.ArrayList(u8) = .empty;
    defer rebuilt.deinit(testing.allocator);
    for (0..pages.count) |i| {
        const page = pages.slice(text.items, i);
        try testing.expect(page.len <= page_bytes);
        // Every page but the last ends right after a blank line.
        if (i + 1 < pages.count) try testing.expect(std.mem.endsWith(u8, page, "\n\n"));
        try rebuilt.appendSlice(testing.allocator, page);
    }
    try testing.expectEqualStrings(text.items, rebuilt.items);
}

test "a page holds at most page_lines lines" {
    const text = "- item\n" ** 1000;
    const pages = Pages.split(text);
    try testing.expectEqual(@as(usize, 10), pages.count);
    for (0..pages.count) |i| {
        const page = pages.slice(text, i);
        try testing.expectEqual(@as(usize, page_lines), std.mem.count(u8, page, "\n"));
    }
}

test "a page is never cut inside a code fence" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "intro\n\n```\n");
    // Blank lines inside the fence, far more than one page of them.
    for (0..2000) |_| try text.appendSlice(testing.allocator, "line of code\n\n");
    try text.appendSlice(testing.allocator, "```\n\nafter\n");

    const pages = Pages.split(text.items);
    // The first page stops before the fence opens.
    try testing.expectEqualStrings("intro\n\n", pages.slice(text.items, 0));
}

test "one enormous paragraph is still cut, on a character boundary" {
    const text = "\u{20AC}" ** 6000; // 18000 bytes, no newline at all
    const pages = Pages.split(text);
    try testing.expect(pages.count >= 3);
    for (0..pages.count) |i| {
        const page = pages.slice(text, i);
        try testing.expect(page.len <= page_bytes);
        try testing.expect(std.unicode.utf8ValidateSlice(page));
    }
}
