pub const StreamInfo = struct {
    sample_rate: u32,
    channels: u16,
    bits_per_sample: u8,
};

/// Interfaz entre backends y consumidores de audio (ALSA).
/// Los samples siempre son i32 estéreo, alineados al MSB (formato S32_LE).
pub const Sink = struct {
    ptr: *anyopaque,
    writeFn: *const fn (ptr: *anyopaque, samples: []const i32, channels: u16) anyerror!void,

    pub fn write(self: Sink, samples: []const i32, channels: u16) !void {
        return self.writeFn(self.ptr, samples, channels);
    }
};
