const std = @import("std");
const gtk = @import("gtk");
const adw = @import("adw");
const gio = @import("gio");
const window = @import("window.zig");
const library = @import("../library.zig");
const player = @import("../player.zig");
const favorites = @import("../favorites.zig");

pub const RunContext = struct {
    lib: *library.Library,
    player: *player.Player,
    io: std.Io,
    favorites: *favorites.Favorites,
};

fn onActivate(app: *gio.Application, ctx: *RunContext) callconv(.c) void {
    const win = window.MainWindow.create(
        @ptrCast(app),
        ctx.lib,
        ctx.player,
        std.heap.page_allocator,
        ctx.io,
        ctx.favorites,
    );
    win.present();
}

pub fn run(
    app_id: [:0]const u8,
    lib: *library.Library,
    p: *player.Player,
    io: std.Io,
    fav: *favorites.Favorites,
) !void {
    adw.init();

    const app = gtk.Application.new(app_id, .{});
    defer gtk.Application.unref(app);

    var ctx = RunContext{ .lib = lib, .player = p, .io = io, .favorites = fav };

    _ = gio.Application.signals.activate.connect(
        @as(*gio.Application, @ptrCast(app)),
        *RunContext,
        onActivate,
        &ctx,
        .{},
    );

    const as_gio_app: *gio.Application = @ptrCast(app);
    _ = gio.Application.run(as_gio_app, 0, null);
}
