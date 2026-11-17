const std = @import("std");
const gtk = @import("gtk");
const adw = @import("adw");
const gdk = @import("gdk");
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

const FavCtx = struct {
    fav: *favorites.Favorites,
    track_path: []const u8,
};

const TrackEntry = struct {
    track: *const library.Track,
    index: usize,
    row: ?*gtk.ListBoxRow = null,
};

const SortMode = enum { title, artist, album, duration };

// Estado interno de la vista
const ViewState = struct {
    allocator: std.mem.Allocator,
    all_entries: std.ArrayListUnmanaged(TrackEntry) = .empty,
    visible_entries: std.ArrayListUnmanaged(TrackEntry) = .empty,
    list_box: *gtk.ListBox,
    scroll: *gtk.ScrolledWindow,
    fav_buttons: std.StringHashMapUnmanaged(*gtk.Button) = .empty,
    row_ctxs: std.ArrayListUnmanaged(*RowCtx) = .empty,
    fav_ctxs: std.ArrayListUnmanaged(*FavCtx) = .empty,
    fav: *favorites.Favorites,
    activation_ctx: ?*anyopaque,
    on_pressed: ?RowPressedFn,
    sort_mode: SortMode = .title,
    query_buf: [256]u8 = undefined,
    query_len: usize = 0,
    queue: std.ArrayListUnmanaged(usize) = .empty,

    pub fn deinit(self: *ViewState) void {
        for (self.row_ctxs.items) |ptr| self.allocator.destroy(ptr);
        self.row_ctxs.deinit(self.allocator);
        
        for (self.fav_ctxs.items) |ptr| self.allocator.destroy(ptr);
        self.fav_ctxs.deinit(self.allocator);

        self.fav_buttons.deinit(self.allocator);
        self.all_entries.deinit(self.allocator);
        self.visible_entries.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

pub const PageBuilt = struct {
    page: *adw.NavigationPage,
    view_state: *ViewState,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PageBuilt) void {
        self.view_state.deinit();
    }
};

pub fn buildPage(
    item: sidebar.NavItem,
    lib: ?*library.Library,
    fav: *favorites.Favorites,
    activation_ctx: ?*anyopaque,
    on_pressed: ?RowPressedFn,
) PageBuilt {
    const allocator = std.heap.page_allocator;
    
    const scroll = gtk.ScrolledWindow.new();
    gtk.ScrolledWindow.setPolicy(scroll, .automatic, .automatic);
    const list = gtk.ListBox.new();
    gtk.Widget.addCssClass(@ptrCast(@alignCast(list)), "boxed-list");
    gtk.Widget.setMarginTop(@ptrCast(@alignCast(list)), 12);
    gtk.Widget.setMarginBottom(@ptrCast(@alignCast(list)), 12);
    gtk.Widget.setMarginStart(@ptrCast(@alignCast(list)), 12);
    gtk.Widget.setMarginEnd(@ptrCast(@alignCast(list)), 12);
    gtk.ScrolledWindow.setChild(scroll, @ptrCast(@alignCast(list)));

    const vs = allocator.create(ViewState) catch unreachable;
    vs.* = .{
        .allocator = allocator,
        .list_box = list,
        .scroll = scroll,
        .fav = fav,
        .activation_ctx = activation_ctx,
        .on_pressed = on_pressed,
    };

    var has_tracks = false;
    if (lib) |l| {
        switch (item) {
            .todas, .anadidos_recientemente => {
                for (l.tracks, 0..) |*t, i| {
                    vs.all_entries.append(allocator, .{ .track = t, .index = i }) catch {};
                }
                has_tracks = l.tracks.len > 0;
            },
            .favoritos => {
                for (l.tracks, 0..) |*t, i| {
                    if (fav.isFavorite(t.path)) {
                        vs.all_entries.append(allocator, .{ .track = t, .index = i }) catch {};
                    }
                }
                has_tracks = vs.all_entries.items.len > 0;
            },
            else => {},
        }
    }

    const toolbar = adw.ToolbarView.new();
    const header = adw.HeaderBar.new();
    adw.ToolbarView.addTopBar(toolbar, @ptrCast(@alignCast(header)));

    if (has_tracks) {
        // 1. Ordenar inicialmente y construir la lista
        sortEntries(vs);
        buildTrackList(vs);
        applyFilter(vs, "");

        // 2. Añadir Buscador
        const search = gtk.SearchEntry.new();
        gtk.SearchEntry.setPlaceholderText(search, "Buscar...");
        gtk.Widget.setSizeRequest(@ptrCast(@alignCast(search)), 240, -1);
        adw.HeaderBar.packStart(header, @ptrCast(@alignCast(search)));
        gtk.SearchEntry.setSearchDelay(search, 100);
        _ = gtk.SearchEntry.signals.search_changed.connect(search, *ViewState, onSearchChanged, vs, .{});

        // 3. Añadir Botón de Ordenar (Popover)
        const menu_btn = gtk.MenuButton.new();
        gtk.MenuButton.setIconName(menu_btn, "view-sort-descending-symbolic");
        gtk.Widget.setTooltipText(@ptrCast(@alignCast(menu_btn)), "Ordenar por...");
        gtk.Widget.addCssClass(@ptrCast(@alignCast(menu_btn)), "flat");

        const popover = gtk.Popover.new();
        const box = gtk.Box.new(gtk.Orientation.vertical, 4);
        gtk.Widget.setMarginTop(@ptrCast(@alignCast(box)), 8);
        gtk.Widget.setMarginBottom(@ptrCast(@alignCast(box)), 8);
        gtk.Widget.setMarginStart(@ptrCast(@alignCast(box)), 8);
        gtk.Widget.setMarginEnd(@ptrCast(@alignCast(box)), 8);

        const btn_title = gtk.Button.newWithLabel("Título");
        gtk.Widget.addCssClass(@ptrCast(@alignCast(btn_title)), "flat");
        _ = gtk.Button.signals.clicked.connect(btn_title, *ViewState, onSortTitleClicked, vs, .{});
        gtk.Box.append(box, @ptrCast(@alignCast(btn_title)));

        const btn_artist = gtk.Button.newWithLabel("Artista");
        gtk.Widget.addCssClass(@ptrCast(@alignCast(btn_artist)), "flat");
        _ = gtk.Button.signals.clicked.connect(btn_artist, *ViewState, onSortArtistClicked, vs, .{});
        gtk.Box.append(box, @ptrCast(@alignCast(btn_artist)));

        const btn_album = gtk.Button.newWithLabel("Álbum");
        gtk.Widget.addCssClass(@ptrCast(@alignCast(btn_album)), "flat");
        _ = gtk.Button.signals.clicked.connect(btn_album, *ViewState, onSortAlbumClicked, vs, .{});
        gtk.Box.append(box, @ptrCast(@alignCast(btn_album)));

        const btn_duration = gtk.Button.newWithLabel("Duración");
        gtk.Widget.addCssClass(@ptrCast(@alignCast(btn_duration)), "flat");
        _ = gtk.Button.signals.clicked.connect(btn_duration, *ViewState, onSortDurationClicked, vs, .{});
        gtk.Box.append(box, @ptrCast(@alignCast(btn_duration)));

        gtk.Popover.setChild(popover, @ptrCast(@alignCast(box)));
        gtk.MenuButton.setPopover(menu_btn, popover);
        adw.HeaderBar.packEnd(header, @ptrCast(@alignCast(menu_btn)));

        adw.ToolbarView.setContent(toolbar, @ptrCast(@alignCast(scroll)));
    } else {
        showEmptyState(toolbar, item);
    }

    const page = adw.NavigationPage.new(@ptrCast(@alignCast(toolbar)), item.title());
    return .{ .page = page, .view_state = vs, .allocator = allocator };
}

fn sortEntries(vs: *ViewState) void {
    const sortFn = struct {
        fn lessThan(mode: SortMode, a: TrackEntry, b: TrackEntry) bool {
            switch (mode) {
                .title => {
                    const at = a.track.info.title orelse "";
                    const bt = b.track.info.title orelse "";
                    return std.mem.lessThan(u8, at, bt);
                },
                .artist => {
                    const aa = a.track.info.artist orelse "";
                    const ba = b.track.info.artist orelse "";
                    return std.mem.lessThan(u8, aa, ba);
                },
                .album => {
                    const aa = a.track.info.album orelse "";
                    const ba = b.track.info.album orelse "";
                    return std.mem.lessThan(u8, aa, ba);
                },
                .duration => {
                    return getDuration(a.track) < getDuration(b.track);
                },
            }
        }
    }.lessThan;
    std.mem.sort(TrackEntry, vs.all_entries.items, vs.sort_mode, sortFn);
}

fn getDuration(track: *const library.Track) f64 {
    if (track.info.sample_rate == 0) return 0;
    return @as(f64, @floatFromInt(track.info.duration_frames)) / @as(f64, @floatFromInt(track.info.sample_rate));
}

fn rebuildList(vs: *ViewState) void {
    // Destruir contextos viejos
    for (vs.row_ctxs.items) |ptr| vs.allocator.destroy(ptr);
    vs.row_ctxs.clearRetainingCapacity();
    for (vs.fav_ctxs.items) |ptr| vs.allocator.destroy(ptr);
    vs.fav_ctxs.clearRetainingCapacity();
    vs.fav_buttons.clearRetainingCapacity();

    // Eliminar widgets visuales
    var child = gtk.Widget.getFirstChild(@ptrCast(@alignCast(vs.list_box)));
    while (child != null) {
        gtk.ListBox.remove(vs.list_box, @ptrCast(@alignCast(child)));
        child = gtk.Widget.getFirstChild(@ptrCast(@alignCast(vs.list_box)));
    }
    
    // Volver a construir
    buildTrackList(vs);
}

fn buildTrackList(vs: *ViewState) void {
    for (vs.all_entries.items) |*entry| {
        const track = entry.track.*;
        const row = adw.ActionRow.new();

        const title_str: []const u8 = track.info.title orelse std.fs.path.basename(track.path);
        const title_z = vs.allocator.dupeZ(u8, title_str) catch continue;
        defer vs.allocator.free(title_z);
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
        const subtitle_z = vs.allocator.dupeZ(u8, subtitle) catch continue;
        defer vs.allocator.free(subtitle_z);
        adw.ActionRow.setSubtitle(row, subtitle_z.ptr);

        const img = gtk.Image.new();
        gtk.Image.setPixelSize(img, 40);
        var cover_loaded = false;
        if (track.info.cover_data) |data| {
            const bytes_obj = glib.Bytes.new(@ptrCast(data.ptr), data.len);
            defer glib.Bytes.unref(bytes_obj);
            const texture_opt = gdk.Texture.newFromBytes(bytes_obj, null);
            if (texture_opt) |texture| {
                gtk.Image.setFromPaintable(img, @ptrCast(@alignCast(texture)));
                cover_loaded = true;
            }
        }
        if (!cover_loaded) {
            gtk.Image.setFromIconName(img, "media-optical-symbolic");
            gtk.Widget.addCssClass(@ptrCast(@alignCast(img)), "dim-label");
        }
        adw.ActionRow.addPrefix(row, @ptrCast(@alignCast(img)));

        const ctx = vs.allocator.create(RowCtx) catch continue;
        ctx.* = .{ .app = vs.activation_ctx orelse continue, .idx = entry.index, .fav = vs.fav, .track_path = track.path };
        vs.row_ctxs.append(vs.allocator, ctx) catch {};

        const is_fav = vs.fav.isFavorite(track.path);
        const star_icon: [:0]const u8 = if (is_fav) "starred-symbolic" else "non-starred-symbolic";
        const fav_btn = gtk.Button.newFromIconName(star_icon);
        gtk.Widget.addCssClass(@ptrCast(@alignCast(fav_btn)), "flat");
        gtk.Widget.addCssClass(@ptrCast(@alignCast(fav_btn)), "circular");
        adw.ActionRow.addSuffix(row, @ptrCast(@alignCast(fav_btn)));

        vs.fav_buttons.put(vs.allocator, track.path, fav_btn) catch {};

        const fctx = vs.allocator.create(FavCtx) catch continue;
        fctx.* = .{ .fav = vs.fav, .track_path = track.path };
        vs.fav_ctxs.append(vs.allocator, fctx) catch {};

        _ = gtk.Button.signals.clicked.connect(fav_btn, *FavCtx, onFavoriteClicked, fctx, .{});

        if (vs.activation_ctx != null and vs.on_pressed != null) {
            const gesture = gtk.GestureClick.new();
            gtk.GestureSingle.setButton(@ptrCast(@alignCast(gesture)), 1);
            _ = gtk.GestureClick.signals.released.connect(gesture, *RowCtx, vs.on_pressed.?, ctx, .{});
            gtk.Widget.addController(@ptrCast(@alignCast(row)), @ptrCast(@alignCast(gesture)));
        }

        gtk.ListBox.append(vs.list_box, @ptrCast(@alignCast(row)));
        entry.row = @ptrCast(@alignCast(row));
    }
}

fn updateQueue(vs: *ViewState) void {
    vs.queue.clearRetainingCapacity();
    for (vs.visible_entries.items) |entry| {
        vs.queue.append(vs.allocator, entry.index) catch {};
    }
}

fn onSearchChanged(search: *gtk.SearchEntry, vs: *ViewState) callconv(.c) void {
    const text_z = gtk.Editable.getText(@ptrCast(@alignCast(search)));
    const query = std.mem.span(text_z);
    const len = @min(query.len, vs.query_buf.len);
    @memcpy(vs.query_buf[0..len], query[0..len]);
    vs.query_len = len;
    applyFilter(vs, vs.query_buf[0..vs.query_len]);
}

fn applyFilter(vs: *ViewState, query: []const u8) void {
    vs.visible_entries.clearRetainingCapacity();

    for (vs.all_entries.items) |entry| {
        const t = entry.track;
        var matches = true;
        if (query.len > 0) {
            const title = t.info.title orelse "";
            const artist = t.info.artist orelse "";
            const album = t.info.album orelse "";
            matches = containsIgnoreCase(title, query) or
                      containsIgnoreCase(artist, query) or
                      containsIgnoreCase(album, query);
        }
        
        if (entry.row) |row| {
            gtk.Widget.setVisible(@ptrCast(@alignCast(row)), if (matches) 1 else 0);
        }
        
        if (matches) {
            vs.visible_entries.append(vs.allocator, entry) catch {};
        }
    }
    updateQueue(vs);
}

fn refreshWithSort(vs: *ViewState) void {
    sortEntries(vs);
    rebuildList(vs);
    applyFilter(vs, vs.query_buf[0..vs.query_len]);
}

fn onSortTitleClicked(btn: *gtk.Button, vs: *ViewState) callconv(.c) void {
    _ = btn; vs.sort_mode = .title; refreshWithSort(vs);
}
fn onSortArtistClicked(btn: *gtk.Button, vs: *ViewState) callconv(.c) void {
    _ = btn; vs.sort_mode = .artist; refreshWithSort(vs);
}
fn onSortAlbumClicked(btn: *gtk.Button, vs: *ViewState) callconv(.c) void {
    _ = btn; vs.sort_mode = .album; refreshWithSort(vs);
}
fn onSortDurationClicked(btn: *gtk.Button, vs: *ViewState) callconv(.c) void {
    _ = btn; vs.sort_mode = .duration; refreshWithSort(vs);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |c_needle, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c_needle)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
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

fn onFavoriteClicked(btn: *gtk.Button, ctx: *FavCtx) callconv(.c) void {
    const now_fav = ctx.fav.toggle(ctx.track_path);
    const new_icon: [:0]const u8 = if (now_fav) "starred-symbolic" else "non-starred-symbolic";
    gtk.Button.setIconName(btn, new_icon);
    ctx.fav.save();
}
