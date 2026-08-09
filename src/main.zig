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

        const eqlCmd = Commands.eqlCmd;
        if (eqlCmd(cmd, "--help")) {
            try stdout.write(Commands.help());

            utils.exit(.Success);
        }

        if (eqlCmd(cmd, "list")) {
            const listOutput = try Commands.list(arenaAllocator, io, environ);

            try stdout.write(listOutput.items);

            utils.exit(.Success);
        }

        if (eqlCmd(cmd, "create")) {
            const rootName = args.next() orelse {
                try stderr.write("'root' argument expected\n");

                utils.exit(.InvalidArg);
            };

            try Commands.create(io, environ, rootName);

            try stdout.write("Root was successfully created\n");

            utils.exit(.Success);
        }
    }

    try stderr.write(Commands.help());

    utils.exit(.InvalidArg);
}

/// The CLI commands.
const Commands = struct {
    const MAX_ROOT_NAME_BYTES = 60;

    /// Compares `a` and `b` command names.
    inline fn eqlCmd(a: []const u8, b: []const u8) bool {
        return mem.eql(u8, a, b);
    }

    pub inline fn help() []const u8 {
        return
        \\commands:
        \\  list                           Show path to the config, path to roots and all created roots.
        \\
        \\  add [root, ?source, ?dest]     'root' is name of a root to copy 'source' file to.
        \\                                 'source' is path to a file in the system which is to be copied to 'dest'.
        \\                                 'dest' is a path relative to 'root' to copy 'source' to.
        \\                                 If 'source' and 'dest' are not specified, just root is created.
        \\
        \\  delete [root, ?file]           If 'file' specified, delete the 'file' in 'root'.
        \\                                 If only 'file' is not specified, delete the whole root (prompt is shown for safety).
        \\
        \\  update [root, newSource, dest] Make 'dest' in 'root' track 'newSource' instead of the current.
        \\
        ;
    }

    /// Returns output of the command.
    pub inline fn list(allocator: mem.Allocator, io: Io, environ: process.Environ) !std.ArrayList(u8) {
        // Capacity 170 is enough for most cases
        var output: std.ArrayList(u8) = try .initCapacity(allocator, 170);

        var userDirPathBuffer: [utils.MAX_PATH_BYTES]u8 = undefined;
        const userDirPathLen = try utils.getUserDirPath(environ, &userDirPathBuffer);

        const rootsDirPath = getRootsDirPath(
            &userDirPathBuffer,

            userDirPathLen,
        );

        const configPath = block: {
            var buffer: [utils.MAX_PATH_BYTES]u8 = undefined;
            break :block getConfigPath(userDirPathBuffer[0..userDirPathLen], &buffer);
        };

        try output.appendSlice(allocator, "Config should be located at: ");
        try output.appendSlice(allocator, configPath);
        try output.append(allocator, '\n');

        const noRootCreatedMsg = "\nNo root created yet\n";

        const cwd = Dir.cwd();

        var rootsDirEntries = block: {
            const rootsDir = cwd.openDir(
                io,
                rootsDirPath,
                .{ .iterate = true },
            ) catch |err| {
                if (err == Dir.OpenError.FileNotFound) {
                    try output.appendSlice(allocator, noRootCreatedMsg);

                    return output;
                }

                return err;
            };

            break :block rootsDir.iterate().reader;
        };

        var currentEntry: ?Dir.Entry = try rootsDirEntries.next(io) orelse {
            try output.appendSlice(allocator, noRootCreatedMsg);

            return output;
        };

        try output.appendSlice(allocator, "Roots are located in: ");
        try output.appendSlice(allocator, rootsDirPath);

        try output.appendSlice(allocator, "\n\nCreatedRoots:\n");

        while (currentEntry) |entry| : (currentEntry = try rootsDirEntries.next(io)) {
            // On macos and windows roots and config located in one dir,
            // so check is it a dir (root)
            if ((comptime OS != .linux) and entry.kind != .directory) {
                continue;
            }

            try output.append(allocator, ' ');
            try output.append(allocator, ' ');
            try output.appendSlice(allocator, entry.name);
            try output.append(allocator, '\n');
        }

        return output;
    }

    const CreateError = error{ RootAlreadyExists, CreateDirFail };
    pub inline fn create(
        io: Io,
        environ: process.Environ,
        rootName: []const u8,
    ) (CreateError || utils.UserDirPathError || RootPathError)!void {
        var userDirPathBuffer: [utils.MAX_PATH_BYTES]u8 = undefined;
        const userDirPathLen = try utils.getUserDirPath(
            environ,
            &userDirPathBuffer,
        );

        const rootPath = block: {
            const rootsDirPath = getRootsDirPath(
                &userDirPathBuffer,
                userDirPathLen,
            );

            break :block try getRootPath(
                &userDirPathBuffer,
                rootsDirPath.len,
                rootName,
            );
        };

        const cwd = Dir.cwd();
        cwd.createDir(
            io,
            rootPath,
            Dir.Permissions.default_dir,
        ) catch |err| {
            if (err == Dir.CreateDirError.PathAlreadyExists) {
                return CreateError.RootAlreadyExists;
            }

            return CreateError.CreateDirFail;
        };
    }

    /// Inserts a platfrom-specific relative
    /// path of the roots dir to `pathBuffer` starting from `userDirPathLen`
    ///
    /// `userDirPathLen` must not include trailing slash.
    ///
    /// Returns a slice of the full roots dir path.
    inline fn getRootsDirPath(
        pathBuffer: *[utils.MAX_PATH_BYTES]u8,
        userDirPathLen: usize,
    ) []const u8 {
        return utils.insertPathComponent(
            pathBuffer,
            userDirPathLen,
            switch (OS) {
                .linux => "/.local/share/ssync",
                .macos => "/Library/Application Support/ssync",
                .windows => "\\ssync",
                else => unreachable,
            },
        );
    }

    const RootPathError = error{RootNameTooLong};

    /// Copies a slash and `rootName` to `pathBuffer` starting from `rootsDirPathLen`.
    ///
    /// `rootsDirPathLen` must not include trailing slash.
    ///
    /// Returns a slice of the full root path.
    inline fn getRootPath(
        pathBuffer: *[utils.MAX_PATH_BYTES]u8,
        rootsDirPathLen: usize,
        rootName: []const u8,
    ) RootPathError![]const u8 {
        if (rootName.len > MAX_ROOT_NAME_BYTES) {
            @branchHint(.cold);

            return RootPathError.RootNameTooLong;
        }

        const rootRelativePath = block: {
            const slash = (if (OS == .windows) "\\" else "/").*;

            const relativePathLen = slash.len + rootName.len;

            var buffer: [slash.len + MAX_ROOT_NAME_BYTES]u8 = undefined;
            buffer[0] = slash[0];

            @memcpy(buffer[slash.len..relativePathLen], rootName);

            break :block buffer[0..relativePathLen];
        };

        const fullRootPathLen = rootsDirPathLen + rootRelativePath.len;

        @memcpy(pathBuffer[rootsDirPathLen..fullRootPathLen], rootRelativePath);

        return pathBuffer[0..fullRootPathLen];
    }

    // TODO: rework this function
    /// Copies `userDirPath` to `outBuffer` and appends there path to config.
    ///
    /// Returns a slice of the full config path in `outBuffer`.
    inline fn getConfigPath(userDirPath: []const u8, buffer: *[utils.MAX_PATH_BYTES]u8) []const u8 {
        @memcpy(buffer[0..userDirPath.len], userDirPath);

        return utils.insertPathComponent(
            buffer,
            userDirPath.len,
            switch (OS) {
                .linux => "/.config/ssync.toml",
                .macos => "/Library/Application Support/ssync/ssync.toml",
                .windows => "\\ssync\\ssync.toml",
                else => unreachable,
            },
        );
    }
};
