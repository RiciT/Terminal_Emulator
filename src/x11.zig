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
    XftDrawFailure,
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
    xft_draw: *c.XftDraw,
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
        size_hints.width = @intCast(pw);
        size_hints.height = @intCast(ph);
        size_hints.width_inc = @intCast(cw);
        size_hints.height_inc = @intCast(ch);
        size_hints.min_width = @intCast(2 * cfg.border_px + cw);
        size_hints.min_height = @intCast(2 * cfg.border_px + ch);
        c.XSetWMNormalHints(dpy, win, &size_hints);
        _ = c.XStoreName(dpy, win, "termemul");

        //tell X which events to care about
        //KeyPressMask - keyboard input
        //ExposureMask - window revealed -> redraw needed
        //StructureNotifyMask - resize / destroy events
        _ = c.XSelectInput(dpy, win,
            c.KeyPressMask | c.ExposureMask | c.StructureNotifyMask);

        //create an Xft drawing context fo this window
        //this is will be handed for XftDraw* calls
        const xft_draw = c.XftDrawCreate(dpy, win, visual, cmap) orelse return error.XftDrawFailure;

        //plain X GC for background fills -> XFillRectangle, XDrawLine
        var gc_vals = std.mem.zeroes(c.XGCValues);
        const gc = c.XCreateGC(dpy, win, 0, &gc_vals);

        //allocate colours
        var colours: [256]c.XftColor = undefined;

        //0-15 named palette from cfg
        for (cfg.palette16, 0..) |hex, i| {
            if (c.XftColorAllocName(dpy, visual, cmap, hex.ptr, &colours[i]) == 0)
                _ = c.XftColorAllocName(dpy, visual, cmap, "#ffffff", &colours[i]);
        }

        //16-231 rest is 6x6x6 rgb colour cube
        // formula: index = 16 + 36r + 6g + b (r,g,b in 0..5) -> ex: 0->#000000, 1->#5f0000
        for (16..232) |i| {
            const idx = i - 16;
            const r_i = idx / 36;
            const g_i = (idx / 6) % 6;
            const b_i = idx % 6;
            const r_v: u32 = if (r_i == 0) 0 else r_i * 40 + 55;
            const g_v: u32 = if (g_i == 0) 0 else g_i * 40 + 55;
            const b_v: u32 = if (b_i == 0) 0 else b_i * 40 + 55;
            //XRenderColor channels are 16-bit a
            var x_colour = c.XRenderColor{
                .red = @intCast(r_v * 257),
                .green = @intCast(g_v * 257),
                .blue = @intCast(b_v * 257),
                .alpha = 0xFFFF,
            };
            c.XftColorAllocValue(dpy, visual, cmap, &x_colour, &colours[i]);
        }

        //232-255 grayscale
        for (232..256) |i| {
            const val: u32 = (i - 232) * 10 + 6;
            var x_colour = c.XRenderColor{
                .red = @intCast(val * 257),
                .green = @intCast(val * 257),
                .blue = @intCast(val * 257),
                .alpha = 0xFFFF,
            };
            c.XftColorAllocValue(dpy, visual, cmap, &x_colour, &colours[i]);
        }

        //show the window nad flush commands to the X server
        _ = c.XMapWindow(dpy, win);
        _ = c.XFlush(dpy);

        return Win{
            .dpy = dpy,
            .win = win,
            .screen = screen,
            .visual = visual,
            .cmap = cmap,
            .font = font,
            .xft_draw = xft_draw,
            .gc = gc,
            .colours = colours,
            .cw = cw,
            .ch = ch,
            .ca = ca,
            .pw = pw,
            .ph = ph,
        };
    }


};
