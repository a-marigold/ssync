const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const Io = std.Io;
const process = std.process;
const Environ = process.Environ;
const builtin = @import("builtin");
const Utils = @import("Utils.zig");
const Cmd = @import("Cmd.zig");

const OS = builtin.os.tag;

const StdIn = Utils.StdIn;
const StdOut = Utils.StdOut;

const ExitCode = Utils.ExitCode;

const Errors = Cmd.Errors;

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
            break :block try init.args.iterateAllocator(arena.allocator());
        },
        else => unreachable,
    };
    _ = args.skip();

    if (args.next()) |cmd| {
        var stdin: StdIn = block: {
            var buffer: [Cmd.STDIN_BUFFER_BYTES]u8 = undefined;
            break :block .init(io, &buffer);
        };
        var stdout: StdOut = block: {
            var buffer: [Cmd.STDOUT_BUFFER_BYTES]u8 = undefined;
            break :block .init(io, .StdErr, &buffer);
        };

        const exitCode = dispatchCmd(
            io,
            env,
            &stdin,
            &stdout,
            &stderr,
            cmd,
            args,
        ) catch |err| return stderr.writeVec(.{ Errors.getErrMsg(err), "\n" });

        Utils.exit(exitCode);
    }

    try Cmd.help(&stderr);
    Utils.exit(.InvalidArg);
}

/// Calls a corresponding to `cmd` command function.
///
/// `args` iterator should be in a place of the first argument of command.
///
/// Returns an exit code, which is zero in case of success or non-zero in case of handled error.
///
/// In case of command errors and critical errors, returns them.
inline fn dispatchCmd(
    io: Io,
    env: Environ,
    stdin: *StdIn,
    stdout: *StdOut,
    stderr: *StdOut,
    cmd: []const u8,
    args: process.Args.Iterator,
) !ExitCode {
    const eqlStr = Utils.eqlStr;

    switch (true) {
        eqlStr(cmd, "add") => {
            const addArgs: Cmd.AddArgs = .{
                .root = args.next() orelse {
                    try writeErrMsg(stderr, Errors.ARG_EXPECTED("root"));
                    return .InvalidArg;
                },
                .src = args.next() orelse {
                    try writeErrMsg(stderr, Errors.ARG_EXPECTED("src"));
                    return .InvalidArg;
                },
                .dest = args.next() orelse {
                    try writeErrMsg(stderr, Errors.ARG_EXPECTED("dest"));
                    return .InvalidArg;
                },
            };

            try Cmd.add(io, env, &stdout, addArgs);
            return .Success;
        },
        eqlStr(cmd, "delete") => {
            const deleteArgs: Cmd.DeleteArgs = .{
                .root = args.next() orelse {
                    try writeErrMsg(stderr, Errors.ARG_EXPECTED("root"));
                    return .InvalidArg;
                },
                .dest = args.next(),
            };
            try Cmd.delete(io, env, &stdin, &stdout, deleteArgs);
            return .Success;
        },
        eqlStr(cmd, "update") => {
            const updateArgs: Cmd.UpdateArgs = .{
                .root = args.next() orelse {
                    try writeErrMsg(stderr, Errors.ARG_EXPECTED("root"));
                    return .InvalidArg;
                },
                .newSrc = args.next() orelse {
                    try writeErrMsg(stderr, Errors.ARG_EXPECTED("newSrc"));
                    return .InvalidArg;
                },
                .dest = args.next() orelse {
                    try writeErrMsg(stderr, Errors.ARG_EXPECTED("dest"));
                    return .InvalidArg;
                },
            };

            try Cmd.update(io, env, &stdin, &stdout, updateArgs);
            return .Success;
        },
        eqlStr(cmd, "create") => {
            const createArgs: Cmd.CreateArgs = .{
                .root = args.next() orelse {
                    try writeErrMsg(stderr, Errors.ARG_EXPECTED("root"));
                    return .InvalidArg;
                },
            };

            try Cmd.create(io, env, &stdout, createArgs);
            return .Success;
        },
        eqlStr(cmd, "list") => {
            try Cmd.list(io, env, &stdout);
            return .Success;
        },
        eqlStr(cmd, "config") => {
            try Cmd.config(io, env, &stdout);
            return .Success;
        },
        eqlStr(cmd, "--help") => {
            try Cmd.help(&stdout);
            return .Success;
        },
        else => {
            try writeErrMsg(stderr, Errors.UNRECONGNIZED_CMD);
            return .InvalidArg;
        },
    }
}

inline fn writeErrMsg(stderr: *StdOut, comptime msg: []const u8) !void {
    return stderr.write(msg ++ "\n");
}
