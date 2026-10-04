//! YOUR APP'S INTERFACE: REPLACE IT, and these tests with it.
//!
//! The example interface tested the way it runs: real messages through
//! `update`, the real markup built into a widget tree, and a real database in
//! a temp directory. No window and no network. The plumbing has its own tests
//! beside it in `plumbing/`.

const std = @import("std");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const main = @import("main.zig");
const model_mod = @import("model.zig");
const display = @import("display.zig");
const data_mod = @import("plumbing/data.zig");
const nip23 = @import("plumbing/nip23.zig");
const relays = @import("plumbing/relays.zig");
const Fixture = @import("plumbing/testkit.zig").Fixture;

const canvas = native_sdk.canvas;
const testing = std.testing;

const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;
const Effects = main.Effects;

const AppMarkup = canvas.MarkupView(Model, Msg);

// -- helpers ----------------------------------------------------------------

/// The model is tens of kilobytes, so it lives on the heap like it does in the
/// running app.
fn newModel() !*Model {
    const model = try testing.allocator.create(Model);
    model.* = .{};
    return model;
}

fn freeModel(model: *Model) void {
    model.closeArticleForTest();
    testing.allocator.destroy(model);
}

fn buildTree(arena: std.mem.Allocator, model: *const Model) !AppUi.Tree {
    var view = try AppMarkup.init(arena, main.app_markup);
    var ui = AppUi.init(arena);
    const node = view.build(&ui, model) catch |err| {
        // Name the app.native position instead of a bare error trace: the
        // usual causes are a binding with no matching Model field, or an on-*
        // message with no Msg arm.
        if (err == error.MarkupBuild) {
            std.debug.print("app.native:{d}:{d}: {s}\n", .{ view.diagnostic.line, view.diagnostic.column, view.diagnostic.message });
        }
        return err;
    };
    return ui.finalize(node);
}

fn find(widget: canvas.Widget, comptime match: fn (canvas.Widget) bool) ?canvas.Widget {
    if (match(widget)) return widget;
    for (widget.children) |child| {
        if (find(child, match)) |found| return found;
    }
    return null;
}

/// The first widget of `kind` whose text is exactly `text`.
fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}

/// The first widget of `kind` announced as `label`.
fn findByLabel(widget: canvas.Widget, kind: canvas.WidgetKind, label: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.semantics.label, label)) return widget;
    for (widget.children) |child| {
        if (findByLabel(child, kind, label)) |found| return found;
    }
    return null;
}

fn hasTextContaining(widget: canvas.Widget, needle: []const u8) bool {
    if (widget.kind == .text and std.mem.indexOf(u8, widget.text, needle) != null) return true;
    for (widget.children) |child| {
        if (hasTextContaining(child, needle)) return true;
    }
    return false;
}

/// A miss fails the test with the mismatch spelled out rather than a bare
/// null unwrap: the usual cause is app.native and this test drifting apart.
fn expectByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) !canvas.Widget {
    return findByText(widget, kind, text) orelse {
        std.debug.print("no {t} with text \"{s}\" in the view - if you changed app.native, update this test to match\n", .{ kind, text });
        return error.WidgetNotFound;
    };
}

fn expectByLabel(widget: canvas.Widget, kind: canvas.WidgetKind, label: []const u8) !canvas.Widget {
    return findByLabel(widget, kind, label) orelse {
        std.debug.print("no {t} labelled \"{s}\" in the view - if you changed app.native, update this test to match\n", .{ kind, label });
        return error.WidgetNotFound;
    };
}

fn expectNoText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) !void {
    if (findByText(widget, kind, text) != null) {
        std.debug.print("found a {t} with text \"{s}\" that should not be there\n", .{ kind, text });
        return error.UnexpectedWidget;
    }
}

/// A press on `target`, delivered the way the window delivers it.
fn press(model: *Model, fx: *Effects, tree: AppUi.Tree, target: canvas.Widget) !void {
    const msg = tree.msgForPointer(target.id, .up) orelse {
        std.debug.print("pressing {t} \"{s}\" sends no message\n", .{ target.kind, target.text });
        return error.NoMessage;
    };
    model_mod.update(model, msg, fx);
}

