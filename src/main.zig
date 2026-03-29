const std = @import("std");
pub const cli = @import("cli/args.zig");
pub const tokenizer = @import("parser/tokenizer.zig");
pub const json = @import("output/json.zig");
pub const grammar_loader = @import("grammar/loader.zig");
pub const grammar_compiler = @import("grammar/compiler.zig");
pub const events = @import("parser/events.zig");
pub const engine = @import("parser/engine.zig");

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
        std.process.fatal("failed to read file: {s}", .{parsed.target_path});
    };

    // 5. Stdout setup
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    // 6. Dispatch based on grammar
    if (parsed.grammar_path) |gp| {
        // Phase 2: TOML grammar → structural events
        const grammar_source = readSourceFile(allocator, gp) catch {
            std.process.fatal("failed to read grammar file: {s}", .{gp});
        };
        const grammar = grammar_loader.parseGrammar(grammar_source, allocator) catch |err| {
            const msg: []const u8 = switch (err) {
                error.InvalidToml => "invalid TOML syntax in grammar file",
                error.MissingPatterns => "grammar file missing required [[patterns]] section",
                error.EmptyPatternSequence => "pattern has empty sequence",
                error.InvalidCaptureFormat => "invalid capture format, expected $name:IDENTIFIER",
                error.OutOfMemory => "out of memory",
                else => "unknown grammar error",
            };
            std.process.fatal("error: {s}: {s}", .{ msg, gp });
        };
        const automaton = try grammar_compiler.compile(grammar.patterns, allocator);
        const tokens = try tokenizer.tokenize(source, grammar.keyword_table, allocator);
        const structural_events = try engine.parse(automaton, tokens, source, grammar.patterns, allocator);
        try json.serializeEvents(structural_events, stdout);
    } else {
        // No grammar: raw token output
        const tokens = try tokenizer.tokenize(source, null, allocator);
        try json.serializeTokens(tokens, stdout);
    }

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
    const json_events = parsed.value.object.get("events").?;
    try std.testing.expect(json_events.array.items.len > 0);

    // Check that we get identifier tokens (sample.zig has identifiers)
    var has_identifier = false;
    for (json_events.array.items) |event| {
        const typ = event.object.get("type").?.string;
        if (std.mem.eql(u8, typ, "identifier")) has_identifier = true;
    }
    try std.testing.expect(has_identifier);
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

    switch (result.term) {
        .Exited => |code| try std.testing.expect(code != 0),
        else => {},
    }
    try std.testing.expect(result.stderr.len > 0);
}

test "integration: parse with TOML grammar produces structural events" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--grammar", "tests/fixtures/grammars/zig.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;
    try std.testing.expect(json_events.array.items.len > 0);

    // Should have structural events with "confidence" field
    var has_function = false;
    for (json_events.array.items) |event| {
        const typ = event.object.get("type").?.string;
        try std.testing.expect(event.object.get("confidence") != null);
        if (std.mem.eql(u8, typ, "function")) has_function = true;
    }
    try std.testing.expect(has_function);
}

test "integration: parse without grammar produces raw tokens" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;
    try std.testing.expect(json_events.array.items.len > 0);

    // Raw tokens have "type" but no "confidence"
    const first = json_events.array.items[0].object;
    try std.testing.expect(first.get("type") != null);
    try std.testing.expect(first.get("confidence") == null);
}

test "integration: nonexistent grammar file exits non-zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--grammar", "nonexistent.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| try std.testing.expect(code != 0),
        else => {},
    }
    try std.testing.expect(result.stderr.len > 0);
}

test "integration: malformed grammar file exits non-zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--grammar", "tests/fixtures/grammars/malformed.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| try std.testing.expect(code != 0),
        else => {},
    }
    try std.testing.expect(result.stderr.len > 0);
}
