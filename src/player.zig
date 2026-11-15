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
    current_index: ?usize = null,
    stop_requested: std.atomic.Value(bool) = .init(false),
    interrupt_reason: InterruptReason = .none,

    /// Interrumpe la pista actual tras N segundos. 0 = deshabilitado.
    max_seconds: f32 = 0,

    samples_written: u64 = 0,
    current_sample_rate: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, engine: *audio.AudioEngine, tracks: []library.Track) Player {
        return .{ .allocator = allocator, .engine = engine, .tracks = tracks };
    }

    pub fn requestStop(self: *Player) void {
        self.stop_requested.store(true, .release);
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
                    try p.engine.writeS32(samples, channels);
                    if (p.max_seconds > 0 and p.current_sample_rate > 0) {
                        const frames = samples.len / @as(usize, channels);
                        p.samples_written += frames;
                        const secs = @as(f32, @floatFromInt(p.samples_written)) /
                            @as(f32, @floatFromInt(p.current_sample_rate));
                        if (secs >= p.max_seconds) {
                            p.interrupt_reason = .preview_limit;
                            return error.Interrupted;
                        }
                    }
                }
            }.write,
        };
    }

    pub fn playAt(self: *Player, index: usize) !PlayResult {
        if (index >= self.tracks.len) return error.IndexOutOfBounds;
        self.current_index = index;
        self.stop_requested.store(false, .release);
        self.samples_written = 0;
        self.interrupt_reason = .none;

        var dec = try decoder.Decoder.open(self.allocator, self.tracks[index].path);
        defer dec.deinit();

        const info = dec.info();
        self.current_sample_rate = info.sample_rate;
        try self.engine.configure(info.sample_rate, 2, info.bits_per_sample);

        // A partir de aquí el PCM está configurado. En cualquier salida
        // (éxito, interrupción o error) lo dejamos limpio para la siguiente pista.
        defer self.engine.drop();

        std.debug.print("  {d} Hz, {d} bits, {s}\n", .{
            info.sample_rate,
            info.bits_per_sample,
            @tagName(std.meta.activeTag(dec)),
        });

        dec.decode(self.makeSink()) catch |err| switch (err) {
            error.Interrupted => {
                self.engine.drain();
                return switch (self.interrupt_reason) {
                    .stopped_by_user => .stopped_by_user,
                    .preview_limit => .preview_limit,
                    .none => .preview_limit,
                };
            },
            else => return err,
        };

        self.engine.drain();
        return .completed;
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
