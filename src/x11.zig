// X11 window and font rendering

//(0,0) is top-left
//Cell (col,row) -> pixel (border + col*rw, border + row*ch)
//Text baseline is at y + ascent so not the top of the cell

const std = @import("std");
const c = @import("c.zig").c; //c libs
const cfg = @import("config.zig");
//const term = @import("term.zig");
//we dont need pty here

const WinError = error{
    NoDisplay,
    FontNotFound,
};

pub const Win = struct {
    //win props
    dpy: *c.Display,
    win: c.Window,
    screen: c_int,
    visual: *c.Visual,
    cmap: c.Colormap,

    //text
    font: *c.XftFont,
    xftdraw: *c.XftDraw,
    gc: c.GC,

    //pre-allocate all 256 xterm colours
    colours: [256]c.XftColor,

    //font matrices (in pixels)
    cw: u32, //cell width
    ch: u32, //cell heigth
    ca: u32, //ascent (offset from top of cell)

    //current window pixel dims
    pw: u32,
    ph: u32,

    // INIT window, font, colours
    pub fn init(cols: u32, rows: u32) !Win {
        //connect to X server by $DISPLAY
        const dpy = c.XOpenDisplay(null) orelse return error.NoDisplay;
        const screen = c.DefaultScreen(dpy);
        const root = c.RootWindow(dpy, screen);
        const visual = c.DefaultVisual(dpy, screen);
        const cmap = c.DefaultColormap(dpy, screen);

        //Xft font lookup via fontconfig
        const font = c.XftFontOpenName(dpy, screen, cfg.font_name.ptr) orelse return error.FontNotFound;

        //moonospace fonts - advance width is the cell width
        const cw: u32 = @intCast(font.*.max_advance_width);
        const ch: u32 = @intCast(font.*.ascent + font.*.descent);
        const ca: u32 = @intCast(font.*.ascent);

        const pw: u32 = cols * cw + 2 * cfg.border_px;
        const ph: u32 = rows * ch + 2 * cfg.border_px;

        // create the actual window
        // CWBackPixel is the background color
        // CWBorderPixel - neede when depth != parent depth
        // CWBitGravity - keep contents aligned to where
        var wa = std.mem.zeroes(c.XSetWindowAttributes);
        wa.background_pixel = c.BlackPixel(dpy, screen);
        wa.border_pixel = c.BlackPixel(dpy, screen);
        wa.bit_gravity = c.NorthWestGravity;

        const win = c.XCreateWindow(
            dpy, root,
            0, 0, pw, ph,
            0, c.CopyFromParent, c.InputOutput, visual,
            c.CWBackPixel | c.CWBorderPixel | c.CWBitGravity,
            &wa
        );

        //WM Hints - accomodating snapping
        var size_hints = std.mem.zeroes(c.XSizeHints);
    }
};
