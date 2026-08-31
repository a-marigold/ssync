const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const builtin = @import("builtin");

comptime {
    if (!builtin.is_test) @compileError("'TestUtils' is only for tests");
}

/// `buffer` must have length at least 1 'cause some functions of the reader can cause a panic.
pub fn mockFailingIoReader() Io.Reader {
    var buffer: [10]u8 = undefined;

    var reader: Io.Reader = .failing;
    reader.buffer = &buffer;

    return reader;
}
/// Returned writer has zero-length buffer, so
/// any writing method of `Io.Writer` calls the failing vtable functions.
pub fn mockFailingIoWriter() Io.Writer {
    return .failing;
}

pub const ExpectFileExistError = error{DirNotExist};
pub fn expectFileExist(io: Io, dir: Dir, path: []const u8) ExpectFileExistError!void {
    dir.statFile(io, path, .{}) catch return ExpectFileExistError.DirNotExist;
}

pub const ExpectFileNotExistError = error{DirExist};
pub fn expectFileNotExist(io: Io, dir: Dir, path: []const u8) ExpectFileNotExistError!void {
    _ = dir.statFile(io, path, .{}) catch return;
    return ExpectFileNotExistError;
}
