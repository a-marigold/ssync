pub const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const Io = std.Io;
const process = std.process;
const unicode = std.unicode;
const builtin = @import("builtin");

const constants = @import("constants.zig");
const utils = @import("utils.zig");

const OS = builtin.os.tag;

const Errors = constants.Errors;

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
            try utils.writeStdio(stdoutWriter, constants.HELP_TEXT);

            process.exit(0);
        } else if (mem.eql(u8, command, "list")) {
            const listOutput = try Commands.list(arenaAllocator, io, environ);

            try utils.writeStdio(stdoutWriter, listOutput.items);

            process.exit(0);
        }
    } else {
        try utils.writeStdio(stderrWriter, Errors.UNKNOWN_CMD);
    }
}

const Commands = struct {
    pub inline fn list(allocator: mem.Allocator, io: Io, environ: process.Environ) !std.ArrayList(u8) {
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

        return output;
    }
};
