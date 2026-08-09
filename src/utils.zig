const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const process = std.process;
const unicode = std.unicode;
const builtin = @import("builtin");

const OS = builtin.os.tag;

pub const MAX_PATH_BYTES = Io.Dir.max_path_bytes;

pub const UserDirPathError = error{
    GetUserProfileEnvFail,

    /// Only on windows.
    ConvertPathToUtf8Fail,
    GetHomeEnvFail,
};

/// Writes to `buffer` the path to user dir.
///
/// Returns length of the path in `buffer` or `null` in case of error.
pub inline fn getUserDirPath(
    /// `process.Environ` from which to read the user dir path.
    environ: process.Environ,
    buffer: *[MAX_PATH_BYTES]u8,
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
        const path = environ.getPosix("HOME") orelse {
            return UserDirPathError.GetHomeEnvFail;
        };
        const pathLen = path.len;

        @memcpy(buffer[0..pathLen], path);

        return pathLen;
    }
}

/// Simply inserts `component` to `path` starting from `startIndex`, without resolving relativness.
///
/// `path[0..startIndex]` must not include trailing slash, but `component` must start with slash.
///
/// Returns a slice in `pathBuffer` of the result.
pub inline fn insertPathComponent(
    pathBuffer: *[MAX_PATH_BYTES]u8,
    startIndex: usize,
    component: []const u8,
) []const u8 {
    const newPathLen = startIndex + component.len;

    @memcpy(pathBuffer[startIndex..newPathLen], component);

    return pathBuffer[0..newPathLen];
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

/// High-level wrapper over unbufferred, streaming `stdout` or `stderr` from zig std.
pub const StdIo = struct {
    stdio: Io.File.Writer,

    pub inline fn init(io: Io, comptime stdioType: enum { Stdout, Stderr }) @This() {
        var stdio: Io.File.Writer = switch (stdioType) {
            .Stdout => Io.File.stdout(),

            .Stderr => Io.File.stderr(),
        }.writer(io, &.{}); // Empty slice means unbuffered

        // If it is not done, the first call of `stdioWriter.vtable.drain`
        // (which is in `StdIo.print`) ends with error and turns the `mode` to `streaming` on its own
        stdio.mode = stdio.mode.toStreaming();

        return .{ .stdio = stdio };
    }

    /// Outputs `data` to `stdout` or `stderr`.
    pub inline fn write(self: *@This(), data: []const u8) !void {
        const writer = @constCast(&self.stdio.interface);

        _ = try writer.vtable.drain(writer, &.{data}, 1);
    }
};

pub inline fn getUtf16Literal(comptime utf8Literal: []const u8) []const u16 {
    return comptime std.unicode.utf8ToUtf16LeStringLiteral(utf8Literal);
}
