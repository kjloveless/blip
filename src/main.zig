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
const BLIP_TAB_STOP: u8 = 8;
const BLIP_QUIT_TIMES: u2 = 3;

fn CTRL_KEY(key: u8) u8 {
    return key & 0x1f;
}

const editorKey = enum(u8) {
    BACKSPACE = 127,
    ARROW_LEFT = 150,
    ARROW_RIGHT,
    ARROW_UP,
    ARROW_DOWN,
    DEL_KEY,
    HOME_KEY,
    END_KEY,
    PAGE_UP,
    PAGE_DOWN,
};

const editorHighlight = enum(u8) {
    HL_NORMAL = 0,
    HL_NUMBER,
    HL_MATCH,
};

//------------------------------------------------------------------------------
// Data 
//------------------------------------------------------------------------------
const erow = struct {
    chars: std.ArrayList(u8),
    render: std.ArrayList(u8),
    hl: std.ArrayList(u8),
};

const editorConfig = struct {
    cx: u16,
    cy: u16,
    rx: u16,
    rowoff: u16,
    coloff: u16,
    screenrows: u16,
    screencols: u16,
    numrows: u16,
    row: std.ArrayList(erow),
    dirty: bool,
    filename: ?[]u8,
    statusmsg: std.ArrayList(u8),
    statusmsg_time: i64,
    original_termios: posix.termios,
    reader: std.fs.File.Reader,
    writer: std.fs.File.Writer,
    allocator: std.mem.Allocator,
};

var E: editorConfig = undefined;

//-----------------------------------------------------------------------------
// File I/O
//-----------------------------------------------------------------------------
fn editorRowsToString() !std.ArrayList(u8) {
    var result = std.ArrayList(u8).init(E.allocator);
    var i: usize = 0;
    while (i < E.numrows) : (i += 1) {
        try result.appendSlice(E.row.items[i].chars.items);
        try result.append('\n');
    }
    return result;
}

fn editorOpen(filename: []u8) !void {
    E.filename = filename;
    const file: std.fs.File = try std.fs.cwd().openFile(
        filename,
        .{ },
    );
    defer file.close();
    var file_reader = std.io.bufferedReader(file.reader());
    var input_stream = file_reader.reader();

    while(true) {
        const line = input_stream.readUntilDelimiterAlloc(
            E.allocator, 
            '\n',
            std.math.maxInt(u16),
        ) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (line.len > -1) {
            // strip newline chars
            // may not be needed if readUntilDelimiter is exclusive of
            // delimiter
        }
        try editorInsertRow(E.numrows, line);
    }
    E.dirty = false;
}

fn editorSave() !void {
    if (E.filename == null) {
        E.filename = try editorPrompt(
            E.writer, 
            E.reader, 
            "Save as: {s} (ESC to cancel)",
            null);

        if (E.filename == null) {
            try editorSetStatusMessage("Save aborted", .{});
            return;
        }
    }

    const updatedText = try editorRowsToString();
    
    std.fs.cwd().writeFile(.{
        .sub_path = E.filename.?, 
        .data = updatedText.items, 
        .flags = .{ 
            .read = true,
            .truncate = true, 
            .mode = 0o644,
        },
    }) catch {
        try editorSetStatusMessage("Failed to save! I/O error: ", .{}); // add err message
    };
    E.dirty = false;
    try editorSetStatusMessage("written to disk", .{});
}

