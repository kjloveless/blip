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
const BLIP_VERSION: []const u8 = "0.0.1";
fn CTRL_KEY(key: u8) u8 {
    return key & 0x1f;
}

//------------------------------------------------------------------------------
// Data 
//------------------------------------------------------------------------------
const editorConfig = struct {
    cx: u16,
    cy: u16,
    screenrows: u16,
    screencols: u16,
    original_termios: posix.termios,
};

var E: editorConfig = undefined;

//-----------------------------------------------------------------------------
// Append Buffer
//-----------------------------------------------------------------------------
const abuf = struct {
    b: std.ArrayList(u8),
};

const ABUF_INIT = abuf{ .b = std.ArrayList(u8).init(std.heap.page_allocator) };

fn abAppend(ab: *abuf, s: []const u8) !void {
    try ab.b.appendSlice(s);
}

fn abFree(append_buffer: *abuf) void {
    append_buffer.b.deinit();
}

//------------------------------------------------------------------------------
// Init
//------------------------------------------------------------------------------
fn initEditor(writer: std.fs.File.Writer, reader: std.fs.File.Reader) !void {
    E.cx = 0;
    E.cy = 0;

    if (try getWindowSize(writer, reader, &E.screenrows, &E.screencols) == -1) {
        die("getWindowSize", error.WriteError); //pass correct error
    }
}

pub fn main() !void {
    enableRawMode();
    defer(disableRawMode());
    const stdin = io.getStdIn().reader();
    const stdout = io.getStdOut().writer();
    try initEditor(stdout, stdin);
    while (true) {
        try editorRefreshScreen(stdout);
        try editorProcessKeypress(stdin);
    }
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

fn getCursorPosition(writer: std.fs.File.Writer, reader: std.fs.File.Reader, rows: *u16, cols: *u16) !i8 {
    var buffer: [32]u8 = undefined;
    var i: usize = 0;

    if (try writer.write("\x1b[6n") != 4) {
        return -1;
    }

    var char: [1]u8 = undefined;
    while (i < buffer.len - 1) : (i += 1) {
        if (try reader.read(&char) != 1) {
            break;
        }
        buffer[i] = char[0];
        if (buffer[i] == 'R') {
            break;
        }
    }
    buffer[i] = '\x00';

    if (buffer[0] != '\x1b' or buffer[1] != '[') {
        return -1;
    }

    var row_col_iter = std.mem.split(u8, buffer[2..i], ";");
    const row_str = row_col_iter.next().?;
    const col_str = row_col_iter.next().?;

    rows.* = try std.fmt.parseInt(u16, row_str, 10);
    cols.* = try std.fmt.parseInt(u16, col_str, 10);

    return 0;
} 

fn getWindowSize(writer: std.fs.File.Writer, reader: std.fs.File.Reader, rows: *u16, cols: *u16) !i8 {
    var ws: posix.winsize = undefined;
    const ioctl_result = posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if ((ioctl_result == -1) or (ws.ws_col == 0)) {
        if (try writer.write("\x1b[999C\x1b[999B") != 12) {
            return -1;
        }
        return getCursorPosition(writer, reader, rows, cols);
    } else {
        cols.* = ws.ws_col;
        rows.* = ws.ws_row;
        return 0;
    }
}

//-----------------------------------------------------------------------------
// Output
//-----------------------------------------------------------------------------
fn editorDrawRows(append_buffer: *abuf) !void {
    var y: u8 = 0;
    while (y < E.screenrows) : (y += 1) {
        if (y == E.screenrows / 3) {
            var welcome_buffer: [80]u8 = undefined;
            const welcome = try std.fmt.bufPrint(
                &welcome_buffer, 
                "blip editor -- version {s}", 
                .{ BLIP_VERSION }
            );
            var padding: u16 = @intCast((E.screencols - welcome.len) / 2);
            if (padding > 0) {
                try abAppend(append_buffer, "~");
                padding -= 1;
            }
            while (padding > 0) : (padding -= 1) {
                try abAppend(append_buffer, " ");
            }
            try abAppend(append_buffer, welcome);
        } else {
            try abAppend(append_buffer, "~");
        }

        try abAppend(append_buffer, "\x1b[K");
        if (y < E.screenrows - 1) {
            try abAppend(append_buffer, "\r\n");
        }
    }
}

fn editorRefreshScreen(writer: std.fs.File.Writer) !void {
    var append_buffer: abuf = ABUF_INIT;

    try abAppend(&append_buffer, "\x1b[?25l");
    try abAppend(&append_buffer, "\x1b[H");

    try editorDrawRows(&append_buffer);

    var buffer: [32]u8 = undefined;
    const cursor_position = try std.fmt.bufPrint(
        &buffer,
        "\x1b[{d};{d}H",
        .{ E.cy + 1, E.cx + 1}    
    );
    try abAppend(&append_buffer, cursor_position);

    try abAppend(&append_buffer, "\x1b[?25h");

    _ = try writer.write(append_buffer.b.items);
    abFree(&append_buffer);
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
