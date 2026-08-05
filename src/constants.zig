pub const Errors = struct {
    pub const UNKNOWN_CMD = "Unknown command. Use 'ssync --help'.";

    pub const GET_USER_DIR_PATH_FAIL =
        "Failed to get the user dir path.";
};

pub const HELP_TEXT =
    \\commands:
    \\  list                           List the created roots and paths to them in the system.
    \\  add [root, source, dest]       'root' is name of a root folder to copy 'source' file to. Root is created if does not exit.
    \\                                 'source' is path to a file in the system which is to be copied to 'dest'.
    \\                                 'dest' is a path relative to 'root' to copy 'source' to.
    \\  delete [root, ?file]           If file specified, delete the 'file' in 'root'.
    \\                                 If only 'root' specified, delete the whole root (prompt is shown for safety).
    \\  update [root, newSource, dest] Make 'dest' in 'root' track 'newSource' instead of the current.
;
