const std = @import("std");
const audio = @import("audio.zig");
const device = @import("device.zig");
const decoder = @import("decoder.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var list_devices = false;
    var forced_device: ?[:0]const u8 = null;
    var file_arg: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--list-devices")) {
            list_devices = true;
        } else if (std.mem.eql(u8, a, "--device")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("--device requiere un argumento\n", .{});
                return error.MissingDeviceArg;
            }
            forced_device = try allocator.dupeZ(u8, args[i]);
        } else if (a.len > 0 and a[0] == '-') {
            std.debug.print("Opción desconocida: {s}\n", .{a});
            return error.UnknownOption;
        } else {
            file_arg = a;
        }
    }

    if (list_devices) {
        var dl = try device.listAllHw(allocator);
        defer dl.deinit();
        std.debug.print("Dispositivos hw: disponibles:\n", .{});
        for (dl.items) |d| std.debug.print("  {s}\n", .{d.name});
        return;
    }

    const file: [:0]const u8 = if (file_arg) |f|
        try allocator.dupeZ(u8, f)
    else
        try allocator.dupeZ(u8, "test.flac");

    // Elige el dispositivo: forzado, o el primero disponible.
    var auto_dev: ?device.Device = null;
    defer if (auto_dev) |*d| d.deinit();

    const dev_name: [:0]const u8 = if (forced_device) |f|
        f
    else blk: {
        auto_dev = try device.findDefaultHw(allocator);
        break :blk auto_dev.?.name;
    };
    std.debug.print("Device: {s}\n", .{dev_name});

    var engine = try audio.AudioEngine.init(dev_name);
    defer engine.deinit();

    var dec = try decoder.Decoder.open(allocator, file);
    defer dec.deinit();

    const info = dec.info();
    std.debug.print("File: {d} Hz, {d} bits, {d} ch, format={s}\n", .{
        info.sample_rate,
        info.bits_per_sample,
        info.channels,
        @tagName(std.meta.activeTag(dec)),
    });

    try engine.configure(info.sample_rate, 2, info.bits_per_sample);
    engine.printActualHwParams();

    try dec.decode(audio.sinkFor(&engine));

    engine.drain();
    std.debug.print("Reproducción completada.\n", .{});
}
