const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const Dir = Io.Dir;
const process = std.process;
const unicode = std.unicode;
const builtin = @import("builtin");

const OS = builtin.os.tag;

pub const UserPathError = error{
    GetUserProfileEnvFail,

    /// Only on windows.
    ConvertPathToUtf8Fail,
    GetHomeEnvFail,
};

/// Writes to `buffer` the path to user dir.
///
/// `buffer` must have length at list as the max path bytes of system.
///
/// Returns a slice of the path in `buffer` or `UserPathError`.
pub inline fn getUserPath(
    /// `process.Environ` from which to read the user dir path.
    env: process.Environ,
    buffer: []u8,
) UserPathError![]const u8 {
    if (OS == .windows) {
        const utf16Path = env.getWindows(
            unicode.utf8ToUtf16LeStringLiteral("%USERPROFILE%"),
        ) orelse {
            return UserPathError.GetUserProfileEnvFail;
        };

        const utf8PathLen = unicode.utf16LeToUtf8(buffer, utf16Path) catch {
            return UserPathError.ConvertPathToUtf8Fail;
        };

        return utf8PathLen;
    } else {
        const path = env.getPosix("HOME") orelse {
            return UserPathError.GetHomeEnvFail;
        };

        const bufferPath = buffer[0..path.len];

        @memcpy(bufferPath, path);

        return bufferPath;
    }
}

/// If `relativePath` is `.` or `./`, returns `pathBuffer[0..firstPathLen]`.
/// Otherwise copies `relativePath` to `pathBuffer` starting from `firstPathLen`.
///
/// `pathBuffer` must have length at least as max path bytes of system.
///
/// `pathBuffer[0..firstPathLen]` must contain the firstPath without trailing slash.
///
/// `relativePath` must be relative and have length at least 1.
///
/// Resolves `./` and `.\` in `relativePath`.
///
/// Returns a slice of the result in `pathBuffer`.
pub inline fn joinPath(
    pathBuffer: []u8,
    firstPathLen: usize,
    relativePath: []const u8,
) []const u8 {
    const slash = if (OS == .windows) '\\' else '/';

    const slashLen = 1;

    // If it starts with './', just copy including slash
    if (relativePath[0] == '.') {
        // Only '.' or './'
        if (relativePath.len <= 2) {
            return pathBuffer[0..firstPathLen];
        }

        return insertSlice(u8, pathBuffer, firstPathLen, relativePath[1..]);
    }

    pathBuffer[firstPathLen] = slash;

    return insertSlice(u8, pathBuffer, firstPathLen + slashLen, relativePath);
}

pub inline fn createDir(io: Io, dir: Dir, path: []const u8) !void {
    return dir.createDir(io, path, Dir.Permissions.default_dir);
}

/// Inserts `slice` to `buffer` starting from `startIndex`.
///
/// `buffer` is assumed to have enough length to receive `slice`.
///
/// Returns `buffer[0..resultLen]`.
pub inline fn insertSlice(
    comptime T: type,
    buffer: []T,
    startIndex: usize,
    slice: []const T,
) []const u8 {
    const newLen = startIndex + slice.len;

    @memcpy(buffer[startIndex..newLen], slice);

    return buffer[0..newLen];
}

/// Concats every string of `strings` into `buffer`.
///
/// `buffer` must have enough length.
pub inline fn concatStrings(buffer: []u8, strings: anytype) []const u8 {
    inline for (0..strings.len) |index| {
        const string = strings[index];

        comptime {
            const stringInfo = @typeInfo(string);

            if ((stringInfo == .array and stringInfo.array.child != u8) or
                (stringInfo == .pointer and stringInfo.pointer.child != u8) or
                true)
            {
                @compileError("Expected string");
            }
        }

        @memcpy(buffer[0..string.len], string);
    }
}

/// High-level wrapper over buffered, streaming `stdin`.
pub const StdIn = struct {
    reader: Io.File.Reader,

    pub inline fn init(io: Io, buffer: []u8) @This() {
        return .{ .reader = Io.File.stdin().readerStreaming(io, buffer) };
    }

    pub const ReadError = Io.Reader.Error;

    pub inline fn readByte(self: *@This()) ReadError!u8 {
        const reader: *Io.Reader = @constCast(&self.reader.interface);

        return reader.takeByte();
    }
};

/// High-level wrapper over unbufferred, streaming `stdout` or `stderr`.
pub const StdOut = struct {
    writer: Io.File.Writer,

    pub inline fn init(io: Io, comptime stdoutType: enum { Stdout, Stderr }) @This() {
        return .{
            .writer = switch (stdoutType) {
                .Stdout => Io.File.stdout(),
                .Stderr => Io.File.stderr(),
            }.writerStreaming(io, &.{}), // Empty slice means unbuffered

        };
    }
    pub const WriteError = Io.Writer.Error;
    /// Outputs `data` to stdio.
    pub inline fn write(self: *@This(), data: []const u8) WriteError!void {
        const writer: *Io.Writer = @constCast(&self.writer.interface);

        _ = try writer.vtable.drain(writer, &.{data}, 1);
    }
};

pub const ConfirmError = error{UnknownChar} || StdIn.ReadError || StdOut.WriteError;

/// Returns `true` if the first char read from `stdin` is `y` or `false` if `n`.
pub inline fn confirm(stdin: *StdIn, stdout: *StdOut, query: []const u8) ConfirmError!bool {
    try stdout.write(query);

    const input = try stdin.readByte();

    return switch (input) {
        'y' => true,
        'n' => false,
        else => ConfirmError.UnknownChar,
    };
}

pub inline fn exit(code: enum(u8) { Success = 0, GeneralError = 1, InvalidArg = 2 }) noreturn {
    process.exit(@intFromEnum(code));
}

pub fn __debug__(comptime fmt: []const u8, args: anytype) void {
    if (builtin.mode != .debug) {
        @compileError("'__debug__' is only for 'Debug' mode");
    }

    std.debug.print(fmt ++ "\n", args);
}
