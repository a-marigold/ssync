const std = @import("std");
const testing = std.testing;

const Utils = @import("../Utils.zig");
const Cmd = @import("../Cmd.zig");

test {
    testing.refAllDecls(@This());
}
