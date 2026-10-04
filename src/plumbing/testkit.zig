//! Shared by the tests, and by nothing else: a throwaway database with a
//! couple of authors who can sign articles into it.

const std = @import("std");
const nostr = @import("nostr");
const nip23 = @import("nip23.zig");
const store_mod = @import("store.zig");

const testing = std.testing;

pub const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    store: store_mod.Store,
    signer: nostr.keys.Signer,
    alice: nostr.keys.KeyPair,
    bob: nostr.keys.KeyPair,

    /// Fixed secret keys, so a failing test fails the same way every time.
    /// They exist only here.
    pub fn init(self: *Fixture) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer self.arena.deinit();

        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_len = try self.tmp.dir.realPath(testing.io, &dir_buf);
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const file = try std.fmt.bufPrintZ(&path_buf, "{s}/events.mdb", .{dir_buf[0..dir_len]});
        self.store = try store_mod.openAt(file);
        errdefer self.store.deinit();

        self.signer = nostr.keys.Signer.init();
        self.alice = try self.signer.keyPairFromSecretKey(@splat(0x01));
        self.bob = try self.signer.keyPairFromSecretKey(@splat(0x02));
    }

    pub fn deinit(self: *Fixture) void {
        self.signer.deinit();
        self.store.deinit();
        self.arena.deinit();
        self.tmp.cleanup();
    }

    /// Where the database file is, for reopening it.
    pub fn path(self: *Fixture, buf: *[std.fs.max_path_bytes]u8) ![:0]const u8 {
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_len = try self.tmp.dir.realPath(testing.io, &dir_buf);
        return std.fmt.bufPrintZ(buf, "{s}/events.mdb", .{dir_buf[0..dir_len]});
    }

    pub const Spec = struct {
        created_at: i64 = 1_700_000_000,
        d: []const u8 = "essay",
        /// The `t` tag. Articles are only kept when it is the topic asked for.
        topic: []const u8 = nip23.topic,
        title: ?[]const u8 = null,
        summary: ?[]const u8 = null,
        published_at: ?[]const u8 = null,
        content: []const u8 = "Some body text.",
    };

    /// A signed kind:30023 event. Its tags are allocated in the fixture's
    /// arena; `spec.content` is borrowed, so it must outlive the event.
    pub fn make(self: *Fixture, who: nostr.keys.KeyPair, spec: Spec) !nostr.event.Event {
        const a = self.arena.allocator();
        var tags: std.ArrayList(nostr.event.Tag) = .empty;
        try tags.append(a, try a.dupe([]const u8, &.{ "d", spec.d }));
        try tags.append(a, try a.dupe([]const u8, &.{ "t", spec.topic }));
        if (spec.title) |t| try tags.append(a, try a.dupe([]const u8, &.{ "title", t }));
        if (spec.summary) |t| try tags.append(a, try a.dupe([]const u8, &.{ "summary", t }));
        if (spec.published_at) |t| try tags.append(a, try a.dupe([]const u8, &.{ "published_at", t }));
        return nostr.event.create(testing.allocator, self.signer, who, spec.created_at, nip23.kind, tags.items, spec.content, null);
    }

    /// Makes an article and stores it the way a relay worker would.
    pub fn save(self: *Fixture, who: nostr.keys.KeyPair, spec: Spec) !nostr.store.IngestResult {
        const ev = try self.make(who, spec);
        return store_mod.accept(&self.store, testing.allocator, self.signer, nip23.wanted, ev);
    }
};
