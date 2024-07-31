//------------------------------------------------------------------------------
// Includes
//------------------------------------------------------------------------------
const std = @import("std");
const io = std.io;
const mem = std.mem;
const posix = std.posix;
const Terminal = @import("posix/terminal.zig").Terminal;

const in = @import("input.zig").inputKey;

var terminal: Terminal = undefined;

//------------------------------------------------------------------------------
// Defines
//------------------------------------------------------------------------------
const BLIP_VERSION: []const u8 = "0.0.1";
const BLIP_TAB_STOP: u8 = 4;
const BLIP_QUIT_TIMES: u2 = 3;

fn CTRL_KEY(key: u8) u8 {
    return key & 0x1f;
}

const editorHighlight = enum(u8) {
    HL_NORMAL = 0,
    HL_COMMENT,
    HL_MLCOMMENT,
    HL_KEYWORD1,
    HL_KEYWORD2,
    HL_STRING,
    HL_NUMBER,
    HL_MATCH,
};

const HL_HIGHLIGHT_NUMBERS: u32 = 1;
const HL_HIGHLIGHT_STRINGS: u32 = 1 << 1;

//------------------------------------------------------------------------------
// Data 
//------------------------------------------------------------------------------
const erow = struct {
    idx: u16,
    chars: std.ArrayList(u8),
    render: std.ArrayList(u8),
    hl: std.ArrayList(u8),
    hl_open_comment: bool,
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
    syntax: ?editorSyntax,
    reader: std.fs.File.Reader,
    writer: std.fs.File.Writer,
    allocator: std.mem.Allocator,
};

var E: editorConfig = undefined;

const editorSyntax = struct {
    filetype: []const u8,
    filematch: []const []const u8,
    keywords: []const ?[]const u8,
    singleline_comment_start: ?[]const u8,
    multiline_comment_start: ?[]const u8,
    multiline_comment_end: ?[]const u8,
    flags: u32,
};

//-----------------------------------------------------------------------------
// Filetypes
//-----------------------------------------------------------------------------
const C_HL_extensions = &[_][]const u8{
    ".c",
    ".h",
    ".cpp",
};
const C_HL_keywords = &[_]?[]const u8{
    "switch", "if", "while", "for", "break", "continue", "return", "else",
    "struct", "union", "typedef", "static", "enum", "class", "case",

    "int|", "long|", "double|", "float|", "char|", "unsigned|", "signed|",
    "void|", null
};

const HLDB = [_]editorSyntax{
    .{
        .filetype = "c",
        .filematch = C_HL_extensions,
        .keywords = C_HL_keywords,
        .singleline_comment_start = "//",
        .multiline_comment_start = "/*",
        .multiline_comment_end = "*/",
        .flags = HL_HIGHLIGHT_NUMBERS | HL_HIGHLIGHT_STRINGS,
    },
};

const HLDB_ENTRIES = HLDB.len;

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

    try editorSelectSyntaxHighlight();

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
            "Save as: {s} (ESC to cancel)",
            null);

        if (E.filename == null) {
            try editorSetStatusMessage("Save aborted", .{});
            return;
        }
        try editorSelectSyntaxHighlight();
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
    } else if (key == @intFromEnum(in.ARROW_RIGHT) 
        or key == @intFromEnum(in.ARROW_DOWN)) {
        static.direction = 1;
    } else if (key == @intFromEnum(in.ARROW_LEFT)
        or key == @intFromEnum(in.ARROW_UP)) {
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
    E.syntax = null;
    E.reader = io.getStdIn().reader();
    E.writer = io.getStdOut().writer();

    terminal = Terminal.init(E.reader, E.writer);

    if (try terminal.getWindowSize(&E.screenrows, &E.screencols) == -1) {
        Terminal.die("getWindowSize", error.WriteError); //pass correct error
    }
    E.screenrows -= 2;
}

pub fn main() !void {
    Terminal.enableRawMode();
    defer(Terminal.disableRawMode());
    errdefer(Terminal.disableRawMode());
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
        try editorRefreshScreen();
        try editorProcessKeypress();
    }
}

