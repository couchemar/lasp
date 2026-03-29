const std = @import("std");
pub const cli = @import("cli/args.zig");
pub const tokenizer = @import("parser/tokenizer.zig");
pub const json = @import("output/json.zig");

/// Reads entire file into arena-allocated buffer.
/// Returns the file content as a byte slice.
/// Prints descriptive error messages to stderr for FileNotFound and AccessDenied.
fn readSourceFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                std.debug.print("error: file not found: {s}\n", .{path});
                return err;
            },
            error.AccessDenied => {
                std.debug.print("error: access denied: {s}\n", .{path});
                return err;
            },
            else => return err,
        }
    };
    defer file.close();

    return file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

/// Reads a keyword file (one keyword per line) and returns a slice of keyword strings.
/// Uses the provided allocator for all allocations. Trims empty lines.
fn loadKeywordFile(allocator: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    const content = try readSourceFile(allocator, path);
    var keywords: std.ArrayList([]const u8) = .empty;
    var iter = std.mem.tokenizeScalar(u8, content, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            try keywords.append(allocator, trimmed);
        }
    }
    return keywords.toOwnedSlice(allocator);
}

pub fn main() void {}

test {
    std.testing.refAllDeclsRecursive(@This());
}

test {
    // Pull in tests from all modules.
    _ = cli;
    _ = tokenizer;
}

test "readSourceFile returns file contents" {
    const allocator = std.testing.allocator;
    // Read this file itself as a basic smoke test
    const content = try readSourceFile(allocator, "src/main.zig");
    defer allocator.free(content);
    try std.testing.expect(content.len > 0);
    // The file should start with "const std"
    try std.testing.expect(std.mem.startsWith(u8, content, "const std"));
}

test "readSourceFile returns FileNotFound for missing file" {
    const allocator = std.testing.allocator;
    const result = readSourceFile(allocator, "nonexistent_file_that_does_not_exist.txt");
    try std.testing.expectError(error.FileNotFound, result);
}

test "loadKeywordFile loads keywords from file" {
    // Use arena since loadKeywordFile internally allocates file content
    // that isn't returned — mirrors real usage in main()
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Write a temp keyword file
    const tmp = try std.fs.cwd().createFile("test_keywords.txt", .{});
    defer std.fs.cwd().deleteFile("test_keywords.txt") catch {};
    try tmp.writeAll("fn\nstruct\nuse\npub\n\nconst\n");
    tmp.close();

    const keywords = try loadKeywordFile(allocator, "test_keywords.txt");

    try std.testing.expectEqual(@as(usize, 5), keywords.len);
    try std.testing.expectEqualStrings("fn", keywords[0]);
    try std.testing.expectEqualStrings("struct", keywords[1]);
    try std.testing.expectEqualStrings("use", keywords[2]);
    try std.testing.expectEqualStrings("pub", keywords[3]);
    try std.testing.expectEqualStrings("const", keywords[4]);
}

const minish = @import("minish");
const gen = minish.gen;

// Feature: phase1-tokenizer-cli, Property 4: File read round trip
test "property: file read round trip" {
    const bytes_gen = gen.string(.{ .min_len = 0, .max_len = 256, .charset = .alphanumeric });

    try minish.check(std.testing.allocator, bytes_gen, struct {
        fn prop(data: []const u8) !void {
            const tmp_path = "test_prop4_roundtrip.tmp";

            // Write random bytes to temp file
            const file = try std.fs.cwd().createFile(tmp_path, .{});
            try file.writeAll(data);
            file.close();
            defer std.fs.cwd().deleteFile(tmp_path) catch {};

            // Read back with readSourceFile
            const content = try readSourceFile(std.testing.allocator, tmp_path);
            defer std.testing.allocator.free(content);

            // Round trip: content must equal original data
            try std.testing.expectEqualSlices(u8, data, content);
        }
    }.prop, .{ .num_runs = 100 });
}
