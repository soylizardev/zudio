const std = @import("std");
const gtk = @import("gtk");
const adw = @import("adw");

pub const MainWindow = struct {
    window: *adw.ApplicationWindow,

    pub fn create(app: *gtk.Application) *MainWindow {
        const win = adw.ApplicationWindow.new(app);

        // AdwApplicationWindow NO usa gtk_window_set_child.
        // El método correcto es adw_application_window_set_content.
        adw.ApplicationWindow.setContent(
            win,
            @ptrCast(@alignCast(gtk.Label.new("Zudio — Motor de audio listo. UI en construcción."))),
        );

        gtk.Window.setTitle(@ptrCast(win), "Zudio");
        gtk.Window.setDefaultSize(@ptrCast(win), 1100, 700);

        const self = std.heap.page_allocator.create(MainWindow) catch unreachable;
        self.* = .{ .window = win };
        return self;
    }

    pub fn present(self: *MainWindow) void {
        gtk.Window.present(@ptrCast(self.window));
    }

    pub fn destroy(self: *MainWindow) void {
        std.heap.page_allocator.destroy(self);
    }
};
