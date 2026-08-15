const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const Io = std.Io;
const process = std.process;
const Environ = process.Environ;
const builtin = @import("builtin");
const Utils = @import("Utils.zig");
const Commands = @import("Commands.zig");

const ErrorMsgs = Commands.ErrorMsgs;

const __debug__ = Utils.__debug__;

const OS = builtin.os.tag;
const StdIn = Utils.StdIn;
const StdOut = Utils.StdOut;

pub fn main(init: process.Init.Minimal) !void {
    const env = init.environ;

    var arena: heap.ArenaAllocator = .init(heap.page_allocator);
    const arenaAllocator = arena.allocator();

    var threaded: Io.Threaded = .init(arenaAllocator, .{});
    const io = threaded.io();

    var stderr: StdOut = .init(io, .Stderr);

    var args = try init.args.iterateAllocator(arenaAllocator);

    _ = args.skip();

    if (args.next()) |cmd| {
        var stdout: StdOut = .init(io, .Stdout);

        if (eqlCmd(cmd, "--help")) {
            try Commands.help(&stdout);
            Utils.exit(.Success);
        }

        if (eqlCmd(cmd, "add")) {
            var stdin: StdIn = block: {
                // `stdin` is only used for y/n confirmation, so assume 1 byte is enough
                var buffer: [1]u8 = undefined;
                break :block .init(io, &buffer);
            };

            const rootName = args.next() orelse {
                try stderr.write(&.{ErrorMsgs.argExpected("root") ++ "\n"});
                Utils.exit(.InvalidArg);
            };
            const srcPath = args.next() orelse {
                try stderr.write(&.{ErrorMsgs.argExpected("src") ++ "\n"});
                Utils.exit(.InvalidArg);
            };
            const destPath = args.next() orelse {
                try stderr.write(&.{ErrorMsgs.argExpected("dest") ++ "\n"});
                Utils.exit(.InvalidArg);
            };

            try Commands.add(
                io,
                env,
                &stdin,
                &stdout,
                rootName,
                srcPath,
                destPath,
            );

            Utils.exit(.Success);
        }

        if (eqlCmd(cmd, "delete")) {
            const rootName = args.next() orelse {
                try stderr.write(&.{ErrorMsgs.argExpected("root") ++ "\n"});
                Utils.exit(.InvalidArg);
            };
            const rootFilePath = args.next() orelse {
                try stderr.write(&.{ErrorMsgs.argExpected("file") ++ "\n"});
                Utils.exit(.InvalidArg);
            };

            var stdin: StdIn = block: {
                // `stdin` is only used for y/n confirmation, so assume 1 byte is enough
                var buffer: [1]u8 = undefined;

                break :block .init(io, &buffer);
            };

            try Commands.delete(
                io,
                env,
                &stdin,
                &stdout,
                rootName,
                rootFilePath,
            );

            Utils.exit(.Success);
        }

        if (eqlCmd(cmd, "create")) {
            const rootName = args.next() orelse {
                try stderr.write(&.{ErrorMsgs.argExpected("root") ++ "\n"});
                Utils.exit(.InvalidArg);
            };

            try Commands.create(io, env, &stdout, rootName);
            Utils.exit(.Success);
        }

        if (eqlCmd(cmd, "list")) {
            try Commands.list(arenaAllocator, io, env, &stdout);
            Utils.exit(.Success);
        }

        if (eqlCmd(cmd, "config")) {
            try Commands.config(io, env, &stdout, &stderr);
            Utils.exit(.Success);
        }
    }

    try Commands.help(&stderr);
    Utils.exit(.InvalidArg);
}

/// Compares `a` and `b` command names.
inline fn eqlCmd(a: []const u8, b: []const u8) bool {
    return mem.eql(u8, a, b);
}
