const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // --- Header agregado que translateC procesará ---
    const c_header = b.addWriteFiles().add("c.h",
        \\#include <alsa/asoundlib.h>
        \\#include <FLAC/stream_decoder.h>
        \\#include <FLAC/metadata.h>
        \\#include "dr_mp3.h"
        \\#include "dr_wav.h"
    );

    const translate_c = b.addTranslateC(.{
        .root_source_file = c_header,
        .target = target,
        .optimize = optimize,
    });
    // Necesario para que el #include "dr_mp3.h" encuentre el archivo.
    translate_c.addIncludePath(b.path("src/vendor"));
    const c_module = translate_c.createModule();

    // --- Ejecutable principal ---
    const exe = b.addExecutable(.{
        .name = "zudio",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "c", .module = c_module },
            },
        }),
    });

    // Include path también para el compilador de C (dr_impl.c).
    exe.root_module.addIncludePath(b.path("src/vendor"));
    // Implementaciones de las dr_libs.
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/vendor/dr_impl.c"),
        .flags = &.{},
    });

    // Librerías del sistema que siguen siendo necesarias (ALSA + libFLAC).
    exe.root_module.linkSystemLibrary("FLAC", .{});
    exe.root_module.linkSystemLibrary("asound", .{});
    exe.root_module.link_libc = true;

    const gobject = b.dependency("gobject", .{
    .target = target,
    .optimize = optimize,
    });

    exe.root_module.addImport("gtk", gobject.module("gtk4"));
    exe.root_module.addImport("adw", gobject.module("adw1"));
    exe.root_module.addImport("gobject", gobject.module("gobject2"));
    exe.root_module.addImport("glib", gobject.module("glib2"));
    exe.root_module.addImport("gio", gobject.module("gio2"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run Zudio");
    run_step.dependOn(&run_cmd.step);
}
