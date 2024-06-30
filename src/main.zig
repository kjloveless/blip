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
const editorConfig = struct {
    original_termios: posix.termios,
};

var E: editorConfig = undefined;

//------------------------------------------------------------------------------
// Init
//------------------------------------------------------------------------------
pub fn main() !void {
    enableRawMode();
    defer(disableRawMode());
    const stdin = io.getStdIn().reader();
    const stdout = io.getStdOut().writer();
    while (true) {
        try editorRefreshScreen(stdout);
        try editorProcessKeypress(stdin);
    }
    //    if (iscntrl(&char)) {
    //        try stdout.print("{d}\r\n", .{char});
    //    } else {
    //        try stdout.print("{d} ('{c}')\r\n", .{char, char});
    //    }
}

//------------------------------------------------------------------------------
// Terminal
//------------------------------------------------------------------------------
fn die(msg: []const u8, err: anyerror) noreturn {
    disableRawMode();
    _ = posix.write(posix.STDOUT_FILENO, "\x1b[2J") catch {
        posix.exit(1);
    };
    _ = posix.write(posix.STDOUT_FILENO, "\x1b[H") catch {
        posix.exit(1);
    };

    std.debug.print("error {d} ({s}): {s}", .{ @intFromError(err), msg, @errorName(err) });
    // should return the actual error code, hacking this for now
    posix.exit(1);
}

fn iscntrl(c: *[1]u8) bool {
    return ((c[0] >= 0 and c[0] < 32) or c[0] == 127);
}

fn enableRawMode() void {
    E.original_termios = posix.tcgetattr(posix.STDIN_FILENO) catch |err| switch (err) {
        error.NotATerminal => die("tcgetattr", error.NotATerminal),
        error.Unexpected => die("tcgetattr", error.Unexpected),
    };
    var raw = E.original_termios;

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
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, E.original_termios) catch |err| switch (err) {
        error.NotATerminal => die("tcsetattr", error.NotATerminal),
        error.ProcessOrphaned => die("tcsetattr", error.ProcessOrphaned),
        error.Unexpected => die("tcsetattr", error.Unexpected),
    };
}

fn editorReadKey(reader: std.fs.File.Reader) u8 {
    var bytes_read: usize = undefined;
    var char: [1]u8 = undefined;
    while (bytes_read != 1) {
        bytes_read = reader.read(&char) catch |err| switch (err) {
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
    } 
    return char[0];
    //const line = (try reader.readUntilDelimiterOrEof(
    //        buffer,
    //        '\n',
    //)) orelse return null;

    // trim windows-only carriage return char
    //if (@import("builtin").os.tag == .windows) {
    //    return std.mem.trimRight(u8, line, "\r");
    //} else {
    //    return line;
    //}
}

//-----------------------------------------------------------------------------
// Output
//-----------------------------------------------------------------------------
fn editorDrawRows(writer: *const std.fs.File.Writer) !void {
    var y: u8 = 0;
    while (y < 24) : (y += 1) {
        _ = try writer.write("~\r\n");
    }
}

fn editorRefreshScreen(writer: std.fs.File.Writer) !void {
    _ = try writer.write("\x1b[2J");
    _ = try writer.write("\x1b[H");

    try editorDrawRows(&writer);

    _ = try writer.write("\x1b[H");
}

//-----------------------------------------------------------------------------
// Input
//-----------------------------------------------------------------------------
fn editorProcessKeypress(reader: std.fs.File.Reader) !void {
    const char = editorReadKey(reader);

    switch (char) {
        CTRL_KEY('q') => {
            disableRawMode();
            _ = try posix.write(posix.STDOUT_FILENO, "\x1b[2J");
            _ = try posix.write(posix.STDOUT_FILENO, "\x1b[H");
            posix.exit(0);
        },
        else => {},
    }
}
