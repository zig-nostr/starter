//! The build graph. The Native SDK's `addAppArtifacts` wires the standard app
//! build (the executable, `zig build run`, `zig build test`, and the
//! -Dautomation / -Doptimize flags); the only thing added here is the `nostr`
//! library, linked into both the app and its tests.

const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("native_sdk", .{});
    const app = native_sdk.addAppArtifacts(b, dep, .{ .name = "starter" });

    linkNostr(b, app.exe.root_module);
    linkNostr(b, app.tests.root_module);
}

/// Adds the `nostr` import to `mod`, compiling the library (and its bundled
/// secp256k1 and LMDB) for the module's own target and optimize mode.
fn linkNostr(b: *std.Build, mod: *std.Build.Module) void {
    const nostr = b.dependency("nostr", .{
        .target = mod.resolved_target.?,
        .optimize = libraryOptimize(mod.optimize.?),
    });
    mod.addImport("nostr", nostr.module("nostr"));
}

/// The library is built one notch safer than the app that links it.
///
/// ReleaseFast compiles Zig's bounds and overflow checks out, and everything
/// `nostr` parses is bytes a stranger chose: a relay's frames, an event's
/// JSON, its tags. So a ReleaseFast app gets a ReleaseSafe library, and Debug
/// and ReleaseSafe are left alone.
fn libraryOptimize(app: std.builtin.OptimizeMode) std.builtin.OptimizeMode {
    return switch (app) {
        .ReleaseFast, .ReleaseSmall => .ReleaseSafe,
        .Debug, .ReleaseSafe => app,
    };
}
