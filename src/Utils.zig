const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const Dir = Io.Dir;
const process = std.process;
const unicode = std.unicode;
const debug = std.debug;
const assert = debug.assert;
const builtin = @import("builtin");

const OS = builtin.os.tag;

const MAX_PATH_BYTES = Dir.max_path_bytes;

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
    /// Used to read the user dir path.
    env: process.Environ,
    buffer: []u8,
) UserPathError![]const u8 {
    switch (OS) {
        .windows => {
            const utf16Path = env.getWindows(
                unicode.utf8ToUtf16LeStringLiteral("%USERPROFILE%"),
            ) orelse return UserPathError.GetUserProfileEnvFail;

            const utf8PathLen = unicode.utf16LeToUtf8(
                buffer,
                utf16Path,
            ) catch return UserPathError.ConvertPathToUtf8Fail;

            return buffer[0..utf8PathLen];
        },
        else => {
            const path = env.getPosix("HOME") orelse return UserPathError.GetHomeEnvFail;

            const bufferPath = buffer[0..path.len];

            @memcpy(bufferPath, path);

            return bufferPath;
        },
    }
}

/// If `relativePath` is `.` or `./`, returns the unchanged first path.
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

    // If it starts with './', just copy including slash
    if (relativePath[0] == '.') {
        // Only '.' or './'
        if (relativePath.len <= 2) {
            return pathBuffer[0..firstPathLen];
        }

        return insertStr(pathBuffer, firstPathLen, relativePath[1..]);
    }

    const slash = if (OS == .windows) '\\' else '/';

    const slashLen = 1;

    pathBuffer[firstPathLen] = slash;

    return insertStr(pathBuffer, firstPathLen + slashLen, relativePath);
}

/// Inserts `str` to `buffer` starting from `startIndex`.
///
/// `buffer` is assumed to have enough length to receive `str`.
///
/// Returns a slice of the result in `buffer`.
pub inline fn insertStr(
    buffer: []u8,
    startIndex: usize,
    str: []const u8,
) []const u8 {
    const newLen = startIndex + str.len;

    @memcpy(buffer[startIndex..newLen], str);

    return buffer[0..newLen];
}

pub const Path = struct {
    buffer: [MAX_PATH_BYTES]u8,
    /// The end of current path in `buffer`. After this elements are `undefined`.
    ///
    ///
    ///
    /// Never includes trailing slash.
    end: usize,

    /// Copies `absPath` to initialized `Path.buffer`.
    pub inline fn init() @This() {
        return .{
            .buffer = undefined,
            .end = 0,
        };
    }

    pub const AppendError = error{
        /// When `relativePath` starts with `..`
        RelativePathBeyond,
        RelativePathAbsolute,
    };
    /// Appends `relPath` to the path.
    ///
    /// Invalidates `end` of the path.
    ///
    /// Resolves relativness of the first `relPath` component (`./abc`).
    ///
    /// If the first component is like `../` (goes beyond the current path),
    /// returns an error 'cause it cannot be appended.
    ///
    /// If `relPath` is absolute, returns an error.
    ///
    /// `relPath` must have length at least 1.
    ///
    /// Returns a slice of the new path.
    pub fn append(path: *@This(), relPath: []const u8) AppendError![]const u8 {
        const slash = if (OS == .windows) '\\' else '/';

        if (relPath[0] == '.') {
            if (relPath.len == 1) {
                return path[path.end];
            }

            const secondChar = relPath[1];

            switch (secondChar) {
                '/' => if (relPath.len == 2) {
                    return path[0..path.end];
                } else {
                    @branchHint(.likely);

                    // Reuse the slash
                    var newEnd = path.end;
                    defer path.end = newEnd;

                    const normalRelPath = relPath[1..];

                    @memcpy(path.buffer[newEnd..][0..normalRelPath.len], normalRelPath);
                    newEnd += normalRelPath.len - 1;

                    return path.buffer[0..newEnd];
                },

                // Return error for `..` or `../`.
                // Otherwise it is a valid path like `..abc`
                '.' => if (relPath.len == 2 or relPath[2] == '/') {
                    @branchHint(.unlikely);
                    return AppendError.RelativePathBeyond;
                },

                else => {
                    var newEnd = path.end;
                    defer path.end = newEnd;

                    path[newEnd] = slash;
                    newEnd += 1;

                    path[newEnd] = secondChar;
                    newEnd += 1;
                    // TODO: fix trailing slash
                    return path.buffer[0..newEnd];
                },
            }
        } else if (isAbs(relPath)) {
            return AppendError.RelativePathAbsolute;
        }

        var newEnd = path.end;
        defer path.end = newEnd;

        path[newEnd] = slash;
        newEnd += 1;

        @memcpy(path.buffer[newEnd..relPath.len], relPath);
        newEnd += relPath.len;

        return path.buffer[0..newEnd];
    }

    /// Invalidates `end` of the path.
    ///
    /// `literalPath` must start with a slash.
    ///
    /// Comptime asserts that `literalPath` does not end with a slash.
    pub inline fn appendLiteral(path: *@This(), comptime literalPath: []const u8) []const u8 {
        const slash = if (OS == .windows) '\\' else '/';
        comptime assert(literalPath[0] == slash and literalPath[literalPath.len - 1] != slash);

        var newEnd = 0;
        defer path.end = newEnd;

        @memcpy(&path.buffer[newEnd..][0..literalPath.len], literalPath);
        newEnd += literalPath.len;

        return path.buffer[0..newEnd];
    }

    /// `path` must have length at least 1.
    pub fn isAbs(path: []const u8) bool {
        return switch (OS) {
            .windows => Dir.path.isAbsoluteWindows(path),
            else => path[0] == '/',
        };
    }

    // TODO: add 'appendLiteral'
};

pub inline fn createDir(io: Io, dir: Dir, path: []const u8) !void {
    return dir.createDir(io, path, Dir.Permissions.default_dir);
}

pub const SymLinkError = switch (OS) {
    .windows => Dir.SymLinkError | Dir.StatError,
    else => Dir.SymLinkError,
};
/// On windows, stats `targetPath` to find out is it a dir and passes appropriate flag to `dir.symLink` function.
///
/// On other platforms just creates symlink 'cause the mentioned flag does not matters there.
pub inline fn symLink(
    io: Io,
    dir: Dir,
    targetPath: []const u8,
    symLinkPath: []const u8,
) SymLinkError!void {
    return dir.symLink(
        io,
        targetPath,
        symLinkPath,
        .{
            .is_directory = switch (OS) {
                .windows => block: {
                    const targetKind = (try dir.statFile(
                        io,
                        targetPath,
                        .{ .follow_symlinks = true },
                    )).kind;

                    break :block targetKind == .directory;
                },
                else => false,
            },
        },
    );
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

    pub inline fn init(io: Io, comptime stdoutType: enum { StdOut, StdErr }, buffer: []u8) @This() {
        return .{
            .writer = switch (stdoutType) {
                .StdOut => Io.File.stdout(),
                .StdErr => Io.File.stderr(),
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

pub const ConfirmError = error{ UnknownChar, ReadFail, WriteFail };
/// Writes `query` to `stdout`.
///
/// Returns `true` if the first char read from `stdin` is `y` or `false` if `n`.
pub inline fn confirm(
    stdin: *StdIn,
    stdout: *StdOut,
    /// An array of slices (`StdOut.write` recevies data like that).
    query: anytype,
) ConfirmError!bool {
    stdout.write(query) catch return ConfirmError.WriteFail;

    const input = stdin.readByte() catch return ConfirmError.ReadFail;

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

// TODO: 'Path' struct with builder and iterator