//-----------------------------------------------------------------------------
// Find
//-----------------------------------------------------------------------------
fn editorFindCallback(query: *[] u8, key: u16) error{OutOfMemory}!void {
    const static = struct {
        var last_match: isize = -1;
        var direction: isize = 1;
        var saved_hl_line: isize = undefined;
        var saved_hl: std.ArrayList(u8) = undefined;
    };

    if (static.saved_hl.items.len > 0) {
        E.row.items[@intCast(static.saved_hl_line)].hl.clearAndFree();
        E.row.items[@intCast(static.saved_hl_line)].hl = try static.saved_hl.clone();
    }

    if (key == '\r' or key == '\x1b') {
        static.last_match = -1;
        static.direction = 1;
        return;
    } else if (key == @intFromEnum(editorKey.ARROW_RIGHT) 
        or key == @intFromEnum(editorKey.ARROW_DOWN)) {
        static.direction = 1;
    } else if (key == @intFromEnum(editorKey.ARROW_LEFT)
        or key == @intFromEnum(editorKey.ARROW_UP)) {
        static.direction = -1;
    } else {
        static.last_match = -1;
        static.direction = 1;
    }

    if (static.last_match == -1) static.direction = 1;
    var current: isize = static.last_match;
    var i: u16 = 0;
    while (i < E.numrows) : (i += 1) {
        current += static.direction;
        if (current == -1) {
            current = E.numrows - 1;
        } else if (current == E.numrows) {
            current = 0;
        }

        const row = &E.row.items[@intCast(current)];
        const match = std.mem.indexOf(u8, row.render.items, query.*);
        if (match != null) {
            static.last_match = current;
            E.cy = @intCast(current);
            E.cx = editorRowRxToCx(row, @intCast(match.?));
            E.rowoff = E.numrows;
            var offset: usize = 0;

            static.saved_hl_line = current;
            static.saved_hl = try row.*.hl.clone();
            //static.saved_hl = try row.*.hl.clone(); 
            while (offset < query.*.len) : (offset += 1) {
                row.*.hl.items[match.? + offset] = @intFromEnum(editorHighlight.HL_MATCH);
            }
            break;
        }
    }

}

fn editorFind() !void {
    const saved_cx = E.cx;
    const saved_cy = E.cy;
    const saved_coloff = E.coloff;
    const saved_rowoff = E.rowoff;

    const query = try editorPrompt(
        E.writer, 
        E.reader, 
        "Search: {s} (Use ESC/Arrows/Enter)",
        &editorFindCallback);

    if (query == null) {
        E.cx = saved_cx;
        E.cy = saved_cy;
        E.coloff = saved_coloff;
        E.rowoff = saved_rowoff;
    }
}

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
fn initEditor(
    allocator: std.mem.Allocator,
) !void {
    E.allocator = allocator;
    E.cx = 0;
    E.cy = 0;
    E.rx = 0;
    E.rowoff = 0;
    E.coloff = 0;
    E.numrows = 0;
    E.row = std.ArrayList(erow).init(E.allocator);
    E.dirty = false; 
    E.filename = null;
    E.statusmsg = std.ArrayList(u8).init(E.allocator);
    try E.statusmsg.append('\x00');
    E.statusmsg_time = 0;
    E.reader = io.getStdIn().reader();
    E.writer = io.getStdOut().writer();

    if (try getWindowSize(E.writer, E.reader, &E.screenrows, &E.screencols) == -1) {
        die("getWindowSize", error.WriteError); //pass correct error
    }
    E.screenrows -= 2;
}

