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

pub fn main() !void {
    // 1. Set up arena allocator
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 2. Collect CLI args (skip binary name)
    var arg_list: std.ArrayList([]const u8) = .empty;
    var args_iter = std.process.args();
    _ = args_iter.next(); // skip binary name
    while (args_iter.next()) |arg| {
        try arg_list.append(allocator, arg);
    }

    // 3. Parse CLI args
    const parsed = cli.parseArgs(arg_list.items) catch |err| {
        std.process.fatal("{s}", .{cli.formatCliError(err)});
    };

    // 4. Read source file
    const source = readSourceFile(allocator, parsed.target_path) catch {
        // readSourceFile already printed the error to stderr
        std.process.fatal("failed to read file: {s}", .{parsed.target_path});
    };

    // 5. Load keyword table if --grammar provided
    const keywords: ?[]const []const u8 = if (parsed.grammar_path) |gp|
        loadKeywordFile(allocator, gp) catch {
            std.process.fatal("failed to load grammar file: {s}", .{gp});
        }
    else
        null;

    // 6. Tokenize
    const tokens = try tokenizer.tokenize(source, keywords, allocator);

    // 7. Serialize to JSON on stdout
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try json.serializeTokens(tokens, stdout);
    try stdout.writeAll("\n");
    try stdout.flush();
}

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

// --- Integration Tests ---

fn runLasp(allocator: std.mem.Allocator, args: []const []const u8) !struct { stdout: []u8, stderr: []u8, term: std.process.Child.Term } {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "zig-out/bin/lasp");
    for (args) |a| try argv.append(allocator, a);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var stdout_buf: std.ArrayList(u8) = .empty;
    var stderr_buf: std.ArrayList(u8) = .empty;
    try child.collectOutput(allocator, &stdout_buf, &stderr_buf, 1024 * 1024);
    const term = try child.wait();

    // collectOutput manages the ArrayList buffers; extract owned slices
    const stdout_slice = try allocator.dupe(u8, stdout_buf.items);
    const stderr_slice = try allocator.dupe(u8, stderr_buf.items);
    stdout_buf.deinit(allocator);
    stderr_buf.deinit(allocator);

    return .{ .stdout = stdout_slice, .stderr = stderr_slice, .term = term };
}

test "integration: parse produces valid JSON with expected token types" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);

    // Verify it's valid JSON with "events" array
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const events = parsed.value.object.get("events").?;
    try std.testing.expect(events.array.items.len > 0);

    // Check that we get identifier tokens (sample.zig has identifiers)
    var has_identifier = false;
    for (events.array.items) |event| {
        const typ = event.object.get("type").?.string;
        if (std.mem.eql(u8, typ, "identifier")) has_identifier = true;
    }
    try std.testing.expect(has_identifier);
}

test "integration: parse with --grammar produces keyword tokens" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--grammar", "tests/fixtures/keywords.txt" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const events = parsed.value.object.get("events").?;

    // With keywords.txt containing "const", "pub", "fn", "return",
    // we should see keyword tokens
    var has_keyword = false;
    for (events.array.items) |event| {
        const typ = event.object.get("type").?.string;
        if (std.mem.eql(u8, typ, "keyword")) has_keyword = true;
    }
    try std.testing.expect(has_keyword);
}

test "integration: parse nonexistent file exits non-zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "nonexistent.zig" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should exit with non-zero
    switch (result.term) {
        .Exited => |code| try std.testing.expect(code != 0),
        else => {}, // Signal/other termination is also non-zero
    }
    // Stderr should contain error message
    try std.testing.expect(result.stderr.len > 0);
}

test "integration: no args prints usage and exits non-zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should exit with non-zero
    switch (result.term) {
        .Exited => |code| try std.testing.expect(code != 0),
        else => {},
    }
    // Stderr should contain error/usage message
    try std.testing.expect(result.stderr.len > 0);
}
