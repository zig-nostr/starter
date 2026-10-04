//! The local store: where verified events are kept, so the next launch shows
//! them before any relay has answered.
//!
//! This is `nostr.store.Store` (an LMDB database in one file) opened at a
//! path under the home directory, plus the one door every event from a relay
//! goes through. The library does the hard parts. `ingest` keeps only the
//! newest version of each pubkey + `d` tag (that is what an addressable event
//! is), and the signature check is one option on it.
//!
//! The file knows nothing about articles: `accept` is told which filter the
//! events have to match.

const std = @import("std");
const nostr = @import("nostr");

pub const Store = nostr.store.Store;

/// The directory under `$HOME` that holds this app's data. Rename it with the
/// app, or two apps built from this template will share a database.
pub const data_dir = ".starter";

/// LMDB reserves this much address space, not disk. Articles are text, so this
/// is far more than the app will ever fill.
const map_size: usize = 4 << 30;

/// Opens (creating if needed) the database at `$HOME/.starter/events.mdb`.
/// The `Store` lives for the whole process: it is never closed, and the OS
/// reclaims it at exit, which is safe because LMDB commits each write durably.
pub fn open(io: std.Io, environ: *const std.process.Environ.Map) !*Store {
    const home = environ.get("HOME") orelse ".";
    var dir_buf: [512]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ home, data_dir });
    // Like `mkdir -p`: fine if it exists already.
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
    dir.close(io);

    var path_buf: [600]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/events.mdb", .{dir_path});

    const store = try std.heap.page_allocator.create(Store);
    errdefer std.heap.page_allocator.destroy(store);
    store.* = try openAt(path);
    return store;
}

/// Opens a database at an exact path. The tests use this with a temp file.
pub fn openAt(path: [:0]const u8) !Store {
    return Store.open(path.ptr, .{ .map_size = map_size });
}

/// What to do with an event a relay sent: check that it is one we asked for
/// (`filter`) and is made of valid text, verify its signature and id, and
/// store it. The result says what happened; `.added` and `.replaced` are the
/// two that changed the database.
///
/// A relay can send anything down any subscription, so nothing here trusts
/// the filter the relay was given. A wrong kind or topic is `.invalid` like a
/// forged signature is.
pub fn accept(
    store: *Store,
    gpa: std.mem.Allocator,
    signer: nostr.keys.Signer,
    filter: nostr.filter.Filter,
    ev: nostr.event.Event,
) !nostr.store.IngestResult {
    if (!filter.matches(ev) or !wellFormed(ev)) return .invalid;
    return store.ingest(gpa, ev, .{ .verify_with = signer });
}

/// Whether every string in the event is valid UTF-8, which JSON promises and a
/// relay does not always deliver. Checked once, when an event arrives, so
/// nothing after that has to wonder what a stray byte will do to a text layout.
pub fn wellFormed(ev: nostr.event.Event) bool {
    if (!std.unicode.utf8ValidateSlice(ev.content)) return false;
    for (ev.tags) |tag| {
        for (tag) |field| {
            if (!std.unicode.utf8ValidateSlice(field)) return false;
        }
    }
    return true;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const Fixture = @import("testkit.zig").Fixture;
const nip23 = @import("nip23.zig");

/// The articles in the store, newest first by `created_at`.
fn newest(store: *Store, gpa: std.mem.Allocator, limit: u32) !nostr.store.QueryResult {
    return store.query(gpa, .{ .kinds = &[_]u16{nip23.kind}, .limit = limit });
}

test "an edit replaces the article it edits, and an older copy is refused" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    const first = Fixture.Spec{ .created_at = 1_000, .title = "First draft" };
    const second = Fixture.Spec{ .created_at = 2_000, .title = "Second draft" };

    try testing.expectEqual(nostr.store.IngestResult.added, try fx.save(fx.alice, first));
    try testing.expectEqual(nostr.store.IngestResult.replaced, try fx.save(fx.alice, second));
    // A relay that still holds the first draft sends it again.
    try testing.expectEqual(nostr.store.IngestResult.stale, try fx.save(fx.alice, first));

    var result = try newest(&fx.store, testing.allocator, 10);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.events.len);
    try testing.expectEqualStrings("Second draft", nip23.titleOf(result.events[0]));
}

