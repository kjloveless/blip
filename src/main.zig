//------------------------------------------------------------------------------
// Includes
//------------------------------------------------------------------------------
const std = @import("std");
const io = std.io;
const mem = std.mem;
const posix = std.posix;

//------------------------------------------------------------------------------
// Defines
//------------------------------------------------------------------------------
fn CTRL_KEY(key: u8) u8 {
    return key & 0x1f;
}

//------------------------------------------------------------------------------
// Data 
//------------------------------------------------------------------------------
var original_termios: posix.termios = undefined;

//------------------------------------------------------------------------------
// Init
//------------------------------------------------------------------------------
pub fn main() !void {
    enableRawMode();
    defer(disableRawMode());
    const stdin = io.getStdIn().reader();
    const stdout = io.getStdOut().writer();
    
    while (true) {
        var char: [1]u8 = .{ '\x00' };
        _ = stdin.read(&char) catch |err| switch (err) {
            error.AccessDenied => die("read", error.AccessDenied),
            error.BrokenPipe => die("read", error.BrokenPipe),
            error.ConnectionResetByPeer => die("read", error.ConnectionResetByPeer),
            error.ConnectionTimedOut => die("read", error.ConnectionTimedOut),
            error.InputOutput => die("read", error.InputOutput),
            error.IsDir => die("read", error.IsDir),
            error.NotOpenForReading => die("read", error.NotOpenForReading),
            error.OperationAborted => die("read", error.OperationAborted),
            error.SocketNotConnected => die("read", error.SocketNotConnected),
            error.SystemResources => die("read", error.SystemResources),
            error.Unexpected => die("read", error.Unexpected),
            error.WouldBlock => continue,
        }; 

        if (iscntrl(&char)) {
            try stdout.print("{d}\r\n", .{char});
        } else {
            try stdout.print("{d} ('{c}')\r\n", .{char, char});
        }

        if (char[0] == CTRL_KEY('q')) {
            break;
        }
    }
}

//------------------------------------------------------------------------------
// Terminal
//------------------------------------------------------------------------------
fn die(msg: []const u8, err: anyerror) noreturn {
    std.debug.print("error {d} ({s}): {s}", .{ @intFromError(err), msg, @errorName(err) });
    // should return the actual error code, hacking this for now
    posix.exit(1);
}

fn iscntrl(c: *[1]u8) bool {
    return ((c[0] >= 0 and c[0] < 32) or c[0] == 127);
}

fn enableRawMode() void {
    original_termios = posix.tcgetattr(posix.STDIN_FILENO) catch |err| switch (err) {
        error.NotATerminal => die("tcgetattr", error.NotATerminal),
        error.Unexpected => die("tcgetattr", error.Unexpected),
    };
    var raw = original_termios;

    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;

    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    
    raw.cflag.CSIZE = .CS8;

    raw.oflag.OPOST = false;

    raw.cc[@intFromEnum(posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(posix.V.TIME)] = 1;

    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw) catch |err| switch (err) {
        error.NotATerminal => die("tcsetattr", error.NotATerminal),
        error.ProcessOrphaned => die("tcsetattr", error.ProcessOrphaned),
        error.Unexpected => die("tcsetattr", error.Unexpected),
    };
}

fn disableRawMode() void {
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, original_termios) catch |err| switch (err) {
        error.NotATerminal => die("tcsetattr", error.NotATerminal),
        error.ProcessOrphaned => die("tcsetattr", error.ProcessOrphaned),
        error.Unexpected => die("tcsetattr", error.Unexpected),
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
