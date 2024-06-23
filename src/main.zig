const std = @import("std");
const io = std.io;
const mem = std.mem;

pub fn main() !void {
    const stdin = io.getStdIn().reader();
    // const stdout = io.getStdOut().writer();

    var char: [1]u8 = undefined;
    // var input: []const u8 = undefined;

    while (try stdin.read(&char) == 1 and !mem.eql(u8, &char, "q")) {
        // input = (try nextLine(stdin, &buffer)).?;
        // try stdout.print("{s}\n", .{input});
    }
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