test "the same d tag from two authors, and two d tags from one author, are separate articles" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    try testing.expectEqual(nostr.store.IngestResult.added, try fx.save(fx.alice, .{ .d = "notes", .title = "Alice, notes" }));
    try testing.expectEqual(nostr.store.IngestResult.added, try fx.save(fx.alice, .{ .d = "other", .title = "Alice, other" }));
    try testing.expectEqual(nostr.store.IngestResult.added, try fx.save(fx.bob, .{ .d = "notes", .title = "Bob, notes" }));

    var result = try newest(&fx.store, testing.allocator, 10);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.events.len);
}

test "an article whose text is not UTF-8 is not stored, even when it is signed" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    try testing.expectEqual(nostr.store.IngestResult.invalid, try fx.save(fx.alice, .{ .title = "Broken", .content = "bytes that are not text: \xff\xfe" }));
    try testing.expectEqual(@as(usize, 0), try fx.store.eventCount());
}

test "an event with a forged signature is not stored" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    var forged = try fx.make(fx.alice, .{ .title = "Forged" });
    forged.sig[0] ^= 0xff;

    try testing.expectEqual(nostr.store.IngestResult.invalid, try accept(&fx.store, testing.allocator, fx.signer, nip23.wanted, forged));
    var result = try newest(&fx.store, testing.allocator, 10);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.events.len);
}

test "an event whose content was changed after signing is not stored" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    var tampered = try fx.make(fx.alice, .{ .title = "Tampered" });
    tampered.content = "Different words than were signed.";

    try testing.expectEqual(nostr.store.IngestResult.invalid, try accept(&fx.store, testing.allocator, fx.signer, nip23.wanted, tampered));
}

test "an article about something else is not stored" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    try testing.expectEqual(nostr.store.IngestResult.invalid, try fx.save(fx.alice, .{ .title = "Off topic", .topic = "recipes" }));
    try testing.expectEqual(@as(usize, 0), try fx.store.eventCount());
}

test "an event of a kind nobody asked for is not stored, even when it is signed" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    const note = try nostr.event.create(testing.allocator, fx.signer, fx.alice, 1_000, 1, &.{}, "a short note", null);
    try testing.expectEqual(nostr.store.IngestResult.invalid, try accept(&fx.store, testing.allocator, fx.signer, nip23.wanted, note));
    try testing.expectEqual(@as(usize, 0), try fx.store.eventCount());
}

test "articles survive closing and reopening the store" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    _ = try fx.save(fx.alice, .{ .title = "Kept" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try fx.path(&path_buf);
    fx.store.deinit();
    fx.store = try openAt(path);

    var result = try newest(&fx.store, testing.allocator, 10);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.events.len);
    try testing.expectEqualStrings("Kept", nip23.titleOf(result.events[0]));
}

test "text that is not UTF-8 is not well formed" {
    const base: nostr.event.Event = .{
        .id = @splat(0),
        .pubkey = @splat(0),
        .created_at = 0,
        .kind = 1,
        .tags = &.{},
        .content = "plain \u{20AC} text",
        .sig = @splat(0),
    };
    try testing.expect(wellFormed(base));

    var broken = base;
    broken.content = "broken \xff\xfe bytes";
    try testing.expect(!wellFormed(broken));
    // A truncated multi-byte sequence at the very end.
    broken.content = "cut short \xe2\x82";
    try testing.expect(!wellFormed(broken));

    const bad_tag = [_]nostr.event.Tag{&.{ "title", "bad \xc0\xaf title" }};
    var tagged = base;
    tagged.tags = &bad_tag;
    try testing.expect(!wellFormed(tagged));
}
