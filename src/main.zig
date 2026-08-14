const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const path = Dir.path;
const process = std.process;
const Environ = process.Environ;
const unicode = std.unicode;
const builtin = @import("builtin");
const utils = @import("utils.zig");

const OS = builtin.os.tag;

const MAX_PATH_BYTES = Io.Dir.max_path_bytes;
const StdOut = utils.StdOut;
const StdIn = utils.StdIn;

const __debug__ = utils.__debug__;

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

        const eqlCmd = Commands.eqlCmd;

        if (eqlCmd(cmd, "--help")) {
            try Commands.help(&stdout);
            utils.exit(.Success);
        }

        if (eqlCmd(cmd, "list")) {
            try Commands.list(arenaAllocator, io, env, &stdout);
            utils.exit(.Success);
        }

        if (eqlCmd(cmd, "add")) {
            var stdin: StdIn = block: {
                // `stdin` is only used for y/n confirmation, so assume 1 byte is enough
                var buffer: [1]u8 = undefined;

                break :block .init(io, &buffer);
            };

            const rootName = args.next() orelse {
                try stderr.write(ErrorMsgs.argExpected("root") ++ "\n");
                utils.exit(.InvalidArg);
            };

            const srcPath = args.next() orelse {
                try stderr.write(ErrorMsgs.argExpected("src") ++ "\n");
                utils.exit(.InvalidArg);
            };

            const destPath = args.next() orelse {
                try stderr.write(ErrorMsgs.argExpected("dest") ++ "\n");
                utils.exit(.InvalidArg);
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

            utils.exit(.Success);
        }

        if (eqlCmd(cmd, "create")) {
            const rootName = args.next() orelse {
                try stderr.write(ErrorMsgs.argExpected("root") ++ "\n");
                utils.exit(.InvalidArg);
            };

            try Commands.create(io, env, &stdout, rootName);
            utils.exit(.Success);
        }

        if (eqlCmd(cmd, "config")) {
            try Commands.config(io, env, &stdout, &stderr);
            utils.exit(.Success);
        }
    }

    try Commands.help(&stderr);

    utils.exit(.InvalidArg);
}

const ErrorMsgs = Commands.ErrorMsgs;

