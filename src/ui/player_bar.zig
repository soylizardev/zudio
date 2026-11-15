const std = @import("std");
const gtk = @import("gtk");
const adw = @import("adw");
const audio_controller = @import("audio_controller.zig");
const player = @import("../player.zig");
const favorites = @import("../favorites.zig");

pub const FavoriteChangedFn = *const fn (ctx: *anyopaque, path: []const u8, is_fav: bool) void;

pub const PlayerBar = struct {
    root: *gtk.Box,
    title_label: *gtk.Label,
    artist_label: *gtk.Label,
    time_current: *gtk.Label,
    time_total: *gtk.Label,
    slider: *gtk.Scale,
    btn_play: *gtk.Button,
    btn_shuffle: *gtk.Button,
    btn_repeat: *gtk.Button,
    btn_favorite: *gtk.Button,
    fav: *favorites.Favorites,
    controller: *audio_controller.AudioController,
    player_ref: *player.Player,
    fav_callback: ?FavoriteChangedFn = null,
    fav_callback_ctx: ?*anyopaque = null,
    last_known_index: i64 = -1,
    last_fav_state: bool = false,
    pending_seek_frame: ?u64 = null,
    pending_seek_ticks: u32 = 0,

    pub fn build(
        ctrl: *audio_controller.AudioController,
        p: *player.Player,
        fav: *favorites.Favorites,
        fav_callback: ?FavoriteChangedFn,
        fav_callback_ctx: ?*anyopaque,
    ) *PlayerBar {
        const bar = gtk.Box.new(gtk.Orientation.horizontal, 12);
        gtk.Widget.setMarginTop(@ptrCast(@alignCast(bar)), 8);
        gtk.Widget.setMarginBottom(@ptrCast(@alignCast(bar)), 8);
        gtk.Widget.setMarginStart(@ptrCast(@alignCast(bar)), 16);
        gtk.Widget.setMarginEnd(@ptrCast(@alignCast(bar)), 16);

        const info_box = gtk.Box.new(gtk.Orientation.vertical, 2);
        gtk.Widget.setHexpand(@ptrCast(@alignCast(info_box)), 1);

        const title = gtk.Label.new("Sin reproducción");
        gtk.Widget.addCssClass(@ptrCast(@alignCast(title)), "title-4");
        gtk.Widget.setHalign(@ptrCast(@alignCast(title)), gtk.Align.start);

        const artist = gtk.Label.new("—");
        gtk.Widget.addCssClass(@ptrCast(@alignCast(artist)), "dim-label");
        gtk.Widget.addCssClass(@ptrCast(@alignCast(artist)), "caption");
        gtk.Widget.setHalign(@ptrCast(@alignCast(artist)), gtk.Align.start);

        gtk.Box.append(info_box, @ptrCast(@alignCast(title)));
        gtk.Box.append(info_box, @ptrCast(@alignCast(artist)));

        const center_box = gtk.Box.new(gtk.Orientation.vertical, 4);
        gtk.Widget.setHexpand(@ptrCast(@alignCast(center_box)), 1);

        const controls = gtk.Box.new(gtk.Orientation.horizontal, 8);
        gtk.Widget.setHalign(@ptrCast(@alignCast(controls)), gtk.Align.center);

        const btn_shuffle = makeIconButton("media-playlist-shuffle-symbolic", "Aleatorio");
        const btn_prev = makeIconButton("media-skip-backward-symbolic", "Anterior");
        const btn_play = makeIconButton("media-playback-start-symbolic", "Reproducir");
        const btn_next = makeIconButton("media-skip-forward-symbolic", "Siguiente");
        const btn_repeat = makeIconButton("media-playlist-repeat-symbolic", "Repetir");

        const btn_favorite = makeIconButton("non-starred-symbolic", "Marcar como favorito");

        gtk.Box.append(controls, @ptrCast(@alignCast(btn_shuffle)));
        gtk.Box.append(controls, @ptrCast(@alignCast(btn_prev)));
        gtk.Box.append(controls, @ptrCast(@alignCast(btn_play)));
        gtk.Box.append(controls, @ptrCast(@alignCast(btn_next)));
        gtk.Box.append(controls, @ptrCast(@alignCast(btn_repeat)));
        gtk.Box.append(controls, @ptrCast(@alignCast(btn_favorite)));

        const progress_row = gtk.Box.new(gtk.Orientation.horizontal, 8);
        gtk.Widget.setHalign(@ptrCast(@alignCast(progress_row)), gtk.Align.center);

        const time_current = gtk.Label.new("0:00");
        gtk.Widget.addCssClass(@ptrCast(@alignCast(time_current)), "caption");

        const slider = gtk.Scale.newWithRange(gtk.Orientation.horizontal, 0.0, 1.0, 0.001);
        gtk.Widget.setSizeRequest(@ptrCast(@alignCast(slider)), 320, -1);
        gtk.Scale.setDrawValue(slider, 0);

        const time_total = gtk.Label.new("0:00");
        gtk.Widget.addCssClass(@ptrCast(@alignCast(time_total)), "caption");

        gtk.Box.append(progress_row, @ptrCast(@alignCast(time_current)));
        gtk.Box.append(progress_row, @ptrCast(@alignCast(slider)));
        gtk.Box.append(progress_row, @ptrCast(@alignCast(time_total)));

        gtk.Box.append(center_box, @ptrCast(@alignCast(controls)));
        gtk.Box.append(center_box, @ptrCast(@alignCast(progress_row)));

        gtk.Box.append(bar, @ptrCast(@alignCast(info_box)));
        gtk.Box.append(bar, @ptrCast(@alignCast(center_box)));

        const self = std.heap.page_allocator.create(PlayerBar) catch unreachable;
        self.* = .{
            .root = bar,
            .title_label = title,
            .artist_label = artist,
            .time_current = time_current,
            .time_total = time_total,
            .slider = slider,
            .btn_play = btn_play,
            .btn_shuffle = btn_shuffle,
            .btn_repeat = btn_repeat,
            .btn_favorite = btn_favorite,
            .fav = fav,
            .controller = ctrl,
            .player_ref = p,
            .fav_callback = fav_callback,
            .fav_callback_ctx = fav_callback_ctx,
        };

        _ = gtk.Button.signals.clicked.connect(btn_play, *PlayerBar, onPlayClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(btn_prev, *PlayerBar, onPrevClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(btn_next, *PlayerBar, onNextClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(btn_shuffle, *PlayerBar, onShuffleClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(btn_repeat, *PlayerBar, onRepeatClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(btn_favorite, *PlayerBar, onFavClicked, self, .{});

        _ = gtk.Range.signals.change_value.connect(slider, *PlayerBar, onChangeValue, self, .{});

        return self;
    }

    pub fn tick(self: *PlayerBar) void {
        const cur_idx = self.player_ref.current_index.load(.acquire);
        const pos = self.player_ref.positionSeconds();
        const dur = self.player_ref.durationSeconds();

        const index_changed = cur_idx != self.last_known_index;
        if (index_changed) {
            self.last_known_index = cur_idx;
            if (cur_idx >= 0) {
                const idx: usize = @intCast(cur_idx);
                if (idx < self.player_ref.tracks.len) {
                    const track = self.player_ref.tracks[idx];
                    const title_str: []const u8 = track.info.title orelse std.fs.path.basename(track.path);
                    if (std.heap.page_allocator.dupeZ(u8, title_str)) |tz| {
                        defer std.heap.page_allocator.free(tz);
                        gtk.Label.setLabel(self.title_label, tz.ptr);
                    } else |_| {}

                    var abuf: [512]u8 = undefined;
                    const artist_str: []const u8 = blk: {
                        const artist = track.info.artist;
                        const album = track.info.album;
                        if (artist != null and album != null) {
                            break :blk std.fmt.bufPrint(&abuf, "{s} — {s}", .{ artist.?, album.? }) catch "";
                        } else if (artist) |a| break :blk a;
                        break :blk "";
                    };
                    if (std.heap.page_allocator.dupeZ(u8, artist_str)) |az| {
                        defer std.heap.page_allocator.free(az);
                        gtk.Label.setLabel(self.artist_label, az.ptr);
                    } else |_| {}
                }
            } else {
                gtk.Label.setLabel(self.title_label, "Sin reproducción");
                gtk.Label.setLabel(self.artist_label, "—");
            }
        }

        if (cur_idx >= 0) {
            const idx: usize = @intCast(cur_idx);
            if (idx < self.player_ref.tracks.len) {
                const track = self.player_ref.tracks[idx];
                const is_fav = self.fav.isFavorite(track.path);
                if (index_changed or is_fav != self.last_fav_state) {
                    const star_icon: [:0]const u8 = if (is_fav) "starred-symbolic" else "non-starred-symbolic";
                    gtk.Button.setIconName(self.btn_favorite, star_icon);
                    self.last_fav_state = is_fav;
                }
            }
        } else if (index_changed) {
            gtk.Button.setIconName(self.btn_favorite, "non-starred-symbolic");
            self.last_fav_state = false;
        }

        var buf_pos: [16]u8 = undefined;
        var buf_dur: [16]u8 = undefined;
        gtk.Label.setLabel(self.time_current, formatTime(&buf_pos, pos).ptr);
        gtk.Label.setLabel(self.time_total, formatTime(&buf_dur, dur).ptr);

        if (self.pending_seek_frame) |frame| {
            self.pending_seek_ticks += 1;
            if (self.pending_seek_ticks >= 2) {
                self.pending_seek_frame = null;
                self.pending_seek_ticks = 0;
                self.controller.seekToFrame(frame);
            }
        }

        if (self.pending_seek_frame == null) {
            if (dur > 0) {
                gtk.Range.setValue(@ptrCast(@alignCast(self.slider)), pos / dur);
            } else {
                gtk.Range.setValue(@ptrCast(@alignCast(self.slider)), 0.0);
            }
        }

        const is_paused = self.player_ref.is_paused.load(.monotonic);
        const is_playing = self.player_ref.is_playing.load(.monotonic);
        const icon: [:0]const u8 = if (is_playing and !is_paused)
            "media-playback-pause-symbolic"
        else
            "media-playback-start-symbolic";
        gtk.Button.setIconName(self.btn_play, icon);

        const shuffle_on = self.player_ref.shuffle.load(.monotonic);
        if (shuffle_on) {
            gtk.Widget.addCssClass(@ptrCast(@alignCast(self.btn_shuffle)), "accent");
        } else {
            gtk.Widget.removeCssClass(@ptrCast(@alignCast(self.btn_shuffle)), "accent");
        }

        const repeat = self.player_ref.repeat_mode.load(.monotonic);
        const repeat_icon: [:0]const u8 = if (repeat == 2)
            "media-playlist-repeat-song-symbolic"
        else
            "media-playlist-repeat-symbolic";
        gtk.Button.setIconName(self.btn_repeat, repeat_icon);
        if (repeat > 0) {
            gtk.Widget.addCssClass(@ptrCast(@alignCast(self.btn_repeat)), "accent");
        } else {
            gtk.Widget.removeCssClass(@ptrCast(@alignCast(self.btn_repeat)), "accent");
        }
    }
};

fn formatTime(buf: *[16]u8, seconds: f64) [:0]const u8 {
    const total: u32 = if (seconds < 0) 0 else @intFromFloat(seconds);
    const mins = total / 60;
    const secs = total % 60;
    return std.fmt.bufPrintZ(buf, "{d}:{d:0>2}", .{ mins, secs }) catch "0:00";
}

fn makeIconButton(icon_name: [:0]const u8, tooltip: [:0]const u8) *gtk.Button {
    const btn = gtk.Button.newFromIconName(icon_name);
    gtk.Widget.setTooltipText(@ptrCast(@alignCast(btn)), tooltip);
    gtk.Widget.addCssClass(@ptrCast(@alignCast(btn)), "flat");
    gtk.Widget.addCssClass(@ptrCast(@alignCast(btn)), "circular");
    return btn;
}

fn onPlayClicked(btn: *gtk.Button, self: *PlayerBar) callconv(.c) void {
    _ = btn;
    self.controller.togglePause();
}
fn onPrevClicked(btn: *gtk.Button, self: *PlayerBar) callconv(.c) void {
    _ = btn;
    self.controller.prev();
}
fn onNextClicked(btn: *gtk.Button, self: *PlayerBar) callconv(.c) void {
    _ = btn;
    self.controller.next();
}
fn onShuffleClicked(btn: *gtk.Button, self: *PlayerBar) callconv(.c) void {
    _ = btn;
    self.controller.toggleShuffle();
}
fn onRepeatClicked(btn: *gtk.Button, self: *PlayerBar) callconv(.c) void {
    _ = btn;
    self.controller.cycleRepeat();
}

fn onFavClicked(btn: *gtk.Button, self: *PlayerBar) callconv(.c) void {
    const cur_idx = self.player_ref.current_index.load(.acquire);
    if (cur_idx < 0) return;
    const idx: usize = @intCast(cur_idx);
    if (idx >= self.player_ref.tracks.len) return;
    const track = self.player_ref.tracks[idx];
    const now_fav = self.fav.toggle(track.path);
    const new_icon: [:0]const u8 = if (now_fav) "starred-symbolic" else "non-starred-symbolic";
    gtk.Button.setIconName(btn, new_icon);
    self.last_fav_state = now_fav;
    self.fav.save();

    // Notificar al MainWindow para que actualice la fila de la lista al instante.
    if (self.fav_callback) |cb| {
        if (self.fav_callback_ctx) |ctx| {
            cb(ctx, track.path, now_fav);
        }
    }
}

fn onChangeValue(
    slider: *gtk.Scale,
    scroll_type: gtk.ScrollType,
    value: f64,
    self: *PlayerBar,
) callconv(.c) c_int {
    _ = slider;
    _ = scroll_type;

    const dur_frames = self.player_ref.duration_samples.load(.monotonic);
    if (dur_frames == 0) return 0;

    const frame: u64 = @intFromFloat(value * @as(f64, @floatFromInt(dur_frames)));
    self.pending_seek_frame = frame;
    self.pending_seek_ticks = 0;
    return 0;
}