pub fn main() !void {
    enableRawMode();
    defer(disableRawMode());
    errdefer(disableRawMode());
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    try initEditor(allocator);
    const args = try std.process.argsAlloc(E.allocator);
    defer E.allocator.free(args);
    if (args.len >= 2) {
        try editorOpen(args[1]);
    }

    try editorSetStatusMessage(
        "Help: Ctrl-S = save | Ctrl-Q = quit | Ctrl-F = find", 
        .{});

    while (true) {
        try editorRefreshScreen(E.writer);
        try editorProcessKeypress(E.reader);
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

fn iscntrl(c: u8) bool {
    return ((c >= 0 and c < 32) or c == 127);
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

fn editorReadKey(reader: std.fs.File.Reader) !u8 {
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
                        '1' => return @intFromEnum(editorKey.HOME_KEY),
                        '3' => return @intFromEnum(editorKey.DEL_KEY),
                        '4' => return @intFromEnum(editorKey.END_KEY),
                        '5' => return @intFromEnum(editorKey.PAGE_UP),
                        '6' => return @intFromEnum(editorKey.PAGE_DOWN),
                        '7' => return @intFromEnum(editorKey.HOME_KEY),
                        '8' => return @intFromEnum(editorKey.END_KEY),
                        else => {},
                    }
                }
            } else if (seq[0] == 'O') {
                switch (seq[1]) {
                    'H' => return @intFromEnum(editorKey.HOME_KEY),
                    'F' => return @intFromEnum(editorKey.END_KEY),
                    else => {},
                }
            } else {
                switch (seq[1]) {
                    'A' => return @intFromEnum(editorKey.ARROW_UP),
                    'B' => return @intFromEnum(editorKey.ARROW_DOWN),
                    'C' => return @intFromEnum(editorKey.ARROW_RIGHT),
                    'D' => return @intFromEnum(editorKey.ARROW_LEFT),
                    'H' => return @intFromEnum(editorKey.HOME_KEY),
                    'F' => return @intFromEnum(editorKey.END_KEY),
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
// Syntax Highlighting
//-----------------------------------------------------------------------------
fn editorUpdateSyntax(row: *erow) !void {
    row.*.hl.clearAndFree();

    var i: usize = 0;
    while (i < row.*.render.items.len) : (i += 1) {
        if (std.ascii.isDigit(row.*.render.items[i])) {
            try row.*.hl.append(@intFromEnum(editorHighlight.HL_NUMBER));
        } else {
            try row.*.hl.append(@intFromEnum(editorHighlight.HL_NORMAL));
        }
    }
}

fn editorSyntaxToColor(hl: u8) u8 {
    switch (hl) {
        @intFromEnum(editorHighlight.HL_NUMBER) => return 31,
        @intFromEnum(editorHighlight.HL_MATCH) => return 34,
        else => return 37,
    }
}

//-----------------------------------------------------------------------------
// Row Operations
//-----------------------------------------------------------------------------
fn editorRowCxToRx(row: *erow, cx: u16) u16 {
    var rx: u16 = 0;
    var i: u16 = 0;
    while (i < cx) : (i += 1) {
        if (row.*.chars.items[i] == '\t') {
            rx += (BLIP_TAB_STOP - 1) - (rx % BLIP_TAB_STOP);
        }
        rx += 1;
    }
    return rx;
}

fn editorRowRxToCx(row: *erow, rx: u16) u16 {
    var cur_rx: u16 = 0;
    var cx: u16 = 0;
    
    while (cx < row.*.chars.items.len) : (cx += 1) {
        if (row.*.chars.items[cx] == '\t') {
            cur_rx += (BLIP_TAB_STOP - 1) - (cur_rx % BLIP_TAB_STOP);
        }
        cur_rx += 1;

        if (cur_rx > rx) {
            return cx;
        }
    }

    return cx;
}

fn editorUpdateRow(row: *erow) !void {
    var i: usize = 0;
    row.*.render.clearAndFree();
    while (i < row.*.chars.items.len) : (i += 1) {
        if (row.*.chars.items[i] == '\t') {
            try row.*.render.appendSlice(" " ** BLIP_TAB_STOP);
        } else {
            try row.*.render.append(row.*.chars.items[i]);
        }
    }

    try editorUpdateSyntax(row);
}

fn editorInsertRow(at: u16, s: []u8) !void {
    if (at < 0 or at > E.numrows) return;

    try E.row.insert(at, erow{
        .chars = std.ArrayList(u8).init(E.allocator),
        .render = std.ArrayList(u8).init(E.allocator),
        .hl = std.ArrayList(u8).init(E.allocator),
    });
    const item = &E.row.items[at];

    try item.*.chars.appendSlice(s);
    try editorUpdateRow(item);

    E.numrows += 1;
    E.dirty = true;
}

fn editorFreeRow(row: *erow) void {
    row.*.chars.clearAndFree();
    row.*.render.clearAndFree();
    row.*.hl.clearAndFree();
}

fn editorDelRow(at: u16) !void {
    if (at < 0 or at >= E.numrows) return;

    editorFreeRow(&E.row.items[at]);
    _ = E.row.orderedRemove(at);
    E.numrows -= 1;
    E.dirty = true;
}

fn editorRowInsertChar(row: *erow, at: u16, c: u8) !void {
    var here: usize = at;
    if (at < 0 or at > row.*.chars.items.len) {
        here = row.*.chars.items.len;
    }
    try row.*.chars.insert(here, c);
    try editorUpdateRow(row);
    E.dirty = true;
}

fn editorRowAppendString(row: *erow, s: []u8) !void {
    try row.*.chars.appendSlice(s);
    try editorUpdateRow(row);
    E.dirty = true;
}

fn editorRowDelChar(row: *erow, at: u16) !void {
    if (at < 0 or at >= row.*.chars.items.len) return;
    _ = row.*.chars.orderedRemove(at);
    try editorUpdateRow(row);
    E.dirty = true;
}

//-----------------------------------------------------------------------------
// Editor Operations
//-----------------------------------------------------------------------------
fn editorInsertChar(c: u8) !void {
    if (E.cy == E.numrows) {
        try editorInsertRow(E.numrows, "");
    }
    try editorRowInsertChar(&E.row.items[E.cy], E.cx, c);
    E.cx += 1;
}

fn editorInsertNewline() !void {
    if (E.cx == 0) {
        try editorInsertRow(E.cy, "");
    } else {
        const row = &E.row.items[E.cy];
        try editorInsertRow(E.cy + 1, row.*.chars.items[E.cx..]);
        row.chars.items = row.chars.items[0..E.cx];
        try editorUpdateRow(row);
    }
    E.cy += 1;
    E.cx = 0;
}

fn editorDelChar() !void {
    if (E.cy == E.numrows) return;
    if (E.cx == 0 and E.cy == 0) return;

    const row = &E.row.items[E.cy];
    if (E.cx > 0) {
        try editorRowDelChar(row, E.cx - 1);
        E.cx -= 1;
    } else {
        E.cx = @intCast(E.row.items[E.cy - 1].chars.items.len);
        try editorRowAppendString(&E.row.items[E.cy - 1], row.*.chars.items);
        try editorDelRow(E.cy);
        E.cy -= 1;
    }
}

//-----------------------------------------------------------------------------
// Output
//-----------------------------------------------------------------------------
fn editorScroll() void {
    E.rx = 0;
    if (E.cy < E.numrows) {
        E.rx = editorRowCxToRx(&E.row.items[E.cy], E.cx);
    }

    if (E.cy < E.rowoff) {
        E.rowoff = E.cy;
    }
    if (E.cy >= E.rowoff + E.screenrows) {
        E.rowoff = E.cy - E.screenrows + 1;
    }

    if (E.rx < E.coloff) {
        E.coloff = E.rx;
    }
    if (E.rx >= E.coloff + E.screencols) {
        E.coloff = E.rx - E.screencols + 1;
    }
}

fn editorDrawRows(append_buffer: *abuf) !void {
    var y: u8 = 0;
    while (y < E.screenrows) : (y += 1) {
        const filerow = y + E.rowoff;
        if (filerow >= E.numrows) {
            if (E.numrows == 0 and y == E.screenrows / 3) {
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
        } else {
            const render_len = E.row.items[filerow].render.items.len;
            
            if (E.coloff < render_len) {
                var len = render_len - E.coloff;

                if (len > E.screencols) len = E.screencols;
            
                const start = E.coloff;
                const end = @min(start + len, render_len);

                var i = start;
                var current_color: isize = -1;
                while (i < end) : (i += 1) {
                    const c = E.row.items[filerow].render.items[i];
                    const hl = E.row.items[filerow].hl.items[i];

                    if (hl == @intFromEnum(editorHighlight.HL_NORMAL)) {
                        if (current_color != -1) {
                            try abAppend(append_buffer, "\x1b[39m");
                            current_color = -1;
                        }
                        try abAppend(append_buffer, &[_]u8{c});
                    } else {
                        const color = editorSyntaxToColor(hl);
                        if (color != current_color) {
                            current_color = color;
                            var buffer = std.ArrayList(u8).init(E.allocator);
                            try std.fmt.format(
                                buffer.writer(), 
                                "\x1b[{d}m",
                                .{color});
                
                            try abAppend(append_buffer, buffer.items);
                        }
                        try abAppend(append_buffer, &[_]u8{c});
                    }
                }
                try abAppend(append_buffer, "\x1b[39m");
            } else {
                try abAppend(append_buffer, "");
            }
        }

        try abAppend(append_buffer, "\x1b[K");
        try abAppend(append_buffer, "\r\n");
    }
}

fn editorDrawStatusBar(append_buffer: *abuf) !void {
    try abAppend(append_buffer, "\x1b[7m");
    var status = std.ArrayList(u8).init(E.allocator);
    var row_status = std.ArrayList(u8).init(E.allocator);

    try std.fmt.format(
        status.writer(),
        "{s} - {d} lines {s}",
        .{ 
            if (E.filename != null) E.filename.? else "[No Name]", 
            E.numrows, 
            if (E.dirty) "modified" else "", 
        }
    );
    try std.fmt.format(
        row_status.writer(),
        "{d}/{d}",
        .{ E.cy + 1, E.numrows }
    );

    try abAppend(append_buffer, status.items);
    var len: usize = status.items.len;
    while (len < E.screencols) : (len += 1) {
        if (E.screencols - len == row_status.items.len) {
            try abAppend(append_buffer, row_status.items);
            break;
        } else {
            try abAppend(append_buffer, " ");
        }
    }
    try abAppend(append_buffer, "\x1b[m");
    try abAppend(append_buffer, "\r\n");
}

fn editorDrawMessageBar(append_buffer: *abuf) !void {
    try abAppend(append_buffer, "\x1b[K");
    if (E.statusmsg.items.len > 0 
        and std.time.timestamp() - E.statusmsg_time < 5) {
        try abAppend(append_buffer, E.statusmsg.items);
    }
}

fn editorRefreshScreen(writer: std.fs.File.Writer) !void {
    editorScroll();
    var append_buffer: abuf = ABUF_INIT;

    try abAppend(&append_buffer, "\x1b[?25l");
    try abAppend(&append_buffer, "\x1b[H");

    try editorDrawRows(&append_buffer);
    try editorDrawStatusBar(&append_buffer);
    try editorDrawMessageBar(&append_buffer);

    var buffer: [32]u8 = undefined;
    const cursor_position = try std.fmt.bufPrint(
        &buffer,
        "\x1b[{d};{d}H",
        .{ (E.cy - E.rowoff) + 1, (E.rx - E.coloff) + 1}    
    );
    try abAppend(&append_buffer, cursor_position);

    try abAppend(&append_buffer, "\x1b[?25h");

    _ = try writer.write(append_buffer.b.items);
    abFree(&append_buffer);
}

fn editorSetStatusMessage(comptime msg: []const u8, args: anytype) !void {
    E.statusmsg.clearAndFree();
    var formattedMsg = std.ArrayList(u8).init(E.allocator);
    try std.fmt.format(formattedMsg.writer(), msg, args);
    try E.statusmsg.appendSlice(formattedMsg.items);
    E.statusmsg_time = std.time.timestamp();
}

//-----------------------------------------------------------------------------
// Input
//-----------------------------------------------------------------------------
fn editorPrompt(
    writer: std.fs.File.Writer, 
    reader: std.fs.File.Reader, 
    comptime prompt: []const u8,
    callback: ?*const fn (*[] u8, u16) error{OutOfMemory}!void
) !?[]u8 {
    _ = &prompt; // fix this later
    var buffer = std.ArrayList(u8).init(E.allocator);
    
    while (true) {
        try editorSetStatusMessage(prompt, .{ buffer.items });
        try editorRefreshScreen(writer);
        
        const c = try editorReadKey(reader);
        if (c == @intFromEnum(editorKey.DEL_KEY) or c == CTRL_KEY('h') or c ==
            @intFromEnum(editorKey.BACKSPACE)) {
            if (buffer.items.len != 0) {
                _ = buffer.pop();
            }
        }
        if (c == '\x1b') {
            try editorSetStatusMessage("", .{});
            if (callback != null) {
                try callback.?(&buffer.items, c);
            }
            buffer.clearAndFree();
            return null;
        } else if (c == '\r') {
            if (buffer.items.len != 0) {
                try editorSetStatusMessage("", .{});
                if (callback != null) {
                    try callback.?(&buffer.items, c);
                }
                return buffer.items;
            }
        } else if (!iscntrl(c) and c < 128) {
            try buffer.append(c);
        }

        if (callback != null) {
            try callback.?(&buffer.items, c);
        }
    }
}

fn editorMoveCursor(key: u8) void {
    var row: ?*erow = if (E.cy >= E.numrows) null else &E.row.items[E.cy];
    switch (key) {
        @intFromEnum(editorKey.ARROW_LEFT) => {
            if (E.cx != 0) {
                E.cx -= 1;
            } else if (E.cy > 0) {
                E.cy -= 1;
                E.cx = @intCast(E.row.items[E.cy].chars.items.len);
            }
        },
        @intFromEnum(editorKey.ARROW_RIGHT) => {
            if (row != null and E.cx < row.?.chars.items.len) {
                E.cx += 1;
            } else if (row != null and E.cx == row.?.chars.items.len) {
                E.cy += 1;
                E.cx = 0;
            }

        },
        @intFromEnum(editorKey.ARROW_UP) => {
            if (E.cy != 0) {
                E.cy -= 1;
            } 
        },
        @intFromEnum(editorKey.ARROW_DOWN) => {
            if (E.cy < E.numrows) {
                E.cy += 1;
            }
        },
        else => {},
    }

    row = if (E.cy >= E.numrows) null else &E.row.items[E.cy];
    if (row != null and E.cx > row.?.chars.items.len) {
        E.cx = @intCast(row.?.chars.items.len);
    }
}

fn editorProcessKeypress(reader: std.fs.File.Reader) !void {
    const char = try editorReadKey(reader);
    const Q = struct {
        var quit_times: u2 = BLIP_QUIT_TIMES;
    };

    switch (char) {
        '\r' => try editorInsertNewline(),

        CTRL_KEY('q') => {
            if (E.dirty and Q.quit_times > 0) {
                try editorSetStatusMessage("WARNING!!! File has unsaved changes. Press Ctrl-Q {d} more times to quit." 
                    , .{ Q.quit_times });
                Q.quit_times -= 1;
                return;
            }
            disableRawMode();
            _ = try posix.write(posix.STDOUT_FILENO, "\x1b[2J");
            _ = try posix.write(posix.STDOUT_FILENO, "\x1b[H");
            posix.exit(0);
        },

        CTRL_KEY('s') => {
            try editorSave();
        },

        @intFromEnum(editorKey.HOME_KEY) => E.cx = 0,

        @intFromEnum(editorKey.END_KEY) => {
            if (E.cy < E.numrows) {
                E.cx = @intCast(E.row.items[E.cy].chars.items.len);
            }
        },

        CTRL_KEY('f') => {
            try editorFind();
        },

        @intFromEnum(editorKey.BACKSPACE), @intFromEnum(editorKey.DEL_KEY),
        CTRL_KEY('h') => {
            if (char == @intFromEnum(editorKey.DEL_KEY)) {
                editorMoveCursor(@intFromEnum(editorKey.ARROW_RIGHT));
            }
            try editorDelChar();
        },

        @intFromEnum(editorKey.PAGE_UP), @intFromEnum(editorKey.PAGE_DOWN) => {
            if (char == @intFromEnum(editorKey.PAGE_UP)) {
                E.cy = E.rowoff;
            } else if (char == @intFromEnum(editorKey.PAGE_DOWN)) {
                E.cy = E.rowoff + E.screenrows - 1;
                if (E.cy > E.numrows) {
                    E.cy = E.numrows;
                }
            }
            var times: u16 = E.screenrows;
            while (times > 0) : (times -= 1) {
                if (char == @intFromEnum(editorKey.PAGE_UP)) {
                    editorMoveCursor(@intFromEnum(editorKey.ARROW_UP));
                } else {
                    editorMoveCursor(@intFromEnum(editorKey.ARROW_DOWN));
                }
            }
        },

        @intFromEnum(editorKey.ARROW_UP) => editorMoveCursor(char),
        @intFromEnum(editorKey.ARROW_DOWN) => editorMoveCursor(char),
        @intFromEnum(editorKey.ARROW_LEFT) => editorMoveCursor(char),
        @intFromEnum(editorKey.ARROW_RIGHT) => editorMoveCursor(char),

        CTRL_KEY('l'), '\x1b' => {},

        //'w', 's', 'a', 'd' => editorMoveCursor(char),
        else => try editorInsertChar(char),
    }
    Q.quit_times = BLIP_QUIT_TIMES;
}
