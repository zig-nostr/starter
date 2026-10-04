//! What a NIP-23 long-form article is, and the one question this app asks.
//!
//! This is the data layer: it reads an event's own fields and answers
//! questions about it. Nothing here touches a relay, the store or the window,
//! so the tests build events by hand and check the answers.
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

/// How many articles one relay is asked for.
pub const per_relay_limit = 50;

/// The `t` tag an article must carry to be asked for.
///
/// Public relays hold a great deal of spam under kind 30023: SEO pages,
/// placeholders, adult listings. Jumble reads long-form from the accounts you
/// follow, and this app follows nobody, so it narrows by topic instead. To see
/// every article a relay will give you, delete the `.tags` line from `wanted`.
pub const topic = "nostr";

/// The one question this app puts to a relay. This is the line to change when
/// you want different data. The same filter is applied to every event that
/// comes back (`Filter.matches`), because a relay is free to ignore the filter
/// it was sent.
pub const wanted: nostr.filter.Filter = .{
    .kinds = &[_]u16{kind},
    .tags = &[_]nostr.filter.TagFilter{.{ .letter = 't', .values = &[_][]const u8{topic} }},
    .limit = per_relay_limit,
};

// -- one article ------------------------------------------------------------

/// What the rest of the program knows about an article. The strings point into
/// the event they were read from, so an `Article` is good for as long as that
/// event is.
pub const Article = struct {
    /// The event id, which is how an article is asked for again.
    id: [32]u8,
    author: [32]u8,
    /// Empty when the event has neither a title tag nor a first line.
    title: []const u8,
    /// Empty when absent.
    summary: []const u8,
    /// Seconds since the epoch, as `publishedAt` reads it.
    published: i64,
    /// Markdown.
    content: []const u8,

    pub fn from(ev: Event) Article {
        return .{
            .id = ev.id,
            .author = ev.pubkey,
            .title = titleOf(ev),
            .summary = summaryOf(ev),
            .published = publishedAt(ev),
            .content = ev.content,
        };
    }
};

/// Newest first, which is the order a reader expects.
pub fn newerFirst(_: void, a: Article, b: Article) bool {
    if (a.published != b.published) return a.published > b.published;
    return std.mem.order(u8, &a.id, &b.id) == .lt;
}

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

/// Whether an article is worth showing. Relays hold plenty of empty events
/// with a `d` tag and nothing else.
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

test "empty articles are not worth showing" {
    try testing.expect(!worthListing(testEvent(&.{}, "")));
    try testing.expect(!worthListing(testEvent(&.{}, " \n\t ")));
    try testing.expect(worthListing(testEvent(&.{}, "words")));
}

test "an article carries what was read from the event" {
    const tags = [_]nostr.event.Tag{
        &.{ "title", "Hello" },
        &.{ "summary", "A short summary." },
        &.{ "published_at", "1650000000" },
    };
    const article = Article.from(testEvent(&tags, "body"));
    try testing.expectEqualStrings("Hello", article.title);
    try testing.expectEqualStrings("A short summary.", article.summary);
    try testing.expectEqualStrings("body", article.content);
    try testing.expectEqual(@as(i64, 1_650_000_000), article.published);
    try testing.expectEqual(@as([32]u8, @splat(0x11)), article.id);
    try testing.expectEqual(@as([32]u8, @splat(0x22)), article.author);
}

test "articles sort newest first, and ties are broken by id" {
    var articles = [_]Article{
        Article.from(testEvent(&.{}, "a")),
        Article.from(testEvent(&.{}, "b")),
        Article.from(testEvent(&.{}, "c")),
    };
    articles[0].published = 10;
    articles[1].published = 30;
    articles[2].published = 20;
    std.mem.sort(Article, &articles, {}, newerFirst);
    try testing.expectEqual(@as(i64, 30), articles[0].published);
    try testing.expectEqual(@as(i64, 20), articles[1].published);
    try testing.expectEqual(@as(i64, 10), articles[2].published);

    var tied = [_]Article{ Article.from(testEvent(&.{}, "a")), Article.from(testEvent(&.{}, "b")) };
    tied[0].id = @splat(0x20);
    tied[1].id = @splat(0x10);
    std.mem.sort(Article, &tied, {}, newerFirst);
    try testing.expectEqual(@as([32]u8, @splat(0x10)), tied[0].id);
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
