//pseudo-terminal (pty) management
// - master - this
// - slave - inhereted by the shell
//
// flow:    openpty() -> allocates the master/slave pair
//          fork() -> splits into parent (emulator) and shell (child)
//          child: ->   setsid() + TIOSCTTY -> makes slave the controlling term
//                      dup2(slave, 0/1/2) -> shell's stdio = the pty slave
//                      execvp("bin/sh") -> replace child with shell
//          parent: -> keeps master closes slave

const std = @import("std");
const c = @import("c.zig").c;
const cfg = @import("config.zig");

const PtyErrors = error{
    OpenPtyFailed,
    ForkFailed,
    HangUp,
};

pub const Pty = struct {
    master: i32,

    //fork a shell with a fresh PTY sized to cols x rows
    //returns the parent PTY stuct - the child is the shell
    pub fn spawn(cols: u32, rows: u32) !Pty {
        var master: c_int = undefined;
        var slave: c_int = undefined;

        //initial window size so the shell knows its dimensions
        var win_size = c.struct_winsize{
            .ws_col = @intCast(cols),
            .ws_row = @intCast(rows),
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        //openpty() allocates a pty pair and sets the initial win size
        if (c.openpty(&master, &slave, null, null, &win_size) < 0)
            return error.OpenPtyFailed;

        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;

        if (pid == 0) {
            //child process

            //master belongs to the parent
            _ = c.close(master);

            //create a new session and detach from the parent's controlling terminal
            _ = c.setsid();

            //make the slave the controlling terminal
            //TIOSCTTY sets ctty to the fd -> which requires being session leader
            if (c.ioctl(slave, c.TIOCSCTTY, @as(c_int, 0)) < 0)
                std.process.exit(1);

            //wire slave to standard streams
            _ = c.dup2(slave, 0); //stdin
            _ = c.dup2(slave, 1); //stdout
            _ = c.dup2(slave, 2); //stderr
            if (slave > 2) _ = c.close(slave);

            //set colours to xterm256 so that programs use full colour
            _ = c.setenv("TERM", "xterm-256color", 1);

            //replace child with shell - search PATH with execvp
            //argv must be null terminated but cast is safe here
            var argv = [_:null]?[*:0]const u8{ cfg.shell.ptr, null };
            _ = c.execvp(cfg.shell.ptr, @ptrCast(&argv));
            std.process.exit(1);
        }

        //parent process
        //we keep master here and discard slave
        _ = c.close(slave);
        return Pty{ .master = master };
    }

    //helpers

    //read bytes the shell wrote to its stdout
    pub fn read(self: Pty, buf: []u8) !usize {
        return std.posix.read(self.master, buf) catch |err| switch (err) {
            //EIO means slave side closed -> shell exited
            error.InputOutput => error.HangUp,
            else => err,
        };
    }

    //send keystrokes - paste data to the shell's stdin
    pub fn write(self: Pty, data: []const u8) void {
        var sent: usize = 0;
        while (sent < data.len) {
            sent += std.posix.write(self.master, data[sent..]) catch break;
        }
    }

    //tell the kernel (and shell) the terminal has been resized
    //this causes SIGWINCH to be sent to the foreground process
    pub fn resize(self: Pty, cols: u32, rows: u32) void {
        var win_size = c.struct_winsize{
            .ws_col = @intCast(cols),
            .ws_row = @intCast(rows),
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        _ = c.ioctl(self.master, c.TIOCSWINSZ, &win_size);
    }

    pub fn deinit(self: Pty) void {
        std.posix.close(self.master);
    }
};
