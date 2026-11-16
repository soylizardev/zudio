const std = @import("std");
const player = @import("../player.zig");

const Command = union(enum) {
    play: usize,
    seek: u64,
};

pub const AudioController = struct {
    player: *player.Player,
    thread: std.Thread,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    pending: ?Command = null,
    running: std.atomic.Value(bool) = .init(true),

    pub fn init(allocator: std.mem.Allocator, p: *player.Player, io: std.Io) !*AudioController {
        const self = try allocator.create(AudioController);
        self.* = .{ .player = p, .thread = undefined, .io = io };
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
        return self;
    }

    pub fn setQueue(self: *AudioController, indices: []const usize) void {
        self.player.setQueue(indices);
    }

    pub fn play(self: *AudioController, index: usize) void {
        self.player.engine.unpause() catch {};
        self.player.is_paused.store(false, .release);
        self.mutex.lockUncancelable(self.io);
        self.pending = .{ .play = index };
        self.mutex.unlock(self.io);
        self.player.requestStop();
    }

    pub fn seekToFrame(self: *AudioController, frame: u64) void {
        self.player.engine.unpause() catch {};
        self.player.is_paused.store(false, .release);
        self.mutex.lockUncancelable(self.io);
        self.pending = .{ .seek = frame };
        self.mutex.unlock(self.io);
        self.player.requestStop();
    }

    pub fn next(self: *AudioController) void {
        if (self.player.nextIndex()) |idx| self.play(idx);
    }

    pub fn prev(self: *AudioController) void {
        if (self.player.prevIndex()) |idx| self.play(idx);
    }

    pub fn togglePause(self: *AudioController) void {
        const paused = self.player.is_paused.load(.monotonic);
        if (paused) {
            self.player.engine.unpause() catch return;
            self.player.is_paused.store(false, .release);
        } else {
            self.player.engine.pause() catch return;
            self.player.is_paused.store(true, .release);
        }
    }

    pub fn toggleShuffle(self: *AudioController) void {
        self.player.toggleShuffle();
    }

    pub fn cycleRepeat(self: *AudioController) void {
        self.player.cycleRepeat();
    }

    pub fn shutdown(self: *AudioController) void {
        self.running.store(false, .release);
        self.player.engine.unpause() catch {};
        self.player.requestStop();
        self.thread.join();
    }

    fn runLoop(self: *AudioController) void {
        while (self.running.load(.acquire)) {
            var cmd: ?Command = null;
            self.mutex.lockUncancelable(self.io);
            cmd = self.pending;
            self.pending = null;
            self.mutex.unlock(self.io);

            if (cmd) |c| switch (c) {
                .play => |idx| {
                    _ = self.player.playAt(idx) catch {};
                },
                .seek => |frame| {
                    const cur = self.player.current_index.load(.acquire);
                    if (cur >= 0) {
                        const idx: usize = @intCast(cur);
                        _ = self.player.playAtFromFrame(idx, frame) catch {};
                    }
                },
            };

            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
        }
    }
};
