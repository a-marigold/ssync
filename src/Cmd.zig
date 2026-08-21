//! The CLI commands.

const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const process = std.process;
const Environ = process.Environ;
const builtin = @import("builtin");
const Utils = @import("Utils.zig");
const SsyncConfig = @import("SsyncConfig.zig");

const __debug__ = Utils.__debug__;

const OS = builtin.os.tag;
const MAX_PATH_BYTES = Dir.max_path_bytes;

const StdIn = Utils.StdIn;
const StdOut = Utils.StdOut;

const PathBuilder = Utils.PathBuilder;

/// Relatively to user path.
const ROOTS_DIR_PATH = switch (OS) {
    .linux => "/.local/share/ssync",
    .macos => "/Library/Application Support/ssync",
    .windows => "\\ssync",
    else => unreachable,
};

/// Relatively to user path.
const CONFIG_PATH = switch (OS) {
    .linux => "/.config/ssync.toml",
    .macos => "/Library/Application Support/ssync/ssync.toml",
    .windows => "\\ssync\\ssync.toml",
    else => unreachable,
};

pub const MAX_ROOT_NAME_BYTES = 100;

/// The desired amount of bytes of stdout buffer that fits every command.
pub const STDOUT_BUFFER_BYTES = Help.TEXT.len;
/// `0` to make stderr unbufferred.
pub const STDERR_BUFFER_BYTES = 0;

/// Messages of all CLI logical errors.
///
/// Messages don't end with line break.
pub const Errors = struct {
    const PREFIX = "error: ";

    pub inline fn ARG_EXPECTED(comptime argName: []const u8) []const u8 {
        return PREFIX ++ "'" ++ argName ++ "' arg expected";
    }

    const CREATE_CONFIG_FAIL = PREFIX ++ "Failed to create config";
    const NON_RELATIVE_DEST = PREFIX ++ "'dest' must be a relative to 'root' path";
};

const Help = struct {
    const TEXT =
        \\Commands:
        \\  list                         Show path to roots and list created roots.
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

    /// Writes the help text to `stdout`.
    fn help(stdout: *StdOut) !void {
        try stdout.write(.{TEXT});
    }
};
pub const help = Help.help;

