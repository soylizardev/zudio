const std = @import("std");
const c = @import("c");

const types = @import("types.zig");
pub const StreamInfo = types.StreamInfo;
pub const Sink = types.Sink;

const Ctx = struct {
    allocator: std.mem.Allocator,
    sink: ?Sink = null,
    info: StreamInfo = .{ .sample_rate = 0, .channels = 0, .bits_per_sample = 0 },
    got_info: bool = false,
};

fn metadataCallback(
    decoder: [*c]const c.FLAC__StreamDecoder,
    metadata: [*c]const c.FLAC__StreamMetadata,
    client_data: ?*anyopaque,
) callconv(.c) void {
    _ = decoder;
    if (metadata == null or client_data == null) return;
    const ctx: *Ctx = @ptrCast(@alignCast(client_data.?));
    const meta = metadata[0];
    if (meta.type == c.FLAC__METADATA_TYPE_STREAMINFO) {
        ctx.info.sample_rate = meta.data.stream_info.sample_rate;
        ctx.info.channels = @intCast(meta.data.stream_info.channels);
        ctx.info.bits_per_sample = @intCast(meta.data.stream_info.bits_per_sample);
        ctx.got_info = true;
    }
}

fn errorCallback(
    decoder: [*c]const c.FLAC__StreamDecoder,
    status: c.FLAC__StreamDecoderErrorStatus,
    client_data: ?*anyopaque,
) callconv(.c) void {
    _ = decoder;
    _ = client_data;
    std.debug.print("FLAC decode error (status={d})\n", .{status});
}

fn writeCallback(
    decoder: [*c]const c.FLAC__StreamDecoder,
    frame: [*c]const c.FLAC__Frame,
    buffer: [*c]const [*c]const c.FLAC__int32,
    client_data: ?*anyopaque,
) callconv(.c) c.FLAC__StreamDecoderWriteStatus {
    _ = decoder;
    if (frame == null or client_data == null) return c.FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;

    const ctx: *Ctx = @ptrCast(@alignCast(client_data.?));
    const sink = ctx.sink orelse return c.FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    const frame_info = frame[0];

    const blocksize: usize = @intCast(frame_info.header.blocksize);
    const source_channels: usize = @intCast(frame_info.header.channels);

    if (source_channels == 0 or source_channels > 2) {
        std.debug.print("Unsupported channel count: {d}\n", .{source_channels});
        return c.FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }

    // Alineación al MSB del contenedor S32.
    const shift: u5 = switch (ctx.info.bits_per_sample) {
        16 => 16,
        24 => 8,
        32 => 0,
        else => {
            std.debug.print("Unsupported bits_per_sample: {d}\n", .{ctx.info.bits_per_sample});
            return c.FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
        },
    };

    // Por ahora siempre estéreo en el destino (mono se duplica).
    const dst_channels: usize = 2;
    const samples = ctx.allocator.alloc(i32, blocksize * dst_channels) catch
        return c.FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    defer ctx.allocator.free(samples);

    if (source_channels == 1) {
        for (0..blocksize) |i| {
            const v: i32 = buffer[0][i] << shift;
            samples[i * 2] = v;
            samples[i * 2 + 1] = v;
        }
    } else {
        for (0..blocksize) |i| {
            samples[i * 2] = buffer[0][i] << shift;
            samples[i * 2 + 1] = buffer[1][i] << shift;
        }
    }

    sink.write(samples, @intCast(dst_channels)) catch
        return c.FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;

    return c.FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
}

pub const Decoder = struct {
    handle: ?*c.FLAC__StreamDecoder,
    ctx: *Ctx,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: [:0]const u8) !Decoder {
        const ctx = try allocator.create(Ctx);
        ctx.* = .{ .allocator = allocator };
        errdefer allocator.destroy(ctx);

        const handle_opt: ?*c.FLAC__StreamDecoder = c.FLAC__stream_decoder_new();
        if (handle_opt == null) return error.DecoderAllocFailed;
        const handle = handle_opt.?;
        errdefer _ = c.FLAC__stream_decoder_delete(handle);

        const status = c.FLAC__stream_decoder_init_file(
            handle,
            path.ptr,
            writeCallback,
            metadataCallback,
            errorCallback,
            ctx,
        );
        if (status != c.FLAC__STREAM_DECODER_INIT_STATUS_OK) {
            std.debug.print("FLAC init failed (status={d})\n", .{status});
            return error.FlacInitFailed;
        }

        if (c.FLAC__stream_decoder_process_until_end_of_metadata(handle) == 0) {
            return error.FlacMetadataFailed;
        }

        if (!ctx.got_info) return error.NoStreamInfo;
        if (ctx.info.channels == 0 or ctx.info.sample_rate == 0 or ctx.info.bits_per_sample == 0) {
            return error.BadStreamInfo;
        }

        return .{ .handle = handle, .ctx = ctx, .allocator = allocator };
    }

    pub fn info(self: *const Decoder) StreamInfo {
        return self.ctx.info;
    }

    pub fn decode(self: *Decoder, sink: Sink) !void {
        self.ctx.sink = sink;
        if (c.FLAC__stream_decoder_process_until_end_of_stream(self.handle) == 0) {
            return error.FlacDecodeFailed;
        }
    }

    pub fn deinit(self: *Decoder) void {
        if (self.handle) |h| _ = c.FLAC__stream_decoder_delete(h);
        self.allocator.destroy(self.ctx);
    }
};
