const std = @import("std");
const c = @import("c");
const types = @import("types.zig");

pub const Decoder = struct {
    handle: ?*c.drmp3 = null,
    allocator: std.mem.Allocator,
    stream_info: types.StreamInfo,

    pub fn open(allocator: std.mem.Allocator, path: [:0]const u8) !Decoder {
        const h = try allocator.create(c.drmp3);
        errdefer allocator.destroy(h);

        if (c.drmp3_init_file(h, path.ptr, null) == 0) {
            allocator.destroy(h);
            return error.Mp3OpenFailed;
        }

        // dr_mp3 expone sampleRate y channels como campos del struct.
        return .{
            .handle = h,
            .allocator = allocator,
            .stream_info = .{
                .sample_rate = h.sampleRate,
                .channels = @intCast(h.channels),
                .bits_per_sample = 16, // dr_mp3 decodifica siempre a i16
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
        var buf: [max_frames * 2]i16 = undefined;
        var out: [max_frames * 2]i32 = undefined;

        while (true) {
            const frames_read = c.drmp3_read_pcm_frames_s16(handle, max_frames, &buf);
            if (frames_read == 0) break;
            const n: usize = @intCast(frames_read);

            if (src_channels == 1) {
                for (0..n) |i| {
                    const v: i32 = @as(i32, buf[i]) << 16;
                    out[i * 2] = v;
                    out[i * 2 + 1] = v;
                }
                try sink.write(out[0 .. n * 2], 2);
            } else {
                for (0..n * 2) |i| {
                    out[i] = @as(i32, buf[i]) << 16;
                }
                try sink.write(out[0 .. n * 2], 2);
            }
        }
    }

    pub fn deinit(self: *Decoder) void {
        if (self.handle) |h| {
            c.drmp3_uninit(h);
            self.allocator.destroy(h);
            self.handle = null;
        }
    }
};
