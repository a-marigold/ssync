const std = @import("std");
const Io = std.Io;

const Errors = struct {
    pub const UNKNOWN_CMD = "Unknown command. Use 'ssync --help'.";
};

pub fn main(init: std.process.Init.Minimal) !void {
    const arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const arenaAllocator = arena.allocator();

    const threaded: Io.Threaded = .init(arenaAllocator, .{});
    const io = threaded.io();

    const stderr = Io.File.stdout().writer().interface;
    const args = try init.args.iterateAllocator(arenaAllocator);

    if (args.next()) |command| {
        const stdout = try std.Io.File.stdout().writer(io, &.{});
        _ = command;
        _ = stdout;
    } else {
        writeStdio(stderr, Errors.UNKNOWN_CMD);
    }
}

inline fn writeStdio(writer: *Io.Writer, data: []const u8) void {
    _ = writer.vtable.drain(&.{data}, 1);
}
