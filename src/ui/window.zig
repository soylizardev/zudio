const std = @import("std");
const gtk = @import("gtk");
const adw = @import("adw");
const glib = @import("glib");
const sidebar = @import("sidebar.zig");
const content = @import("content.zig");
const player_bar = @import("player_bar.zig");
const audio_controller = @import("audio_controller.zig");
const library = @import("../library.zig");
const player = @import("../player.zig");
const favorites = @import("../favorites.zig");

pub const MainWindow = struct {
    window: *adw.ApplicationWindow,
    split_view: *adw.NavigationSplitView,
    player_bar_ref: *player_bar.PlayerBar,
    library: *library.Library,
    controller: *audio_controller.AudioController,
    player_ref: *player.Player,
    favorites: *favorites.Favorites,
    current_page: ?content.PageBuilt = null,

    pub fn create(
        app: *gtk.Application,
        lib: *library.Library,
        p: *player.Player,
        allocator: std.mem.Allocator,
        io: std.Io,
        fav: *favorites.Favorites,
    ) *MainWindow {
        const win = adw.ApplicationWindow.new(app);
        gtk.Window.setDefaultSize(@ptrCast(win), 1100, 700);

        const split = adw.NavigationSplitView.new();
        adw.NavigationSplitView.setMinSidebarWidth(split, 200.0);
        adw.NavigationSplitView.setMaxSidebarWidth(split, 280.0);

        const ctrl = audio_controller.AudioController.init(allocator, p, io) catch unreachable;

        const sb = sidebar.build();
        const sb_page = adw.NavigationPage.new(@ptrCast(@alignCast(sb.toolbar)), "Zudio");
        adw.NavigationSplitView.setSidebar(split, sb_page);

        const self = std.heap.page_allocator.create(MainWindow) catch unreachable;
        self.* = .{
            .window = win,
            .split_view = split,
            .player_bar_ref = undefined,
            .library = lib,
            .controller = ctrl,
            .player_ref = p,
            .favorites = fav,
            .current_page = null,
        };

        self.current_page = content.buildPage(
            .todas,
            lib,
            fav,
            @ptrCast(@alignCast(self)),
            onRowPressed,
        );
        adw.NavigationSplitView.setContent(split, self.current_page.?.page);

        const pb = player_bar.PlayerBar.build(ctrl, p, fav, onFavoriteChanged, @ptrCast(@alignCast(self)));
        self.player_bar_ref = pb;

        const bottom = gtk.Box.new(gtk.Orientation.vertical, 0);
        const sep = gtk.Separator.new(gtk.Orientation.horizontal);
        gtk.Box.append(bottom, @ptrCast(@alignCast(sep)));
        gtk.Box.append(bottom, @ptrCast(@alignCast(pb.root)));

        const root = gtk.Box.new(gtk.Orientation.vertical, 0);
        gtk.Widget.setVexpand(@ptrCast(@alignCast(split)), 1);
        gtk.Box.append(root, @ptrCast(@alignCast(split)));
        gtk.Box.append(root, @ptrCast(@alignCast(bottom)));

        adw.ApplicationWindow.setContent(win, @ptrCast(@alignCast(root)));

        _ = gtk.ListBox.signals.row_selected.connect(
            sb.list_box,
            *MainWindow,
            onNavSelected,
            self,
            .{},
        );

        _ = glib.timeoutAdd(200, tickCallback, self);

        return self;
    }

    pub fn present(self: *MainWindow) void {
        gtk.Window.present(@ptrCast(self.window));
    }

    pub fn destroy(self: *MainWindow) void {
        if (self.current_page) |*p| p.deinit();
        self.controller.shutdown();
        std.heap.page_allocator.destroy(self);
    }
};

fn tickCallback(data: ?*anyopaque) callconv(.c) c_int {
    const self: *MainWindow = @ptrCast(@alignCast(data.?));
    self.player_bar_ref.tick();
    return 1;
}

/// Llamada por el PlayerBar cuando cambia un favorito desde la barra.
/// Actualiza el botón de la fila correspondiente en la lista actual, al instante.
pub fn onFavoriteChanged(ctx: *anyopaque, path: []const u8, is_fav: bool) void {
    const self: *MainWindow = @ptrCast(@alignCast(ctx));
    if (self.current_page) |*p| {
        if (p.fav_buttons.get(path)) |btn| {
            const icon: [:0]const u8 = if (is_fav) "starred-symbolic" else "non-starred-symbolic";
            gtk.Button.setIconName(btn, icon);
        }
    }
}

fn onNavSelected(
    list: *gtk.ListBox,
    row: ?*gtk.ListBoxRow,
    self: *MainWindow,
) callconv(.c) void {
    _ = list;
    const r = row orelse return;
    const idx: c_int = gtk.ListBoxRow.getIndex(r);
    const item: sidebar.NavItem = switch (idx) {
        0 => .todas,
        1 => .albumes,
        2 => .artistas,
        3 => .favoritos,
        4 => .anadidos_recientemente,
        5 => .listas,
        else => return,
    };

    // Liberar el mapa de la vista anterior antes de crear la nueva.
    if (self.current_page) |*p| p.deinit();

    self.current_page = content.buildPage(
        item,
        self.library,
        self.favorites,
        @ptrCast(@alignCast(self)),
        onRowPressed,
    );
    adw.NavigationSplitView.setContent(self.split_view, self.current_page.?.page);
}

fn onRowPressed(
    gesture: *gtk.GestureClick,
    n_press: c_int,
    x: f64,
    y: f64,
    ctx: *content.RowCtx,
) callconv(.c) void {
    _ = gesture;
    _ = n_press;
    _ = x;
    _ = y;

    if (ctx.suppressed) {
        ctx.suppressed = false;
        return;
    }

    const self: *MainWindow = @ptrCast(@alignCast(ctx.app));
    if (ctx.idx >= self.library.tracks.len) return;

    // Establecer la cola activa según la vista actual antes de reproducir.
    if (self.current_page) |*p| {
        self.controller.setQueue(p.queue);
    }

    self.controller.play(ctx.idx);
}