/// What `main` builds for the model: `Data` over a fixture's store, with a
/// fetcher that has no relays to ask.
const Rig = struct {
    fetcher: relays.Fetcher,
    data: data_mod.Data,

    fn init(rig: *Rig, fx: *Fixture) void {
        rig.fetcher = relays.Fetcher.init(&fx.store, &.{}, nip23.wanted);
        rig.data = data_mod.Data.init(&fx.store, &rig.fetcher);
    }
};

fn loadModel(rig: *Rig, model: *Model) void {
    model.data = &rig.data;
    model.reload();
}

fn newEffects() Effects {
    var fx = Effects.init(testing.allocator);
    fx.executor = .fake;
    return fx;
}

/// Paragraphs of about 100 bytes, enough of them for `pages` pages or so.
fn longArticle(arena: std.mem.Allocator, paragraphs: usize) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (0..paragraphs) |i| try text.print(arena, "Paragraph {d} of the long article. {s}\n\n", .{ i, "It goes on for a while." ** 3 });
    return text.items;
}

// -- the list ---------------------------------------------------------------

test "the list shows the saved articles, by the date they were published" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    // The older article was edited most recently, so it is newest by
    // created_at and not by when it was first published.
    _ = try fx.save(fx.alice, .{ .d = "old", .title = "Edited old essay", .created_at = 5_000_000_000, .published_at = "1000000000" });
    _ = try fx.save(fx.bob, .{ .d = "new", .title = "Fresh essay", .created_at = 1_700_000_000, .published_at = "1700000000" });

    const model = try newModel();
    defer freeModel(model);
    var rig: Rig = undefined;
    rig.init(&fx);
    loadModel(&rig, model);

    try testing.expectEqual(@as(usize, 2), model.row_count);
    try testing.expectEqualStrings("Fresh essay", model.rows[0].title());
    try testing.expectEqualStrings("Edited old essay", model.rows[1].title());

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const tree = try buildTree(arena_state.allocator(), model);
    _ = try expectByLabel(tree.root, .list_item, "Fresh essay");
    _ = try expectByLabel(tree.root, .list_item, "Edited old essay");
    try testing.expect(hasTextContaining(tree.root, "2023-11-14"));
    try testing.expect(hasTextContaining(tree.root, "2001-09-09"));
    _ = try expectByText(tree.root, .status_bar, "2 articles saved");
}

test "an article with no title tag is listed by its first line" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    _ = try fx.save(fx.alice, .{ .content = "# The heading is the title\n\nThen the text." });

    const model = try newModel();
    defer freeModel(model);
    var rig: Rig = undefined;
    rig.init(&fx);
    loadModel(&rig, model);

    try testing.expectEqualStrings("The heading is the title", model.rows[0].title());
}

test "the list never holds more than its capacity" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var buf: [16]u8 = undefined;
    for (0..display.list_cap + 10) |i| {
        const d = try std.fmt.bufPrint(&buf, "essay-{d}", .{i});
        // The store keeps the slug until the event is gone, so make it owned.
        _ = try fx.save(fx.alice, .{ .d = try fx.arena.allocator().dupe(u8, d), .created_at = 1_000 + @as(i64, @intCast(i)) });
    }

    const model = try newModel();
    defer freeModel(model);
    var rig: Rig = undefined;
    rig.init(&fx);
    loadModel(&rig, model);

    try testing.expectEqual(@as(usize, display.list_cap), model.row_count);
}