/// The CLI commands.
const Commands = struct {
    const MAX_ROOT_NAME_BYTES = 60;

    pub const ErrorMsgs = struct {
        pub inline fn argExpected(comptime argName: []const u8) []const u8 {
            return "'" ++ argName ++ "' arg expected";
        }
    };

    /// Compares `a` and `b` command names.
    inline fn eqlCmd(a: []const u8, b: []const u8) bool {
        return mem.eql(u8, a, b);
    }

    /// Write the help text to `stdout`.
    pub fn help(stdout: *StdOut) !void {
        const text =
            \\Commands:
            \\  list                         Show path to roots and all created roots.
            \\
            \\  config                       Show path to config and create it if doesn't exist.
            \\
            \\  create [root]                Create a root.
            \\
            \\  add [root, src, dest]        'root' is name of a root to copy 'src' file to.
            \\                               'src' is path to a file in the system which is to be copied to 'dest'.
            \\                               'dest' is a path relative to 'root' to copy 'src' to.
            \\
            \\  delete [root, ?file]         If 'file' specified, delete the 'file' in 'root'.
            \\                               If only 'file' is not specified, delete the whole root (prompt is shown for safety).
            \\
            \\  update [root, newSrc, dest]  Make 'dest' in 'root' track 'newSrc' instead of the current.
            \\
            \\Terms:
            \\  root  Synchronization root, root folder of data with a similar domain.
            \\        Used to separate, for example, 'music', 'configs', 'editor' and so on.
            \\        Roots can be handled differently in handlers, and that is the key purpose of them.
            \\
        ;

        try stdout.write(text);
    }

    /// Writes output to `stdout`.
    pub fn list(allocator: mem.Allocator, io: Io, env: Environ, stdout: *StdOut) !void {
        // Capacity 170 is enough for most cases
        var output: std.ArrayList(u8) = try .initCapacity(allocator, 170);

        var userPathBuffer: [MAX_PATH_BYTES]u8 = undefined;
        const userPath = try utils.getUserPath(env, &userPathBuffer);

        const rootsDirPath = getRootsDirPath(
            &userPathBuffer,
            userPath.len,
        );

        const noRootCreatedMsg = "\nNo root created yet\n";

        const cwd = Dir.cwd();

        var rootsDirEntries = block: {
            const rootsDir = cwd.openDir(
                io,
                rootsDirPath,
                .{ .iterate = true, .follow_symlinks = true },
            ) catch |err| {
                if (err == Dir.OpenError.FileNotFound) {
                    try output.appendSlice(allocator, noRootCreatedMsg);

                    return stdout.write(output.items);
                }

                return err;
            };

            var buffer: [2048]u8 align(8) = undefined;

            break :block Dir.Reader.init(
                rootsDir,
                &buffer,
            );
        };

        var currentEntry: ?Dir.Entry = try rootsDirEntries.next(io) orelse {
            try output.appendSlice(allocator, noRootCreatedMsg);

            return stdout.write(output.items);
        };

        try output.appendSlice(allocator, "Roots are located in: ");
        try output.appendSlice(allocator, rootsDirPath);

        try output.appendSlice(allocator, "\n\nCreated roots:\n");
        while (currentEntry) |entry| : (currentEntry = try rootsDirEntries.next(io)) {
            // On macos and windows roots and config
            // are located in one dir, so check is it a dir (that is root)
            if ((comptime OS != .linux) and entry.kind != .directory) {
                continue;
            }

            try output.append(allocator, ' ');
            try output.append(allocator, ' ');
            try output.appendSlice(allocator, entry.name);

            try output.append(allocator, '\n');
        }

        try stdout.write(output.items);
    }

    /// Writes output to `stdout`.
    pub fn config(io: Io, env: Environ, stdout: *StdOut, stderr: *StdOut) !void {
        const outputEndChar = '\n';
        const outputEndCharLen = 1;

        var output: [MAX_PATH_BYTES + outputEndCharLen]u8 = undefined;

        const configPath = block: {
            const userPath = try utils.getUserPath(env, &output);

            break :block getConfigPath(&output, userPath.len);
        };

        createConfig(io, configPath) catch {
            try stderr.write("Failed to create config\n");
        };

        output[configPath.len] = outputEndChar;

        try stdout.write(output[0 .. configPath.len + outputEndCharLen]);
    }
    inline fn createConfig(io: Io, configPath: []const u8) !void {
        const cwd = Dir.cwd();

        // Happy path is when config exists, Sad path is when does not
        _ = cwd.statFile(
            io,
            configPath,
            .{ .follow_symlinks = false },
        ) catch |err| {
            switch (err) {
                Dir.StatFileError.FileNotFound => {
                    try cwd.writeFile(io, .{
                        .sub_path = configPath,
                        .data = SsyncConfig.CONFIG_FILE_TEXT,
                        .flags = .{},
                    });
                },
                else => return err,
            }
        };
    }

    const CreateError = error{ RootAlreadyExists, CreateRootFail, CreateRootsDirFail };
    pub fn create(
        io: Io,
        env: Environ,
        stdout: *StdOut,
        rootName: []const u8,
    ) !void {
        var userPathBuffer: [MAX_PATH_BYTES]u8 = undefined;
        const userPath = try utils.getUserPath(env, &userPathBuffer);

        const rootsDirPath = getRootsDirPath(
            &userPathBuffer,
            userPath.len,
        );

        const rootPath = block: {
            break :block try getRootPath(
                &userPathBuffer,
                rootsDirPath.len,
                rootName,
            );
        };

        const cwd = Dir.cwd();

        utils.createDir(
            io,
            cwd,
            rootPath,
        ) catch |err| {
            switch (err) {
                Dir.CreateDirError.FileNotFound => {
                    // Roots dir has not been created yet

                    utils.createDir(
                        io,
                        cwd,
                        rootPath,
                    ) catch return CreateError.CreateRootsDirFail;

                    utils.createDir(
                        io,
                        cwd,
                        rootPath,
                    ) catch return CreateError.CreateRootFail;
                },
                Dir.CreateDirError.PathAlreadyExists => return CreateError.RootAlreadyExists,
                else => return CreateError.CreateRootFail,
            }
        };

        try stdout.write("Root was successfully created\n");
    }

    const AddError = error{
        DestPathAbsolute,
        GetSrcFullPathFail,
    };
    /// `stdin` is only used for confirmation for deletion.
    ///
    /// Writes output to `stdout` on its own.
    pub fn add(
        io: Io,
        env: Environ,
        stdin: *StdIn,
        stdout: *StdOut,
        rootName: []const u8,
        srcPath: []const u8,
        destPath: []const u8,
    ) (AddError || utils.UserPathError || RootPathError || ReplaceRootError)!void {
        var userPathBuffer: [MAX_PATH_BYTES]u8 = undefined;
        const userPath = try utils.getUserPath(env, &userPathBuffer);

        const rootsDirPath = getRootsDirPath(&userPathBuffer, userPath.len);

        const rootPath = try getRootPath(
            &userPathBuffer,
            rootsDirPath.len,
            rootName,
        );

        const cwd = Dir.cwd();

        const srcFullPath = block: {
            if (path.isAbsolute(srcPath)) {
                break :block srcPath;
            }

            var buffer: [MAX_PATH_BYTES]u8 = undefined;
            const fullPathLen = cwd.realPathFile(
                io,
                srcPath,
                &buffer,
            ) catch {
                return AddError.GetSrcFullPathFail;
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
            return replaceRoot(
                io,
                stdin,
                stdout,
                rootPath,
                srcFullPath,
            );
        }
    }
    const ReplaceRootError = error{
        RootNotExist,
        StatSrcFail,
        SrcNotDir,
        DeleteRootFail,
        SymLinkRootFail,
        ConfirmationFail,
    };
    inline fn replaceRoot(
        io: Io,
        stdin: *StdIn,
        stdout: *StdOut,
        rootPath: []const u8,
        srcFullPath: []const u8,
    ) ReplaceRootError!void {
        const cwd = Dir.cwd();

        cwd.deleteDir(io, rootPath) catch |err| {
            switch (err) {
                Dir.DeleteDirError.DirNotEmpty => {
                    while (true) {
                        const isConfirmed = utils.confirm(
                            stdin,
                            stdout,
                            "Root is not empty. Rewrite all files [y/n]? ",
                        ) catch |confirmErr| {
                            switch (confirmErr) {
                                utils.ConfirmError.UnknownChar => continue,
                                else => return ReplaceRootError.ConfirmationFail,
                            }
                        };

                        if (isConfirmed) {
                            return cwd.deleteTree(
                                io,
                                rootPath,
                            ) catch ReplaceRootError.DeleteRootFail;
                        } else {
                            return;
                        }
                    }
                },
                Dir.DeleteDirError.FileNotFound => return ReplaceRootError.RootNotExist,
                else => return ReplaceRootError.DeleteRootFail,
            }
        };

        const srcFileKind = (cwd.statFile(
            io,
            srcFullPath,
            .{ .follow_symlinks = false },
        ) catch return ReplaceRootError.StatSrcFail).kind;

        if (srcFileKind != .directory) {
            return ReplaceRootError.SrcNotDir;
        }

        cwd.symLink(
            io,
            srcFullPath,
            rootPath,
            .{ .is_directory = true },
        ) catch return ReplaceRootError.SymLinkRootFail;
    }

    // Writes output to `stdout`.
    pub fn delete(
        io: Io,
        env: Environ,
        stdin: *StdIn,
        stdout: *StdOut,
        rootName: []const u8,
        rootFilePath: ?[]const u8,
    ) void {
        const userPathBuffer: [MAX_PATH_BYTES]u8 = undefined;
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

        const cwd = Dir.cwd();

        if (rootFilePath) |filePath| {
            if (path.isAbsolute(filePath)) {
                return;
            }

            const fullFilePath = utils.joinPath(
                &userPathBuffer,
                rootPath.len,
                rootFilePath,
            );

            const fileKind = (try cwd.statFile(
                io,
                fullFilePath,
                .{ .follow_symlinks = true },
            )).kind;

            switch (fileKind) {
                File.Kind.file => {
                    try cwd.deleteFile(io, fullFilePath);
                },
                File.Kind.directory => {
                    const query = block: {
                        var buffer: []u8 = undefined;

                        break :block utils.concatStrings(&buffer, .{
                            "'", fullFilePath, "' is a dir. Delete all files [y/n]?",
                        });
                    };

                    while (true) {
                        const isConfirmed = utils.confirm(
                            stdin,
                            stdout,
                            query,
                        ) catch |err| {
                            switch (err) {
                                utils.ConfirmError.UnknownChar => continue,
                                else => {},
                            }
                        };

                        if (isConfirmed) {
                            return cwd.deleteTree(io, fullFilePath) catch {};
                        } else {
                            return;
                        }
                    }
                },
                else => unreachable,
            }
        }
    }

    /// Starting from `userPathLen`, copies platform-specific relative path
    /// of the roots dir to `pathBuffer`, which already contains user path
    ///
    /// `userPathLen` must not include trailing slash.
    ///
    /// Returns a slice of the full roots dir path.
    inline fn getRootsDirPath(pathBuffer: []u8, userPathLen: usize) []const u8 {
        return utils.insertSlice(
            u8,
            pathBuffer,
            userPathLen,
            switch (OS) {
                .linux => "/.local/share/ssync",
                .macos => "/Library/Application Support/ssync",
                .windows => "\\ssync",

                else => unreachable,
            },
        );
    }

    const RootPathError = error{RootNameTooLong};
    /// Starting from `rootsDirPathLen`, copies `rootName` to `pathBuffer`,
    /// which already contains roots dir path.
    ///
    /// `rootsDirPathLen` must not include trailing slash.
    ///
    /// Resolves slashes.
    ///
    /// Returns a slice of the full root path.
    inline fn getRootPath(
        pathBuffer: []u8,
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

    /// Starting from `userPathLEn`, copies platfrom specific relative path
    /// of the config to `pathBuffer`, which already contains user path.
    ///
    /// `userPathLen` must not include trailing slash.
    ///
    /// Returns a slice of the full path.
    inline fn getConfigPath(pathBuffer: []u8, userPathLen: usize) []const u8 {
        return utils.insertSlice(
            u8,
            pathBuffer,
            userPathLen,
            switch (OS) {
                .linux => "/.config/ssync.toml",
                .macos => "/Library/Application Support/ssync/ssync.toml",
                .windows => "\\ssync\\ssync.toml",
                else => unreachable,
            },
        );
    }
};

const SsyncConfig = struct {
    // TODO: add text
    pub const CONFIG_FILE_TEXT =
        \\
    ;
};
