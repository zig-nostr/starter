//! Wiring: describes the window and hands the app to the Native SDK.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

pub const Effects = native_sdk.Effects(Msg);

/// Everything that can happen. Nothing does yet.
pub const Msg = union(enum) {
    idle,

    pub const view_unbound = .{"idle"};
};

/// Everything the window shows. Nothing yet.
pub const Model = struct {};

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    _ = model;
    _ = fx;
    switch (msg) {
        .idle => {},
    }
}

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
    const app_state = try ReaderApp.create(std.heap.page_allocator, .{
        .name = app_name,
        .scene = shell_scene,
        .canvas_label = canvas_label,
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
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("articles.zig");
    _ = @import("store.zig");
    _ = @import("testkit.zig");
    _ = @import("tests.zig");
}