test "an empty list says what it is waiting for" {
    const model = try newModel();
    defer freeModel(model);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var tree = try buildTree(arena_state.allocator(), model);
    _ = try expectByText(tree.root, .text, "Nothing saved yet. Press Refresh to ask the relays again.");

    // With a relay mid-flight it says so instead, and Refresh is disabled.
    var store: relays.Store = undefined;
    const urls = [_][]const u8{"ws://a:1"};
    var fetcher = relays.Fetcher.init(&store, &urls, nip23.wanted);
    var data = data_mod.Data.init(&store, &fetcher);
    fetcher.set(0, .reading);
    model.data = &data;

    tree = try buildTree(arena_state.allocator(), model);
    _ = try expectByText(tree.root, .text, "Asking relays for articles...");
    const refresh = try expectByText(tree.root, .button, "Refresh");
    try testing.expect(refresh.state.disabled);
}

test "Refresh asks again, and a tick shows what arrived" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    const model = try newModel();
    defer freeModel(model);
    var effects = newEffects();
    defer effects.deinit();

    // No sockets: a fetcher with no relays has nothing to start, but its
    // version still moves when a worker would have stored something.
    var rig: Rig = undefined;
    rig.init(&fx);
    const fetcher = &rig.fetcher;
    model.data = &rig.data;

    model_mod.update(model, .refresh, &effects);
    try testing.expectEqual(@as(usize, 0), model.row_count);

    // A worker stores an article and bumps the version.
    _ = try fx.save(fx.alice, .{ .title = "Just arrived" });
    fetcher.bump();

    // The tick notices and re-reads.
    model_mod.update(model, .{ .tick = .{ .key = 1 } }, &effects);
    try testing.expectEqual(@as(usize, 1), model.row_count);
    try testing.expectEqualStrings("Just arrived", model.rows[0].title());

    // A tick with nothing new does not read again: change the store behind the
    // model's back and the list stays as it was.
    _ = try fx.save(fx.bob, .{ .title = "Unannounced" });
    model_mod.update(model, .{ .tick = .{ .key = 1 } }, &effects);
    try testing.expectEqual(@as(usize, 1), model.row_count);

    // A timer the host refused to start is not a tick.
    fetcher.bump();
    model_mod.update(model, .{ .tick = .{ .key = 1, .outcome = .rejected } }, &effects);
    try testing.expectEqual(@as(usize, 1), model.row_count);
}

test "the status line counts relays that answered, not relays that are listed" {
    const model = try newModel();
    defer freeModel(model);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("0 articles saved", model.status(arena));

    var store: relays.Store = undefined;
    const urls = [_][]const u8{ "ws://a:1", "ws://b:1", "ws://c:1" };
    var fetcher = relays.Fetcher.init(&store, &urls, nip23.wanted);
    var data = data_mod.Data.init(&store, &fetcher);
    model.data = &data;

    try testing.expectEqualStrings("0 articles saved | 0 of 3 relays answered", model.status(arena));

    fetcher.set(0, .done);
    fetcher.set(1, .reading);
    try testing.expectEqualStrings("0 articles saved | asking relays, 1 of 3 answered", model.status(arena));

    fetcher.set(1, .failed);
    fetcher.set(2, .failed);
    try testing.expectEqualStrings("0 articles saved | 1 of 3 relays answered, 2 unreachable", model.status(arena));
}

// -- reading ----------------------------------------------------------------

test "pressing an article opens it, and Articles goes back" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    _ = try fx.save(fx.alice, .{ .title = "Worth reading", .content = "First paragraph.\n\nSecond paragraph." });

    const model = try newModel();
    defer freeModel(model);
    var effects = newEffects();
    defer effects.deinit();
    var rig: Rig = undefined;
    rig.init(&fx);
    loadModel(&rig, model);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tree = try buildTree(arena, model);
    try press(model, &effects, tree, try expectByLabel(tree.root, .list_item, "Worth reading"));
    try testing.expect(model.isReading());

    tree = try buildTree(arena, model);
    _ = try expectByText(tree.root, .text, "Worth reading");
    try testing.expectEqualStrings("First paragraph.\n\nSecond paragraph.", model.pageText());
    // One page, so there is no page control.
    try expectNoText(tree.root, .text, "Page 1 of 1");

    try press(model, &effects, tree, try expectByText(tree.root, .button, "Articles"));
    try testing.expect(!model.isReading());
    tree = try buildTree(arena, model);
    _ = try expectByLabel(tree.root, .list_item, "Worth reading");
}

