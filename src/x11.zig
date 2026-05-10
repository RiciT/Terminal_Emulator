// X11 window and font rendering

//(0,0) is top-left
//Cell (col,row) -> pixel (border + col*rw, border + row*ch)
//Text baseline is at y + ascent so not the top of the cell

const std = @import("std");
const c = @import("c.zig").c; //c libs
const cfg = @import("config.zig");
const term = @import("term.zig");
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
            const r_v: u32 = if (r_i == 0) 0 else @as(u32, @intCast(r_i)) * 40 + 55;
            const g_v: u32 = if (g_i == 0) 0 else @as(u32, @intCast(g_i)) * 40 + 55;
            const b_v: u32 = if (b_i == 0) 0 else @as(u32, @intCast(b_i)) * 40 + 55;
            //XRenderColor channels are 16-bit a
            var x_colour = c.XRenderColor{
                .red = @intCast(r_v * 257),
                .green = @intCast(g_v * 257),
                .blue = @intCast(b_v * 257),
                .alpha = 0xFFFF,
            };
            _ = c.XftColorAllocValue(dpy, visual, cmap, &x_colour, &colours[i]);
        }

        //232-255 grayscale
        for (232..256) |i| {
            const val: u32 = (@as(u32, @intCast(i)) - 232) * 10 + 6;
            var x_colour = c.XRenderColor{
                .red = @intCast(val * 257),
                .green = @intCast(val * 257),
                .blue = @intCast(val * 257),
                .alpha = 0xFFFF,
            };
            _ = c.XftColorAllocValue(dpy, visual, cmap, &x_colour, &colours[i]);
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

    pub fn deinit(self: *Win) void {
        c.XftDrawDestroy(self.xft_draw);
        c.XftFontClose(self.dpy, self.font);
        _ = c.XDestroyWindow(self.dpy, self.win);
        _ = c.XCloseDisplay(self.dpy);
    }

    //X11 connection to be used in poll()
    pub fn fd(self: *const Win) i32 {
        return c.XConnectionNumber(self.dpy);
    }

    //rendering a single frame
    pub fn render(self: *Win, t: *term.Term) void {
        const screen = t.getScreen();

        for (0..t.rows) |row| {
            for (0..t.cols) |col| {
                const g = &screen[row * t.cols + col];
                if (!g.filled) continue;

                //reverse order swaps fg and bg
                const fg: u8 = if (g.attr.reverse) g.bg else g.fg;
                const bg: u8 = if (g.attr.reverse) g.fg else g.bg;

                const px: c_int = @intCast(cfg.border_px + col * self.cw);
                const py: c_int = @intCast(cfg.border_px + row * self.ch);

                //fill bg rectangle with bg colour pixel
                // use XFillRectangle because only solid colours are needed
                _ = c.XSetForeground(self.dpy, self.gc, self.colours[bg].pixel);
                _ = c.XFillRectangle(self.dpy, self.win, self.gc, px, py, self.cw, self.ch);

                //draw character (we can skip spaces)
                if (g.char == ' ' and g.char != 0 and !g.attr.invisible) {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(g.char, &buf) catch 1;

                    //XftDrawStringUtf8 takes the baseline y so modify with the ascent
                    const baseline: c_int = py + @as(c_int, @intCast(self.ca));

                    c.XftDrawStringUtf8(
                        self.xft_draw,
                        &self.colours[fg],
                        self.font,
                        px,
                        baseline,
                        &buf,
                        @intCast(len)
                    );

                    //underline
                    if (g.attr.underline) {
                        _ = c.XSetForeground(self.dpy, self.gc, self.colours[fg].pixel);
                        _ = c.XDrawLine(self.dpy, self.win, self.gc, px, baseline + 1,
                            px + @as(c_int, @intCast(self.cw)), baseline + 1);
                    }
                }

                g.filled = false;
            }
        }

        //draw cursor
        if (!t.cursor.hidden) {
            const cx: c_int = @intCast(cfg.border_px + @as(usize, @intCast(t.cursor.x)) * self.cw);
            const cy: c_int = @intCast(cfg.border_px + @as(usize, @intCast(t.cursor.y)) * self.ch);
            _ = c.XSetForeground(self.dpy, self.gc, self.colours[cfg.default_fg].pixel);
            _ = c.XDrawRectangle(self.dpy, self.win, self.gc,
                cx, cy,
                self.cw - 1,
                self.ch - 1);
        }

        //flush all drawing commands to the X server in one batch
        _ = c.XFlush(self.dpy);
    }

    //Window Resizing
    pub fn resize(self: *Win, pw: u32, ph: u32) struct { cols: u32, rows: u32 } {
        self.pw = pw;
        self.ph = ph;

        //redo XftDraw - cache drawables which changed on resize
        c.XftDrawDestroy(self.xft_draw);
        self.xft_draw = c.XftDrawCreate(self.dpy, self.win, self.visual, self.cmap).?;

        const cols = (pw - 2 * cfg.border_px) / self.cw;
        const rows = (ph - 2 * cfg.border_px) / self.ch;
        return .{ .cols = @max(1, cols), .rows = @max(1, rows) };
    }

    //Keyboard events -> byte sequences
    //This is to process escape sequences
    //for now only implement 'xterm-256color'
    pub fn translateKey(e: *c.XKeyEvent, buf: []u8,) []const u8 {
        var keysym: c.KeySym = undefined;
        var xbuf: [32]u8 = undefined;

        //XLookupStrings handles dead keys and modifiers
        const xlen: usize = @intCast(c.XLookupString(e, &xbuf, xbuf.len, &keysym, null));

        //keymap of special key of xterm esc sequences
        const special: ?[]const u8 = switch (keysym) {
            c.XK_Return    => "\r",
            c.XK_BackSpace => "\x7f",
            c.XK_Delete    => "\x1b[3~",
            c.XK_Escape    => "\x1b",
            c.XK_Tab       => "\t",
            c.XK_Up        => "\x1b[A",
            c.XK_Down      => "\x1b[B",
            c.XK_Right     => "\x1b[C",
            c.XK_Left      => "\x1b[D",
            c.XK_Home      => "\x1b[H",
            c.XK_End       => "\x1b[F",
            c.XK_Page_Up   => "\x1b[5~",
            c.XK_Page_Down => "\x1b[6~",
            c.XK_Insert    => "\x1b[2~",
            c.XK_F1        => "\x1bOP",
            c.XK_F2        => "\x1bOQ",
            c.XK_F3        => "\x1bOR",
            c.XK_F4        => "\x1bOS",
            c.XK_F5        => "\x1b[15~",
            c.XK_F6        => "\x1b[17~",
            c.XK_F7        => "\x1b[18~",
            c.XK_F8        => "\x1b[19~",
            c.XK_F9        => "\x1b[20~",
            c.XK_F10       => "\x1b[21~",
            c.XK_F11       => "\x1b[23~",
            c.XK_F12       => "\x1b[24~",
            else           => null,
        };

        if (special) |s| {
            //copy the literal into the caller's buffer
            //so return val lifetime is tied to buf rather than the literal
            const n = @min(s.len, buf.len);
            @memcpy(buf[0..n], s[0..n]);
            return buf[0..n];
        }

        //get printable char
        if (xlen > 0) {
            const n = @min(xlen, buf.len);
            @memcpy(buf[0..n], xbuf[0..n]);
            return buf[0..n];
        }

        return buf[0..0]; //theres nothing to return if we get here
    }
};
