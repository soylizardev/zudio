const std = @import("std");

pub const Favorites = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []u8,
    paths: std.StringHashMapUnmanaged(void) = .empty,
    dirty: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !Favorites {
        var self = Favorites{
            .allocator = allocator,
            .io = io,
            .home = try allocator.dupe(u8, home),
        };

        const path = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/.config/zudio/favorites.txt",
            .{home},
            0,
        );
        defer allocator.free(path);

        var buf: [16384]u8 = undefined;
        const contents = std.Io.Dir.readFile(std.Io.Dir.cwd(), io, path, &buf) catch return self;

        var lines = std.mem.tokenizeScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            const dup = try allocator.dupe(u8, trimmed);
            try self.paths.put(allocator, dup, {});
        }
        return self;
    }

    pub fn deinit(self: *Favorites) void {
        var it = self.paths.keyIterator();
        while (it.next()) |k| {
            self.allocator.free(k.*);
        }
        self.paths.deinit(self.allocator);
        self.allocator.free(self.home);
    }

    pub fn isFavorite(self: *const Favorites, path: []const u8) bool {
        return self.paths.contains(path);
    }

    pub fn toggle(self: *Favorites, path: []const u8) bool {
        if (self.paths.contains(path)) {
            if (self.paths.fetchRemove(path)) |kv| {
                self.allocator.free(kv.key);
            }
            self.dirty = true;
            return false;
        } else {
            const dup = self.allocator.dupe(u8, path) catch return false;
            self.paths.put(self.allocator, dup, {}) catch {
                self.allocator.free(dup);
                return false;
            };
            self.dirty = true;
            return true;
        }
    }

    pub fn save(self: *Favorites) void {
        if (!self.dirty) return;

        const dir_path = std.fmt.allocPrintSentinel(
            self.allocator,
            "{s}/.config/zudio",
            .{self.home},
            0,
        ) catch return;
        defer self.allocator.free(dir_path);

        std.Io.Dir.cwd().createDirPath(self.io, dir_path) catch return;

        const path = std.fmt.allocPrintSentinel(
            self.allocator,
            "{s}/.config/zudio/favorites.txt",
            .{self.home},
            0,
        ) catch return;
        defer self.allocator.free(path);

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);

        var it = self.paths.keyIterator();
        while (it.next()) |k| {
            out.appendSlice(self.allocator, k.*) catch return;
            out.append(self.allocator, '\n') catch return;
        }

        var file = std.Io.Dir.cwd().createFile(self.io, path, .{}) catch return;
        defer file.close(self.io);
        file.writeStreamingAll(self.io, out.items) catch return;
        self.dirty = false;
    }
};
