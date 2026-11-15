const std = @import("std");
const audio = @import("audio.zig");
const decoder = @import("decoder.zig");
const library = @import("library.zig");

pub const PlayResult = enum { completed, stopped_by_user, preview_limit };
const InterruptReason = enum { none, stopped_by_user, preview_limit };

pub const Player = struct {
    allocator: std.mem.Allocator,
    engine: *audio.AudioEngine,
    tracks: []library.Track,
    io: std.Io,

    current_index: std.atomic.Value(i64) = .init(-1),
    stop_requested: std.atomic.Value(bool) = .init(false),
    samples_written: std.atomic.Value(u64) = .init(0),
    skip_until: std.atomic.Value(u64) = .init(0),
    duration_samples: std.atomic.Value(u64) = .init(0),
    sample_rate: std.atomic.Value(u32) = .init(0),
    is_playing: std.atomic.Value(bool) = .init(false),
    is_paused: std.atomic.Value(bool) = .init(false),
    shuffle: std.atomic.Value(bool) = .init(false),
    repeat_mode: std.atomic.Value(u8) = .init(0),

    max_seconds: f32 = 0,
    interrupt_reason: InterruptReason = .none,

    pub fn init(
        allocator: std.mem.Allocator,
        engine: *audio.AudioEngine,
        tracks: []library.Track,
        io: std.Io,
    ) Player {
        return .{ .allocator = allocator, .engine = engine, .tracks = tracks, .io = io };
    }

    pub fn requestStop(self: *Player) void {
        self.stop_requested.store(true, .release);
    }

    pub fn toggleShuffle(self: *Player) void {
        const cur = self.shuffle.load(.monotonic);
        self.shuffle.store(!cur, .monotonic);
    }

    pub fn cycleRepeat(self: *Player) void {
        const cur = self.repeat_mode.load(.monotonic);
        const next: u8 = if (cur >= 2) 0 else cur + 1;
        self.repeat_mode.store(next, .monotonic);
    }

    pub fn nextIndex(self: *Player) ?usize {
        const total = self.tracks.len;
        if (total == 0) return null;
        const cur_i = self.current_index.load(.acquire);
        const cur: usize = if (cur_i < 0) 0 else @intCast(cur_i);

        if (self.shuffle.load(.monotonic)) {
            if (total == 1) return 0;
            const rng_impl: std.Random.IoSource = .{ .io = self.io };
            const rng = rng_impl.interface();
            var pick: usize = cur;
            while (pick == cur) {
                pick = rng.uintLessThan(usize, total);
            }
            return pick;
        }
        if (cur + 1 < total) return cur + 1;
        if (self.repeat_mode.load(.monotonic) == 1) return 0;
        return null;
    }

    pub fn prevIndex(self: *Player) ?usize {
        const total = self.tracks.len;
        if (total == 0) return null;
        const cur_i = self.current_index.load(.acquire);
        if (cur_i <= 0) {
            if (self.repeat_mode.load(.monotonic) == 1) return total - 1;
            return 0;
        }
        return @intCast(cur_i - 1);
    }

    fn makeSink(self: *Player) decoder.Sink {
        return .{
            .ptr = self,
            .writeFn = struct {
                fn write(ptr: *anyopaque, samples: []const i32, channels: u16) anyerror!void {
                    const p: *Player = @ptrCast(@alignCast(ptr));
                    if (p.stop_requested.load(.acquire)) {
                        p.interrupt_reason = .stopped_by_user;
                        return error.Interrupted;
                    }

                    const frames = samples.len / @as(usize, channels);
                    const skip_remaining = p.skip_until.load(.acquire);

                    var to_write: []const i32 = samples;
                    var write_frames: usize = frames;

                    if (skip_remaining > 0) {
                        if (frames <= skip_remaining) {
                            _ = p.skip_until.fetchSub(frames, .monotonic);
                            return;
                        }
                        const skip_frames: usize = @intCast(skip_remaining);
                        _ = p.skip_until.store(0, .release);
                        const skip_samples = skip_frames * @as(usize, channels);
                        to_write = samples[skip_samples..];
                        write_frames = frames - skip_frames;
                    }

                    try p.engine.writeS32(to_write, channels);
                    _ = p.samples_written.fetchAdd(write_frames, .monotonic);

                    if (p.max_seconds > 0) {
                        const sr = p.sample_rate.load(.monotonic);
                        if (sr > 0) {
                            const written = p.samples_written.load(.monotonic);
                            const secs = @as(f32, @floatFromInt(written)) /
                                @as(f32, @floatFromInt(sr));
                            if (secs >= p.max_seconds) {
                                p.interrupt_reason = .preview_limit;
                                return error.Interrupted;
                            }
                        }
                    }
                }
            }.write,
        };
    }

    pub fn playAt(self: *Player, index: usize) !PlayResult {
        return self.playAtFromFrame(index, 0);
    }

    pub fn playAtFromFrame(self: *Player, index: usize, start_frame: u64) !PlayResult {
        if (index >= self.tracks.len) return error.IndexOutOfBounds;

        self.current_index.store(@intCast(index), .release);
        self.stop_requested.store(false, .release);
        self.is_playing.store(true, .release);
        self.is_paused.store(false, .release);
        self.interrupt_reason = .none;
        self.skip_until.store(0, .release);

        var dec = decoder.Decoder.open(self.allocator, self.tracks[index].path) catch |err| {
            self.is_playing.store(false, .release);
            return err;
        };

        const info = dec.info();
        self.sample_rate.store(info.sample_rate, .release);
        self.duration_samples.store(info.total_frames, .release);

        self.engine.configure(info.sample_rate, 2, info.bits_per_sample) catch |err| {
            dec.deinit();
            self.is_playing.store(false, .release);
            return err;
        };
        defer self.engine.drop();

        // Intentar seek rápido. Si falla, cerrar el decoder y reabrirlo limpio,
        // porque libFLAC deja el stream en estado ABORTED tras un seek fallido.
        if (start_frame > 0) {
            if (dec.seekToFrame(start_frame)) |_| {
                std.debug.print("  seek rápido OK a frame {d}\n", .{start_frame});
            } else |err| {
                std.debug.print("  ✗ seek rápido falló ({s}), reabriendo con decode+discard\n", .{@errorName(err)});
                dec.deinit();
                dec = decoder.Decoder.open(self.allocator, self.tracks[index].path) catch |err2| {
                    self.is_playing.store(false, .release);
                    return err2;
                };
                self.skip_until.store(start_frame, .release);
            }
        }
        defer dec.deinit();

        self.samples_written.store(start_frame, .release);

        std.debug.print("  {d} Hz, {d} bits, {s} (seek={d})\n", .{
            info.sample_rate,
            info.bits_per_sample,
            @tagName(std.meta.activeTag(dec)),
            start_frame,
        });

        dec.decode(self.makeSink()) catch |err| switch (err) {
            error.Interrupted => {
                // drop descarta el buffer inmediatamente (sin esperar 500ms del drain).
                // Es lo correcto al cambiar de pista o hacer seek.
                self.engine.drop();
                self.is_playing.store(false, .release);
                return switch (self.interrupt_reason) {
                    .stopped_by_user => .stopped_by_user,
                    .preview_limit => .preview_limit,
                    .none => .preview_limit,
                };
            },
            else => {
                self.is_playing.store(false, .release);
                return err;
            },
        };

        self.engine.drain();
        self.is_playing.store(false, .release);
        return .completed;
    }

    pub fn positionSeconds(self: *Player) f64 {
        const sr = self.sample_rate.load(.monotonic);
        if (sr == 0) return 0;
        const w = self.samples_written.load(.monotonic);
        return @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(sr));
    }

    pub fn durationSeconds(self: *Player) f64 {
        const sr = self.sample_rate.load(.monotonic);
        if (sr == 0) return 0;
        const d = self.duration_samples.load(.monotonic);
        return @as(f64, @floatFromInt(d)) / @as(f64, @floatFromInt(sr));
    }

    pub fn playAllFrom(self: *Player, start: usize) !usize {
        var idx = start;
        while (idx < self.tracks.len) : (idx += 1) {
            std.debug.print("[{d}/{d}] {s}\n", .{ idx + 1, self.tracks.len, self.tracks[idx].path });
            const result = self.playAt(idx) catch |err| {
                std.debug.print("  ✗ fallo ({s}), saltando.\n", .{@errorName(err)});
                continue;
            };
            switch (result) {
                .completed => {},
                .preview_limit => std.debug.print("  ⏭ preview {d}s, siguiente.\n", .{self.max_seconds}),
                .stopped_by_user => {
                    std.debug.print("  ⏹ detenido por el usuario.\n", .{});
                    return idx;
                },
            }
        }
        return self.tracks.len;
    }
};
