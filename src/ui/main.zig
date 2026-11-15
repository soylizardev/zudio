const std = @import("std");
const gtk = @import("gtk");
const adw = @import("adw");
const gio = @import("gio");
const window = @import("window.zig");

fn onActivate(app: *gio.Application, _: ?*anyopaque) callconv(.c) void {
    const win = window.MainWindow.create(@ptrCast(app));
    win.present();
}

pub fn run(app_id: [:0]const u8) !void {
    adw.init();

    const app = gtk.Application.new(app_id, .{});
    defer gtk.Application.unref(app);

    _ = gio.Application.signals.activate.connect(
        @as(*gio.Application, @ptrCast(app)),  // p_instance
        ?*anyopaque,                            // P_Data: puntero opaco, no void
        onActivate,                             // callback
        null,                                   // p_data
        .{},                                    // p_options
    );

    const as_gio_app: *gio.Application = @ptrCast(app);
    const status = gio.Application.run(as_gio_app, 0, null);
    _ = status;
}
