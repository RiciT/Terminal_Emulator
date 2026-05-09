// X11 window and font rendering

//(0,0) is top-left
//Cell (col,row) -> pixel (border + col*rw, border + row*ch)
//Text baseline is at y + ascent so not the top of the cell

const std = @import("std");
const c = @import("c.zig"); //c libs
//const cfg = @import("config.zig");
//const term = @import("term.zig");
//we dont need pty here

pub const Win = struct {
    dpy: *c.Display,
};
