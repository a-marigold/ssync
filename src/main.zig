const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const Io = std.Io;
const process = std.process;
const unicode = std.unicode;
const win = std.os.windows;
const builtin = @import("builtin");

const OS = builtin.os.tag;

const MAX_PATH_LEN = win.MAX_PATH;

const Errors = struct {
    pub const UNKNOWN_CMD = "Unknown command. Use 'ssync --help'.";

    pub const GET_USER_DIR_PATH_FAIL = "Failed to get the user dir path.";
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

pub fn main(init: process.Init.Minimal) !void {
    const environ = init.environ;

    var arena: heap.ArenaAllocator = .init(heap.page_allocator);
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
    } else {
        try writeStdio(stderrWriter, Errors.UNKNOWN_CMD);
    }
}

const UserDirPathError = error{
    GetUserProfileEnvFail,

    ConvertPathToUtf8Fail,

    GetHomeEnvFail,
};

/// Writes to `buffer` the path to user dir.
///
/// Returns length of the path in `buffer` or `null` in case of error.
inline fn getUserDirPath(
    /// `process.Environ` from which to read the user dir path.
    environ: process.Environ,
    buffer: *[MAX_PATH_LEN]u8,
) UserDirPathError!usize {
    if (OS == .windows) {
        const utf16Path = environ.getWindows(getUtf16Literal("%USERPROFILE%")) orelse {
            return UserDirPathError.GetUserProfileEnvFail;
        };

        const utf8PathLen = unicode.utf16LeToUtf8(buffer, utf16Path) catch {
            return UserDirPathError.ConvertPathToUtf8Fail;
        };

        return utf8PathLen;
    } else {
        const path = environ.getPosix("$HOME") orelse {
            return UserDirPathError.GetHomeEnvFail;
        };
        const pathLen = path.len;

        @memcpy(buffer[0..pathLen], path);

        return pathLen;
    }
}

/// Inserts `literal` to `path` starting from `startIndex`.
///
/// `path[0..startIndex]` must not include trailing slash, but `literal` must start with slash.
///
/// Returns a slice of `path[0..startIndex]` joined with `literal`.
inline fn insertPathLiteral(path: *[MAX_PATH_LEN]u8, startIndex: usize, comptime literal: []const u8) []const u8 {
    const insertionStart = startIndex + 1;
    const newPathLen = insertionStart + literal.len;

    @memcpy(path[insertionStart..newPathLen], literal);

    return path[0..newPathLen];
}

/// Appends every slice of `slices` to `array`.
inline fn arrayAppendSlices(
    allocator: mem.Allocator,
    comptime T: type,
    array: *std.ArrayList(T),
    slices: anytype,
) !void {
    inline for (slices) |slice| {
        try array.appendSlice(allocator, slice);
    }
}

/// Used with unbuffered stdio.
inline fn writeStdio(writer: *Io.Writer, data: []const u8) !void {
    _ = try writer.vtable.drain(writer, &.{data}, 1);
}

inline fn getUtf16Literal(comptime utf8Literal: []const u8) []const u16 {
    return comptime std.unicode.utf8ToUtf16LeStringLiteral(utf8Literal);
}
