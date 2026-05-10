// Config file

// Xft font name
pub const font_name: [:0]const u8 = "monospace:size=13";

// shell to exec inside the pty
pub const shell: [:0]const u8 = "/bin/bash";

// starting terminal size
pub const default_cols: u32 = 80;
pub const default_rows: u32 = 24;

// pixels of padding around the cell grid
pub const border_px: u32 = 4;

//width \t char
pub const tab_width: u32 = 8;

// which of the 16 palette entries are default fg / bg
pub const default_fg: u8 = 15; // bright white
pub const default_bg: u8 = 1;  // black

// color palette
// in hex so Xft can parse it directly
// colours 16-255 are computed at init as 6×6×6 cube + grayscale
pub const palette16 = [16][:0]const u8{
    "#1d2021", // 0  black
    "#cc241d", // 1  red
    "#98971a", // 2  green
    "#d79921", // 3  yellow
    "#458588", // 4  blue
    "#b16286", // 5  magenta
    "#689d6a", // 6  cyan
    "#a89984", // 7  white
    "#928374", // 8  bright black
    "#fb4934", // 9  bright red
    "#b8bb26", // 10 bright green
    "#fabd2f", // 11 bright yellow
    "#83a598", // 12 bright blue
    "#d3869b", // 13 bright magenta
    "#8ec07c", // 14 bright cyan
    "#ebdbb2", // 15 bright white
};
