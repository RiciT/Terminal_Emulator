//Terminal state machine and screen buffer

//almost all of these esc sequences are from the [ghostty-vt source code](https://github.com/forketyfork/architect)

const std = @import("std");
const cfg = @import("config.zig");

//glyph attribute in a byte
pub const Attr = packed struct {
    bold: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    italic: bool = false,
    invisible: bool = false,
    _pad: u2 = 0,
};

//terminal cell
pub const Glyph = struct {
    char: u21 = ' ',
    fg: u8 = cfg.default_fg,
    bg: u8 = cfg.default_bg,
    attr: Attr = .{},
    filled: bool = true,
};

//cursor state
pub const Cursor = struct {
    x: i32 = 0,
    y: i32 = 0,
    fg: u8 = cfg.default_fg,
    bg: u8 = cfg.default_bg,
    attr: Attr = .{},
    hidden: bool = false,
};

//parser state
const State = enum { ground, escape, csi, osc };

const MAX_PARAMS = 16;
const MAX_OSC    = 512;

//Uft8Decoder state
const Utf8Dec = struct {
    buf: [4]u8 = undefined,
    len: u8 = 0,
    expected: u8 = 0,

    fn feed(self: *Utf8Dec, byte: u8) ?u21 {
        if (byte < 0x80) return @intCast(byte); // ASCII fast-path

        if (byte >= 0xC0) {
            //start byte -> reset and store
            self.buf[0] = byte;
            self.len = 1;
            self.expected = if (byte < 0xE0) 2 else if (byte < 0xF0) 3 else 4;
            return null;
        }

        //continuation byte
        if (self.len > 0 and self.len < 4) {
            self.buf[self.len] = byte;
            self.len += 1;
            if (self.len == self.expected) {
                const cp = std.unicode.utf8Decode(self.buf[0..self.len]) catch '?';
                self.len = 0;
                return @intCast(cp);
            }
        }
        return null;
    }
};

