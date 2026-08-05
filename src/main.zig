pub const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const Io = std.Io;
const process = std.process;
const unicode = std.unicode;
const builtin = @import("builtin");

const utils = @import("utils.zig");

const Errors = struct {
    pub const UNKNOWN_CMD = "Unknown command. Use 'ssync --help'.";

    pub const GET_USER_DIR_PATH_FAIL = "Failed to get the user dir path.";
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
;

pub fn main(init: process.Init.Minimal) !void {
    const environ = init.environ;

    var arena: heap.ArenaAllocator = .init(heap.page_allocator);
    const arenaAllocator = arena.allocator();

    var threaded: Io.Threaded = .init(arenaAllocator, .{});
    const io = threaded.io();

    var stderr = Io.File.stdout().writer(io, &.{});

    const stderrWriter = &stderr.interface;

    var args = try init.args.iterateAllocator(arenaAllocator);

    if (args.next()) |command| {
        var stdout = Io.File.stdout().writer(io, &.{});

        const stdoutWriter = &stdout.interface;

        if (mem.eql(u8, command, "--help")) {
            try utils.writeStdio(stdoutWriter, HELP_TEXT);

            process.exit(0);
        } else if (mem.eql(u8, command, "list")) {
            try Commands.list(arenaAllocator, io, environ);

            process.exit(0);
        }
    } else {
        try utils.writeStdio(stderrWriter, Errors.UNKNOWN_CMD);
    }
}

const Commands = struct {
    pub inline fn list(allocator: mem.Allocator, io: Io, environ: process.Environ) !void {
        var output: std.ArrayList(u8) = try .initCapacity(allocator, 600);

        var userDirPathBuffer: [utils.MAX_PATH_LEN]u8 = undefined;
        const userDirPathLen = try utils.getUserDirPath(environ, &userDirPathBuffer);

        const rootsDirPath = utils.insertPathLiteral(
            &userDirPathBuffer,
            userDirPathLen,
            if (OS == .linux) "/.local/share/ssync" else if (OS == .macos)
                "/Library/Application Support"
            else
                "\\ssync",
        );

        try utils.arrayAppendSlices(
            allocator,
            u8,
            &output,
            .{ "path to roots: ", rootsDirPath, "\n\ncreated roots:\n" },
        );

        const cwd = Io.Dir.cwd();

        var roots = block: {
            const rootsDir = try cwd.openDir(
                io,
                rootsDirPath,
                .{ .iterate = true },
            );
            break :block rootsDir.iterate().reader;
        };

        while (try roots.next(io)) |root| {
            if (root.kind == .directory) {
                try utils.arrayAppendSlices(
                    allocator,
                    u8,
                    &output,
                    .{ "  ", root.name },
                );
                try output.append(allocator, '\n');
            }
        }
    }
};
