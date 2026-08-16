const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const Dir = Io.Dir;
const process = std.process;
const unicode = std.unicode;
const debug = std.debug;
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

        return insertStr(pathBuffer, firstPathLen, relativePath[1..]);
    }

    pathBuffer[firstPathLen] = slash;

    return insertStr(pathBuffer, firstPathLen + slashLen, relativePath);
}

pub inline fn createDir(io: Io, dir: Dir, path: []const u8) !void {
    return dir.createDir(io, path, Dir.Permissions.default_dir);
}

/// Inserts `string` to `buffer` starting from `startIndex`.
///
/// `buffer` is assumed to have enough length to receive `string`.
///
/// Returns a slice of the result in `buffer`.
pub inline fn insertStr(
    buffer: []u8,
    startIndex: usize,
    string: []const u8,
) []const u8 {
    const newLen = startIndex + string.len;

    @memcpy(buffer[startIndex..newLen], string);

    return buffer[0..newLen];
}

/// Concats every string of `strings` into `buffer`.
///
/// `buffer` must have enough length.
///
/// Returns a slice in `buffer` containing concatinated strings.
pub inline fn concatStr(buffer: []u8, strings: anytype) []const u8 {
    var resultLen: usize = 0;

    inline for (0..strings.len) |index| {
        const string = strings[index];

        comptime {
            const isString = switch (@typeInfo(@TypeOf(string))) {
                .array => |info| info.child == u8,

                .pointer => |info| switch (@typeInfo(info.child)) {
                    .array => |childInfo| childInfo.child == u8,
                    .int => |childInfo| childInfo.bits == 8 and childInfo.signedness == .unsigned,
                    else => false,
                },

                else => false,
            };

            if (!isString) {
                @compileError(std.fmt.comptimePrint("Expected string at index {d}", .{index}));
            }
        }

        @memcpy(buffer[0..string.len], string);

        resultLen += string.len;
    }

    return buffer[0..resultLen];
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

/// High-level wrapper over streaming `stdout` or `stderr`.
pub const StdOut = struct {
    writer: Io.File.Writer,

    pub inline fn init(io: Io, comptime stdoutType: enum { Stdout, Stderr }, buffer: []u8) @This() {
        return .{
            .writer = switch (stdoutType) {
                .Stdout => Io.File.stdout(),
                .Stderr => Io.File.stderr(),
            }.writerStreaming(io, buffer),
        };
    }

    pub const WriteError = Io.Writer.Error;

    /// Writes every slice of `data` to the buffer of `init` function
    /// and outputs it if the buffer ends.
    ///
    /// `data` is an array (with comptime known length) of slices.
    pub inline fn write(self: *@This(), data: anytype) WriteError!void {
        const writer: *Io.Writer = @constCast(&self.writer.interface);

        inline for (data) |slice| {
            try writer.writeAll(slice);
        }
    }

    pub inline fn flush(self: *@This()) WriteError!void {
        const writer: *Io.Writer = @constCast(&self.writer.interface);

        return writer.flush();
    }
};

pub const ConfirmError = error{UnknownChar} || StdIn.ReadError || StdOut.WriteError;
/// Writes `query` to `stdout`.
///
/// Returns `true` if the first char read from `stdin` is `y` or `false` if `n`.
pub inline fn confirm(
    stdin: *StdIn,
    stdout: *StdOut,
    /// An array of slices (`StdOut.write` recevies data like that).
    query: anytype,
) ConfirmError!bool {
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

    debug.print(fmt ++ "\n", args);
}
