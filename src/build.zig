const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "termemul",
        .root_module = b.path("src/main.zig"),
    });

    //sys libraries to link
    exe.linkSystemLibrary("X11");
    exe.linkSystemLibrary("Xft");
    exe.linkSystemLibrary("freetype2");
    exe.linkSystemLibrary("fontconfig");
    exe.linkSystemLibrary("util");
    exe.linkLibC(); //call into libc
}