test "a long article is read a page at a time" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const content = try longArticle(arena, 400);
    _ = try fx.save(fx.alice, .{ .title = "Very long", .content = content });

    const model = try newModel();
    defer freeModel(model);
    var effects = newEffects();
    defer effects.deinit();
    var rig: Rig = undefined;
    rig.init(&fx);
    loadModel(&rig, model);

    model_mod.update(model, .{ .open = 0 }, &effects);
    const pages = model.pageCount();
    try testing.expect(pages > 3);

    var tree = try buildTree(arena, model);
    var label_buf: [32]u8 = undefined;
    _ = try expectByText(tree.root, .text, try std.fmt.bufPrint(&label_buf, "Page 1 of {d}", .{pages}));
    // The first page has no previous page to go to.
    try testing.expect((try expectByLabel(tree.root, .button, "Previous page")).state.disabled);
    try testing.expect(!(try expectByLabel(tree.root, .button, "Next page")).state.disabled);

    const first_page = model.pageText();
    try press(model, &effects, tree, try expectByLabel(tree.root, .button, "Next page"));
    try testing.expectEqual(@as(usize, 2), model.pageNumber());
    try testing.expect(!std.mem.eql(u8, first_page, model.pageText()));

    tree = try buildTree(arena, model);
    _ = try expectByText(tree.root, .text, try std.fmt.bufPrint(&label_buf, "Page 2 of {d}", .{pages}));
    try press(model, &effects, tree, try expectByLabel(tree.root, .button, "Previous page"));
    try testing.expectEqualStrings(first_page, model.pageText());

    // Paging past either end stays put.
    model_mod.update(model, .prev_page, &effects);
    try testing.expectEqual(@as(usize, 1), model.pageNumber());
    for (0..pages + 3) |_| model_mod.update(model, .next_page, &effects);
    try testing.expectEqual(pages, model.pageNumber());
}

test "opening a row that is not there does nothing" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const model = try newModel();
    defer freeModel(model);
    var effects = newEffects();
    defer effects.deinit();
    var rig: Rig = undefined;
    rig.init(&fx);
    loadModel(&rig, model);

    model_mod.update(model, .{ .open = 7 }, &effects);
    try testing.expect(!model.isReading());
}

test "opening a second article replaces the first" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    _ = try fx.save(fx.alice, .{ .d = "a", .title = "Alpha", .created_at = 2_000, .content = "alpha text" });
    _ = try fx.save(fx.alice, .{ .d = "b", .title = "Beta", .created_at = 1_000, .content = "beta text" });
    const model = try newModel();
    defer freeModel(model);
    var effects = newEffects();
    defer effects.deinit();
    var rig: Rig = undefined;
    rig.init(&fx);
    loadModel(&rig, model);

    model_mod.update(model, .{ .open = 0 }, &effects);
    try testing.expectEqualStrings("alpha text", model.pageText());
    model_mod.update(model, .{ .open = 1 }, &effects);
    try testing.expectEqualStrings("beta text", model.pageText());
    try testing.expectEqualStrings("Beta", model.readTitle());
    try testing.expectEqual(@as(usize, 1), model.pageNumber());
}

// -- links ------------------------------------------------------------------

test "only plain web links are opened" {
    try testing.expect(model_mod.isSafeExternalUrl("https://example.com/a?b=c#d"));
    try testing.expect(model_mod.isSafeExternalUrl("http://example.com"));

    try testing.expect(!model_mod.isSafeExternalUrl("javascript:alert(1)"));
    try testing.expect(!model_mod.isSafeExternalUrl("file:///etc/passwd"));
    try testing.expect(!model_mod.isSafeExternalUrl("nostr:npub1abc"));
    try testing.expect(!model_mod.isSafeExternalUrl("//example.com"));
    try testing.expect(!model_mod.isSafeExternalUrl("https://example.com/a b"));
    try testing.expect(!model_mod.isSafeExternalUrl("https://example.com/\x00"));
    try testing.expect(!model_mod.isSafeExternalUrl("https://example.com/\n--flag"));
    try testing.expect(!model_mod.isSafeExternalUrl(""));
    try testing.expect(!model_mod.isSafeExternalUrl("https://example.com/" ++ "a" ** 2000));
}