//TERMINAL
pub const Term = struct {
    alloc: std.mem.Allocator,
    cols: u32,
    rows: u32,

    screen: []Glyph, //primary screen buffer
    alt_screen: []Glyph, //alternate screen (used by vim, htop, etc.)
    use_alt: bool = false,

    cursor: Cursor = .{},
    saved_cursor: Cursor = .{}, // ESC 7 / ESC 8

    //parser
    state: State = .ground,
    params: [MAX_PARAMS]i32 = [_]i32{0} ** MAX_PARAMS,
    param_count: u8 = 0,
    csi_private: bool = false, // set when '?' seen - (DEC private modes)
    osc_buf: [MAX_OSC]u8 = undefined,
    osc_len: u32 = 0,

    //scroll region
    scroll_top: u32 = 0,
    scroll_bot: u32 = 0,

    //UTF8 streaming decoder
    utf8: Utf8Dec = .{},

    filled: bool = true,

    //lifecycle loop
    pub fn init(alloc: std.mem.Allocator, cols: u32, rows: u32) !Term {
        const screen = try alloc.alloc(Glyph, cols * rows);
        const alt_screen = try alloc.alloc(Glyph, cols * rows);
        @memset(screen, Glyph{});
        @memset(alt_screen, Glyph{});
        return Term{
            .alloc = alloc,
            .cols = cols,
            .rows = rows,
            .screen = screen,
            .alt_screen = alt_screen,
            .scroll_bot = rows - 1,
        };
    }

    pub fn deinit(self: *Term) void {
        self.alloc.free(self.screen);
        self.alloc.free(self.alt_screen);
    }

    pub fn resize(self: *Term, cols: u32, rows: u32) !void {
        const new_scr = try self.alloc.alloc(Glyph, cols * rows);
        const new_alt = try self.alloc.alloc(Glyph, cols * rows);
        @memset(new_scr, Glyph{});
        @memset(new_alt, Glyph{});

        //cwopy what fits of the old primary screen
        const copy_rows = @min(rows, self.rows);
        const copy_cols = @min(cols, self.cols);
        for (0..copy_rows) |r| {
            for (0..copy_cols) |c|
                new_scr[r * cols + c] = self.screen[r * self.cols + c];
        }

        self.alloc.free(self.screen);
        self.alloc.free(self.alt_screen);
        self.screen = new_scr;
        self.alt_screen = new_alt;
        self.cols = cols;
        self.rows = rows;
        self.scroll_top = 0;
        self.scroll_bot = rows - 1;
        self.cursor.x = @min(self.cursor.x, @as(i32, @intCast(cols - 1)));
        self.cursor.y = @min(self.cursor.y, @as(i32, @intCast(rows - 1)));
        //mark everything filled so the renderer redraws
        for (self.screen) |*g| g.filled = true;
        self.filled = true;
    }

    pub fn getScreen(self: *Term) []Glyph {
        return if (self.use_alt) self.alt_screen else self.screen;
    }

    //feed bytes from the pty to the parser
    pub fn feed(self: *Term, data: []const u8) void {
        for (data) |byte| self.processByte(byte);
    }

    //byte dispathing function
    fn processByte(self: *Term, byte: u8) void {
        // C0 control characters are always handled regardless of state
        switch (byte) {
            0x07 => {}, //BELL -> not going to handle cuz its very annoying
            0x08 => { self.cursor.x -= 1; self.clampCursor(); return; }, // BS
            0x09 => { self.doTab(); return; }, //HT
            0x0A, 0x0B, 0x0C => { self.doLinefeed(); return; }, //LF VT FF
            0x0D => { self.cursor.x = 0; return; }, // CR
            0x1B => { self.state = .escape; return; }, //ESC
            else => {},
        }

        switch (self.state) {
            .ground => self.doGround(byte),
            .escape => self.doEscape(byte),
            .csi => self.doCsi(byte),
            .osc => self.doOsc(byte),
        }
    }

    fn doGround(self: *Term, byte: u8) void {
        if (byte < 0x20 or byte == 0x7F) return; //ignore remaining C0/DEL
        if (self.utf8.feed(byte)) |cp| self.putChar(cp);
    }

    fn doEscape(self: *Term, byte: u8) void {
        self.state = .ground;
        switch (byte) {
            '[' => {
                // CSI - zero out params for fresh sequence
                self.state = .csi;
                self.param_count = 0;
                self.csi_private = false;
                @memset(&self.params, 0);
            },
            ']' => {
                self.state = .osc;
                self.osc_len = 0;
            },
            'M' => self.doReverseIndex(), // RI - scroll region down
            '7' => self.saved_cursor = self.cursor, //DECSC
            '8' => self.cursor = self.saved_cursor, //DECRC
            'c' => self.doReset(),          //RIS - full reset
            else => {},
        }
    }

    fn doCsi(self: *Term, byte: u8) void {
        switch (byte) {
            '?' => self.csi_private = true,
            '0'...'9' => {
                //get decimals into current param
                const i = if (self.param_count == 0) blk: {
                    self.param_count = 1;
                    break :blk @as(u8, 0);
                } else self.param_count - 1;
                self.params[i] = self.params[i] * 10 + @as(i32, byte - '0');
            },
            ';' => {
                //separator go to next param slot
                if (self.param_count < MAX_PARAMS) self.param_count += 1;
            },
            0x40...0x7E => {
                //final byte flush and return to ground
                if (self.param_count == 0 and self.params[0] == 0)
                    self.param_count = 0; //leave at zero if no params given

                self.state = .ground;
                if (self.csi_private)
                    self.dispatchDecPrivate(byte)
                else
                    self.dispatchCsi(byte);
            },
            else => self.state = .ground, // invalid abort
        }
    }

    fn doOsc(self: *Term, byte: u8) void {
        switch (byte) {
            0x07, 0x9C => self.state = .ground, //BEL or ST ends OSC
            0x1B => self.state = .ground, //ESC \ two-byte ST
            else => {
                if (self.osc_len < MAX_OSC - 1) {
                    self.osc_buf[self.osc_len] = byte;
                    self.osc_len += 1;
                }
            },
        }
        //OSC payloads we could act on: "0;title" = set window title.
        //for now we parse but discard.
    }

    //helpers
    inline fn p(self: *const Term, idx: u8, default: i32) i32 {
        if (idx < self.param_count and self.params[idx] != 0)
            return self.params[idx];
        return default;
    }

    inline fn cur(self: *Term) []Glyph {
        return if (self.use_alt) self.alt_screen else self.screen;
    }

    inline fn cell(self: *Term, x: u32, y: u32) *Glyph {
        return &self.cur()[y * self.cols + x];
    }

    fn clampCursor(self: *Term) void {
        self.cursor.x = std.math.clamp(self.cursor.x, 0, @as(i32, @intCast(self.cols - 1)));
        self.cursor.y = std.math.clamp(self.cursor.y, 0, @as(i32, @intCast(self.rows - 1)));
    }

    fn moveCursor(self: *Term, dx: i32, dy: i32) void {
        self.cursor.x += dx;
        self.cursor.y += dy;
        self.clampCursor();
    }

    //characther placement
    fn putChar(self: *Term, cp: u21) void {
        std.debug.print("putchar cp={} fg={} bg={}\n", .{cp, self.cursor.fg, self.cursor.bg});
        //wrap line
        if (self.cursor.x >= self.cols) {
            self.cursor.x = 0;
            self.cursor.y += 1;
            self.checkScroll();
        }

        const g = self.cell(@intCast(self.cursor.x), @intCast(self.cursor.y));
        g.* = Glyph{
            .char = cp,
            .fg = self.cursor.fg,
            .bg = self.cursor.bg,
            .attr = self.cursor.attr,
            .filled = true,
        };
        self.cursor.x += 1;
        self.filled = true;
    }

    fn doTab(self: *Term) void {
        const next = (@divTrunc(self.cursor.x, cfg.tab_width) + 1) * cfg.tab_width;
        self.cursor.x = @min(next, @as(i32, @intCast(self.cols - 1)));
    }

    fn doLinefeed(self: *Term) void {
        self.cursor.y += 1;
        self.checkScroll();
    }

    fn checkScroll(self: *Term) void {
        if (self.cursor.y > self.scroll_bot) {
            self.scrollUp(1);
            self.cursor.y = @intCast(self.scroll_bot);
        }
    }

    //scrolling
    fn scrollUp(self: *Term, n: i32) void {
        const lines: u32 = @intCast(@max(1, n));
        const top = self.scroll_top;
        const bot = self.scroll_bot;
        const scr = self.cur();

        //shift rows upward within the scroll region
        var r = top;
        while (r + lines <= bot) : (r += 1) {
            @memcpy(scr[r * self.cols..(r + 1) * self.cols],
                    scr[(r + lines) * self.cols..(r + lines + 1) * self.cols]);
            for (scr[r * self.cols..(r + 1) * self.cols]) |*g| g.filled = true;
        }
        while (r <= bot) : (r += 1) self.clearRow(r);
        self.filled = true;
    }

    fn scrollDown(self: *Term, n: i32) void {
        const lines: u32 = @intCast(@max(1, n));
        const top = self.scroll_top;
        const bot = self.scroll_bot;
        const scr = self.cur();

        var r = bot;
        while (r >= top + lines) : (r -= 1) {
            @memcpy(scr[r * self.cols..(r + 1) * self.cols], scr[(r - lines) * self.cols..(r - lines + 1) * self.cols]);
            for (scr[r * self.cols..(r + 1) * self.cols]) |*g| g.filled = true;
            if (r == 0) break;
        }
        var r2 = top;
        while (r2 < top + lines and r2 <= bot) : (r2 += 1)
            self.clearRow(r2);
        self.filled = true;
    }

    fn doReverseIndex(self: *Term) void {
        if (self.cursor.y == self.scroll_top)
            self.scrollDown(1)
        else
            self.cursor.y -= 1;
    }

    //clear line and screen
    fn clearRow(self: *Term, row: u32) void {
        const scr = self.cur();
        const start = row * self.cols;
        for (0..self.cols) |c| {
            scr[start + c] = Glyph{
                .fg = self.cursor.fg, .bg = self.cursor.bg, .filled = true,
            };
        }
    }

    fn eraseInLine(self: *Term, mode: i32) void {
        const row: u32 = @intCast(self.cursor.y);
        const col: u32 = @intCast(self.cursor.x);
        const scr = self.cur();
        const base = row * self.cols;
        const blank = Glyph{ .fg = self.cursor.fg, .bg = self.cursor.bg, .filled = true };

        switch (mode) {
            0 => for (col..self.cols) |c| { scr[base + c] = blank; }, //cursor - end
            1 => for (0..col + 1) |c| { scr[base + c] = blank; }, //start - cursor
            2 => for (0..self.cols) |c| { scr[base + c] = blank; }, //whole line
            else => {},
        }
        self.filled = true;
    }

    fn eraseInDisplay(self: *Term, mode: i32) void {
        const row: u32 = @intCast(self.cursor.y);
        const col: u32 = @intCast(self.cursor.x);
        const scr = self.cur();
        const blank = Glyph{ .fg = self.cursor.fg, .bg = self.cursor.bg, .filled = true };

        switch (mode) {
            0 => { //cursor to end of screen
                for (col..self.cols) |c| scr[row * self.cols + c] = blank;
                var r = row + 1;
                while (r < self.rows) : (r += 1) self.clearRow(r);
            },
            1 => { //start of screen to cursor
                for (0..row) |r| self.clearRow(@intCast(r));
                for (0..col + 1) |c| scr[row * self.cols + c] = blank;
            },
            2, 3 => { //whole screen - cursor not moved per VT100 spec
                for (0..self.rows) |r| self.clearRow(@intCast(r));
            },
            else => {},
        }
        self.filled = true;
    }

    //Select graphichs rendition - bold, etc...
    fn doSgr(self: *Term) void {
        const count = if (self.param_count == 0) @as(u8, 1) else self.param_count;
        var i: u8 = 0;
        while (i < count) : (i += 1) {
            //ignore trailing ; that isnt explicitly a reset
            if (self.params[i] == 0 and i > 0 and i == count - 1) continue;
            switch (self.params[i]) {
                0 => { self.cursor.attr = .{}; self.cursor.fg = cfg.default_fg; self.cursor.bg = cfg.default_bg; },
                1 => self.cursor.attr.bold = true,
                3 => self.cursor.attr.italic = true,
                4 => self.cursor.attr.underline = true,
                5 => self.cursor.attr.blink = true,
                7 => self.cursor.attr.reverse = true,
                8 => self.cursor.attr.invisible = true,
                22 => self.cursor.attr.bold = false,
                23 => self.cursor.attr.italic = false,
                24 => self.cursor.attr.underline = false,
                25 => self.cursor.attr.blink = false,
                27 => self.cursor.attr.reverse = false,
                28 => self.cursor.attr.invisible = false,
                30...37 => self.cursor.fg = @intCast(self.params[i] - 30),
                // 38-48 - 256-colour foreground
                38 => if (i + 2 < count and self.params[i + 1] == 5) {
                    self.cursor.fg = @intCast(self.params[i + 2]);
                    i += 2;
                },
                39 => self.cursor.fg = cfg.default_fg,
                40...47 => self.cursor.bg = @intCast(self.params[i] - 40),
                // 48-108 - 256-colour background
                48 => if (i + 2 < count and self.params[i + 1] == 5) {
                    self.cursor.bg = @intCast(self.params[i + 2]);
                    i += 2;
                },
                49 => self.cursor.bg = cfg.default_bg,
                90...97 => self.cursor.fg = @intCast(self.params[i] - 90 + 8),
                100...107 => self.cursor.bg = @intCast(self.params[i] - 100 + 8),
                else => {},
            }
        }
    }

    //csi dispatch
    fn dispatchCsi(self: *Term, final: u8) void {
        const l = self.p(0, 0);
        const n = self.p(0, 1);
        const m = self.p(1, 1);

        switch (final) {
            'A' => self.moveCursor(0, -n), //CUU cursor up
            'B' => self.moveCursor(0, n), //CUD cursor down
            'C' => self.moveCursor(n, 0), //CUF cursor right
            'D' => self.moveCursor(-n, 0), //CUB cursor left
            'E' => { self.cursor.x = 0; self.moveCursor(0, n); }, //CNL
            'F' => { self.cursor.x = 0; self.moveCursor(0, -n); },//CPL
            'G' => { self.cursor.x = @max(0, n - 1); self.clampCursor(); }, //CHA
            'H', 'f' => {
                //CUP - cursor position (1-based - 0-based)
                self.cursor.y = @max(0, n - 1);
                self.cursor.x = @max(0, m - 1);
                self.clampCursor();
            },
            'J' => self.eraseInDisplay(l), //ED
            'K' => self.eraseInLine(l), //EL
            'L' => self.insertLines(n), //IL
            'M' => self.deleteLines(n), //DL
            'P' => self.deleteChars(n), //DCH
            'S' => self.scrollUp(n),
            'T' => self.scrollDown(n),
            '@' => self.insertChars(n), //ICH
            'd' => { self.cursor.y = @max(0, n - 1); self.clampCursor(); }, //VPA
            'm' => self.doSgr(),//SGR
            'r' => {
                //DECSTBM - set scroll region (1-based)
                self.scroll_top = @intCast(@max(0, n - 1));
                self.scroll_bot = @intCast(@min(
                    @as(i32, @intCast(self.rows - 1)),
                    self.p(1, @intCast(self.rows)) - 1));
                self.cursor.x = 0;
                self.cursor.y = 0;
            },
            's' => self.saved_cursor = self.cursor, //SCP
            'u' => self.cursor = self.saved_cursor, //RCP
            else => {},
        }
        self.filled = true;
    }

    //DEC private mode dispatch - ?h / ?l
    fn dispatchDecPrivate(self: *Term, final: u8) void {
        const mode = self.p(0, 0);
        switch (final) {
            'h' => switch (mode) {
                25 => self.cursor.hidden = false, //DECTCEM show cursor
                1049 => self.switchAlt(true), //switch to alt screen
                else => {},
            },
            'l' => switch (mode) {
                25 => self.cursor.hidden = true, //DECTCEM hide cursor
                1049 => self.switchAlt(false), //switch to primary screen
                else => {},
            },
            else => {},
        }
    }

    fn switchAlt(self: *Term, to_alt: bool) void {
        if (to_alt and !self.use_alt) {
            self.saved_cursor = self.cursor;
            @memset(self.alt_screen, Glyph{});
            self.cursor.x = 0;
            self.cursor.y = 0;
        } else if (!to_alt and self.use_alt) {
            self.cursor = self.saved_cursor;
        }
        self.use_alt = to_alt;
        for (self.cur()) |*g| g.filled = true;
        self.filled = true;
    }

    //block editing
    fn insertLines(self: *Term, n: i32) void {
        const lines: u32 = @intCast(@max(1, n));
        const row: u32 = @intCast(self.cursor.y);
        const bot = self.scroll_bot;
        const scr = self.cur();
        var r = bot;
        while (r >= row + lines) : (r -= 1) {
            @memcpy(scr[r * self.cols..(r + 1) * self.cols],
                scr[(r - lines) * self.cols..(r - lines + 1) * self.cols]);
            if (r == 0) break;
        }
        var r2 = row;
        while (r2 < row + lines and r2 <= bot) : (r2 += 1) self.clearRow(r2);
    }

    fn deleteLines(self: *Term, n: i32) void {
        const lines: u32 = @intCast(@max(1, n));
        const row: u32 = @intCast(self.cursor.y);
        const bot = self.scroll_bot;
        const scr = self.cur();
        var r = row;
        while (r + lines <= bot) : (r += 1)
            @memcpy(scr[r * self.cols..(r + 1) * self.cols],
                scr[(r + lines) * self.cols..(r + lines + 1) * self.cols]);
        while (r <= bot) : (r += 1) self.clearRow(r);
    }

    fn insertChars(self: *Term, n: i32) void {
        const chars: u32 = @intCast(@max(1, n));
        const row: u32 = @intCast(self.cursor.y);
        const col: u32 = @intCast(self.cursor.x);
        const scr = self.cur();
        const base = row * self.cols;
        const blank = Glyph{ .fg = self.cursor.fg, .bg = self.cursor.bg, .filled = true };
        var c = self.cols - 1;
        while (c >= col + chars) : (c -= 1) scr[base + c] = scr[base + c - chars];
        var c2 = col;
        while (c2 < col + chars and c2 < self.cols) : (c2 += 1) scr[base + c2] = blank;
    }

    fn deleteChars(self: *Term, n: i32) void {
        const chars: u32 = @intCast(@max(1, n));
        const row: u32 = @intCast(self.cursor.y);
        const col: u32 = @intCast(self.cursor.x);
        const scr = self.cur();
        const base = row * self.cols;
        const blank = Glyph{ .fg = self.cursor.fg, .bg = self.cursor.bg, .filled = true };
        var c = col;
        while (c + chars < self.cols) : (c += 1) scr[base + c] = scr[base + c + chars];
        while (c < self.cols) : (c += 1) scr[base + c] = blank;
    }

    fn doReset(self: *Term) void {
        self.cursor = .{};
        self.saved_cursor = .{};
        self.scroll_top = 0;
        self.scroll_bot = self.rows - 1;
        self.state = .ground;
        self.use_alt = false;
        @memset(self.screen, Glyph{});
        @memset(self.alt_screen, Glyph{});
        self.filled = true;
    }
};
