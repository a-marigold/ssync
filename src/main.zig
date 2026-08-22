const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const Io = std.Io;
const process = std.process;
const Environ = process.Environ;
const builtin = @import("builtin");
const Utils = @import("Utils.zig");
const Cmd = @import("Cmd.zig");

const Errors = Cmd.Errors;

const OS = builtin.os.tag;

const StdIn = Utils.StdIn;
const StdOut = Utils.StdOut;

pub fn main(init: process.Init.Minimal) !void {
    const env = init.environ;

    // Functions that use allocator in `Threaded` are not used, so `undefined` is passed
    var threaded: Io.Threaded = .init(undefined, .{});
    const io = threaded.io();

    var stderr: StdOut = block: {
        var buffer: [Cmd.STDERR_BUFFER_BYTES]u8 = undefined;
        break :block .init(io, .StdErr, &buffer);
    };

    var args = switch (comptime OS) {
        .linux, .macos => init.args.iterate(),
        .windows => block: {
            // Initialize allocator only for windows
            var arena: heap.ArenaAllocator = .init(heap.page_allocator);
            const arenaAllocator = arena.allocator();

            break :block try init.args.iterateAllocator(arenaAllocator);
        },
        else => unreachable,
    };

    _ = args.skip();

    if (args.next()) |cmd| {
        var stdout: StdOut = block: {
            var buffer: [Cmd.STDOUT_BUFFER_BYTES]u8 = undefined;
            break :block .init(io, .StdErr, &buffer);
        };

        if (eqlCmd(cmd, "--help")) {
            try Cmd.help(&stdout);
            Utils.exit(.Success);
        }

        if (eqlCmd(cmd, "add")) {
            const rootName = args.next() orelse {
                try stderr.write(.{Errors.ARG_EXPECTED("root") ++ "\n"});
                Utils.exit(.InvalidArg);
            };
            const srcPath = args.next() orelse {
                try stderr.write(.{Errors.ARG_EXPECTED("src") ++ "\n"});
                Utils.exit(.InvalidArg);
            };
            const destPath = args.next() orelse {
                try stderr.write(.{Errors.ARG_EXPECTED("dest") ++ "\n"});
                Utils.exit(.InvalidArg);
            };

            try Cmd.add(
                io,
                env,
                &stdout,
                rootName,
                srcPath,
                destPath,
            );
            Utils.exit(.Success);
        }

        if (eqlCmd(cmd, "delete")) {
            const rootName = args.next() orelse {
                try stderr.write(.{Errors.ARG_EXPECTED("root") ++ "\n"});
                Utils.exit(.InvalidArg);
            };

            const rootFilePath = args.next() orelse {
                try stderr.write(.{Errors.ARG_EXPECTED("file") ++ "\n"});
                Utils.exit(.InvalidArg);
            };

            var stdin: StdIn = block: {
                // `stdin` is only used for y/n confirmation, so assume 1 byte is enough
                var buffer: [1]u8 = undefined;
                break :block .init(io, &buffer);
            };

            try Cmd.delete(
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
                try stderr.write(.{Errors.ARG_EXPECTED("root") ++ "\n"});
                Utils.exit(.InvalidArg);
            };

            try Cmd.create(io, env, &stdout, rootName);
            Utils.exit(.Success);
        }

        if (eqlCmd(cmd, "list")) {
            try Cmd.list(io, env, &stdout);
            Utils.exit(.Success);
        }

        if (eqlCmd(cmd, "config")) {
            try Cmd.config(io, env, &stdout);
            Utils.exit(.Success);
        }
    }

    try Cmd.help(&stderr);
    Utils.exit(.InvalidArg);
}

/// Compares `a` and `b` command names.
inline fn eqlCmd(a: []const u8, b: []const u8) bool {
    return mem.eql(u8, a, b);
}
