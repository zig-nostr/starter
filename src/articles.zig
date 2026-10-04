//! What a NIP-23 long-form article is, as far as this app cares.
//!
//! Nothing here touches a relay, the store or the window. Every function reads
//! an event's own fields and answers a question about it, so the tests build
//! events by hand and check the answers.
//!
//! The reference for what to read out of an event is how Jumble shows
//! long-form: the filter (constants.ts, the "articles" feed tab asks for
//! `kinds: [30023]`), the metadata tags (lib/event-metadata.ts,
//! `getLongFormArticleMetadataFromEvent`), and which timestamp a reader sees
//! (lib/event-feed.ts, `getEventFeedTimestamp`).

const std = @import("std");
const nostr = @import("nostr");

const Event = nostr.event.Event;

/// NIP-23: long-form content. An addressable event, so a relay (and the local
/// store) keeps only the newest version of each pubkey + `d` tag.
pub const kind: u16 = 30023;

/// How many articles one relay is asked for, and the most the list holds.
pub const list_cap = 50;

/// The `t` tag an article must carry to be asked for.
///
/// Public relays hold a great deal of spam under kind 30023: SEO pages,
/// placeholders, adult listings. Jumble reads long-form from the accounts you
/// follow, and this app follows nobody, so it narrows by topic instead. To see
/// every article a relay will give you, delete the `.tags` line from `wanted`.
pub const topic = "nostr";

/// The one question this app puts to a relay. The same filter is applied to
/// every event that comes back (`Filter.matches`), because a relay is free to
/// ignore the filter it was sent.
pub const wanted: nostr.filter.Filter = .{
    .kinds = &[_]u16{kind},
    .tags = &[_]nostr.filter.TagFilter{.{ .letter = 't', .values = &[_][]const u8{topic} }},
    .limit = list_cap,
};

// -- reading an event -------------------------------------------------------

/// The value of the first tag called `name`, or null.
pub fn tagValue(ev: Event, name: []const u8) ?[]const u8 {
    for (ev.tags) |tag| {
        if (tag.len >= 2 and std.mem.eql(u8, tag[0], name)) return tag[1];
    }
    return null;
}

/// The article's title: the `title` tag, or failing that the first line of the
/// content with its markdown heading marks taken off. Empty when there is
/// neither, and the caller decides what to call such an article.
pub fn titleOf(ev: Event) []const u8 {
    if (tagValue(ev, "title")) |t| {
        const trimmed = std.mem.trim(u8, t, whitespace);
        if (trimmed.len > 0) return trimmed;
    }
    return firstLine(ev.content);
}

/// The `summary` tag, trimmed. Empty when absent.
pub fn summaryOf(ev: Event) []const u8 {
    return std.mem.trim(u8, tagValue(ev, "summary") orelse "", whitespace);
}

/// The date a reader should see: the `published_at` tag when it is a plain
/// number that is not later than the event itself, otherwise `created_at`.
///
/// `created_at` moves every time the author edits, so using it alone would
/// date an old article by its last typo fix. A `published_at` after
/// `created_at` is nonsense (clients also write milliseconds there), and
/// Jumble falls back the same way.
pub fn publishedAt(ev: Event) i64 {
    const raw = tagValue(ev, "published_at") orelse return ev.created_at;
    const stamp = std.fmt.parseInt(i64, raw, 10) catch return ev.created_at;
    if (stamp <= 0 or stamp > ev.created_at) return ev.created_at;
    return stamp;
}

/// Whether every string in the event is valid UTF-8, which JSON promises and a
/// relay does not always deliver. Checked once, when an event arrives, so
/// nothing after that has to wonder what a stray byte will do to a text layout.
pub fn wellFormed(ev: Event) bool {
    if (!std.unicode.utf8ValidateSlice(ev.content)) return false;
    for (ev.tags) |tag| {
        for (tag) |field| {
            if (!std.unicode.utf8ValidateSlice(field)) return false;
        }
    }
    return true;
}

/// Whether an article is worth a row. Relays hold plenty of empty events with
/// a `d` tag and nothing else.
pub fn worthListing(ev: Event) bool {
    return std.mem.trim(u8, ev.content, whitespace).len > 0;
}

const whitespace = " \t\r\n";