const List = struct {
    /// Errors returned by this function are only critical errors.
    fn list(io: Io, env: Environ, stdout: *StdOut) !void {
        var pathBuilder: PathBuilder = .init();

        const userPath = try Utils.getUserPath(env, &pathBuilder.buffer);
        pathBuilder.end = userPath.len;

        const rootsDirPath = pathBuilder.appendLiteral(ROOTS_DIR_PATH);

        const noRootCreatedMsg = "\nNo root created yet\n";

        const cwd = Dir.cwd();

        var rootsDirEntries = block: {
            const rootsDir = cwd.openDir(
                io,
                rootsDirPath,
                .{ .iterate = true, .follow_symlinks = true },
            ) catch |err| {
                if (err == Dir.OpenError.FileNotFound) {
                    try stdout.write(.{noRootCreatedMsg});

                    return stdout.flush();
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
            try stdout.write(.{noRootCreatedMsg});
            return stdout.flush();
        };

        try stdout.write(.{ "Roots are located in: ", rootsDirPath, "\n\nCreated roots:\n" });

        while (currentEntry) |entry| : (currentEntry = try rootsDirEntries.next(io)) {
            // On macos and windows roots and config
            // are located in one dir, so check is it a dir (that is root)
            if ((comptime OS != .linux) and entry.kind != .directory) {
                continue;
            }

            try stdout.write(.{ "  ", entry.name, "\n" });
        }

        return stdout.flush();
    }
};
pub const list = List.list;

const Config = struct {
    fn config(io: Io, env: Environ, stdout: *StdOut, stderr: *StdOut) !void {
        const outputEndChar = '\n';
        const outputEndCharLen = 1;

        var output: [MAX_PATH_BYTES + outputEndCharLen]u8 = undefined;

        const configPath = block: {
            const userPath = try Utils.getUserPath(env, &output);
            break :block getConfigPath(&output, userPath.len);
        };

        createConfig(io, configPath) catch {
            try stderr.write(.{Errors.CREATE_CONFIG_FAIL});
        };

        output[configPath.len] = outputEndChar;

        try stdout.write(.{output[0 .. configPath.len + outputEndCharLen]});
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
};
pub const config = Config.config;

const Create = struct {
    const Error = error{ RootAlreadyExists, CreateRootFail, CreateRootsDirFail, RootNameTooLong };
    fn create(
        io: Io,
        env: Environ,
        stdout: *StdOut,
        rootName: []const u8,
    ) !void {
        var pathBuilder: PathBuilder = .init();

        const userPath = try Utils.getUserPath(env, &pathBuilder.buffer);
        pathBuilder.end = userPath.len;

        const rootsDirPath = pathBuilder.appendLiteral(ROOTS_DIR_PATH);

        const rootPath = block: {
            if (rootName.len > MAX_ROOT_NAME_BYTES) {
                return Error.RootNameTooLong;
            }

            break :block pathBuilder.append(rootName);
        };
        const cwd = Dir.cwd();

        Utils.createDir(
            io,
            cwd,
            rootPath,
        ) catch |err| {
            switch (err) {
                // Roots dir has not been created yet
                Dir.CreateDirError.FileNotFound => {
                    Utils.createDir(
                        io,
                        cwd,
                        rootsDirPath,
                    ) catch return Error.CreateRootsDirFail;

                    Utils.createDir(
                        io,
                        cwd,
                        rootPath,
                    ) catch return Error.CreateRootFail;
                },

                Dir.CreateDirError.PathAlreadyExists => return Error.RootAlreadyExists,
                else => return Error.CreateRootFail,
            }
        };

        try stdout.write(.{"Root was successfully created\n"});
        return stdout.flush();
    }
};
pub const create = Create.create;
pub const CreateError = Create.Error;

const Add = struct {
    const Error = error{
        RootNameTooLong,
        DestPathAbsolute,
        GetSrcFullPathFail,
        SymLinkFail,
        DestAlreadyExist,
        CannotReplaceRoot,
    };
    fn add(
        io: Io,
        env: Environ,
        stdout: *StdOut,
        rootName: []const u8,
        srcPath: []const u8,
        destPath: []const u8,
    ) (Error || Utils.UserPathError || RootPathError)!void {
        var pathBuilder: PathBuilder = .init();

        const userPath = try Utils.getUserPath(env, &pathBuilder.buffer);
        pathBuilder.end = userPath.len;

        const rootPath = block: {
            if (rootName.len < MAX_ROOT_NAME_BYTES) {
                return Error.RootNameTooLong;
            }

            _ = pathBuilder.appendLiteral(ROOTS_DIR_PATH);

            break :block try pathBuilder.append(rootName);
        };

        const cwd = Dir.cwd();

        const destFullPath = pathBuilder.append(
            destPath,
        ) catch |err| switch (err) {
            PathBuilder.AppendError.RelativePathAbsolute => Error.DestPathAbsolute,
            else => {},
        };

        const srcFullPath = block: {
            if (Utils.isPathAbs(srcPath)) {
                break :block srcPath;
            }

            var buffer: [MAX_PATH_BYTES]u8 = undefined;
            const fullPathLen = cwd.realPathFile(
                io,
                srcPath,
                &buffer,
            ) catch {
                return Error.GetSrcFullPathFail;
            };

            break :block buffer[0..fullPathLen];
        };

        if (destFullPath.len == rootPath.len) {
            return Error.CannotReplaceRoot;
        }

        Utils.symLink(
            io,
            cwd,
            srcFullPath,
            destFullPath,
        ) catch return Error.SymLinkFail;
        // TODO: create dirs step-by-step

        try stdout.write(.{ "Successfully added ", srcPath, " to the dest in root" });
    }
};
pub const add = Add.add;
pub const AddError = Add.Error;

const Delete = struct {
    pub fn delete(
        io: Io,
        env: Environ,
        stdin: *StdIn,
        stdout: *StdOut,
        rootName: []const u8,
        rootFilePath: ?[]const u8,
    ) !void {
        var pathBuilder: PathBuilder = .init();

        const userPath = try Utils.getUserPath(env, &pathBuilder.buffer);
        pathBuilder.end = userPath.len;

        const rootPath = block: {
            if (rootName.len > MAX_ROOT_NAME_BYTES) {
                return; // TODO
            }

            _ = pathBuilder.appendLiteral(ROOTS_DIR_PATH);

            break :block pathBuilder.append(rootName);
        };

        const cwd = Dir.cwd();

        if (rootFilePath) |filePath| {
            if (Utils.isPathAbs(filePath)) {
                return;
            }

            const fullFilePath = pathBuilder.append(
                filePath,
            );

            const fileKind = (try cwd.statFile(
                io,
                fullFilePath,
                .{ .follow_symlinks = true },
            )).kind;

            switch (fileKind) {
                .file => try cwd.deleteFile(io, fullFilePath),

                .directory => {
                    try deleteDirWithConfirm(
                        io,
                        stdin,
                        stdout,
                        fullFilePath,
                        .{ "'", fullFilePath, "' is a non-empty dir. Delete it [y/n]? " },
                    );
                },

                else => unreachable,
            }
        }

        try deleteDirWithConfirm(
            io,
            stdin,
            stdout,
            rootPath,
            .{"Root is not empty. Delete it [y/n]? "},
        );
    }
};
pub const delete = Delete.delete;

const Update = struct {
    /// Uses `stdin` only for confirmation of directories deletion.
    ///
    /// Writes output to `stdout`.
    ///
    /// Critical errors are returned, but logical errors are handled with `stderr` and `null` is returned when they are.
    fn update(
        io: Io,
        env: Environ,
        stdin: *StdIn,
        stdout: *StdOut,
        stderr: *StdOut,
        rootName: []const u8,
        src: []const u8,
        dest: []const u8,
    ) !?void {
        var pathBuilder: PathBuilder = .init();

        const userPath = try Utils.getUserPath(env, &pathBuilder.buffer);
        pathBuilder.len = userPath.len;

        const rootPath = block: {
            if (rootName.len > MAX_ROOT_NAME_BYTES) {
                return; // TODO
            }

            _ = pathBuilder.appendLiteral(ROOTS_DIR_PATH);
            break :block pathBuilder.append(rootName);
        };

        const destFullPath = pathBuilder.append(
            dest,
        ) catch |err| switch (err) {
            PathBuilder.AppendError.RelativePathAbsolute => stderr.write(Errors.NON_RELATIVE_DEST),
            else => {}, // TODO
        };

        const cwd = Dir.cwd();

        const srcFullPath = block: {
            if (Utils.isPathAbs(src)) {
                break :block src;
            }

            var buffer: [MAX_PATH_BYTES]u8 = undefined;
            break :block try cwd.realPathFile(io, src, &buffer);
        };

        if (destFullPath.len == rootPath.len) {
            return Add.replaceRoot(io, stdin, stdout, rootPath, srcFullPath);
        }

        try Utils.symLink(io, cwd, srcFullPath, srcFullPath);
    }

    const ReplaceRootError = error{
        StatSrcFail,
        SrcNotDir,
        SymLinkRootFail,
    } || DeleteDirWithConfirmError;
    /// Deletes a root at `rootPath` and places a symlink targeting `srcFullPath` there.
    ///
    /// If the root is not empty, uses `stdin` and `stdout` to confirm deletion.
    inline fn replaceRoot(
        io: Io,
        stdin: *StdIn,
        stdout: *StdOut,
        rootPath: []const u8,
        srcFullPath: []const u8,
    ) ReplaceRootError!void {
        const cwd = Dir.cwd();

        try deleteDirWithConfirm(
            io,
            stdin,
            stdout,
            rootPath,
            .{"Root is not empty. Delete it [y/n]? "},
        );

        const srcFileKind = (cwd.statFile(
            io,
            srcFullPath,
            .{ .follow_symlinks = true },
        ) catch return ReplaceRootError.StatSrcFail).kind;

        if (srcFileKind != .directory) {
            return ReplaceRootError.SrcNotDir;
        }

        // `Utils.symLink` isn't used not to do `stat` on windows twice

        cwd.symLink(
            io,
            srcFullPath,
            rootPath,
            .{ .is_directory = true },
        ) catch return ReplaceRootError.SymLinkRootFail;
    }
};
pub const update = Update.update;

//
// --- Cmd Utils ---
//

const DeleteDirWithConfirmError = error{
    DirNotFound,
    DeleteFail,
    ConfirmationFail,
};
/// Deletes dir at `dirPath`.
/// If the dir is not empty, confirms to delete it recursively.
///
/// Uses `stdin` and `stdout` for confirmation.
fn deleteDirWithConfirm(
    io: Io,
    stdin: *StdIn,
    stdout: *StdOut,
    dirPath: []const u8,
    /// To be passed to `Utils.confirm`.
    confirmQuery: anytype,
) DeleteDirWithConfirmError!void {
    const cwd = Dir.cwd();

    cwd.deleteDir(io, dirPath) catch |err| switch (err) {
        Dir.DeleteDirError.DirNotEmpty => {
            while (true) {
                const isConfirmed = Utils.confirm(
                    stdin,
                    stdout,
                    confirmQuery,
                ) catch |confirmErr| switch (confirmErr) {
                    Utils.ConfirmError.UnknownChar => continue,
                    else => return DeleteDirWithConfirmError.ConfirmationFail,
                };

                if (isConfirmed) {
                    return cwd.deleteTree(
                        io,
                        dirPath,
                    ) catch DeleteDirWithConfirmError.DeleteFail;
                } else {
                    return;
                }
            }
        },
        Dir.DeleteDirError.FileNotFound => return DeleteDirWithConfirmError.DirNotFound,
        else => return DeleteDirWithConfirmError.DeleteFail,
    };
}

/// Starting from `userPathLen`, copies platform-specific relative path
/// of the roots dir to `pathBuffer`, which already contains user path
///
/// `userPathLen` must not include trailing slash.
///
/// Returns a slice of the full roots dir path.
inline fn getRootsDirPath(pathBuffer: []u8, userPathLen: usize) []const u8 {
    return Utils.insertStr(
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

/// Starting from `userPathLEn`, copies platfrom specific relative path
/// of the config to `pathBuffer`, which already contains the user path.
///
/// `userPathLen` must not include trailing slash.
///
/// Returns a slice of the full config path.
inline fn getConfigPath(pathBuffer: []u8, userPathLen: usize) []const u8 {
    return Utils.insertStr(
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
    return Utils.joinPath(
        pathBuffer,
        rootsDirPathLen,
        rootName,
    );
}

// TODO: 'follow symlinks' flag for 'add' and 'update' commands.
// TODO: 'args' and 'flags' structs for commands
// TODO: initUserPath
// TODO: checkRootName