// -- the view as a whole ----------------------------------------------------

test "both screens lay out and pass the accessibility audit at every window size" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A summary long enough to need eliding, a title long enough to need
    // wrapping, and a long article for the reader.
    _ = try fx.save(fx.alice, .{ .d = "a", .title = "A title that is far longer than the window is wide, to see what a row does with it " ** 3, .summary = "And a summary just as long. " ** 8, .content = try longArticle(arena, 400) });
    _ = try fx.save(fx.bob, .{ .d = "b", .title = "Short" });

    const model = try newModel();
    defer freeModel(model);
    var effects = newEffects();
    defer effects.deinit();
    var rig: Rig = undefined;
    rig.init(&fx);
    loadModel(&rig, model);

    const options: canvas.LayoutAuditSweepOptions = .{
        .min_size = native_sdk.geometry.SizeF.init(640, 480),
        .default_size = native_sdk.geometry.SizeF.init(880, 720),
    };
    const a11y: canvas.a11y.A11yAuditSweepOptions = .{
        .min_size = options.min_size,
        .default_size = options.default_size,
    };

    var tree = try buildTree(arena, model);
    try canvas.expectLayoutAuditSweepClean(testing.allocator, tree.root, options);
    try canvas.expectA11yAuditSweepClean(testing.allocator, tree.root, a11y);

    model_mod.update(model, .{ .open = 0 }, &effects);
    tree = try buildTree(arena, model);
    try canvas.expectLayoutAuditSweepClean(testing.allocator, tree.root, options);
    try canvas.expectA11yAuditSweepClean(testing.allocator, tree.root, a11y);
}

test "a full list and a full page stay inside the widget budget" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A full list, every row with a summary.
    var buf: [16]u8 = undefined;
    for (0..display.list_cap) |i| {
        const d = try arena.dupe(u8, try std.fmt.bufPrint(&buf, "essay-{d}", .{i}));
        _ = try fx.save(fx.alice, .{ .d = d, .title = "Title", .summary = "A summary of the essay.", .created_at = 1_000 + @as(i64, @intCast(i)) });
    }
    // The worst page the splitter allows: a hundred short bullet items.
    _ = try fx.save(fx.bob, .{ .d = "bullets", .title = "Bullets", .created_at = 9_000, .content = "- item\n" ** 1000 });
    // And one the byte limit allows: paragraphs, with some formatting in them.
    _ = try fx.save(fx.bob, .{ .d = "prose", .title = "Prose", .created_at = 9_001, .content = try longArticle(arena, 80) });

    const model = try newModel();
    defer freeModel(model);
    var effects = newEffects();
    defer effects.deinit();
    var rig: Rig = undefined;
    rig.init(&fx);
    loadModel(&rig, model);

    const nodes = try testing.allocator.alloc(canvas.WidgetLayoutNode, 4096);
    defer testing.allocator.free(nodes);
    const bounds = native_sdk.geometry.RectF.init(0, 0, 880, 720);

    var tree = try buildTree(arena, model);
    var layout = try canvas.layoutWidgetTree(tree.root, bounds, nodes);
    try testing.expect(layout.nodes.len < canvas.max_layout_audit_nodes);

    for (0..model.row_count) |i| {
        if (!std.mem.eql(u8, model.rows[i].title(), "Bullets") and !std.mem.eql(u8, model.rows[i].title(), "Prose")) continue;
        model_mod.update(model, .{ .open = i }, &effects);
        tree = try buildTree(arena, model);
        layout = try canvas.layoutWidgetTree(tree.root, bounds, nodes);
        try testing.expect(layout.nodes.len < canvas.max_layout_audit_nodes);
    }
}
