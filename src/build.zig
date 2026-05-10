const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zigterm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    //sys libraries and libc to link
    exe.linkLibC(); //call into libc
    exe.linkSystemLibrary("X11");
    exe.linkSystemLibrary("Xft");
    exe.linkSystemLibrary("freetype2");
    exe.linkSystemLibrary("fontconfig");
    exe.linkSystemLibrary("util");

    //this makes zig output the file into 'zig-out/bin'
    b.installArtifact(exe);

    //setup a run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    //allow passing in arguments like 'zig build run -- arg1 arg2'
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the terminal emulator");
    run_step.dependOn(&run_cmd.step);
}
