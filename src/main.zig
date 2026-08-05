const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const process = std.process;
const unicode = std.unicode;
const win = std.os.windows;
const builtin = @import("builtin");

const OS = builtin.os.tag;

const MAX_PATH_LEN = win.MAX_PATH;

const Errors = struct {
    pub const UNKNOWN_CMD = "Unknown command. Use 'ssync --help'.";
};
const HELP_TEXT =
    \\commands:
    \\  list                           List the created roots and paths to them in the system.
    \\  add [root, source, dest]       'root' is name of a root folder to copy 'source' file to. Root is created if does not exit.
    \\                                 'source' is path to a file in the system which is to be copied to 'dest'.
    \\                                 'dest' is a path relative to 'root' to copy 'source' to.
    \\  delete [root, ?file]           If file specified, delete the 'file' in 'root'.
    \\                                 If only 'root' specified, delete the whole root (prompt is shown for safety).
    \\  update [root, newSource, dest] Make 'dest' in 'root' track 'newSource' instead of the current.
;

pub fn main(init: std.process.Init.Minimal) !void {
    const environ = init.environ;

    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const arenaAllocator = arena.allocator();

    var threaded: Io.Threaded = .init(arenaAllocator, .{});
    const io = threaded.io();

    var stderr = Io.File.stdout().writer(io, &.{});

    const stderrWriter = &stderr.interface;

    var args = try init.args.iterateAllocator(arenaAllocator);

    if (args.next()) |command| {
        var stdout = Io.File.stdout().writer(io, &.{});

        const stdoutWriter = &stdout.interface;

        if (mem.eql(u8, command, "--help")) {
            try writeStdio(stdoutWriter, HELP_TEXT);

            process.exit(0);
        }
        if (mem.eql(u8, command, "list")) {}

        var userDirPathBuffer: [MAX_PATH_LEN]u8 = undefined;

        const userDirPath = getUserDirPath(environ, &userDirPathBuffer);

        _ = userDirPath;
    } else {
        try writeStdio(stderrWriter, Errors.UNKNOWN_CMD);
    }
}

/// Writes to `buffer` the path to user dir.
///
/// Returns a slice of `buffer` with length of the path or `null` in case of error.
inline fn getUserDirPath(
    /// `process.Environ` from which to read the user dir path.
    environ: process.Environ,
    buffer: *[MAX_PATH_LEN]u8,
) ?[]const u8 {
    if (OS == .windows) {
        const utf16Path = environ.getWindows(getUtf16Literal("%USERPROFILE%")) orelse {
            return null;
        };

        const utf8PathLen = unicode.utf16LeToUtf8(buffer, utf16Path) catch {
            return null;
        };

        return buffer[0..utf8PathLen];
    } else {
        const path = environ.getPosix("$HOME") orelse {
            return null;
        };

        @memcpy(buffer[0..path.len], path);

        return buffer[0..path.len];
    }
}

inline fn writeStdio(writer: *Io.Writer, data: []const u8) !void {
    _ = try writer.vtable.drain(writer, &.{data}, 1);
}

inline fn getUtf16Literal(comptime utf8Literal: []const u8) []const u16 {
    return comptime std.unicode.utf8ToUtf16LeStringLiteral(utf8Literal);
}
