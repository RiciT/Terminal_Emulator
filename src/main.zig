// startup and event loop handled here
//
// our even loop will looks something like this
//          event loop
//      poll() <-- X11 window events
//             <-- PTY events
//
//      is PTY readable?    |   is X11 readable?
//          |               |       |
//          read bytes      |   XNextEvent
//          term.feed()     |   KeyPress -> pty.write()
//          win.render()    |   redraw()
//
//
// the poll function will block until either has data
// this avoids busy-looping with still being able to
// react immediately


const std = @import("std");
const c = @import("c.zig").c; //c libs
const cfg = @import("config.zig"); //some config file
const Term = @import("term.zig").Term; //script that handles terminal
const Pty = @import("pty.zig").Pty; // script that handles pty
const Win = @import("x11.zig").Win; //script that handles x11 window

pub fn main() !void {
    //init locale for unicode chars
    _ = c.setlocale(c.LC_ALL, "");

    //allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    _ = c.signal(c.SIGPIPE, c.SIG_IGN); //ignore sigpipe as we already handle it
    _ = c.signal(c.SIGCHLD, c.SIG_DFL); //cant ignore as then wait4() fails
                                        //and shell becomes a zombie
                                        //this way the kernel automatically reaps
                                        //the shell

    // Init subsystems
    // first spawn the window so we get the font and therefore cell size
    var win = try Win.init(cfg.default_cols, cfg.default_rows);
    defer win.deinit();

    var terminal = try Term.init(alloc, cfg.default_cols, cfg.default_rows);
    defer terminal.deinit();

    var pty = try Pty.spawn(
        @intCast(cfg.default_cols),
        @intCast(cfg.default_rows),
    );
    defer pty.deinit();

    //state declaration
    var pty_buf: [4096]u8 = undefined; //read buffer for pty data
                                       //- arbitrary size for now

    var key_buf: [32]u8 = undefined;
    var xevent: c.XEvent = undefined;

    //main event loop
    while(true) {
        //poll() wathes two fds in paralell:
        //  [0] X11 connection - any pending events?
        //  [1] PTY master - any shell stdout?

        //timeout of 20ms can help with cursor blinking and stuff
        //  could be -1 to block forever until fd is ready
        var pfds = [_]c.struct_pollfd{
            .{ .fd = win.fd(), .events = c.POLLIN, .revents = 0 },
            .{ .fd = pty.master, .events = c.POLLIN, .revents = 0 },
        };

        const ready = c.poll(&pfds, pfds.len, 20);
        if (ready < 0) break; //interrupted by fatal signal

        //pty data <-- shell produced output
        // read as much as available in one syscall then feed it to the VT
        // we want to parse everything before redrawing!
        if (pfds[1].revents & c.POLLIN != 0) {
            const n = pty.read(&pty_buf) catch break; //EIO = shell exit

            if (n == 0) break;
            terminal.feed(pty_buf[0..n]);
            win.render(&terminal);
        }

        //X11 events -> keyboard, resize, expose
        //note: XPending() is non-blocking so drain all before polling again
        //as it could make the keyboard lag
        while (c.XPending(win.dpy) > 0) {
            _ = c.XNextEvent(win.dpy, &xevent);

            switch (xevent.type) {
                //keyboard
                c.KeyPress => {
                    const bytes = Win.translateKey(&xevent.xkey, &key_buf);
                    if (bytes.len > 0) pty.write(bytes);
                },
                //win exposed -> uncovered
                c.Expose => {
                    if (xevent.xexpose.count == 0) {
                        for (terminal.screen) |*g| g.filled = true;
                        for (terminal.alt_screen) |*g| g.filled = true;
                        win.render(&terminal);
                    }
                },
                //win resized
                c.ConfigureNotify => {
                    const e = xevent.xconfigure;
                    const new_pw: u32 = @intCast(e.width);
                    const new_ph: u32 = @intCast(e.height);
                    if (new_pw != win.pw or new_ph != win.ph) {
                        const dims = win.resize(new_pw, new_ph);
                        try terminal.resize(dims.cols, dims.rows);
                        pty.resize(@intCast(dims.cols), @intCast(dims.rows));
                        win.render(&terminal);
                    }
                },
                //win destroyed
                c.DestroyNotify => return,

                else => {},
            }
        }
    }
}
