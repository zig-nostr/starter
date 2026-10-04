//! Wiring: opens the store, builds the relay fetcher, joins them into the one
//! `Data` the interface reads, and hands the window to the Native SDK.
//!
//! The plumbing is in `plumbing/`. The interface is `model.zig`, `display.zig`
//! and `app.native`, and it is yours to replace. This file only joins the two
//! halves, so it changes when the window or the relay list does.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

const model_mod = @import("model.zig");
const data_mod = @import("plumbing/data.zig");
const nip23 = @import("plumbing/nip23.zig");
const relays = @import("plumbing/relays.zig");
const store_mod = @import("plumbing/store.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// The model contract tool (`native check`) and the tests look for these names
// on the root file, so they are re-exported from where they are written.
pub const Model = model_mod.Model;
pub const Msg = model_mod.Msg;
pub const Effects = model_mod.Effects;
pub const update = model_mod.update;
pub const boot = model_mod.boot;

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

const app_name = "starter";
const canvas_label = "main-canvas";
const window_width: f32 = 880;
const window_height: f32 = 720;

// What the window is made of. `app.zon` describes the same window for the
// packaging and checking tools; this is the copy the running app uses, so the
// two have to agree.
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Reader canvas", .accessibility_label = "Reader", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Starter",
    .width = window_width,
    .height = window_height,
    .min_width = 640,
    .min_height = 480,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };

const ReaderApp = native_sdk.UiApp(Model, Msg);

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;

    // The store, the fetcher and `Data` live for the whole process and are
    // never torn down: the OS reclaims them at exit. A store that will not open
    // is not fatal. The app still starts, with an empty list and nothing to
    // fetch.
    const store: ?*store_mod.Store = store_mod.open(init.io, init.environ_map) catch |err| blk: {
        std.debug.print("starter: no local store ({s}); articles will not be saved\n", .{@errorName(err)});
        break :blk null;
    };
    const data: ?*data_mod.Data = if (store) |s| try buildData(gpa, s, init.environ_map) else null;

    // `create` allocates the app on the heap: the model holds the whole list,
    // which is too big to be passed around by value.
    const app_state = try ReaderApp.create(gpa, .{
        .name = app_name,
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .init_fx = boot,
        .update_fx = update,
        .markup = .{
            .source = app_markup,
            // Edit app.native while `native dev` runs and the window follows.
            // Debug only: a packaged app has no source tree to watch.
            .watch_path = if (builtin.mode == .Debug) "src/app.native" else null,
            .io = init.io,
        },
    });
    defer app_state.destroy();
    app_state.model.data = data;

    try runner.runWithOptions(app_state.app(), .{
        .app_name = app_name,
        .window_title = "Starter",
        .bundle_id = "com.zig-nostr.starter",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{
                .allowed_origins = &.{ "zero://inline", "zero://app" },
                // Links inside an article open in the system browser. The
                // toolkit's pattern language cannot say "any https URL", so
                // this lets through whatever `model.isSafeExternalUrl`
                // already passed, and that function is the real gate.
                .external_links = .{ .action = .open_system_browser, .allowed_urls = &.{"*"} },
            },
        },
    }, init);
}

/// Picks the relay list (`STARTER_RELAYS`, or the defaults), builds the fetcher
/// for the question in `nip23.wanted`, and wraps both in the `Data` the
/// interface reads. Starting the fetcher is `boot`'s job, so the first frame is
/// drawn from disk before any relay is asked.
fn buildData(gpa: std.mem.Allocator, store: *store_mod.Store, environ: *const std.process.Environ.Map) !*data_mod.Data {
    var slots: [relays.max_relays][]const u8 = undefined;
    var urls: []const []const u8 = &relays.default_urls;
    if (environ.get(relays.env_name)) |text| {
        const listed = relays.parseList(text, &slots);
        if (listed.len > 0) {
            urls = listed;
        } else {
            std.debug.print("starter: {s} has no usable relay URL; using the defaults\n", .{relays.env_name});
        }
    }
    const fetcher = try gpa.create(relays.Fetcher);
    fetcher.* = relays.Fetcher.init(store, try gpa.dupe([]const u8, urls), nip23.wanted);
    const data = try gpa.create(data_mod.Data);
    data.* = data_mod.Data.init(store, fetcher);
    return data;
}

test {
    _ = @import("display.zig");
    _ = @import("plumbing/data.zig");
    _ = @import("plumbing/nip23.zig");
    _ = @import("plumbing/relays.zig");
    _ = @import("plumbing/store.zig");
    _ = @import("plumbing/testkit.zig");
    _ = @import("plumbing/testrelay.zig");
    _ = @import("tests.zig");
}
