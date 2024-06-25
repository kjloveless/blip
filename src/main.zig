const std = @import("std");
const io = std.io;
const mem = std.mem;
const posix = std.posix;

var original_termios: posix.termios = undefined;

pub fn main() !void {
    defer(disableRawMode());
    try enableRawMode();
    const stdin = io.getStdIn().reader();
    const stdout = io.getStdOut().writer();

    var char: [1]u8 = undefined;

    while (try stdin.read(&char) == 1 and !mem.eql(u8, &char, "q")) {
        if (iscntrl(&char)) {
            try stdout.print("{d}\n", .{char});
        } else {
            try stdout.print("{d} ('{c}')\n", .{char, char});
        }
    }
}

fn iscntrl(c: *[1]u8) bool {
    return ((c[0] >= 0 and c[0] < 32) or c[0] == 127);
}

fn enableRawMode() !void {
    original_termios = try posix.tcgetattr(posix.STDIN_FILENO);
    var raw = original_termios;

    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.iflag.IXON = false;

    try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
}

fn disableRawMode() void {
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, original_termios) catch |err| switch (err) {
        error.NotATerminal => posix.exit(1),
        else => posix.exit(1),
    };
}

fn nextLine(reader: std.fs.File.Reader, buffer: []u8) !?[] u8 {
    const line = (try reader.readUntilDelimiterOrEof(
            buffer,
            '\n',
    )) orelse return null;

    // trim windows-only carriage return char
    if (@import("builtin").os.tag == .windows) {
        return std.mem.trimRight(u8, line, "\r");
    } else {
        return line;
    }
}
