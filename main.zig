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
//const cfg = @import("config.zig") //some config file
//const term = @import("term.zig") //script that handles terminal
//const pty = @import("pty.zig") // script that handles pty
//const win = @import("x11.zig") //script that handles x11 window
