const std = @import("std");
const audio = @import("audio.zig");
const device = @import("device.zig");
const decoder = @import("decoder.zig");
const library = @import("library.zig");
const player = @import("player.zig");
const ui = @import("ui/main.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var list_devices = false;
    var list_tracks_folder: ?[]const u8 = null;
    var play_all_folder: ?[]const u8 = null;
    var forced_device: ?[:0]const u8 = null;
    var file_arg: ?[]const u8 = null;
    var limit_seconds: f32 = 0;
    var launch_ui = false;   // <-- NUEVO

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--list-devices")) {
            list_devices = true;
        } else if (std.mem.eql(u8, a, "--list-tracks")) {
            i += 1;
            if (i >= args.len) return error.MissingFolderArg;
            list_tracks_folder = args[i];
        } else if (std.mem.eql(u8, a, "--play-all")) {
            i += 1;
            if (i >= args.len) return error.MissingFolderArg;
            play_all_folder = args[i];
        } else if (std.mem.eql(u8, a, "--limit")) {
            i += 1;
            if (i >= args.len) return error.MissingLimitArg;
            limit_seconds = try std.fmt.parseFloat(f32, args[i]);
        } else if (std.mem.eql(u8, a, "--device")) {
            i += 1;
            if (i >= args.len) return error.MissingDeviceArg;
            forced_device = try allocator.dupeZ(u8, args[i]);
        } else if (std.mem.eql(u8, a, "--ui")) {   // <-- NUEVO
            launch_ui = true;                       // <-- NUEVO
        } else if (a.len > 0 and a[0] == '-') {
            std.debug.print("Opción desconocida: {s}\n", .{a});
            return error.UnknownOption;
        } else {
            file_arg = a;
        }
    }

    // --- Modo: interfaz gráfica ---                         // <-- BLOQUE NUEVO
    if (launch_ui) {                                          // <-- BLOQUE NUEVO
        try ui.run("com.zudio.Zudio");                        // <-- BLOQUE NUEVO
        return;                                               // <-- BLOQUE NUEVO
    }                                                         // <-- BLOQUE NUEVO

    if (list_devices) {
        var dl = try device.listAllHw(allocator);
        defer dl.deinit();
        std.debug.print("Dispositivos hw: disponibles:\n", .{});
        for (dl.items) |d| std.debug.print("  {s}\n", .{d.name});
        return;
    }

    if (list_tracks_folder) |folder| {
        var lib = try library.scan(allocator, init.io, folder);
        defer lib.deinit();
        std.debug.print("Pistas encontradas en '{s}': {d}\n", .{ folder, lib.tracks.len });
        for (lib.tracks, 0..) |t, idx| {
            std.debug.print("  [{d:>3}] {s}\n", .{ idx + 1, t.path });
        }
        return;
    }

    if (play_all_folder) |folder| {
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

        var lib = try library.scan(allocator, init.io, folder);
        defer lib.deinit();

        std.debug.print("Reproduciendo {d} pista(s) de '{s}'...\n", .{ lib.tracks.len, folder });
        if (limit_seconds > 0) {
            std.debug.print("(límite por pista: {d:.1}s)\n", .{limit_seconds});
        }

        var p = player.Player.init(allocator, &engine, lib.tracks);
        p.max_seconds = limit_seconds;
        _ = try p.playAllFrom(0);

        std.debug.print("Fin.\n", .{});
        return;
    }

    // Modo por defecto: reproducir un solo archivo.
    const file: [:0]const u8 = if (file_arg) |f|
        try allocator.dupeZ(u8, f)
    else
        try allocator.dupeZ(u8, "test.flac");

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
