const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

comptime {
    if (!builtin.is_test) @compileError("'TestUtils' is only for tests");
}

/// `buffer` must have length at least 1 'cause some functions of the reader can cause a panic.
pub fn mockFailingIoReader(buffer: []u8) Io.Reader {
    var reader: Io.Reader = .failing;
    reader.buffer = buffer;

    return reader;
}
/// Returned writer has zero-length buffer, so
/// any writing method of `Io.Writer` calls the failing vtable functions.
pub fn mockFailingIoWriter() Io.Writer {
    return .failing;
}
