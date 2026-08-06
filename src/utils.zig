const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const process = std.process;
const unicode = std.unicode;
const builtin = @import("builtin");

const OS = builtin.os.tag;

/// Assume it is enough.
pub const MAX_PATH_LEN = std.os.windows.MAX_PATH;

pub const UserDirPathError = error{
    GetUserProfileEnvFail,
    ConvertPathToUtf8Fail,
    GetHomeEnvFail,
};
/// Writes to `buffer` the path to user dir.
///
/// Returns length of the path in `buffer` or `null` in case of error.
pub inline fn getUserDirPath(
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
pub inline fn insertPathLiteral(path: *[MAX_PATH_LEN]u8, startIndex: usize, comptime literal: []const u8) []const u8 {
    const insertionStart = startIndex + 1;
    const newPathLen = insertionStart + literal.len;

    @memcpy(path[insertionStart..newPathLen], literal);

    return path[0..newPathLen];
}

/// Appends every slice of `slices` to `array`.
pub inline fn arrayAppendSlices(
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
///
/// Writer MUST be in `streaming` mode, not `positional`.
pub inline fn writeStdio(writer: *Io.Writer, data: []const u8) !void {
    _ = try writer.vtable.drain(writer, &.{data}, 1);
}

pub inline fn getUtf16Literal(comptime utf8Literal: []const u8) []const u16 {
    return comptime std.unicode.utf8ToUtf16LeStringLiteral(utf8Literal);
}
