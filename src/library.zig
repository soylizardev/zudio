const std = @import("std");
const metadata = @import("metadata.zig");

pub const Track = struct {
    path: [:0]u8,
    info: metadata.TrackInfo,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Track) void {
        self.info.deinit(self.allocator);
        self.allocator.free(self.path);
    }
};

pub const Library = struct {
    tracks: []Track,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Library) void {
        for (self.tracks) |*t| t.deinit();
        self.allocator.free(self.tracks);
    }
};

pub fn scan(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8) !Library {
    var tracks: std.ArrayListUnmanaged(Track) = .empty;
    errdefer {
        for (tracks.items) |*t| t.deinit();
        tracks.deinit(allocator);
    }

    var dir = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer dir.close(io);
    try scanDir(allocator, io, &tracks, dir, root_path, "");

    std.mem.sort(Track, tracks.items, {}, struct {
        fn lessThan(_: void, a: Track, b: Track) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);

    return .{ .tracks = try tracks.toOwnedSlice(allocator), .allocator = allocator };
}

fn scanDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    tracks: *std.ArrayListUnmanaged(Track),
    dir: std.Io.Dir,
    root_path: []const u8,
    prefix: []const u8,
) !void {
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .file and isAudio(entry.name)) {
            const full = if (prefix.len == 0)
                try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ root_path, entry.name }, 0)
            else
                try std.fmt.allocPrintSentinel(allocator, "{s}/{s}/{s}", .{ root_path, prefix, entry.name }, 0);
            errdefer allocator.free(full);
            const info = metadata.readTrackInfo(allocator, full);
            try tracks.append(allocator, .{ .path = full, .info = info, .allocator = allocator });
        } else if (entry.kind == .directory) {
            var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(io);
            const new_prefix = if (prefix.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
            defer allocator.free(new_prefix);
            try scanDir(allocator, io, tracks, sub, root_path, new_prefix);
        }
    }
}

fn isAudio(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".flac") or
        std.mem.endsWith(u8, name, ".mp3") or
        std.mem.endsWith(u8, name, ".wav");
}
