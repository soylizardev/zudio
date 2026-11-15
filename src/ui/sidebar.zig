const std = @import("std");
const gtk = @import("gtk");
const adw = @import("adw");

pub const NavItem = enum {
    todas,
    albumes,
    artistas,
    favoritos,
    anadidos_recientemente,
    listas,

    pub fn title(self: NavItem) [:0]const u8 {
        return switch (self) {
            .todas => "Todas",
            .albumes => "Álbumes",
            .artistas => "Artistas",
            .favoritos => "Favoritos",
            .anadidos_recientemente => "Añadidos recientemente",
            .listas => "Listas de reproducción",
        };
    }
};

pub const Built = struct {
    toolbar: *adw.ToolbarView,
    list_box: *gtk.ListBox,
};

pub fn build() Built {
    const toolbar = adw.ToolbarView.new();

    const header = adw.HeaderBar.new();
    adw.ToolbarView.addTopBar(toolbar, @ptrCast(@alignCast(header)));

    const list = gtk.ListBox.new();
    gtk.Widget.addCssClass(@ptrCast(@alignCast(list)), "navigation-sidebar");

    const items = [_]NavItem{
        .todas,
        .albumes,
        .artistas,
        .favoritos,
        .anadidos_recientemente,
        .listas,
    };

    for (items) |item| {
        const row = adw.ActionRow.new();
        adw.PreferencesRow.setTitle(@ptrCast(@alignCast(row)), item.title());
        gtk.ListBox.append(list, @ptrCast(@alignCast(row)));
    }

    adw.ToolbarView.setContent(toolbar, @ptrCast(@alignCast(list)));
    return .{ .toolbar = toolbar, .list_box = list };
}
