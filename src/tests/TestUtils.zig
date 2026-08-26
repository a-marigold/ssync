const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const testing = std.testing;
const builtin = @import("builtin");

comptime {
    if (!builtin.is_test) @compileError("'TestUtils' is only for tests");
}

pub fn mockIoWriter(buffer: []u8) testing.WriterIndirect {
    var outWriter: Io.Writer = .{
        .vtable = &.{
            .drain = struct {
                fn drain(writer: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
                    _ = writer;
                    _ = data;
                    _ = splat;
                    return 0;
                }
            }.drain,
        },
        .buffer = &.{},
        .end = 0,
    };

    return testing.WriterIndirect.init(&outWriter, buffer);
}
