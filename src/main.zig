pub const cli = @import("cli/args.zig");

pub fn main() void {}

test {
    @import("std").testing.refAllDeclsRecursive(@This());
}

test {
    // Pull in tests from all modules.
    _ = cli;
}
