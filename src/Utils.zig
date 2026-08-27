const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const Dir = Io.Dir;
const process = std.process;
const Environ = process.Environ;
const unicode = std.unicode;
const debug = std.debug;
const assert = debug.assert;
const testing = std.testing;
const builtin = @import("builtin");

const TestUtils = @import("tests/TestUtils.zig");

const OS = builtin.os.tag;
const MAX_PATH_BYTES = Dir.max_path_bytes;

pub inline fn findStrScalar(str: []const u8, searchValue: u8) ?usize {
    return mem.findScalarPos(u8, str, 0, searchValue);
}

pub inline fn eqlStr(a: []const u8, b: []const u8) bool {
    return mem.eql(u8, a, b);
}

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

    pub inline fn init() @This() {
        return .{ .buffer = undefined, .end = 0 };
    }

    pub const AppendError = error{OutOfBuffer};
    /// Joins `relPath` with the current path in `buffer`, invalidating `end`.
    ///
    /// Omits trailing slash.
    ///
    /// Passing an absolute path here causes a wrong behaviour.
    ///
    /// If `relPath` doesn't fit `buffer`, returns `AppendError.OutOfBuffer`;
    ///
    /// Returns a slice of the result in `buffer`.
    pub fn append(self: *@This(), relPath: []const u8) AppendError![]const u8 {
        const buffer = @constCast(&self.buffer);

        var newEnd: usize = self.end;
        defer self.end = newEnd;

        if (newEnd + relPath.len > buffer.len) return AppendError.OutOfBuffer;

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
    /// Comptime asserts that `literalPath`
    /// isn't absolute and doesn't end with a slash.
    pub inline fn appendLiteral(self: *@This(), comptime literalPath: []const u8) []const u8 {
        comptime {
            assert(literalPath[0] != '/' and literalPath[0] != '\\');

            const lastChar = literalPath[literalPath.len - 1];
            assert(lastChar != '/' and lastChar != '\\');
        }

        const buffer = @constCast(&self.buffer);

        var newEnd = self.end;
        defer self.end = newEnd;

        const resolvedLiteralPath = "/" ++ literalPath;

        @memcpy(buffer[newEnd..][0..resolvedLiteralPath.len], resolvedLiteralPath);
        newEnd += resolvedLiteralPath.len;

        return buffer[0..newEnd];
    }

    test "`append` and `appendLiteral` join `relPath` with the current buffer path and invalidates `end`" {
        const initPath = "/home/u";

        inline for (.{ "./some/file.toml", "dir/file", "../out" }) |relPath| {
            var pathBuilder: PathBuilder = .init();

            @memcpy(pathBuilder.buffer[0..initPath.len], initPath);

            const fullResult = try append(&pathBuilder, relPath);
            try testing.expectEqualStrings(initPath ++ relPath, fullResult);
            try testing.expectEqual((initPath ++ relPath).len, pathBuilder.end);
        }
        inline for (.{ "./some/file.toml", "dir/file", "../out" }) |relPath| {
            var pathBuilder: PathBuilder = .init();

            @memcpy(pathBuilder.buffer[0..initPath.len], initPath);

            const fullResult = appendLiteral(&pathBuilder, relPath);
            try testing.expectEqualStrings(initPath ++ relPath, fullResult);
            try testing.expectEqual((initPath ++ relPath).len, pathBuilder.end);
        }
    }
    test "`append` omits trailing slash of `relPath`" {
        var pathBuilder: PathBuilder = .init();

        const relPath1 = "./";
        const result1 = try pathBuilder.append(relPath1);
        try testing.expectEqualStrings(".", result1);
        try testing.expectEqual(pathBuilder.end, 1);

        const relPath2 = "./dir/";
        const result2 = try pathBuilder.append(relPath2);
        try testing.expectEqualStrings("././dir", result2);
        try testing.expectEqual("././dir".len, pathBuilder.end);
    }
    test "`append` returns `AppendError.OutOfBuffer` if `relPath` is too big" {
        var pathBuilder: PathBuilder = .init();

        const relPath: [MAX_PATH_BYTES * 2]u8 = undefined;

        try testing.expectError(
            PathBuilder.AppendError.OutOfBuffer,
            pathBuilder.append(&relPath),
        );
    }
};
test {
    testing.refAllDecls(PathBuilder);
}

