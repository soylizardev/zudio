const std = @import("std");
const c = @import("c");

pub const Device = struct {
    name: [:0]u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Device) void {
        self.allocator.free(self.name);
    }
};

/// Devuelve el primer dispositivo PCM de hardware directo.
pub fn findDefaultHw(allocator: std.mem.Allocator) !Device {
    var hints_raw: ?*anyopaque = null;
    const err = c.snd_device_name_hint(-1, "pcm", @ptrCast(&hints_raw));
    if (err < 0) {
        std.debug.print("ALSA hint error ({d}): {s}\n", .{
            err,
            std.mem.sliceTo(c.snd_strerror(err), 0),
        });
        return error.AlsaHintFailed;
    }
    defer _ = c.snd_device_name_free_hint(@ptrCast(@alignCast(hints_raw)));
    const hints: [*c]?*anyopaque = @ptrCast(@alignCast(hints_raw.?));

    var i: usize = 0;
    while (hints[i] != null) : (i += 1) {
        const hint = hints[i].?;
        const name_raw = c.snd_device_name_get_hint(@ptrCast(hint), "NAME");
        if (name_raw == null) continue;
        const name_ptr: [*c]u8 = @ptrCast(name_raw);
        defer c.free(@ptrCast(name_ptr));
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(name_ptr)));

        if (std.mem.startsWith(u8, name, "front:CARD=")) {
            const rest = name["front:".len..];
            const hw_name = try std.fmt.allocPrintSentinel(allocator, "hw:{s}", .{rest}, 0);
            return .{ .name = hw_name, .allocator = allocator };
        }
    }
    return error.NoHwDeviceFound;
}

pub const DeviceList = struct {
    items: []Device,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DeviceList) void {
        for (self.items) |*d| d.deinit();
        self.allocator.free(self.items);
    }
};

/// Devuelve todos los dispositivos hw: disponibles (sin duplicados por CARD/DEV).
pub fn listAllHw(allocator: std.mem.Allocator) !DeviceList {
    var hints_raw: ?*anyopaque = null;
    const err = c.snd_device_name_hint(-1, "pcm", @ptrCast(&hints_raw));
    if (err < 0) return error.AlsaHintFailed;
    defer _ = c.snd_device_name_free_hint(@ptrCast(@alignCast(hints_raw)));
    const hints: [*c]?*anyopaque = @ptrCast(@alignCast(hints_raw.?));

    var list: std.ArrayListUnmanaged(Device) = .empty;
    errdefer {
        for (list.items) |*d| d.deinit();
        list.deinit(allocator);
    }

    var i: usize = 0;
    while (hints[i] != null) : (i += 1) {
        const hint = hints[i].?;
        const name_raw = c.snd_device_name_get_hint(@ptrCast(hint), "NAME");
        if (name_raw == null) continue;
        const name_ptr: [*c]u8 = @ptrCast(name_raw);
        defer c.free(@ptrCast(name_ptr));
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(name_ptr)));

        if (!std.mem.startsWith(u8, name, "front:CARD=")) continue;
        const rest = name["front:".len..];
        const hw_name = try std.fmt.allocPrintSentinel(allocator, "hw:{s}", .{rest}, 0);

        // Evitar duplicados (algunos sistemas exponen el mismo CARD/DEV dos veces).
        var duplicate = false;
        for (list.items) |d| {
            if (std.mem.eql(u8, d.name, hw_name)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            allocator.free(hw_name);
            continue;
        }

        try list.append(allocator, .{ .name = hw_name, .allocator = allocator });
    }

    return .{ .items = try list.toOwnedSlice(allocator), .allocator = allocator };
}
