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

pub inline fn findStrScalar(str: []const u8, searchValue: u8) ?usize {
    return mem.findScalarPos(u8, str, 0, searchValue);
}

/// `path` must have length at least 1.
pub fn isPathAbs(path: []const u8) bool {
    return switch (OS) {
        .windows => Dir.path.isAbsoluteWindows(path),

        else => path[0] == '/',
    };
}

/// Path builder.
///
/// The path can only grow, so it is safe
/// to reuse previous paths after calling `Path.append`.
pub const PathBuilder = struct {
    buffer: [MAX_PATH_BYTES]u8,
    /// The end of current path in `buffer`. After this elements are `undefined`.
    ///
    /// Never includes trailing slash.
    end: usize,

    /// Copies `absPath` to initialized `PathBuilder.buffer`.
    pub inline fn init() @This() {
        return .{
            .buffer = undefined,
            .end = 0,
        };
    }

    /// Joins `relPath` with the current path in `buffer`, invalidating `end`.
    ///
    /// Passing an absolute path here causes a wrong behaviour.
    ///
    /// Asserts that `buffer` has enough length to receive `relPath`.
    ///
    /// Returns a slice of the result in `buffer`.
    pub fn append(self: *@This(), relPath: []const u8) []const u8 {
        const buffer = @constCast(&self.buffer);

        assert(self.end + relPath.len < buffer.len);

        var newEnd: usize = self.end;
        defer self.end = newEnd;

        buffer[newEnd] = '/';
        newEnd += 1;

        @memcpy(buffer[newEnd..][0..relPath.len], relPath);

        newEnd += relPath.len;

        // Omit trailing slash
        newEnd -= @intFromBool(relPath[relPath.len - 1] == '/');

        return buffer[0..newEnd];
    }
    /// Invalidates `end` of the path.
    ///
    /// Comptime asserts that `literalPath` is not absolute and does not end with a slash.
    pub inline fn appendLiteral(self: *@This(), comptime literalPath: []const u8) []const u8 {
        comptime {
            assert(literalPath[0] != '/' and literalPath[0] != '\\');

            const lastChar = literalPath[literalPath - 1];
            assert(lastChar != '/' and lastChar != '\\');
        }

        const buffer = @constCast(&self.buffer);

        var newEnd = self.end;
        defer self.end = newEnd;

        const resolvedLiteralPath = "/" ++ literalPath;

        @memcpy(buffer[newEnd..][0..resolvedLiteralPath], resolvedLiteralPath);
        newEnd += resolvedLiteralPath.len;

        return buffer[0..newEnd];
    }
};

/// Iterator over a path's components.
pub const PathIterator = struct {
    /// Does not always contain the full initial path.
    ///
    /// Instead, it starts with the last handled component.
    path: []const u8,

    pub inline fn init(path: []const u8) @This() {
        return .{ .path = path };
    }

    /// Can return an empty slice if the path is absolute
    /// (`/abc` does not contain anything before the first slash).
    pub inline fn next(self: *@This()) ?[]const u8 {
        const path = self.path;

        const nextSlashIndex: usize = switch (OS) {
            .windows => @min(
                findStrScalar(path, '\\') orelse return null,
                findStrScalar(path, '/') orelse return null,
            ),
            else => findStrScalar(
                path,
                '/',
            ) orelse return null,
        };

        defer self.path = path[nextSlashIndex + 1 ..];
        return path[0..nextSlashIndex];
    }
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

    pub inline fn writeByte(self: *@This(), byte: u8) WriteError!void {
        const writer: *Io.Writer = @constCast(&self.writer.interface);

        return writer.writeByte(byte);
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