/// The first non-empty line, without leading `#` marks.
fn firstLine(content: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, std.mem.trimStart(u8, std.mem.trim(u8, line, whitespace), "#"), whitespace);
        if (text.len > 0) return text;
    }
    return "";
}

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
/// event, so a `Row` stays valid after the query that produced it is freed.
pub const Row = struct {
    /// Position in the list, which is what a press sends back.
    index: usize = 0,
    /// The event's id, to fetch the full article when it is opened.
    id: [32]u8 = @splat(0),
    published: i64 = 0,
    title_text: Text(120) = .{},
    summary_text: Text(200) = .{},
    author_text: Text(short_npub_len) = .{},

    pub fn from(ev: Event) Row {
        var row: Row = .{ .id = ev.id, .published = publishedAt(ev) };
        const heading = titleOf(ev);
        row.title_text.set(if (heading.len > 0) heading else "Untitled");
        row.summary_text.set(summaryOf(ev));
        var npub: [short_npub_len]u8 = undefined;
        row.author_text.set(shortNpub(ev.pubkey, &npub));
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

/// Newest first, which is the order the list is shown in.
pub fn newerFirst(_: void, a: Row, b: Row) bool {
    if (a.published != b.published) return a.published > b.published;
    return std.mem.order(u8, &a.id, &b.id) == .lt;
}

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

/// An unsigned event with just the fields the functions here read.
fn testEvent(tags: []const nostr.event.Tag, content: []const u8) Event {
    return .{
        .id = @splat(0x11),
        .pubkey = @splat(0x22),
        .created_at = 1_700_000_000,
        .kind = kind,
        .tags = tags,
        .content = content,
        .sig = @splat(0),
    };
}

test "the title is the title tag" {
    const tags = [_]nostr.event.Tag{
        &.{ "d", "a-slug" },
        &.{ "title", "  A Plain Title " },
    };
    try testing.expectEqualStrings("A Plain Title", titleOf(testEvent(&tags, "# Not This\n\nbody")));
}

test "without a title tag the title is the first line, heading marks off" {
    try testing.expectEqualStrings("Heading Line", titleOf(testEvent(&.{}, "\n\n## Heading Line\n\nbody")));
    try testing.expectEqualStrings("No marks", titleOf(testEvent(&.{}, "No marks\nsecond line")));
}

test "an empty title tag falls through to the first line" {
    const tags = [_]nostr.event.Tag{&.{ "title", "   " }};
    try testing.expectEqualStrings("From the body", titleOf(testEvent(&tags, "From the body")));
}

test "no title and no content gives an empty title" {
    try testing.expectEqualStrings("", titleOf(testEvent(&.{}, " \n \n")));
}

test "published_at is used when it is a plain number not after created_at" {
    const early = [_]nostr.event.Tag{&.{ "published_at", "1600000000" }};
    try testing.expectEqual(@as(i64, 1_600_000_000), publishedAt(testEvent(&early, "x")));

    // After the event itself, and milliseconds written by mistake: ignored.
    const future = [_]nostr.event.Tag{&.{ "published_at", "1800000000" }};
    try testing.expectEqual(@as(i64, 1_700_000_000), publishedAt(testEvent(&future, "x")));
    const millis = [_]nostr.event.Tag{&.{ "published_at", "1600000000000" }};
    try testing.expectEqual(@as(i64, 1_700_000_000), publishedAt(testEvent(&millis, "x")));

    // Not a number, negative, or missing.
    const junk = [_]nostr.event.Tag{&.{ "published_at", "yesterday" }};
    try testing.expectEqual(@as(i64, 1_700_000_000), publishedAt(testEvent(&junk, "x")));
    const negative = [_]nostr.event.Tag{&.{ "published_at", "-5" }};
    try testing.expectEqual(@as(i64, 1_700_000_000), publishedAt(testEvent(&negative, "x")));
    try testing.expectEqual(@as(i64, 1_700_000_000), publishedAt(testEvent(&.{}, "x")));
}

test "a tag with no value is skipped, not read past its end" {
    const tags = [_]nostr.event.Tag{ &.{"title"}, &.{} };
    try testing.expectEqualStrings("Body title", titleOf(testEvent(&tags, "Body title")));
}

test "text that is not UTF-8 is not well formed" {
    try testing.expect(wellFormed(testEvent(&.{}, "plain \u{20AC} text")));
    try testing.expect(!wellFormed(testEvent(&.{}, "broken \xff\xfe bytes")));
    // A truncated multi-byte sequence at the very end.
    try testing.expect(!wellFormed(testEvent(&.{}, "cut short \xe2\x82")));

    const bad_tag = [_]nostr.event.Tag{&.{ "title", "bad \xc0\xaf title" }};
    try testing.expect(!wellFormed(testEvent(&bad_tag, "fine")));
}

test "empty articles are not worth a row" {
    try testing.expect(!worthListing(testEvent(&.{}, "")));
    try testing.expect(!worthListing(testEvent(&.{}, " \n\t ")));
    try testing.expect(worthListing(testEvent(&.{}, "words")));
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

test "a row is copied out of the event" {
    const tags = [_]nostr.event.Tag{
        &.{ "title", "Hello" },
        &.{ "summary", "A short summary." },
        &.{ "published_at", "1650000000" },
    };
    const row = Row.from(testEvent(&tags, "body"));
    try testing.expectEqualStrings("Hello", row.title());
    try testing.expectEqualStrings("A short summary.", row.summary());
    try testing.expect(row.hasSummary());
    try testing.expectEqual(@as(i64, 1_650_000_000), row.published);
    try testing.expect(std.mem.startsWith(u8, row.author(), "npub1"));
}

test "a row with nothing to call it is Untitled" {
    const row = Row.from(testEvent(&.{}, "\n"));
    try testing.expectEqualStrings("Untitled", row.title());
    try testing.expect(!row.hasSummary());
}

test "rows sort newest first" {
    var rows = [_]Row{ .{ .published = 10 }, .{ .published = 30 }, .{ .published = 20 } };
    std.mem.sort(Row, &rows, {}, newerFirst);
    try testing.expectEqual(@as(i64, 30), rows[0].published);
    try testing.expectEqual(@as(i64, 20), rows[1].published);
    try testing.expectEqual(@as(i64, 10), rows[2].published);
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

test "the wanted filter matches an article on the topic, and nothing else" {
    const on_topic = [_]nostr.event.Tag{ &.{ "d", "slug" }, &.{ "t", topic } };
    try testing.expect(wanted.matches(testEvent(&on_topic, "x")));

    // Right kind, but about something else, or about nothing.
    const off_topic = [_]nostr.event.Tag{&.{ "t", "recipes" }};
    try testing.expect(!wanted.matches(testEvent(&off_topic, "x")));
    try testing.expect(!wanted.matches(testEvent(&.{}, "x")));

    // Right topic, wrong kind.
    var note = testEvent(&on_topic, "x");
    note.kind = 1;
    try testing.expect(!wanted.matches(note));
}
