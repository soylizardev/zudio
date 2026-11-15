const std = @import("std");
const c = @import("c");
const flac = @import("flac.zig");

pub const ActiveFormat = enum {
    s32le,
    s24le,
    s16le,

    pub fn bits(self: ActiveFormat) u8 {
        return switch (self) {
            .s32le => 32,
            .s24le => 24,
            .s16le => 16,
        };
    }

    pub fn name(self: ActiveFormat) []const u8 {
        return switch (self) {
            .s32le => "S32_LE",
            .s24le => "S24_3LE",
            .s16le => "S16_LE",
        };
    }
};

pub const AudioEngine = struct {
    pcm_handle: ?*c.snd_pcm_t = null,
    active_format: ActiveFormat = .s32le,

    pub fn init(device: [:0]const u8) !AudioEngine {
        var handle: ?*c.snd_pcm_t = null;
        const err = c.snd_pcm_open(&handle, device.ptr, c.SND_PCM_STREAM_PLAYBACK, 0);
        if (err < 0) {
            std.debug.print("ALSA open error ({d}): {s}\n", .{
                err,
                std.mem.sliceTo(c.snd_strerror(err), 0),
            });
            return error.AlsaOpenFailed;
        }
        return .{ .pcm_handle = handle };
    }

    /// Prueba si el hardware acepta (fmt, rate, channels) exactamente, sin
    /// plugins ni remuestreo. Devuelve true si logró commitear los params.
    fn tryFormat(
        handle: ?*c.snd_pcm_t,
        fmt: c.snd_pcm_format_t,
        sample_rate: u32,
        channels: u16,
    ) bool {
        var params: ?*c.snd_pcm_hw_params_t = null;
        if (c.snd_pcm_hw_params_malloc(&params) < 0) return false;
        defer c.snd_pcm_hw_params_free(params);

        if (c.snd_pcm_hw_params_any(handle, params) < 0) return false;
        if (c.snd_pcm_hw_params_set_access(handle, params, c.SND_PCM_ACCESS_RW_INTERLEAVED) < 0) return false;
        if (c.snd_pcm_hw_params_set_format(handle, params, fmt) < 0) return false;
        if (c.snd_pcm_hw_params_set_channels(handle, params, @intCast(channels)) < 0) return false;

        var rate: c_uint = @intCast(sample_rate);
        if (c.snd_pcm_hw_params_set_rate_near(handle, params, &rate, null) < 0) return false;
        if (rate != sample_rate) return false; // strict: no resampling

        var buffer_time: c_uint = 500000;
        _ = c.snd_pcm_hw_params_set_buffer_time_near(handle, params, &buffer_time, null);

        if (c.snd_pcm_hw_params(handle, params) < 0) return false;
        return true;
    }

    /// Negocia el mejor formato de hardware disponible:
    /// S32_LE → S24_3LE → S16_LE. Advierte si hay truncación.
    pub fn configure(
        self: *AudioEngine,
        sample_rate: u32,
        channels: u16,
        source_bits: u8,
    ) !void {
        const handle = self.pcm_handle orelse return error.NotInitialized;

        const candidates = [_]struct {
            fmt: c.snd_pcm_format_t,
            tag: ActiveFormat,
        }{
            .{ .fmt = c.SND_PCM_FORMAT_S32_LE, .tag = .s32le },
            .{ .fmt = c.SND_PCM_FORMAT_S24_3LE, .tag = .s24le },
            .{ .fmt = c.SND_PCM_FORMAT_S16_LE, .tag = .s16le },
        };

        for (candidates) |cand| {
            if (tryFormat(handle, cand.fmt, sample_rate, channels)) {
                self.active_format = cand.tag;
                if (source_bits > cand.tag.bits()) {
                    std.debug.print(
                        "AVISO: archivo de {d} bits truncado a {d} bits (hardware solo acepta {s}).\n",
                        .{ source_bits, cand.tag.bits(), cand.tag.name() },
                    );
                }
                return;
            }
        }
        std.debug.print("Ningún formato PCM soportado por el hardware.\n", .{});
        return error.NoSupportedFormat;
    }

    pub fn writeS32(self: *AudioEngine, samples: []const i32, num_channels: u16) !void {
        switch (self.active_format) {
            .s32le => try self.writeDirect(samples, num_channels),
            .s24le => try self.writeAsS24(samples, num_channels),
            .s16le => try self.writeAsS16(samples, num_channels),
        }
    }

    fn writeDirect(self: *AudioEngine, samples: []const i32, num_channels: u16) !void {
        const handle = self.pcm_handle orelse return error.NotInitialized;
        const total_frames: c.snd_pcm_uframes_t = @intCast(samples.len / num_channels);

        var frame_offset: c.snd_pcm_uframes_t = 0;
        while (frame_offset < total_frames) {
            const remaining = total_frames - frame_offset;
            const sample_start = @as(usize, @intCast(frame_offset)) * num_channels;
            const buf_ptr: ?*const anyopaque = @ptrCast(samples.ptr + sample_start);
            const written = c.snd_pcm_writei(handle, buf_ptr, remaining);
            if (written < 0) {
                const err_code: c_int = @intCast(written);
                _ = c.snd_pcm_recover(handle, err_code, 1);
                return error.WriteFailed;
            }
            frame_offset += @intCast(written);
        }
    }

    fn writeAsS16(self: *AudioEngine, samples: []const i32, num_channels: u16) !void {
        const handle = self.pcm_handle orelse return error.NotInitialized;
        const max_buf_frames: usize = 2048;
        const max_samples = max_buf_frames * @as(usize, num_channels);

        var buf: [4096]i16 = undefined;
        var offset: usize = 0;

        while (offset < samples.len) {
            const chunk_len = @min(samples.len - offset, max_samples);
            const chunk = samples[offset .. offset + chunk_len];

            for (0..chunk.len) |i| {
                buf[i] = @intCast(chunk[i] >> 16);
            }

            const frames: c.snd_pcm_uframes_t = @intCast(chunk.len / num_channels);
            const written = c.snd_pcm_writei(handle, @as(?*const anyopaque, @ptrCast(&buf)), frames);
            if (written < 0) {
                const err_code: c_int = @intCast(written);
                _ = c.snd_pcm_recover(handle, err_code, 1);
                return error.WriteFailed;
            }
            offset += @as(usize, @intCast(written)) * num_channels;
        }
    }

    fn writeAsS24(self: *AudioEngine, samples: []const i32, num_channels: u16) !void {
        const handle = self.pcm_handle orelse return error.NotInitialized;
        const max_buf_frames: usize = 1024;
        const max_samples = max_buf_frames * @as(usize, num_channels);

        var buf: [6144]u8 = undefined; // 1024 frames × 2 ch × 3 bytes
        var offset: usize = 0;

        while (offset < samples.len) {
            const chunk_len = @min(samples.len - offset, max_samples);
            const chunk = samples[offset .. offset + chunk_len];

            for (0..chunk.len) |i| {
                const v = chunk[i];
                buf[i * 3 + 0] = @truncate(@as(u32, @bitCast(v >> 8)));
                buf[i * 3 + 1] = @truncate(@as(u32, @bitCast(v >> 16)));
                buf[i * 3 + 2] = @truncate(@as(u32, @bitCast(v >> 24)));
            }

            const frames: c.snd_pcm_uframes_t = @intCast(chunk.len / num_channels);
            const written = c.snd_pcm_writei(handle, @as(?*const anyopaque, @ptrCast(&buf)), frames);
            if (written < 0) {
                const err_code: c_int = @intCast(written);
                _ = c.snd_pcm_recover(handle, err_code, 1);
                return error.WriteFailed;
            }
            offset += @as(usize, @intCast(written)) * num_channels;
        }
    }

    pub fn drain(self: *AudioEngine) void {
        if (self.pcm_handle) |h| _ = c.snd_pcm_drain(h);
    }

    pub fn printActualHwParams(self: *AudioEngine) void {
        const handle = self.pcm_handle orelse return;
        var params: ?*c.snd_pcm_hw_params_t = null;
        if (c.snd_pcm_hw_params_malloc(&params) < 0) return;
        defer c.snd_pcm_hw_params_free(params);
        if (c.snd_pcm_hw_params_current(handle, params) < 0) return;

        var fmt: c.snd_pcm_format_t = undefined;
        var rate: c_uint = 0;
        var ch: c_uint = 0;
        _ = c.snd_pcm_hw_params_get_format(params, &fmt);
        _ = c.snd_pcm_hw_params_get_rate(params, &rate, null);
        _ = c.snd_pcm_hw_params_get_channels(params, &ch);

        std.debug.print("HW real: format={s}, rate={d} Hz, channels={d}\n", .{
            std.mem.sliceTo(c.snd_pcm_format_name(fmt), 0),
            rate,
            ch,
        });
    }

    pub fn deinit(self: *AudioEngine) void {
        if (self.pcm_handle) |h| {
            _ = c.snd_pcm_close(h);
            self.pcm_handle = null;
        }
    }
};

pub fn sinkFor(engine: *AudioEngine) flac.Sink {
    return .{
        .ptr = engine,
        .writeFn = struct {
            fn write(ptr: *anyopaque, samples: []const i32, channels: u16) anyerror!void {
                const e: *AudioEngine = @ptrCast(@alignCast(ptr));
                try e.writeS32(samples, channels);
            }
        }.write,
    };
}
