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

const HOME_ENV_VAR = switch (OS) {
    .windows => "%USERPROFILE%",
    else => "HOME",
};

pub inline fn findStrScalar(str: []const u8, searchValue: u8) ?usize {
    return mem.findScalarPos(u8, str, 0, searchValue);
}

pub inline fn eqlStr(a: []const u8, b: []const u8) bool {
    return mem.eql(u8, a, b);
}

/// Returns path to the user dir (home)
/// encoded in UTF-16 on windows and in UTF-8 on other platforms.
pub inline fn getHomeEnv(env: Environ) ?[]const switch (OS) {
    .windows => u16,
    else => u8,
} {
    return switch (OS) {
        .windows => env.getWindows(HOME_ENV_VAR),
        else => env.getPosix(HOME_ENV_VAR),
    };
}

/// `path` must have length at least 1.
pub fn isPathAbs(path: []const u8) bool {
    return switch (OS) {
        .windows => Dir.path.isAbsoluteWindows(path),
        else => isPathSep(path[0]),
    };
}

pub inline fn isPathSep(char: u8) bool {
    return switch (OS) {
        .windows => char == '/' or char == '\\',
        else => char == '/',
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

    /// Copies `path` to initialized `buffer`.
    ///
    /// Omits trailing slash.
    pub inline fn initPath(path: []const u8) @This() {
        var buffer: [MAX_PATH_BYTES]u8 = undefined;
        @memcpy(buffer[0..path.len], path);

        // Omit trailing slash
        const end = path.len - @intFromBool(isPathSep(path[path.len - 1]));

        return .{ .buffer = buffer, .end = end };
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
        newEnd -= @intFromBool(isPathSep(relPath[relPath.len - 1]));

        return buffer[0..newEnd];
    }

    /// Invalidates `end` of the path.
    ///
    /// Comptime asserts that `literalPath`
    /// isn't absolute and doesn't end with a slash.
    pub inline fn appendLiteral(self: *@This(), comptime literalPath: []const u8) []const u8 {
        comptime {
            assert(!isPathSep(literalPath[0]));
            assert(!isPathSep(literalPath[literalPath.len - 1]));
        }

        const buffer = @constCast(&self.buffer);

        var newEnd = self.end;
        defer self.end = newEnd;

        const resolvedLiteralPath = "/" ++ literalPath;

        @memcpy(buffer[newEnd..][0..resolvedLiteralPath.len], resolvedLiteralPath);
        newEnd += resolvedLiteralPath.len;

        return buffer[0..newEnd];
    }

    test "`initPath` copies `path` to `buffer`, invalidates `end` and omits trailing slash" {
        {
            const somePath = "/home/bar";

            const pathBuilder1: PathBuilder = .initPath(somePath);
            try testing.expectEqualStrings(somePath, pathBuilder1.buffer[0..pathBuilder1.end]);

            const somePathWithSlash = somePath ++ "/";

            const pathBuilder2: PathBuilder = .initPath(somePathWithSlash);
            try testing.expectEqualStrings(
                somePath,
                pathBuilder2.buffer[0..pathBuilder2.end],
            );
        }
    }

    test "`append` and `appendLiteral` join `relPath` with the current buffer path and invalidates `end`" {
        const startPath = "/home/u";

        const cases = .{ "./some/file.toml", "dir/file", "../out" };

        inline for (cases) |relPath| {
            var pathBuilder: PathBuilder = .initPath(startPath);

            const result = try append(&pathBuilder, relPath);

            const expectedResult = startPath ++ "/" ++ relPath;

            try testing.expectEqualStrings(expectedResult, result);
            try testing.expectEqual(expectedResult.len, pathBuilder.end);
        }
        inline for (cases) |relPath| {
            var pathBuilder: PathBuilder = .initPath(startPath);

            const result = appendLiteral(&pathBuilder, relPath);

            const expectedResult = startPath ++ "/" ++ relPath;

            try testing.expectEqualStrings(expectedResult, result);
            try testing.expectEqual(expectedResult.len, pathBuilder.end);
        }
    }
    test "`append` omits trailing slash of `relPath`" {
        const startPath = "/home/w";
        var pathBuilder: PathBuilder = .initPath(startPath);

        const currentDirPath = "./";

        const currentDirResult = try pathBuilder.append(currentDirPath);
        const expectedCurrentDirResult = startPath ++ "/.";

        try testing.expectEqualStrings(expectedCurrentDirResult, currentDirResult);
        try testing.expectEqual(expectedCurrentDirResult.len, pathBuilder.end);

        const nestedDirPath = "./dir/";

        const nestedDirResult = try pathBuilder.append(nestedDirPath);
        const expectedNestedDirResult = expectedCurrentDirResult ++ "/./dir";

        try testing.expectEqualStrings(expectedNestedDirResult, nestedDirResult);
        try testing.expectEqual(expectedNestedDirResult.len, pathBuilder.end);
    }
    test "`append` returns `AppendError.OutOfBuffer` if `relPath` is too big" {
        var pathBuilder: PathBuilder = .initPath("/dev");

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
    /// Instead, it starts with the last handled component.
    path: []const u8,

    pub inline fn init(path: []const u8) @This() {
        return .{ .path = path };
    }

    /// Returns the next component of `path` or `null` in case of its end.
    ///
    /// Invalidates `path.ptr` and `path.len`.
    ///
    /// Returns an empty slice if:
    /// - it's the first iteration over an absolute path
    /// - `path` contains multiple slashes (`///home///dir`)
    pub inline fn next(self: *@This()) ?[]const u8 {
        const path = self.path;

        if (path.len == 0) return null;

        var pathIndex: usize = 0;

        while (pathIndex < path.len and !isPathSep(path[pathIndex])) pathIndex += 1;

        if (pathIndex == path.len) {
            self.path.len = 0;
            return path[0..];
        }

        self.path = path[pathIndex + 1 ..];
        return path[0..pathIndex];
    }

    test "`next` returns the next component of `path` and `null` when `path` ends" {
        const somePath = "../dir/./file.txt";

        var pathIterator: PathIterator = .init(somePath);

        try testing.expectEqualStrings("..", pathIterator.next().?);
        try testing.expectEqualStrings("dir", pathIterator.next().?);
        try testing.expectEqualStrings(".", pathIterator.next().?);
        try testing.expectEqualStrings("file.txt", pathIterator.next().?);

        try testing.expectEqual(null, pathIterator.next());
        try testing.expectEqual(null, pathIterator.next());
        try testing.expectEqual(null, pathIterator.next());
    }

    test "`next` returns an empty slice for the first iteration over absolute `path`" {
        const absPath = "/usr/bin";

        var pathIterator: PathIterator = .init(absPath);

        try testing.expectEqual(0, pathIterator.next().?.len);
    }
    test "`next` returns an empty slice when path has consequent slashes" {
        const somePath = "///home///hellowo";

        var pathIterator: PathIterator = .init(somePath);

        try testing.expectEqual(0, pathIterator.next().?.len);
        try testing.expectEqual(0, pathIterator.next().?.len);
        try testing.expectEqual(0, pathIterator.next().?.len);

        try testing.expectEqualStrings("home", pathIterator.next().?);

        try testing.expectEqual(0, pathIterator.next().?.len);
        try testing.expectEqual(0, pathIterator.next().?.len);

        try testing.expectEqualStrings("hellowo", pathIterator.next().?);
    }

    test "`next` returns null when only a traling slash is left" {
        {
            const somePath = "/";

            var pathIterator: PathIterator = .init(somePath);

            try testing.expectEqual(0, pathIterator.next().?.len);

            try testing.expectEqual(null, pathIterator.next());
            try testing.expectEqual(null, pathIterator.next());
            try testing.expectEqual(null, pathIterator.next());
        }
        {
            const somePath = "./abc/def/";

            var pathIterator: PathIterator = .init(somePath);

            _ = pathIterator.next(); // `.`
            _ = pathIterator.next(); // `abc`
            _ = pathIterator.next(); // `def`

            try testing.expectEqual(null, pathIterator.next());
            try testing.expectEqual(null, pathIterator.next());
            try testing.expectEqual(null, pathIterator.next());
        }
    }
};

test {
    testing.refAllDecls(PathIterator);
}

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

/// Inlines `writer` writes of slices of `data` array (with comptime-known size).
pub inline fn writeArray(writer: *Io.Writer, data: anytype) !void {
    inline for (data) |slice| try writer.writeAll(slice);
}

pub const ConfirmError = error{ UnknownChar, ReadFail, WriteFail };
/// Writes `query` to `stdout`.
///
/// Returns `true` if the first char read from `stdin` is `y` or `false` if `n`.
///
/// Case-sensitive.
pub inline fn confirm(
    stdin: *Io.Reader,
    stdout: *Io.Writer,
    /// An array of slices to be passed to `stdout`.
    query: anytype,
) ConfirmError!bool {
    writeArray(stdout, query) catch return ConfirmError.WriteFail;

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
            var writer: Io.Writer = .fixed(&buffer);

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
        var writer: Io.Writer = .fixed(&buffer);

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
    var stdout: Io.Writer = block: {
        var buffer: [queryStr.len]u8 = undefined;
        break :block .fixed(&buffer);
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
        var writer: Io.Writer = Io.Writer.fixed(&buffer);
        break :block &writer;
    };

    _ = try confirm(stdin, stdout, query);

    try testing.expectEqualStrings(queryStr, stdout.buffered());
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
        var stdout: Io.Writer = TestUtils.mockFailingIoWriter();
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
