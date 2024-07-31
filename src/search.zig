const std = @import("std");
const erow = @import("main.zig").erow;
const in = @import("input.zig").inputKey;


//-----------------------------------------------------------------------------
// Find
//-----------------------------------------------------------------------------
fn editorFindCallback(row: *erow, query: *[] u8, key: u16) error{OutOfMemory}!void {
    const static = struct {
        var last_match: isize = -1;
        var direction: isize = 1;
        var saved_hl_line: isize = undefined;
        var saved_hl: std.ArrayList(u8) = undefined;
    };

    if (static.saved_hl.items.len > 0) {
        row.items[@intCast(static.saved_hl_line)].hl.clearAndFree();
        row.items[@intCast(static.saved_hl_line)].hl = try static.saved_hl.clone();
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

        const row = &row.items[@intCast(current)];
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