//-----------------------------------------------------------------------------
// Syntax Highlighting
//-----------------------------------------------------------------------------
fn is_separator(c: u8) bool {
    return std.ascii.isWhitespace(c) or c == '\x00' or std.mem.indexOf(u8,
        ",.()+-/*=~%<>[];",
        &[_]u8{c}) != null;
}

fn editorUpdateSyntax(row: *erow) !void {
    row.*.hl.clearAndFree();

    var r: usize = 0;
    while (r < row.*.render.items.len) : (r += 1) {
        try row.*.hl.append(@intFromEnum(editorHighlight.HL_NORMAL));
    }
    if (E.syntax == null) return;

    const keywords = E.syntax.?.keywords;

    const scs = E.syntax.?.singleline_comment_start;
    const mcs = E.syntax.?.multiline_comment_start;
    const mce = E.syntax.?.multiline_comment_end;

	var prev_sep: bool = true;
    var in_string: u8 = 0;
    var in_comment: bool = (row.*.idx > 0 and E.row.items[row.*.idx - 1].hl_open_comment); 

    var i: usize = 0;
    while (i < row.*.render.items.len) : (i += 1) {
		const c = row.*.render.items[i];
		const prev_hl = if (i > 0) row.*.hl.items[i - 1] else @intFromEnum(
			editorHighlight.HL_NORMAL);

        if (scs != null and in_string == 0 and !in_comment) {
            if (std.mem.startsWith(u8, row.*.render.items, scs.?)) {
                @memset(row.*.hl.items, @intFromEnum(editorHighlight.HL_COMMENT));
                break;
            }
        }

        if (mcs != null and mce != null and in_string == 0) {
            if (in_comment) {
                row.*.hl.items[i] = @intFromEnum(editorHighlight.HL_MLCOMMENT);
                if (i + mce.?.len <= row.*.render.items.len and 
                    std.mem.eql(u8, row.*.render.items[i..i + mce.?.len], mce.?[0..mce.?.len])) 
                {
                    @memset(row.*.hl.items[i..i + mce.?.len], @intFromEnum(editorHighlight.HL_MLCOMMENT));
                    i += mce.?.len - 1;
                    in_comment = false;
                    prev_sep = true;
                    continue;
                } else {
                    continue;
                }
            } else if (i + mcs.?.len <= row.*.render.items.len and 
                std.mem.eql(u8, row.*.render.items[i..i + mcs.?.len], mcs.?[0..mcs.?.len])) 
            {
                @memset(row.*.hl.items[i..i + mcs.?.len], @intFromEnum(editorHighlight.HL_MLCOMMENT));
                i += mcs.?.len - 1;
                in_comment = true;
                continue;
            }
        }

        if (E.syntax.?.flags & HL_HIGHLIGHT_STRINGS != 0) {
            if (in_string > 0) {
                row.*.hl.items[i] = @intFromEnum(editorHighlight.HL_STRING);
                if (c == '\\' and i + 1 < row.*.render.items.len) {
                    row.*.hl.items[i + 1] = @intFromEnum(editorHighlight.HL_STRING);
                    i += 1;
                    continue;
                }
                if (c == in_string) in_string = 0;
                prev_sep = true;
                continue;
            } else {
                if (c == '"' or c == '\'') {
                    in_string = c;
                    row.*.hl.items[i] = @intFromEnum(editorHighlight.HL_STRING);
                    continue;
                }
            }
        }

        if (E.syntax.?.flags & HL_HIGHLIGHT_NUMBERS != 0) {
            if ((std.ascii.isDigit(c) 
                and (prev_sep or prev_hl == @intFromEnum(editorHighlight.HL_NUMBER)))
                or (c == '.' and prev_hl == @intFromEnum(editorHighlight.HL_NUMBER))) 
		    {
                row.*.hl.items[i] = @intFromEnum(editorHighlight.HL_NUMBER);
			    prev_sep = false;
			    continue;
            }
        }

        if (prev_sep) {
            var j: usize = 0;
            while (j < keywords.len) : (j += 1) {
                if (keywords[j] == null) break;
                var klen = keywords[j].?.len;
                const kw2 = keywords[j].?[klen - 1] == '|';
                if (kw2) {
                    klen -= 1;
                }

                if (i + klen <= row.*.render.items.len and std.mem.eql(
                        u8, 
                        row.*.render.items[i..i+klen],
                        keywords[j].?[0..klen]) 
                    and (i + klen == row.render.items.len or is_separator(row.*.render.items[i + klen]))) 
                {
                    const hlType = if (kw2) editorHighlight.HL_KEYWORD2 else editorHighlight.HL_KEYWORD1;
                    @memset(row.*.hl.items[i..i + klen], @intFromEnum(hlType));
                    i += klen - 1;
                    break;
                }
            }

            if (keywords[j] != null) {
                prev_sep = false;
                continue;
            }
        }

		prev_sep = is_separator(c);
    }

    const changed = (row.*.hl_open_comment != in_comment);
    row.*.hl_open_comment = in_comment;
    if (changed and row.*.idx + 1 < E.numrows) {
        try editorUpdateSyntax(&E.row.items[row.*.idx + 1]);
    }
}

