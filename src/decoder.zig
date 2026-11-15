const std = @import("std");
const types = @import("types.zig");
const flac = @import("flac.zig");
const mp3 = @import("mp3.zig");
const wav = @import("wav.zig");

pub const StreamInfo = types.StreamInfo;
pub const Sink = types.Sink;

pub const Format = enum { flac, mp3, wav };

pub const Decoder = union(Format) {
    flac: flac.Decoder,
    mp3: mp3.Decoder,
    wav: wav.Decoder,

    pub fn open(allocator: std.mem.Allocator, path: [:0]const u8) !Decoder {
        const fmt = detectFormat(path) orelse return error.UnsupportedFormat;
        return switch (fmt) {
            .flac => .{ .flac = try flac.Decoder.open(allocator, path) },
            .mp3 => .{ .mp3 = try mp3.Decoder.open(allocator, path) },
            .wav => .{ .wav = try wav.Decoder.open(allocator, path) },
        };
    }

    pub fn info(self: *const Decoder) types.StreamInfo {
        return switch (self.*) {
            .flac => |d| d.info(),
            .mp3 => |d| d.info(),
            .wav => |d| d.info(),
        };
    }

    pub fn decode(self: *Decoder, sink: types.Sink) !void {
        switch (self.*) {
            .flac => |*d| try d.decode(sink),
            .mp3 => |*d| try d.decode(sink),
            .wav => |*d| try d.decode(sink),
        }
    }

    pub fn seekToFrame(self: *Decoder, frame: u64) !void {
        switch (self.*) {
            .flac => |*d| try d.seekToFrame(frame),
            .mp3 => |*d| try d.seekToFrame(frame),
            .wav => |*d| try d.seekToFrame(frame),
        }
    }

    pub fn deinit(self: *Decoder) void {
        switch (self.*) {
            .flac => |*d| d.deinit(),
            .mp3 => |*d| d.deinit(),
            .wav => |*d| d.deinit(),
        }
    }
};

fn detectFormat(path: []const u8) ?Format {
    if (std.mem.endsWith(u8, path, ".flac")) return .flac;
    if (std.mem.endsWith(u8, path, ".mp3")) return .mp3;
    if (std.mem.endsWith(u8, path, ".wav")) return .wav;
    return null;
}
