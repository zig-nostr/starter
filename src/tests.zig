//! The app tested the way it runs: the real markup built into a widget tree,
//! with no window and no network.

const std = @import("std");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;

const AppMarkup = canvas.MarkupView(Model, Msg);

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

fn hasText(widget: canvas.Widget, text: []const u8) bool {
    if (widget.kind == .text and std.mem.eql(u8, widget.text, text)) return true;
    for (widget.children) |child| {
        if (hasText(child, text)) return true;
    }
    return false;
}

test "the window shows its name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model: Model = .{};
    const tree = try buildTree(arena_state.allocator(), &model);
    try testing.expect(hasText(tree.root, "Starter"));
}

test "the nostr library is linked and speaks the protocol" {
    // A fixed public key, encoded and decoded, is enough to know the library
    // built for this target and its bundled secp256k1 and LMDB came with it.
    const pubkey: [32]u8 = @splat(0x22);
    const npub = try nostr.nip19.encodeNpub(testing.allocator, pubkey);
    defer testing.allocator.free(npub);
    try testing.expect(std.mem.startsWith(u8, npub, "npub1"));
    try testing.expectEqualSlices(u8, &pubkey, &try nostr.nip19.decodeNpub(testing.allocator, npub));
}