fn editorSyntaxToColor(hl: u8) u8 {
    switch (hl) {
        @intFromEnum(editorHighlight.HL_COMMENT) => return 36,
        @intFromEnum(editorHighlight.HL_MLCOMMENT) => return 36,
        @intFromEnum(editorHighlight.HL_KEYWORD1) => return 33,
        @intFromEnum(editorHighlight.HL_KEYWORD2) => return 32,
        @intFromEnum(editorHighlight.HL_STRING) => return 35,
        @intFromEnum(editorHighlight.HL_NUMBER) => return 31,
        @intFromEnum(editorHighlight.HL_MATCH) => return 34,
        else => return 37,
    }
}

fn editorSelectSyntaxHighlight() !void {
    E.syntax = null;
    if (E.filename == null) return;

    const ext = std.fs.path.extension(E.filename.?);

    var j: usize = 0;
    while (j < HLDB_ENTRIES) : (j += 1) {
        const s = HLDB[j];
        var i: usize = 0;

        while (i < s.filematch.len) : (i += 1) {
            const is_ext = s.filematch[i][0] == '.';
            if ((is_ext and std.mem.eql(u8, ext, s.filematch[i]))) {
                E.syntax = s;

                var filerow: usize = 0;
                while (filerow < E.numrows) : (filerow += 1) {
                    try editorUpdateSyntax(&E.row.items[filerow]);
                }

                return;
            }
        }
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
        .idx = at,
        .chars = std.ArrayList(u8).init(E.allocator),
        .render = std.ArrayList(u8).init(E.allocator),
        .hl = std.ArrayList(u8).init(E.allocator),
        .hl_open_comment = false,
    });
    const item = &E.row.items[at];

    var j: usize = at + 1;
    while (j <= E.numrows) : (j += 1) {
        E.row.items[j].idx += 1;
    }

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
    var j: usize = at;
    while (j < E.numrows - 1) : (j += 1) {
        E.row.items[j].idx -= 1;
    }
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
    } else if (E.cy >= E.row.items.len) {
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

                    if (E.row.items[filerow].hl.items.len > 0) {
                        const hl = E.row.items[filerow].hl.items[i];

                        if (Terminal.iscntrl(c)) {
                            const sym = if (c <= 26) '@' + c else '?';
                            try abAppend(append_buffer, "\x1b[7m");
                            try abAppend(append_buffer, &[_]u8{sym});
                            try abAppend(append_buffer, "\x1b[m");
                            if (current_color != -1) {
                                var buf = std.ArrayList(u8).init(E.allocator);
                                try std.fmt.format(
                                    buf.writer(), 
                                    "\x1b[{d}m",
                                    .{current_color});
                                try abAppend(append_buffer, buf.items);
                            }
                        } else if (hl == @intFromEnum(editorHighlight.HL_NORMAL)) {
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
                    } else {
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
    const filetype = if (E.syntax != null) E.syntax.?.filetype else "no ft";

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
        "{s} | {d}/{d}",
        .{ filetype, E.cy + 1, E.numrows }
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

fn editorRefreshScreen() !void {
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

    _ = try E.writer.write(append_buffer.b.items);
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
    comptime prompt: []const u8,
    callback: ?*const fn (*[] u8, u16) error{OutOfMemory}!void
) !?[]u8 {
    _ = &prompt; // fix this later
    var buffer = std.ArrayList(u8).init(E.allocator);
    
    while (true) {
        try editorSetStatusMessage(prompt, .{ buffer.items });
        try editorRefreshScreen();
        
        const c = try terminal.editorReadKey();
        if (c == @intFromEnum(in.DEL_KEY) or c == CTRL_KEY('h') or c ==
            @intFromEnum(in.BACKSPACE)) {
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
        } else if (!Terminal.iscntrl(c) and c < 128) {
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
        @intFromEnum(in.ARROW_LEFT) => {
            if (E.cx != 0) {
                E.cx -= 1;
            } else if (E.cy > 0) {
                E.cy -= 1;
                E.cx = @intCast(E.row.items[E.cy].chars.items.len);
            }
        },
        @intFromEnum(in.ARROW_RIGHT) => {
            if (row != null and E.cx < row.?.chars.items.len) {
                E.cx += 1;
            } else if (row != null and E.cx == row.?.chars.items.len) {
                E.cy += 1;
                E.cx = 0;
            }

        },
        @intFromEnum(in.ARROW_UP) => {
            if (E.cy != 0) {
                E.cy -= 1;
            } 
        },
        @intFromEnum(in.ARROW_DOWN) => {
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

fn editorProcessKeypress() !void {
    const char = try terminal.editorReadKey();
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
            Terminal.disableRawMode();
            _ = try posix.write(posix.STDOUT_FILENO, "\x1b[2J");
            _ = try posix.write(posix.STDOUT_FILENO, "\x1b[H");
            posix.exit(0);
        },

        CTRL_KEY('s') => {
            try editorSave();
        },

        @intFromEnum(in.HOME_KEY) => E.cx = 0,

        @intFromEnum(in.END_KEY) => {
            if (E.cy < E.numrows) {
                E.cx = @intCast(E.row.items[E.cy].chars.items.len);
            }
        },

        CTRL_KEY('f') => {
            try editorFind();
        },

        @intFromEnum(in.BACKSPACE), @intFromEnum(in.DEL_KEY),
        CTRL_KEY('h') => {
            if (char == @intFromEnum(in.DEL_KEY)) {
                editorMoveCursor(@intFromEnum(in.ARROW_RIGHT));
            }
            try editorDelChar();
        },

        @intFromEnum(in.PAGE_UP), @intFromEnum(in.PAGE_DOWN) => {
            if (char == @intFromEnum(in.PAGE_UP)) {
                E.cy = E.rowoff;
            } else if (char == @intFromEnum(in.PAGE_DOWN)) {
                E.cy = E.rowoff + E.screenrows - 1;
                if (E.cy > E.numrows) {
                    E.cy = E.numrows;
                }
            }
            var times: u16 = E.screenrows;
            while (times > 0) : (times -= 1) {
                if (char == @intFromEnum(in.PAGE_UP)) {
                    editorMoveCursor(@intFromEnum(in.ARROW_UP));
                } else {
                    editorMoveCursor(@intFromEnum(in.ARROW_DOWN));
                }
            }
        },

        @intFromEnum(in.ARROW_UP) => editorMoveCursor(char),
        @intFromEnum(in.ARROW_DOWN) => editorMoveCursor(char),
        @intFromEnum(in.ARROW_LEFT) => editorMoveCursor(char),
        @intFromEnum(in.ARROW_RIGHT) => editorMoveCursor(char),

        CTRL_KEY('l'), '\x1b' => {},

        //'w', 's', 'a', 'd' => editorMoveCursor(char),
        else => try editorInsertChar(char),
    }
    Q.quit_times = BLIP_QUIT_TIMES;
}
