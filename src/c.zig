//everything we need from the c libraries of X11 and other c libraries for sys and pty

const c = @cImport({
    //X11
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h"); //XSizeHints, XWMHints
    @cInclude("X11/keysym.h"); // XK_.., keys
    @cInclude("X11/cursorfont.h");
    @cInclude("X11/Xft/Xft.h"); // X11 font rendering - I have seen there are other possibilities but this is what suckless uses

    //PTY
    @cInclude("pty.h"); //openpty()
    @cInclude("unistd.h"); // fork, exec, setsid, read, write
    @cInclude("stdlib.h"); //setenv
    @cInclude("sys/ioctl.h"); // TIOCSWINSZ, TIOCSCTTY
    @cInclude("sys/types.h"); // pid_t
    @cInclude("sys/wait.h"); // waitpid
    @cInclude("termios.h"); // struct termios

    //poll - our main event handler for waiting on multiple fds
    @cInclude("poll.h");

    //signals handling
    @cInclude("signal.h");
});
