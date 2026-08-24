//! The CLI commands.
//!
//! Each command writes its output ot `stdout` by its own,
//! but errors are returned to be handled in the command caller.
//!
//! Commands have error unions (e.g `AddError` for `add`)
//! that contain mostly logical errors and have appropriate error messages.
//! Errors, returned by commands, but not included in their error unions are implied as critical.
//!
//! Commands have `Args` and `Flags` structures.
//! `Args` must be formed in order of the struct fields.

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
const PathIterator = Utils.PathIterator;

/// The desired amount of bytes of stdout buffer that fits every command.
pub const STDOUT_BUFFER_BYTES = Help.TEXT.len;
/// `0` to make stderr unbufferred.
pub const STDERR_BUFFER_BYTES = 0;
/// It is used only for y/n confirmation, so assume 1 byte is enough.
pub const STDIN_BUFFER_BYTES = 1;

/// Relatively to user path.
const ROOTS_DIR_PATH = switch (OS) {
    .linux => ".local/share/ssync",
    .macos => "Library/Application Support/ssync",
    .windows => "ssync",
    else => unreachable,
};
/// Relatively to user path.
const CONFIG_PATH = switch (OS) {
    .linux => ".config/ssync.toml",
    .macos => "Library/Application Support/ssync/ssync.toml",
    .windows => "ssync/ssync.toml",
    else => unreachable,
};

pub const MAX_ROOT_NAME_BYTES = 100;

/// Messages of all CLI logical errors.
///
/// Messages don't end with a line break.
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
        \\  delete [root, ?dest]         If 'dest' specified, delete the file at 'dest' path in 'root'.
        \\                               If only 'file' is not specified, delete the whole root (prompt is shown for safety).
        \\
        \\  update [root, newSrc, dest]  Make 'dest' in 'root' track 'newSrc' instead of the current.
        \\                               If 'dest' is like './', replaces the whole root with 'newSrc' 
        \\                               ('newSrc' must be a folder and prompt is shown for safety).
        \\
        \\Terms:
        \\  root  Synchronization root, root folder of data with a similar domain.
        \\        Used to separate, for example, 'music', 'configs', 'editor' and so on.
        \\        Roots can be handled differently in handlers, and that is the key purpose of them.
        \\
    ;

    /// Writes the help text to `stdout`.
    ///
    /// Errors returned by this function are only critical.
    fn help(stdout: *StdOut) !void {
        try stdout.write(.{TEXT});
        try stdout.flush();
    }
};
pub const help = Help.help;

const List = struct {
    /// Errors returned by this function are only critical.
    fn list(io: Io, env: Environ, stdout: *StdOut) !void {
        var pathBuilder = try initUserPathBuilder(env);

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
            // are located in one dir, so check is it a dir (that is a root)
            if (OS != .linux) {
                if (entry.kind != .directory) {
                    continue;
                }
            }

            try stdout.write(.{ "  ", entry.name, "\n" });
        }

        return stdout.flush();
    }
};
pub const list = List.list;

const Config = struct {
    const Error = CreateConfigError;
    fn config(
        io: Io,
        env: Environ,
        stdout: *StdOut,
    ) (Error || Utils.UserPathError || StdOut.WriteError)!void {
        var pathBuilder = try initUserPathBuilder(env);

        const configPath = pathBuilder.appendLiteral(CONFIG_PATH);

        try createConfig(io, configPath);

        try stdout.write(.{configPath});
        try stdout.writeByte('\n');
        try stdout.flush();
    }

    const CreateConfigError = error{ WriteConfigFail, StatConfigFail };
    /// Tries to create config only if it doesn't exist.
    inline fn createConfig(io: Io, configPath: []const u8) CreateConfigError!void {
        const cwd = Dir.cwd();

        // Happy path is when config exists, Sad path is when does not
        _ = cwd.statFile(
            io,
            configPath,
            .{ .follow_symlinks = false },
        ) catch |err| return switch (err) {
            Dir.StatFileError.FileNotFound => cwd.writeFile(io, .{
                .sub_path = configPath,
                .data = SsyncConfig.CONFIG_FILE_TEXT,
                .flags = .{},
            }) catch Error.WriteConfigFail,

            else => Error.StatConfigFail,
        };
    }
};
pub const config = Config.config;
pub const ConfigError = Config.Error;

