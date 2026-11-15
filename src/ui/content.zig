const std = @import("std");
const gtk = @import("gtk");
const adw = @import("adw");
const glib = @import("glib");
const library = @import("../library.zig");
const sidebar = @import("sidebar.zig");
const favorites = @import("../favorites.zig");

pub const RowPressedFn = *const fn (*gtk.GestureClick, c_int, f64, f64, *RowCtx) callconv(.c) void;

pub const RowCtx = struct {
    app: *anyopaque,
    idx: usize,
    fav: *favorites.Favorites,
    track_path: []const u8,
    suppressed: bool = false,
};

pub const PageBuilt = struct {
    page: *adw.NavigationPage,
    fav_buttons: std.StringHashMapUnmanaged(*gtk.Button) = .empty,

    pub fn deinit(self: *PageBuilt) void {
        self.fav_buttons.deinit(std.heap.page_allocator);
    }
};

const TrackListResult = struct {
    scroll: *gtk.ScrolledWindow,
    list_box: *gtk.ListBox,
};

const ToolbarResult = struct {
    toolbar: *adw.ToolbarView,
    list_box: ?*gtk.ListBox = null,
};

pub fn buildPage(
    item: sidebar.NavItem,
    lib: ?*library.Library,
    fav: *favorites.Favorites,
    activation_ctx: ?*anyopaque,
    on_pressed: ?RowPressedFn,
) PageBuilt {
    var fav_buttons: std.StringHashMapUnmanaged(*gtk.Button) = .empty;
    const tb = buildToolbar(item, lib, fav, activation_ctx, on_pressed, &fav_buttons);
    const page = adw.NavigationPage.new(@ptrCast(@alignCast(tb.toolbar)), item.title());
    return .{ .page = page, .fav_buttons = fav_buttons };
}

fn buildToolbar(
    item: sidebar.NavItem,
    lib: ?*library.Library,
    fav: *favorites.Favorites,
    activation_ctx: ?*anyopaque,
    on_pressed: ?RowPressedFn,
    fav_buttons: *std.StringHashMapUnmanaged(*gtk.Button),
) ToolbarResult {
    const toolbar = adw.ToolbarView.new();
    const header = adw.HeaderBar.new();
    adw.ToolbarView.addTopBar(toolbar, @ptrCast(@alignCast(header)));

    switch (item) {
        .todas, .anadidos_recientemente => {
            if (lib) |l| {
                if (l.tracks.len > 0) {
                    const tl = buildTrackList(l.tracks, fav, activation_ctx, on_pressed, fav_buttons);
                    adw.ToolbarView.setContent(toolbar, @ptrCast(@alignCast(tl.scroll)));
                    return .{ .toolbar = toolbar, .list_box = tl.list_box };
                }
            }
            showEmptyState(toolbar, item);
        },
        .favoritos => {
            if (lib) |l| {
                const alloc = std.heap.page_allocator;
                var filtered: std.ArrayListUnmanaged(library.Track) = .empty;
                defer filtered.deinit(alloc);
                for (l.tracks) |t| {
                    if (fav.isFavorite(t.path)) {
                        filtered.append(alloc, t) catch {};
                    }
                }
                if (filtered.items.len > 0) {
                    const tl = buildTrackList(filtered.items, fav, activation_ctx, on_pressed, fav_buttons);
                    adw.ToolbarView.setContent(toolbar, @ptrCast(@alignCast(tl.scroll)));
                    return .{ .toolbar = toolbar, .list_box = tl.list_box };
                }
            }
            showEmptyState(toolbar, item);
        },
        else => showEmptyState(toolbar, item),
    }
    return .{ .toolbar = toolbar, .list_box = null };
}

fn showEmptyState(toolbar: *adw.ToolbarView, item: sidebar.NavItem) void {
    const status = adw.StatusPage.new();
    adw.StatusPage.setIconName(status, iconFor(item));
    adw.StatusPage.setTitle(status, item.title());
    adw.StatusPage.setDescription(status, descriptionFor(item));
    adw.ToolbarView.setContent(toolbar, @ptrCast(@alignCast(status)));
}

fn iconFor(item: sidebar.NavItem) [:0]const u8 {
    return switch (item) {
        .todas => "music-note-symbolic",
        .albumes => "media-optical-symbolic",
        .artistas => "avatar-default-symbolic",
        .favoritos => "starred-symbolic",
        .anadidos_recientemente => "document-open-recent-symbolic",
        .listas => "view-list-symbolic",
    };
}

fn descriptionFor(item: sidebar.NavItem) [:0]const u8 {
    return switch (item) {
        .todas => "Todas las pistas de tu biblioteca.",
        .albumes => "Explora tu música agrupada por álbum. Próximamente.",
        .artistas => "Explora tu música agrupada por artista. Próximamente.",
        .favoritos => "Aún no tienes favoritos. Marca pistas con la estrella.",
        .anadidos_recientemente => "Las pistas añadidas recientemente.",
        .listas => "Tus listas de reproducción personalizadas. Próximamente.",
    };
}

