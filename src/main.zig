const std = @import("std");
const Io = std.Io;

const Errors = struct {
    pub const UNKNOWN_CMD = "Unknown command. Use 'ssync --help'.";
};

const HELP_TEXT =
    \\commands:
    \\  list                           List the created roots and paths to them in the system.
    \\  add [root, source, dest]       'root' is name of a root folder to copy 'source' file to. Root is created if does not exit.
    \\                                 'source' is path to a file in the system which is to be copied to 'dest'.
    \\                                 'dest' is a path relative to 'root' to copy 'source' to.
    \\  delete [root, ?file]           If file specified, delete the 'file' in 'root'.
    \\                                 If only 'root' specified, delete the whole root (prompt is shown for safety).
    \\  update [root, newSource, dest] Make 'dest' in 'root' track 'newSource' instead of the current.
    \\
    \\flags: 
    \\  --help
;
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
