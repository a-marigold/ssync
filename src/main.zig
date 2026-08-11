const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const Io = std.Io;
const Dir = Io.Dir;
const path = Dir.path;
const process = std.process;
const Environ = process.Environ;
const unicode = std.unicode;
const builtin = @import("builtin");
const utils = @import("utils.zig");

const OS = builtin.os.tag;

const MAX_PATH_BYTES = utils.MAX_PATH_BYTES;
const StdOut = utils.StdOut;

pub fn main(init: process.Init.Minimal) !void {
    const environ = init.environ;

    // TODO: initialize allocator lazily only where needed
    var arena: heap.ArenaAllocator = .init(heap.page_allocator);
    const arenaAllocator = arena.allocator();

    var threaded: Io.Threaded = .init(arenaAllocator, .{});
    const io = threaded.io();

    var stderr: StdOut = .init(io, .Stderr);

    var args = try init.args.iterateAllocator(arenaAllocator);

    _ = args.skip();

    if (args.next()) |cmd| {
        var stdout: StdOut = .init(io, .Stdout);

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
        const text =
            \\Commands:
            \\  list                            Show path to the config, path to roots and all created roots.
            \\
            \\  create [root]                   Create a root.
            \\
            \\  add [root, source, dest]        'root' is name of a root to copy 'source' file to.
            \\                                  'source' is path to a file in the system which is to be copied to 'dest'.
            \\                                  'dest' is a path relative to 'root' to copy 'source' to.
            \\                                  If 'source' and 'dest' are not specified, just root is created.
            \\
            \\  delete [root, ?file]            If 'file' specified, delete the 'file' in 'root'.
            \\                                  If only 'file' is not specified, delete the whole root (prompt is shown for safety).
            \\
            \\  update [root, newSource, dest]  Make 'dest' in 'root' track 'newSource' instead of the current.
            \\
            \\Terms:
            \\  root  Synchronization root, root folder of data with a similar domain.
            \\        Used to separate, for example, 'music', 'configs', 'editor' and so on.
            \\        Roots can be handled differently in handlers, and that is the key purpose of them.
            \\
        ;

        return text;
    }

    /// Returns output of the command.
    pub inline fn list(allocator: mem.Allocator, io: Io, env: Environ) !std.ArrayList(u8) {
        // Capacity 170 is enough for most cases
        var output: std.ArrayList(u8) = try .initCapacity(allocator, 170);

        var userPathBuffer: [MAX_PATH_BYTES]u8 = undefined;
        const userPath = try utils.getUserPath(env, &userPathBuffer);
        const rootsDirPath = getRootsDirPath(
            &userPathBuffer,
            userPath.len,
        );
        const configPath = block: {
            // Copy the user path not to rewrite `rootsDirPath`
            var buffer: [MAX_PATH_BYTES]u8 = userPathBuffer;
            break :block getConfigPath(&buffer, userPath.len);
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
            // On macos and windows roots and config are located in one dir,
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
        env: Environ,
        rootName: []const u8,
    ) (CreateError || utils.UserPathError || RootPathError)!void {
        var userPathBuffer: [MAX_PATH_BYTES]u8 = undefined;
        const userPath = try utils.getUserPath(env, &userPathBuffer);

        const rootPath = block: {
            const rootsDirPath = getRootsDirPath(
                &userPathBuffer,
                userPath.len,
            );

            break :block try getRootPath(
                &userPathBuffer,
                rootsDirPath.len,
                rootName,
            );
        };

        Dir.cwd().createDir(
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

    const AddError = error{
        DestPathAbsolute,
        GetSourceFullPathFail,
        RootNotExist,
        DeleteRootFail,
        StatSourceFail,
        SourceNotDir,
    };
    inline fn add(
        io: Io,
        env: Environ,
        stdout: *StdOut,
        rootName: []const u8,
        sourcePath: []const u8,
        destPath: []const u8,
    ) (AddError || utils.UserPathError || RootPathError)!void {
        const userPathBuffer: [MAX_PATH_BYTES]u8 = undefined;
        const userPath = try utils.getUserPath(env, userPathBuffer);

        const rootsDirPath = getRootsDirPath(userPathBuffer, userPath.len);

        const rootPath = try getRootPath(
            userPathBuffer,
            rootsDirPath.len,
            rootName,
        );

        const cwd = Dir.cwd();

        const sourceFullPath = block: {
            if (path.isAbsolute(sourcePath)) {
                break :block sourcePath;
            }

            var buffer: [MAX_PATH_BYTES]u8 = undefined;
            const fullPathLen = cwd.realPathFile(
                io,
                sourcePath,
                &buffer,
            ) catch {
                return AddError.GetSourceFullPathFail;
            };

            break :block buffer[0..fullPathLen];
        };

        const destFullPath = block: {
            if (path.isAbsolute(destPath)) {
                @branchHint(.cold);

                return AddError.DestPathAbsolute;
            }

            break :block utils.joinPath(
                &userPathBuffer,
                rootPath.len,
                destPath,
            );
        };

        // Symlink the whole root
        if (destFullPath.len == rootPath.len) {
            return try addRoot(
                io,
                stdout,
                rootPath,
                sourceFullPath,
                destFullPath,
            );
        }
    }
    inline fn addRoot(
        io: Io,
        stdout: StdOut,
        rootPath: []const u8,
        sourceFullPath: []const u8,
        destFullPath: []const u8,
    ) AddError!void {
        const cwd = Dir.cwd();

        cwd.deleteDir(io, rootPath) catch |err| {
            switch (err) {
                Dir.DeleteDirError.FileNotFound => return AddError.RootNotExist,
                Dir.DeleteDirError.DirNotEmpty => {
                    try stdout.write("Root is not empty. Rewrite all files [y/n]?:\n");

                    cwd.deleteTree(io, rootPath) catch return AddError.DeleteRootFail;

                    const sourceFileKind = (cwd.statFile(
                        io,
                        sourceFullPath,
                        .{ .follow_symlinks = false },
                    ) catch return AddError.StatSourceFail).kind;
                    if (sourceFileKind != .directory) {
                        return AddError.SourceNotDir;
                    }

                    cwd.symLink(
                        io,
                        sourceFullPath,
                        destFullPath,
                        .{ .is_directory = true },
                    );
                },
                else => return AddError.DeleteRootFail,
            }
        };
    }

    /// Inserts a platfrom-specific relative
    /// path of the roots dir to `pathBuffer` starting from `userPathLen`.
    ///
    /// `userPathLen` must not include trailing slash.
    ///
    /// Returns a slice of the full roots dir path.
    inline fn getRootsDirPath(
        pathBuffer: *[MAX_PATH_BYTES]u8,
        userPathLen: usize,
    ) []const u8 {
        const rootsDirRelativePath = switch (OS) {
            .linux => "/.local/share/ssync",
            .macos => "/Library/Application Support/ssync",
            .windows => "\\ssync",
            else => unreachable,
        };

        return utils.insertSlice(
            u8,
            pathBuffer,
            userPathLen,
            rootsDirRelativePath,
        );
    }

    const RootPathError = error{RootNameTooLong};
    /// Copies a slash and `rootName` to `pathBuffer` starting from `rootsDirPathLen`.
    ///
    /// `rootsDirPathLen` must not include trailing slash.
    ///
    /// Returns a slice of the full root path.
    inline fn getRootPath(
        pathBuffer: *[MAX_PATH_BYTES]u8,
        rootsDirPathLen: usize,
        rootName: []const u8,
    ) RootPathError![]const u8 {
        if (rootName.len > MAX_ROOT_NAME_BYTES) {
            @branchHint(.cold);

            return RootPathError.RootNameTooLong;
        }

        const slash = if (OS == .windows) '\\' else '/';
        const slashLen = 1;

        pathBuffer[rootsDirPathLen] = slash;
        return utils.insertSlice(
            u8,
            pathBuffer,
            rootsDirPathLen + slashLen,
            rootName,
        );
    }

    /// Copies platfrom specific relative path to the config to `pathBuffer` starting from `userPathLen`.
    ///
    /// `userPathLen` must not include trailing slash.
    ///
    /// Returns a slice of the full path.
    inline fn getConfigPath(pathBuffer: *[MAX_PATH_BYTES]u8, userPathLen: usize) []const u8 {
        const configRelativePath = switch (OS) {
            .linux => "/.config/ssync.toml",
            .macos => "/Library/Application Support/ssync/ssync.toml",
            .windows => "\\ssync\\ssync.toml",
            else => unreachable,
        };

        return utils.insertSlice(
            u8,
            pathBuffer,
            userPathLen,
            configRelativePath,
        );
    }
};
