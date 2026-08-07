const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const Io = std.Io;
const Dir = Io.Dir;
const process = std.process;
const unicode = std.unicode;
const builtin = @import("builtin");

const utils = @import("utils.zig");

const OS = builtin.os.tag;

pub fn main(init: process.Init.Minimal) !void {
    const environ = init.environ;

    var arena: heap.ArenaAllocator = .init(heap.page_allocator);
    const arenaAllocator = arena.allocator();

    var threaded: Io.Threaded = .init(arenaAllocator, .{});
    const io = threaded.io();

    var stderr: utils.StdIo = .init(io, .Stderr);

    var args = try init.args.iterateAllocator(arenaAllocator);

    _ = args.skip();

    if (args.next()) |cmd| {
        var stdout: utils.StdIo = .init(io, .Stdout);

        if (mem.eql(u8, cmd, "--help")) {
            try stdout.write(Commands.help());

            process.exit(0);
        } else if (mem.eql(u8, cmd, "list")) {
            const listOutput = try Commands.list(arenaAllocator, io, environ);

            try stdout.write(listOutput.items);

            process.exit(0);
        }
    } else {
        try stderr.write(Commands.help());
    }
}

/// The CLI commands.
const Commands = struct {
    pub inline fn help() []const u8 {
        return
        \\commands:
        \\  list                           List created roots and path to them in the system.
        \\
        \\  add [root, source, dest]       'root' is name of a root folder to copy 'source' file to. Root is created if does not exit.
        \\                                 'source' is path to a file in the system which is to be copied to 'dest'.
        \\                                 'dest' is a path relative to 'root' to copy 'source' to.
        \\
        \\  delete [root, ?file]           If 'file' specified, delete the 'file' in 'root'.
        \\                                 If only 'file' is not specified, delete the whole root (prompt is shown for safety).
        \\
        \\  update [root, newSource, dest] Make 'dest' in 'root' track 'newSource' instead of the current.
        \\
        ;
    }

    pub inline fn list(allocator: mem.Allocator, io: Io, environ: process.Environ) !std.ArrayList(u8) {
        var output: std.ArrayList(u8) = try .initCapacity(allocator, 600);

        var userDirPathBuffer: [utils.MAX_PATH_LEN]u8 = undefined;
        const userDirPathLen = try utils.getUserDirPath(environ, &userDirPathBuffer);

        const rootsDirPath = Commands.userDirPathToRootsDirPath(
            userDirPathBuffer,
            userDirPathLen,
        );

        try utils.arrayAppendSlices(
            allocator,
            u8,
            &output,
            .{ "path to roots: ", rootsDirPath, "\n\ncreated roots:\n" },
        );

        const cwd = Dir.cwd();

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

    /// Inserts a platfrom-specific relative path of the roots dir to
    /// `pathBuffer` starting from `userPathEnd`.
    ///
    /// `pathBuffer[0..userPathEnd]` must not include trailing slash.
    ///
    /// Returns a slice of the real roots dir path.
    inline fn userDirPathToRootsDirPath(
        pathBuffer: [utils.MAX_PATH_LEN]u8,
        userPathLen: usize,
    ) []const u8 {
        return utils.insertPathLiteral(
            &pathBuffer,
            userPathLen,
            switch (OS) {
                .linux => "/.local/share/ssync",
                .macos => "/Library/Application Support/ssync",
                .windows => "\\ssync",
            },
        );
    }
};