const Create = struct {
    const Error = error{
        RootAlreadyExists,
        CreateRootFail,
        CreateRootsDirFail,
    } || CheckRootNameError;

    const Args = struct { root: []const u8 };

    fn create(
        io: Io,
        env: Environ,
        stdout: *StdOut,
        args: Args,
    ) (Error || Utils.UserPathError || StdOut.WriteError)!void {
        const rootName = args.root;

        var pathBuilder = try initUserPathBuilder(env);

        const rootsDirPath = pathBuilder.appendLiteral(ROOTS_DIR_PATH);

        const rootPath = block: {
            try checkRootName(rootName);
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
pub const CreateArgs = Create.Args;

const Add = struct {
    const Error = error{
        RootNameTooLong,
        DestPathAbsolute,
        GetSrcAbsPathFail,
        SymLinkFail,
        DestAlreadyExist,
        CannotReplaceRoot,
        RootNotExist,
        DestComponentNotDir,
    } || CheckRootNameError || CheckRootDestError;

    const Args = struct {
        root: []const u8,
        src: []const u8,
        dest: []const u8,
    };

    fn add(
        io: Io,
        env: Environ,
        stdout: *StdOut,
        args: Args,
    ) (Error || Utils.UserPathError || StdOut.WriteError)!void {
        const rootName = args.root;
        const srcPath = args.src;
        const destPath = args.dest;

        var pathBuilder = try initUserPathBuilder(env);

        const rootPath = block: {
            try checkRootName(rootName);

            _ = pathBuilder.appendLiteral(ROOTS_DIR_PATH);

            break :block pathBuilder.append(rootName);
        };

        const cwd = Dir.cwd();

        const destAbsPath = block: {
            try checkRootDest(destPath);

            break :block pathBuilder.append(destPath);
        };

        const srcAbsPath = block: {
            if (Utils.isPathAbs(srcPath)) {
                break :block srcPath;
            }

            var buffer: [MAX_PATH_BYTES]u8 = undefined;
            const absPathLen = cwd.realPathFile(
                io,
                srcPath,
                &buffer,
            ) catch return Error.GetSrcAbsPathFail;

            break :block buffer[0..absPathLen];
        };

        if (destAbsPath.len == rootPath.len) return Error.CannotReplaceRoot;

        Utils.symLink(
            io,
            cwd,
            srcAbsPath,
            destAbsPath,
        ) catch |err| switch (err) {
            Utils.SymLinkError.PathAlreadyExists => return Error.DestAlreadyExist,
            Utils.SymLinkError.FileNotFound => {
                _ = cwd.statFile(
                    io,
                    rootPath,
                    .{ .follow_symlinks = false },
                ) catch return Error.RootNotExist;

                // Use it instead of `destPath` to ensure there is not a trailing slash
                const resolvedDestPath = destAbsPath[rootPath.len + 1 ..]; // `+ 1` for slash

                var destPathIterator: PathIterator = .init(resolvedDestPath);

                var currentAbsPath = rootPath;
                while (destPathIterator.next()) |component| {
                    currentAbsPath = currentAbsPath[0 .. currentAbsPath.len + component.len];

                    // The destination is reached
                    if (currentAbsPath.len == destAbsPath.len) {
                        Utils.symLink(
                            io,
                            cwd,
                            srcAbsPath,
                            destAbsPath,
                        ) catch return Error.SymLinkFail;

                        try stdout.write(.{ "Successfully added ", srcPath, " to the dest in root" });
                        return stdout.flush();
                    }

                    Utils.createDir(io, cwd, currentAbsPath) catch |dirErr| switch (dirErr) {
                        Dir.CreateDirError.PathAlreadyExists => continue,
                        Dir.CreateDirError.NotDir => return Error.DestComponentNotDir,
                        else => return Error.SymLinkFail,
                    };
                }
            },
            else => return Error.SymLinkFail,
        };

        try stdout.write(.{ "Successfully added ", srcPath, " to the dest in root" });
        return stdout.flush();
    }
};
pub const add = Add.add;
pub const AddError = Add.Error;
pub const AddArgs = Add.Args;

const Delete = struct {
    const Error = error{
        FilePathAbsolute,
        StatFileFail,
        DeleteRootFail,
        DeleteFileFail,
    } || CheckRootNameError || CheckRootDestError;

    const Args = struct {
        root: []const u8,
        dest: ?[]const u8,
    };

    /// Uses `stdin` only for confirmation of directories deletion.
    pub fn delete(
        io: Io,
        env: Environ,
        stdin: *StdIn,
        stdout: *StdOut,
        args: Args,
    ) (Error || Utils.UserPathError || StdOut.WriteError || DeleteDirWithConfirmError)!void {
        const rootName = args.root;
        const destPath = args.dest;

        var pathBuilder = try initUserPathBuilder(env);

        const rootPath = block: {
            try checkRootName(rootName);
            _ = pathBuilder.appendLiteral(ROOTS_DIR_PATH);
            break :block pathBuilder.append(rootName);
        };

        const cwd = Dir.cwd();

        if (destPath == null) {
            return deleteDirWithConfirm(
                io,
                stdin,
                stdout,
                rootPath,
                .{"Root is not empty. Delete it [y/n]? "},
            ) catch |err| switch (err) {
                DeleteDirWithConfirmError.DeleteFail => Error.DeleteRootFail,
                else => err,
            };
        }

        const destAbsPath = block: {
            try checkRootDest(destPath.?);
            break :block pathBuilder.append(destPath.?);
        };

        const fileKind = (cwd.statFile(
            io,
            destAbsPath,
            .{ .follow_symlinks = true },
        ) catch return Error.StatFileFail).kind;

        return switch (fileKind) {
            .file => cwd.deleteFile(io, destAbsPath) catch Error.DeleteFileFail,
            .directory => deleteDirWithConfirm(
                io,
                stdin,
                stdout,
                destAbsPath,
                .{ "'", destAbsPath, "' is a non-empty dir. Delete it [y/n]? " },
            ) catch |err| switch (err) {
                DeleteDirWithConfirmError.DeleteFail => Error.DeleteFileFail,
                else => err,
            },
            else => unreachable,
        };
    }
};
pub const delete = Delete.delete;
pub const DeleteError = Delete.Error;
pub const DeleteArgs = Delete.Args;

const Update = struct {
    const Error = error{
        DestPathAbsolute,

        SymLinkFail,
        SymLinkRootFail,

        GetSrcAbsPathFail,
        ReplaceRootFail,

        /// When a whole root is being updated
        SrcNotDir,
    } || CheckRootNameError || CheckRootDestError;

    const Args = struct {
        root: []const u8,
        newSrc: []const u8,
        dest: []const u8,
    };

    /// Uses `stdin` only for confirmation of directories deletion.
    fn update(
        io: Io,
        env: Environ,
        stdin: *StdIn,
        stdout: *StdOut,
        args: Args,
    ) (Error || Utils.UserPathError)!void {
        const rootName = args.root;
        const srcPath = args.newSrc;
        const destPath = args.dest;

        var pathBuilder = try initUserPathBuilder(env);

        const rootPath = block: {
            try checkRootName(rootName);

            _ = pathBuilder.appendLiteral(ROOTS_DIR_PATH);

            break :block pathBuilder.append(rootName);
        };

        const destAbsPath = block: {
            try checkRootDest(destPath);
            break :block pathBuilder.append(destPath);
        };

        const cwd = Dir.cwd();

        const srcAbsPath = block: {
            if (Utils.isPathAbs(srcPath)) {
                break :block srcPath;
            }

            var buffer: [MAX_PATH_BYTES]u8 = undefined;
            const absPathLen = cwd.realPathFile(
                io,
                srcPath,
                &buffer,
            ) catch return Error.GetSrcAbsPathFail;
            break :block buffer[0..absPathLen];
        };

        if (destAbsPath.len == rootPath.len) {
            return replaceRoot(
                io,
                stdin,
                stdout,
                rootPath,
                srcAbsPath,
            ) catch |err| switch (err) {
                ReplaceRootError.SrcNotDir => Error.SrcNotDir,
                ReplaceRootError.SymLinkFail => Error.SymLinkRootFail,
                else => Error.ReplaceRootFail,
            };
        }

        Utils.symLink(
            io,
            cwd,
            srcAbsPath,
            destAbsPath,
        ) catch return Error.SymLinkFail;
    }

    const ReplaceRootError = error{
        StatSrcFail,
        SrcNotDir,
        SymLinkFail,
    } || DeleteDirWithConfirmError;
    /// Deletes a root at `rootPath` and places a symlink targeting `srcAbsPath` there.
    ///
    /// If the root is not empty, uses `stdin` and `stdout` to confirm deletion.
    inline fn replaceRoot(
        io: Io,
        stdin: *StdIn,
        stdout: *StdOut,
        rootPath: []const u8,
        srcAbsPath: []const u8,
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
            srcAbsPath,
            .{ .follow_symlinks = true },
        ) catch return ReplaceRootError.StatSrcFail).kind;

        if (srcFileKind != .directory) {
            return ReplaceRootError.SrcNotDir;
        }

        // `Utils.symLink` isn't used not to do `stat` on windows twice
        cwd.symLink(
            io,
            srcAbsPath,
            rootPath,
            .{ .is_directory = true },
        ) catch return ReplaceRootError.SymLinkFail;
    }
};
pub const update = Update.update;
pub const UpdateError = Update.Error;
pub const UpdateArgs = Update.Args;

// ---------
// Cmd Utils
// ---------

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

/// Initializes `PathBuilder` with copying the user path there.
/// `result.buffer[0..result.end]` contains the user path.
inline fn initUserPathBuilder(env: Environ) Utils.UserPathError!PathBuilder {
    var pathBuilder: PathBuilder = .init();

    const userPathLen = (try Utils.getUserPath(
        env,
        &pathBuilder.buffer,
    )).len;
    pathBuilder.end = userPathLen;
    return pathBuilder;
}

const CheckRootNameError = error{
    RootNameTooLong,
    RootNameHasSlash,
};
/// Root names cannot be more than `MAX_ROOT_NAME_BYTES` and cannot include slashes (path separators).
fn checkRootName(name: []const u8) CheckRootNameError!void {
    if (name.len > MAX_ROOT_NAME_BYTES) {
        return CheckRootNameError.RootNameTooLong;
    }

    switch (OS) {
        .windows => if (Utils.findStrScalar(
            name,
            '/',
        ) != null or Utils.findStrScalar(
            name,
            '\\',
        ) != null) {
            return CheckRootNameError.RootNameHasSlash;
        },
        else => if (Utils.findStrScalar(name, '/') != null) {
            return CheckRootNameError.RootNameHasSlash;
        },
    }
}

const CheckRootDestError = error{
    DestPathAbsolute,
    DestPathEscapesRoot,
};
/// Checks validity of `destPath` that is relative to a root.
///
/// After calling this function, path to the root and `destPath` can be safely joined.
///
/// Returns an error if `destPath` is absolute or it escapes the root.
///
/// Example of escaping: `/path/to/root` and `./dest/../../` - the resolved dest is `/path/to`.
fn checkRootDest(destPath: []const u8) CheckRootDestError!void {
    if (Utils.isPathAbs(destPath)) {
        @branchHint(.unlikely);

        return CheckRootDestError.DestPathAbsolute;
    }

    // This logic does not resolve and build a new path at all.
    // Instead, it counts components of the resolved `destPath`.
    // If quantity of components is negative, `destPath` escapes the root

    var destPathIterator: PathIterator = .init(destPath);

    var componentsCount: i32 = 0;

    while (destPathIterator.next()) |component| switch (component.len) {
        1 => componentsCount += @intFromBool(component[0] != '.'),
        2 => {
            const isParentDir = component[0] == '.' and component[1] == '.';
            componentsCount -= @intFromBool(isParentDir);
            componentsCount += @intFromBool(!isParentDir);
        },
        else => componentsCount += 1,
    };

    if (componentsCount < 0) {
        return CheckRootDestError.DestPathEscapesRoot;
    }
}

// TODO: 'follow symlinks' flag for 'add' and 'update' commands.
