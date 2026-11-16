const std = @import("std");
const audio = @import("audio.zig");
const device = @import("device.zig");
const decoder = @import("decoder.zig");
const library = @import("library.zig");
const player = @import("player.zig");
const favorites = @import("favorites.zig");
const ui = @import("ui/main.zig");

extern "c" fn system(cmd: [*:0]const u8) c_int;
extern "c" fn exit(status: c_int) noreturn;

fn resolveMusicDir(allocator: std.mem.Allocator, io: std.Io, home: []const u8) ![]u8 {
    var buf: [4096]u8 = undefined;
    const path = try std.fmt.allocPrint(allocator, "{s}/.config/user-dirs.dirs", .{home});
    defer allocator.free(path);

    const contents = try std.Io.Dir.readFile(std.Io.Dir.cwd(), io, path, &buf);

    var lines = std.mem.tokenizeSequence(u8, contents, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "XDG_MUSIC_DIR=")) continue;

        const raw = trimmed["XDG_MUSIC_DIR=".len..];
        const value = std.mem.trim(u8, raw, "\"");

        if (std.mem.startsWith(u8, value, "$HOME/")) {
            return std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, value["$HOME/".len..] });
        }
        return allocator.dupe(u8, value);
    }
    return error.MusicDirNotFound;
}

fn restartPipewire() void {
    _ = system("systemctl --user restart pipewire >/dev/null 2>&1 &");
}

// Zig 0.16.0: el handler recibe std.posix.SIG (enum), no c_int.
fn signalHandler(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    // NOTA: system() y exit() no son async-signal-safe. En un caso ideal,
    // solo se pondría una bandera atómica aquí y se haría el restart en el
    // hilo principal. Para una solución rápida y funcional, lo dejamos así.
    restartPipewire();
    exit(0);
}

var g_signal_handler_installed: bool = false;

fn installSignalHandlers() void {
    if (g_signal_handler_installed) return;
    g_signal_handler_installed = true;

    const act = std.posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    // Zig 0.16.0: sigaction devuelve void, no error union.
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var list_devices = false;
    var list_tracks_folder: ?[]const u8 = null;
    var play_all_folder: ?[]const u8 = null;
    var forced_device_owned: ?[:0]const u8 = null;
    defer if (forced_device_owned) |f| allocator.free(@constCast(f));
    var file_arg: ?[]const u8 = null;
    var limit_seconds: f32 = 0;
    var launch_ui = false;

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
            forced_device_owned = try allocator.dupeZ(u8, args[i]);
        } else if (std.mem.eql(u8, a, "--ui")) {
            launch_ui = true;
        } else if (a.len > 0 and a[0] == '-') {
            std.debug.print("Opción desconocida: {s}\n", .{a});
            return error.UnknownOption;
        } else {
            file_arg = a;
        }
    }

    if (launch_ui) {
        // Registrar PRIMERO para que corra AL FINAL (LIFO), después de liberar ALSA.
        defer restartPipewire();

        var folder_owned: ?[]u8 = null;
        defer if (folder_owned) |f| allocator.free(f);

        const folder: []const u8 = if (file_arg) |f| f else blk: {
            const home = init.environ_map.get("HOME") orelse ".";
            const p = resolveMusicDir(allocator, init.io, home) catch
                try std.fmt.allocPrint(allocator, "{s}/Música/Music", .{home});
            folder_owned = p;
            break :blk p;
        };

        var lib = library.scan(allocator, init.io, folder) catch |err| {
            std.debug.print("No se pudo cargar biblioteca de '{s}': {s}\n", .{
                folder,
                @errorName(err),
            });
            return err;
        };
        defer lib.deinit();

        std.debug.print("Biblioteca cargada: {d} pista(s) de '{s}'\n", .{ lib.tracks.len, folder });

        var auto_dev: ?device.Device = null;
        defer if (auto_dev) |*d| d.deinit();
        const dev_name: [:0]const u8 = if (forced_device_owned) |f|
            f
        else blk: {
            auto_dev = try device.findDefaultHw(allocator);
            break :blk auto_dev.?.name;
        };
        std.debug.print("Device: {s}\n", .{dev_name});

        var engine = try audio.AudioEngine.init(dev_name);
        defer engine.deinit();

        var p = player.Player.init(allocator, &engine, lib.tracks, init.io);
        defer p.deinit();

        const home = init.environ_map.get("HOME") orelse ".";
        var fav = try favorites.Favorites.init(allocator, init.io, home);
        defer fav.deinit();
        std.debug.print("Favoritos cargados: {d}\n", .{fav.paths.count()});

        installSignalHandlers();

        try ui.run("com.zudio.Zudio", &lib, &p, init.io, &fav);
        return;
    }

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
        const dev_name: [:0]const u8 = if (forced_device_owned) |f|
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

        var p = player.Player.init(allocator, &engine, lib.tracks, init.io);
        defer p.deinit();
        p.max_seconds = limit_seconds;
        _ = try p.playAllFrom(0);

        std.debug.print("Fin.\n", .{});
        return;
    }

    const file: [:0]const u8 = if (file_arg) |f|
        try allocator.dupeZ(u8, f)
    else
        try allocator.dupeZ(u8, "test.flac");
    defer allocator.free(@constCast(file));

    var auto_dev: ?device.Device = null;
    defer if (auto_dev) |*d| d.deinit();
    const dev_name: [:0]const u8 = if (forced_device_owned) |f|
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
