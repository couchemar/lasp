const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const reportError = diagnostics.reportError;
/// Reads entire file into arena-allocated buffer.
/// Returns the file content as a byte slice.
/// Prints descriptive error messages to stderr for FileNotFound and AccessDenied.
pub fn readSourceFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                reportError("file not found: {s}", .{path});
                return err;
            },
            error.AccessDenied => {
                reportError("access denied: {s}", .{path});
                return err;
            },
            else => return err,
        }
    };
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    return file_reader.interface.allocRemaining(allocator, .unlimited);
}
/// Reads the target source: stdin when the path is `-`, else the file. Kept
/// as a helper because the read moved out of the shared pre-dispatch step into
/// the query and single-file parse arms (parse-dir never reads its target).
pub fn readSourceOrStdin(io: std.Io, allocator: std.mem.Allocator, target_path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, target_path, "-")) {
        var stdin_buffer: [4096]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
        return try stdin_reader.interface.allocRemaining(allocator, .unlimited);
    }
    return readSourceFile(io, allocator, target_path);
}
