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

    var args = switch (OS) {
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
        var stdin: StdIn = block: {
            // `stdin` is only used for y/n confirmation, so assume 1 byte is enough
            var buffer: [Cmd.STDIN_BUFFER_BYTES]u8 = undefined;
            break :block .init(io, &buffer);
        };

        var stdout: StdOut = block: {
            var buffer: [Cmd.STDOUT_BUFFER_BYTES]u8 = undefined;
            break :block .init(io, .StdErr, &buffer);
        };

        if (Utils.eqlStr(cmd, "--help")) {
            try Cmd.help(&stdout);
            Utils.exit(.Success);
        }

        if (Utils.eqlStr(cmd, "add")) {
            const addArgs: Cmd.AddArgs = .{
                .root = args.next() orelse {
                    try stderr.write(Errors.ARG_EXPECTED("root") ++ "\n");
                    Utils.exit(.InvalidArg);
                },
                .src = args.next() orelse {
                    try stderr.write(Errors.ARG_EXPECTED("src") ++ "\n");
                    Utils.exit(.InvalidArg);
                },
                .dest = args.next() orelse {
                    try stderr.write(Errors.ARG_EXPECTED("dest") ++ "\n");
                    Utils.exit(.InvalidArg);
                },
            };

            Cmd.add(io, env, &stdout, addArgs) catch |err|
                return stderr.write(try Errors.getErrMsg(err, .Add));
            Utils.exit(.Success);
        }

        if (Utils.eqlStr(cmd, "delete")) {
            const deleteArgs: Cmd.DeleteArgs = .{
                .root = args.next() orelse {
                    try stderr.write(Errors.ARG_EXPECTED("root") ++ "\n");
                    Utils.exit(.InvalidArg);
                },
                .dest = args.next(),
            };

            Cmd.delete(io, env, &stdin, &stdout, deleteArgs) catch |err|
                return stderr.write(try Errors.getErrMsg(err, .Delete));
            Utils.exit(.Success);
        }

        if (Utils.eqlStr(cmd, "update")) {
            const updateArgs: Cmd.UpdateArgs = .{
                .root = args.next() orelse {
                    try stderr.write(Errors.ARG_EXPECTED("root") ++ "\n");
                    Utils.exit(.InvalidArg);
                },
                .newSrc = args.next() orelse {
                    try stderr.write(Errors.ARG_EXPECTED("src") ++ "\n");
                    Utils.exit(.InvalidArg);
                },
                .dest = args.next() orelse {
                    try stderr.write(Errors.ARG_EXPECTED("dest") ++ "\n");
                    Utils.exit(.InvalidArg);
                },
            };

            Cmd.update(io, env, &stdin, &stdout, updateArgs) catch |err|
                return stderr.write(try Errors.getErrMsg(err, .Update));
            Utils.exit(.Success);
        }
        if (Utils.eqlStr(cmd, "create")) {
            const createArgs: Cmd.CreateArgs = .{
                .root = args.next() orelse {
                    try stderr.write(Errors.ARG_EXPECTED("root") ++ "\n");
                    Utils.exit(.InvalidArg);
                },
            };

            Cmd.create(io, env, &stdout, createArgs) catch |err|
                return stderr.write(try Errors.getErrMsg(err, .Create));
            Utils.exit(.Success);
        }

        if (Utils.eqlStr(cmd, "list")) {
            try Cmd.list(io, env, &stdout);
            Utils.exit(.Success);
        }

        if (Utils.eqlStr(cmd, "config")) {
            Cmd.config(io, env, &stdout) catch |err|
                return stderr.write(try Errors.getErrMsg(err, .Config));
            Utils.exit(.Success);
        }
    }

    try Cmd.help(&stderr);
    Utils.exit(.InvalidArg);
}