fn buildTrackList(
    tracks: []const library.Track,
    fav: *favorites.Favorites,
    activation_ctx: ?*anyopaque,
    on_pressed: ?RowPressedFn,
    fav_buttons: *std.StringHashMapUnmanaged(*gtk.Button),
) TrackListResult {
    const scroll = gtk.ScrolledWindow.new();
    gtk.ScrolledWindow.setPolicy(scroll, .automatic, .automatic);

    const list = gtk.ListBox.new();
    gtk.Widget.addCssClass(@ptrCast(@alignCast(list)), "boxed-list");
    gtk.Widget.setMarginTop(@ptrCast(@alignCast(list)), 12);
    gtk.Widget.setMarginBottom(@ptrCast(@alignCast(list)), 12);
    gtk.Widget.setMarginStart(@ptrCast(@alignCast(list)), 12);
    gtk.Widget.setMarginEnd(@ptrCast(@alignCast(list)), 12);

    for (tracks, 0..) |track, idx| {
        const row = adw.ActionRow.new();

        const title_str: []const u8 = track.info.title orelse std.fs.path.basename(track.path);
        const title_z = std.heap.page_allocator.dupeZ(u8, title_str) catch continue;
        defer std.heap.page_allocator.free(title_z);
        adw.PreferencesRow.setTitle(@ptrCast(@alignCast(row)), title_z.ptr);

        var buf: [512]u8 = undefined;
        const subtitle: []const u8 = blk: {
            const artist = track.info.artist;
            const album = track.info.album;
            if (artist != null and album != null) {
                break :blk std.fmt.bufPrint(&buf, "{s} — {s}", .{ artist.?, album.? }) catch track.path;
            }
            if (artist) |a| break :blk a;
            if (album) |al| break :blk al;
            break :blk track.path;
        };
        const subtitle_z = std.heap.page_allocator.dupeZ(u8, subtitle) catch continue;
        defer std.heap.page_allocator.free(subtitle_z);
        adw.ActionRow.setSubtitle(row, subtitle_z.ptr);

        const ctx = std.heap.page_allocator.create(RowCtx) catch continue;
        ctx.* = .{
            .app = activation_ctx orelse continue,
            .idx = idx,
            .fav = fav,
            .track_path = track.path,
        };

        const is_fav = fav.isFavorite(track.path);
        const star_icon: [:0]const u8 = if (is_fav) "starred-symbolic" else "non-starred-symbolic";
        const fav_btn = gtk.Button.newFromIconName(star_icon);
        gtk.Widget.addCssClass(@ptrCast(@alignCast(fav_btn)), "flat");
        gtk.Widget.addCssClass(@ptrCast(@alignCast(fav_btn)), "circular");
        adw.ActionRow.addSuffix(row, @ptrCast(@alignCast(fav_btn)));

        // Registrar el botón en el mapa para que la barra pueda actualizarlo.
        fav_buttons.put(std.heap.page_allocator, track.path, fav_btn) catch {};

        const btn_gesture = gtk.GestureClick.new();
        gtk.GestureSingle.setButton(@ptrCast(@alignCast(btn_gesture)), 1);
        _ = gtk.GestureClick.signals.pressed.connect(
            btn_gesture,
            *RowCtx,
            onFavoritePressed,
            ctx,
            .{},
        );
        gtk.Widget.addController(@ptrCast(@alignCast(fav_btn)), @ptrCast(@alignCast(btn_gesture)));

        _ = gtk.Button.signals.clicked.connect(fav_btn, *RowCtx, onFavoriteClicked, ctx, .{});

        if (activation_ctx != null and on_pressed != null) {
            const gesture = gtk.GestureClick.new();
            gtk.GestureSingle.setButton(@ptrCast(@alignCast(gesture)), 1);
            _ = gtk.GestureClick.signals.released.connect(
                gesture,
                *RowCtx,
                on_pressed.?,
                ctx,
                .{},
            );
            gtk.Widget.addController(@ptrCast(@alignCast(row)), @ptrCast(@alignCast(gesture)));
        }

        gtk.ListBox.append(list, @ptrCast(@alignCast(row)));
    }

    gtk.ScrolledWindow.setChild(scroll, @ptrCast(@alignCast(list)));
    return .{ .scroll = scroll, .list_box = list };
}

fn onFavoritePressed(
    gesture: *gtk.GestureClick,
    n: c_int,
    x: f64,
    y: f64,
    ctx: *RowCtx,
) callconv(.c) void {
    _ = gesture;
    _ = n;
    _ = x;
    _ = y;
    ctx.suppressed = true;
    _ = glib.timeoutAdd(500, resetSuppressed, ctx);
}

fn resetSuppressed(data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *RowCtx = @ptrCast(@alignCast(data.?));
    ctx.suppressed = false;
    return 0;
}

fn onFavoriteClicked(btn: *gtk.Button, ctx: *RowCtx) callconv(.c) void {
    const now_fav = ctx.fav.toggle(ctx.track_path);
    const new_icon: [:0]const u8 = if (now_fav) "starred-symbolic" else "non-starred-symbolic";
    gtk.Button.setIconName(btn, new_icon);
    ctx.fav.save();
}
