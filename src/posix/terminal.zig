const std = @import("std");
const posix = std.posix;

const k = @import("../input.zig").inputKey;

var original_termios: posix.termios = undefined;

pub fn die(msg: []const u8, err: anyerror) noreturn {
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

pub fn iscntrl(c: u8) bool {
    return ((c >= 0 and c < 32) or c == 127);
}

pub fn enableRawMode() void {
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

pub fn disableRawMode() void {
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, original_termios) catch |err| switch (err) {
        error.NotATerminal => die("tcsetattr", error.NotATerminal),
        error.ProcessOrphaned => die("tcsetattr", error.ProcessOrphaned),
        error.Unexpected => die("tcsetattr", error.Unexpected),
    };
}

pub fn editorReadKey(reader: std.fs.File.Reader) !u8 {
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

    if (char[0] == '\x1b') {
        var seq: [3]u8 = undefined;

        if (try reader.read(seq[0..1]) != 1) return '\x1b';
        if (try reader.read(seq[1..2]) != 1) return '\x1b';

        if (seq[0] == '[') {
            if (seq[1] >= '0' and seq[1] <= '9') {
                if (try reader.read(seq[2..3]) != 1) return '\x1b';
                if (seq[2] == '~') {
                    switch (seq[1]) {
                        '1' => return @intFromEnum(k.HOME_KEY),
                        '3' => return @intFromEnum(k.DEL_KEY),
                        '4' => return @intFromEnum(k.END_KEY),
                        '5' => return @intFromEnum(k.PAGE_UP),
                        '6' => return @intFromEnum(k.PAGE_DOWN),
                        '7' => return @intFromEnum(k.HOME_KEY),
                        '8' => return @intFromEnum(k.END_KEY),
                        else => {},
                    }
                }
            } else if (seq[0] == 'O') {
                switch (seq[1]) {
                    'H' => return @intFromEnum(k.HOME_KEY),
                    'F' => return @intFromEnum(k.END_KEY),
                    else => {},
                }
            } else {
                switch (seq[1]) {
                    'A' => return @intFromEnum(k.ARROW_UP),
                    'B' => return @intFromEnum(k.ARROW_DOWN),
                    'C' => return @intFromEnum(k.ARROW_RIGHT),
                    'D' => return @intFromEnum(k.ARROW_LEFT),
                    'H' => return @intFromEnum(k.HOME_KEY),
                    'F' => return @intFromEnum(k.END_KEY),
                    else => {},
                }
            }
        }

        return '\x1b';
    } else {
        return char[0];
    }
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

pub fn getWindowSize(writer: std.fs.File.Writer, reader: std.fs.File.Reader, rows: *u16, cols: *u16) !i8 {
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
