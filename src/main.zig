const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const Io = std.Io;
const File = Io.File;
const process = std.process;
const Environ = process.Environ;
const builtin = @import("builtin");
const Utils = @import("Utils.zig");
const Cmd = @import("Cmd.zig");

const OS = builtin.os.tag;

const ExitCode = Utils.ExitCode;

const Errors = Cmd.Errors;

pub fn main(init: process.Init.Minimal) !void {
    const env = init.environ;

    // Functions that use allocator in `Threaded` are not used, so `undefined` is passed
    var threaded: Io.Threaded = .init(undefined, .{});
    const io = threaded.io();

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

    const stderr = block: {
        var buffer: [Cmd.STDERR_BUFFER_BYTES]u8 = undefined;
        var stderrWriter = File.stderr().writerStreaming(io, &buffer);

        break :block &stderrWriter.interface;
    };

    if (args.next()) |cmd| {
        const stdin = block: {
            var buffer: [Cmd.STDIN_BUFFER_BYTES]u8 = undefined;
            break :block @constCast(&File.stdin().readerStreaming(io, &buffer).interface);
        };

        const stdout = block: {
            var buffer: [Cmd.STDOUT_BUFFER_BYTES]u8 = undefined;
            var stdoutWriter = File.stdout().writerStreaming(io, &buffer);

            break :block &stdoutWriter.interface;
        };

        const exitCode = dispatchCmd(
            io,
            env,
            stdin,
            stdout,
            stderr,
            cmd,
            &args,
        ) catch |err| return Utils.writeArray(stdout, .{ try Errors.getErrMsg(err), "\n" });

        Utils.exit(exitCode);
    }

    try Cmd.help(stderr);
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
    stdin: *Io.Reader,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    cmd: []const u8,
    args: *process.Args.Iterator,
) !ExitCode {
    const eqlStr = Utils.eqlStr;

    if (eqlStr(cmd, "add")) {
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

        try Cmd.add(io, env, stdout, addArgs);
        return .Success;
    }

    if (eqlStr(cmd, "delete")) {
        const deleteArgs: Cmd.DeleteArgs = .{
            .root = args.next() orelse {
                try writeErrMsg(stderr, Errors.ARG_EXPECTED("root"));

                return .InvalidArg;
            },
            .dest = args.next(),
        };
        try Cmd.delete(io, env, stdin, stdout, deleteArgs);
        return .Success;
    }

    if (eqlStr(cmd, "update")) {
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

        try Cmd.update(io, env, stdin, stdout, updateArgs);
        return .Success;
    }

    if (eqlStr(cmd, "create")) {
        const createArgs: Cmd.CreateArgs = .{
            .root = args.next() orelse {
                try writeErrMsg(stderr, Errors.ARG_EXPECTED("root"));
                return .InvalidArg;
            },
        };

        try Cmd.create(io, env, stdout, createArgs);
        return .Success;
    }

    if (eqlStr(cmd, "list")) {
        try Cmd.list(io, env, stdout);
        return .Success;
    }

    if (eqlStr(cmd, "config")) {
        try Cmd.config(io, env, stdout);
        return .Success;
    }

    if (eqlStr(cmd, "--help")) {
        try Cmd.help(stdout);
        return .Success;
    }

    try writeErrMsg(stderr, Errors.UNRECONGNIZED_CMD);
    return .InvalidArg;
}

inline fn writeErrMsg(stderr: *Io.Writer, comptime msg: []const u8) !void {
    return stderr.writeAll(msg ++ "\n");
}
