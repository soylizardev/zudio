const std = @import("std");
const c = @import("c");
const types = @import("types.zig");

pub const Decoder = struct {
    handle: ?*c.drwav = null,
    allocator: std.mem.Allocator,
    stream_info: types.StreamInfo,

    pub fn open(allocator: std.mem.Allocator, path: [:0]const u8) !Decoder {
        const h = try allocator.create(c.drwav);
        errdefer allocator.destroy(h);

        if (c.drwav_init_file(h, path.ptr, null) == 0) {
            allocator.destroy(h);
            return error.WavOpenFailed;
        }

        return .{
            .handle = h,
            .allocator = allocator,
            .stream_info = .{
                .sample_rate = h.sampleRate,
                .channels = @intCast(h.channels),
                .bits_per_sample = @intCast(h.bitsPerSample),
            },
        };
    }

    pub fn info(self: *const Decoder) types.StreamInfo {
        return self.stream_info;
    }

    pub fn decode(self: *Decoder, sink: types.Sink) !void {
        const handle = self.handle orelse return error.NotInitialized;
        const src_channels: usize = self.stream_info.channels;
        if (src_channels == 0 or src_channels > 2) return error.UnsupportedChannelCount;

        const max_frames = 4096;
        var buf: [max_frames * 2]i32 = undefined;
        var out: [max_frames * 2]i32 = undefined;

        while (true) {
            const frames_read = c.drwav_read_pcm_frames_s32(handle, max_frames, &buf);
            if (frames_read == 0) break;
            const n: usize = @intCast(frames_read);

            // dr_wav ya devuelve i32 MSB-alineado (16-bit ×65536, 24-bit ×256,
            // 32-bit tal cual). No hay que hacer shift.
            if (src_channels == 1) {
                for (0..n) |i| {
                    out[i * 2] = buf[i];
                    out[i * 2 + 1] = buf[i];
                }
                try sink.write(out[0 .. n * 2], 2);
            } else {
                try sink.write(buf[0 .. n * 2], 2);
            }
        }
    }

    pub fn deinit(self: *Decoder) void {
        if (self.handle) |h| {
            _ = c.drwav_uninit(h);
            self.allocator.destroy(h);
            self.handle = null;
        }
    }
};