/// Iterator over a path's components.
pub const PathIterator = struct {
    /// Does not always contain the full initial path.
    ///
    /// Instead, it starts with the last handled component.
    path: []const u8,

    pub inline fn init(path: []const u8) @This() {
        return .{ .path = path };
    }

    /// Returns the next component of the path or null when the path ends.
    ///
    /// Can return an empty slice if the path is absolute
    /// (`/abc` does not contain anything before the first slash).
    pub inline fn next(self: *@This()) ?[]const u8 {
        const path = self.path;

        const nextSlashIndex: usize = switch (OS) {
            .windows => @min(
                findStrScalar(path, '\\') orelse return null,
                findStrScalar(path, '/') orelse return null,
            ),
            else => findStrScalar(path, '/') orelse return null,
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
/// High-level wrapper over `Io.Writer`.
pub const Writer = struct {
    writer: *Io.Writer,
    // TODO: delete this struct
    pub const WriteError = Io.Writer.Error;

    pub inline fn write(self: *@This(), data: []const u8) WriteError!void {
        return self.writer.writeAll(data);
    }

    /// Writes every slice of `vec` to the internal buffer
    /// and outputs it if the buffer ends.
    ///
    /// `vec` is an array (with comptime known length) of slices.
    pub inline fn writeVec(self: *@This(), vec: anytype) WriteError!void {
        inline for (vec) |slice| try self.writer.writeAll(slice);
    }

    pub inline fn writeByte(self: *@This(), byte: u8) WriteError!void {
        return self.writer.writeByte(byte);
    }

    pub inline fn flush(self: *@This()) WriteError!void {
        return self.writer.flush();
    }
};

pub const ConfirmError = error{ UnknownChar, ReadFail, WriteFail };
/// Writes `query` to `stdout`.
///
/// Returns `true` if the first char read from `stdin` is `y` or `false` if `n`.
///
/// Case-sensitive.
pub inline fn confirm(
    stdin: *Io.Reader,
    stdout: *Writer,
    /// An array of slices to be passed to `stdout`.
    query: anytype,
) ConfirmError!bool {
    stdout.writeVec(query) catch return ConfirmError.WriteFail;

    const input = stdin.takeByte() catch return ConfirmError.ReadFail;

    return switch (input) {
        'y' => true,
        'n' => false,
        else => ConfirmError.UnknownChar,
    };
}

test "'confirm' returns appropriate bool for 'y' and 'n' chars from 'stdin'" {
    const Case = struct { char: u8, result: bool };
    inline for (.{
        Case{ .char = 'y', .result = true },
        Case{ .char = 'n', .result = false },
    }) |case| {
        const stdin = block: {
            var buffer: [6]u8 = undefined;
            var reader = testing.Reader.init(
                &buffer,
                &.{.{ .buffer = &.{case.char} }},
            );
            break :block &reader.interface;
        };

        const queryStr = "abc";
        const query = .{queryStr};

        const stdout = block: {
            var buffer: [queryStr.len]u8 = undefined;
            var writer: Writer = .{ .writer = @constCast(&Io.Writer.fixed(&buffer)) };

            break :block &writer;
        };

        const result = try confirm(stdin, stdout, query);

        try testing.expect(result == case.result);
    }
}
test "'confirm' returns 'UnknownChar' error if 'stdin' consist of invalid char" {
    const invalidInput = "INVALID";

    const stdin = block: {
        var buffer: [invalidInput.len]u8 = undefined;
        var reader = testing.Reader.init(
            &buffer,
            &.{.{ .buffer = invalidInput }},
        );
        break :block &reader.interface;
    };

    const queryStr = "q";
    const query = .{queryStr};

    const stdout = block: {
        var buffer: [queryStr.len]u8 = undefined;
        var writer: Writer = .{ .writer = @constCast(&Io.Writer.fixed(&buffer)) };

        break :block &writer;
    };

    try testing.expectError(
        ConfirmError.UnknownChar,
        confirm(stdin, stdout, query),
    );
}
test "'confirm' returns 'ReadFail' error if reading from 'stdin' failed" {
    var failingStdin = block: {
        var buffer: [1]u8 = undefined;
        break :block TestUtils.mockFailingIoReader(&buffer);
    };

    const queryStr = "q";

    const query = .{queryStr};
    var stdout: Writer = block: {
        var buffer: [queryStr.len]u8 = undefined;
        break :block .{ .writer = @constCast(&Io.Writer.fixed(&buffer)) };
    };

    try testing.expectError(
        ConfirmError.ReadFail,
        confirm(&failingStdin, &stdout, query),
    );
}

test "'confirm' writes 'query' to 'stdout'" {
    const stdin = block: {
        var buffer: [6]u8 = undefined;
        var reader = testing.Reader.init(
            &buffer,
            &.{.{ .buffer = "n" }},
        );
        break :block &reader.interface;
    };

    const queryStr = "Hello, World. Goodbye";
    const query = .{
        queryStr[0..6],
        queryStr[6..12],
        queryStr[12..],
    };

    const stdout = block: {
        var buffer: [queryStr.len]u8 = undefined;
        var writer: Writer = .{ .writer = @constCast(&Io.Writer.fixed(&buffer)) };
        break :block &writer;
    };

    _ = try confirm(stdin, stdout, query);

    try testing.expectEqualStrings(queryStr, stdout.writer.buffered());
}
test "'confirm' returns 'WriteFail' error if writing to stdout failed" {
    const stdin = block: {
        var buffer: [10]u8 = undefined;
        break :block @constCast(&testing.Reader.init(
            &buffer,
            &.{.{ .buffer = "y" }},
        ).interface);
    };
    const queryStr = "q";
    const query = .{queryStr};

    const failingStdout = block: {
        var stdout: Writer = .{ .writer = @constCast(&TestUtils.mockFailingIoWriter()) };
        break :block &stdout;
    };

    try testing.expectError(
        ConfirmError.WriteFail,
        confirm(stdin, failingStdout, query),
    );
}

pub const ExitCode = enum(u8) { Success = 0, GeneralError = 1, InvalidArg = 2 };
pub inline fn exit(code: ExitCode) noreturn {
    process.exit(@intFromEnum(code));
}

pub fn __debug__(comptime fmt: []const u8, args: anytype) void {
    if (builtin.mode != .debug) {
        @compileError("'__debug__' is only for 'Debug' mode");
    }

    debug.print(fmt ++ "\n", args);
}
