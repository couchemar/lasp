const std = @import("std");
pub const cli = @import("cli/args.zig");
pub const tokenizer = @import("parser/tokenizer.zig");
pub const json = @import("output/json.zig");
pub const grammar_loader = @import("grammar/loader.zig");
pub const grammar_compiler = @import("grammar/compiler.zig");
pub const events = @import("parser/events.zig");
pub const engine = @import("parser/engine.zig");
pub const query_filter = @import("query/filter.zig");
pub const query_parser = @import("query/parser.zig");
pub const query_evaluator = @import("query/evaluator.zig");
const build_options = @import("build_options");

/// Reads entire file into arena-allocated buffer.
/// Returns the file content as a byte slice.
/// Prints descriptive error messages to stderr for FileNotFound and AccessDenied.
fn readSourceFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
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
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    return file_reader.interface.allocRemaining(allocator, .unlimited);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // 1. Set up arena allocator
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 2. Collect CLI args (skip binary name)
    var arg_list: std.ArrayList([]const u8) = .empty;
    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip binary name
    while (args_iter.next()) |arg| {
        try arg_list.append(allocator, arg);
    }

    // 3. Parse CLI args
    const parsed = cli.parseArgs(arg_list.items) catch |err| {
        std.process.fatal("{s}", .{cli.formatCliError(err)});
    };

    // 4. Stdout setup
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    // 4.5 Help report: exits before version and before any file I/O (Req 3, 6).
    if (parsed.command == .help) {
        try stdout.writeAll(cli.helpText(parsed.help_topic));
        try stdout.flush();
        return;
    }

    // 5. Version report: exits before any file I/O
    if (parsed.command == .version) {
        try stdout.print("lasp {s}\n", .{build_options.version});
        try stdout.flush();
        return;
    }

    // 6. Read source file or stdin
    const source = blk: {
        if (std.mem.eql(u8, parsed.target_path, "-")) {
            var stdin_buffer: [4096]u8 = undefined;
            var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
            break :blk try stdin_reader.interface.allocRemaining(allocator, .unlimited);
        } else {
            break :blk readSourceFile(io, allocator, parsed.target_path) catch {
                std.process.fatal("failed to read file: {s}", .{parsed.target_path});
            };
        }
    };

    // 7. Dispatch based on command
    switch (parsed.command) {
        .query => {
            // Query command always requires grammar
            const gp = parsed.grammar_path orelse {
                std.process.fatal("error: query command requires --grammar/-g flag", .{});
            };

            // Parse grammar, compile automaton, tokenize, run engine
            const grammar_source = readSourceFile(io, allocator, gp) catch {
                std.process.fatal("failed to read grammar file: {s}", .{gp});
            };
            const grammar = grammar_loader.parseGrammar(grammar_source, allocator) catch |err| {
                const msg: []const u8 = switch (err) {
                    error.InvalidToml => "invalid TOML syntax in grammar file",
                    error.MissingPatterns => "grammar file missing required [[patterns]] section",
                    error.EmptyPatternSequence => "pattern has empty sequence",
                    error.InvalidCaptureFormat => "invalid capture format, expected $name:IDENTIFIER",
                    error.InvalidPositionValue => "invalid position value, expected 'start'",
                    error.InvalidWeightValue => "invalid weight value, weights must be non-negative",
                    error.InvalidConstraintType => "invalid constraint type",
                    error.InvalidConstraintDepth => "invalid constraint depth",
                    error.InvalidConstraintField => "invalid constraint field",
                    error.InvalidConstraintValues => "invalid constraint values",
                    error.DeprecatedField => "deprecated field (exclude/not_preceded_by), use [[patterns.constraints]] instead",
                    error.InvalidCommentLineType => "error: [comments] line must be an array of strings",
                    error.InvalidCommentBlockType => "error: [comments] block_open/block_close must be strings",
                    error.UnpairedBlockDelimiter => "error: [comments] block_open and block_close must both be present or both absent",
                    error.CommentPrefixTooLong => "error: [comments] line prefix too long (max 8 characters)",
                    error.TooManyLinePrefixes => "error: [comments] too many line prefixes (max 16)",
                    error.BlockDelimiterTooLong => "error: [comments] block delimiter too long (max 8 characters)",
                    error.OutOfMemory => "out of memory",
                    else => "unknown grammar error",
                };
                std.process.fatal("error: {s}: {s}", .{ msg, gp });
            };
            const automaton = try grammar_compiler.compile(grammar.patterns, allocator);
            const tokens = try tokenizer.tokenize(source, grammar.keyword_table, grammar.comments, allocator);
            const structural_events = try engine.parse(automaton, tokens, source, grammar.patterns, grammar.blocks, grammar.weights, allocator);

            // Parse selector string into QueryFilter
            const selector = parsed.query_selector orelse {
                std.process.fatal("error: query command requires a selector string", .{});
            };
            const filter = query_parser.parse(selector, allocator) catch |err| {
                const msg: []const u8 = switch (err) {
                    error.EmptySelector => "error: empty selector string",
                    error.UnclosedBracket => "error: unclosed bracket in selector",
                    error.MissingFieldName => "error: missing field name in attribute condition",
                    error.MissingOperator => "error: missing or invalid operator in attribute condition",
                    error.MissingValue => "error: missing value in attribute condition",
                    error.UnclosedQuote => "error: unclosed quote in attribute value",
                    error.InvalidOperator => "error: invalid operator, expected '=', '!=', or '>'",
                    error.InvalidNumericValue => "error: invalid numeric value for '>' operator",
                    error.UnexpectedCharacter => "error: unexpected character in selector",
                    error.OutOfMemory => "error: out of memory",
                };
                std.process.fatal("{s}", .{msg});
            };

            // Evaluate filter against structural events
            const filtered = try query_evaluator.evaluate(structural_events, filter, allocator);

            // Output: names-only or JSON
            if (parsed.names_only) {
                for (filtered) |event| {
                    if (event.captures.len > 0) {
                        try stdout.writeAll(event.captures[0].value);
                        try stdout.writeAll("\n");
                    }
                }
            } else {
                try json.serializeEvents(filtered, stdout);
            }
        },
        .parse, .parse_dir => {
            if (parsed.grammar_path) |gp| {
                // Phase 2: TOML grammar → structural events
                const grammar_source = readSourceFile(io, allocator, gp) catch {
                    std.process.fatal("failed to read grammar file: {s}", .{gp});
                };
                const grammar = grammar_loader.parseGrammar(grammar_source, allocator) catch |err| {
                    const msg: []const u8 = switch (err) {
                        error.InvalidToml => "invalid TOML syntax in grammar file",
                        error.MissingPatterns => "grammar file missing required [[patterns]] section",
                        error.EmptyPatternSequence => "pattern has empty sequence",
                        error.InvalidCaptureFormat => "invalid capture format, expected $name:IDENTIFIER",
                        error.InvalidPositionValue => "invalid position value, expected 'start'",
                        error.InvalidWeightValue => "invalid weight value, weights must be non-negative",
                        error.InvalidConstraintType => "invalid constraint type",
                        error.InvalidConstraintDepth => "invalid constraint depth",
                        error.InvalidConstraintField => "invalid constraint field",
                        error.InvalidConstraintValues => "invalid constraint values",
                        error.DeprecatedField => "deprecated field (exclude/not_preceded_by), use [[patterns.constraints]] instead",
                        error.InvalidCommentLineType => "error: [comments] line must be an array of strings",
                        error.InvalidCommentBlockType => "error: [comments] block_open/block_close must be strings",
                        error.UnpairedBlockDelimiter => "error: [comments] block_open and block_close must both be present or both absent",
                        error.CommentPrefixTooLong => "error: [comments] line prefix too long (max 8 characters)",
                        error.TooManyLinePrefixes => "error: [comments] too many line prefixes (max 16)",
                        error.BlockDelimiterTooLong => "error: [comments] block delimiter too long (max 8 characters)",
                        error.OutOfMemory => "out of memory",
                        else => "unknown grammar error",
                    };
                    std.process.fatal("error: {s}: {s}", .{ msg, gp });
                };
                const automaton = try grammar_compiler.compile(grammar.patterns, allocator);
                const tokens = try tokenizer.tokenize(source, grammar.keyword_table, grammar.comments, allocator);
                var structural_events = try engine.parse(automaton, tokens, source, grammar.patterns, grammar.blocks, grammar.weights, allocator);

                // Apply node filter if specified
                if (parsed.node_filter) |filter| {
                    var filtered_events: std.ArrayList(events.StructuralEvent) = .empty;
                    defer filtered_events.deinit(allocator);
                    for (structural_events) |event| {
                        if (std.ascii.eqlIgnoreCase(event.type_name, filter)) {
                            try filtered_events.append(allocator, event);
                        }
                    }
                    structural_events = try filtered_events.toOwnedSlice(allocator);
                }

                // Output dispatch: names-only or JSON
                if (parsed.names_only) {
                    for (structural_events) |event| {
                        if (event.captures.len > 0) {
                            try stdout.writeAll(event.captures[0].value);
                            try stdout.writeAll("\n");
                        }
                    }
                } else {
                    try json.serializeEvents(structural_events, stdout);
                }
            } else {
                // No grammar: raw token output
                const tokens = try tokenizer.tokenize(source, null, .{}, allocator);
                try json.serializeTokens(tokens, stdout);
            }
        },
        .version => unreachable,
        .help => unreachable,
    }

    if (!parsed.names_only) try stdout.writeAll("\n");
    try stdout.flush();
}

test {
    std.testing.refAllDecls(@This());
}

test {
    // Pull in tests from all modules.
    _ = cli;
    _ = tokenizer;
}

test "readSourceFile returns file contents" {
    const allocator = std.testing.allocator;
    // Read this file itself as a basic smoke test
    const content = try readSourceFile(std.testing.io, allocator, "src/main.zig");
    defer allocator.free(content);
    try std.testing.expect(content.len > 0);
    // The file should start with "const std"
    try std.testing.expect(std.mem.startsWith(u8, content, "const std"));
}

test "readSourceFile returns FileNotFound for missing file" {
    const allocator = std.testing.allocator;
    const result = readSourceFile(std.testing.io, allocator, "nonexistent_file_that_does_not_exist.txt");
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
            const io = std.testing.io;
            const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
            var wbuf: [256]u8 = undefined;
            var writer = file.writer(io, &wbuf);
            try writer.interface.writeAll(data);
            try writer.interface.flush();
            file.close(io);
            defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

            // Read back with readSourceFile
            const content = try readSourceFile(std.testing.io, std.testing.allocator, tmp_path);
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

    const result = try std.process.run(allocator, std.testing.io, .{ .argv = argv.items });
    return .{ .stdout = result.stdout, .stderr = result.stderr, .term = result.term };
}

test "integration: parse produces valid JSON with expected token types" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
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
        .exited => |code| try std.testing.expect(code != 0),
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
        .exited => |code| try std.testing.expect(code != 0),
        else => {},
    }
    try std.testing.expect(result.stderr.len > 0);
}

test "integration: --version prints version and exits zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{"--version"});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "lasp "));
}

// --- Integration Tests for CLI Help Text Feature ---

test "integration: help command prints usage and exits zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{"help"});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    // Should contain basic help text
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "Usage:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "lasp - Language-Agnostic Structural Parser"));
}

test "integration: --help flag prints usage and exits zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{"--help"});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "Usage:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "lasp - Language-Agnostic Structural Parser"));
}

test "integration: -h flag prints usage and exits zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{"-h"});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "Usage:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "lasp - Language-Agnostic Structural Parser"));
}

test "integration: parse --help prints parse-specific help and exits zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "--help" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    // Should contain parse-specific help
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "lasp parse - parse a single file"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "<file|->"));
}

test "integration: parse -h prints parse-specific help and exits zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "-h" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "lasp parse - parse a single file"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "<file|->"));
}

test "integration: query --help prints query-specific help and exits zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "query", "--help" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    // Should contain query-specific help
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "lasp query - filter structural events"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "<selector>"));
}

test "integration: parse-dir --help prints parse-dir-specific help and exits zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse-dir", "--help" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    // Should contain parse-dir-specific help
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "lasp parse-dir - parse all files in a directory"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "<dir>"));
}

test "integration: query -h prints query-specific help and exits zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "query", "-h" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    // Should contain query-specific help
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "lasp query - filter structural events"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "<selector>"));
}

test "integration: parse-dir -h prints parse-dir-specific help and exits zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse-dir", "-h" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    // Should contain parse-dir-specific help
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "lasp parse-dir - parse all files in a directory"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "<dir>"));
}

test "integration: help with invalid files/grammar prints usage and exits zero (no file error)" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "nonexistent.zig", "-g", "nope.toml", "--help" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    // Should contain help text
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "Usage:"));
    // Should NOT contain file/grammar error messages on stderr
    try std.testing.expect(result.stderr.len == 0);
}

test "integration: help takes precedence over version (--help --version)" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "--help", "--version" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    // Should be help text, not version
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "Usage:"));
    // Help text starts with "lasp - Language-Agnostic Structural Parser", not "lasp 0.2.0"
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "lasp - Language-Agnostic Structural Parser"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result.stdout, 1, "lasp 0.2.0"));
}

test "integration: help takes precedence over version (--version --help)" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "--version", "--help" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    // Should be help text, not version
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "Usage:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "lasp - Language-Agnostic Structural Parser"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result.stdout, 1, "lasp 0.2.0"));
}

test "integration: help with stdin short-circuits before reading stdin" {
    const allocator = std.testing.allocator;
    const source = "fn add() void {}\n"; // Some valid code

    const result = try runLaspWithStdin(allocator, &.{ "parse", "-", "--help" }, source);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    // Should contain help text, not parse output
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "Usage:"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result.stdout, 1, "\"type\": \"function\""));
}

test "integration: parse with TOML grammar produces structural events" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--grammar", "tests/fixtures/grammars/zig.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

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

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

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
        .exited => |code| try std.testing.expect(code != 0),
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
        .exited => |code| try std.testing.expect(code != 0),
        else => {},
    }
    try std.testing.expect(result.stderr.len > 0);
}

// --- Phase 3 Integration Tests ---

test "integration: structural events include col field" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--grammar", "tests/fixtures/grammars/zig.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    for (json_events.array.items) |event| {
        // Every structural event must have a "col" field
        try std.testing.expect(event.object.get("col") != null);
    }
}

test "integration: raw token events include col field" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    for (json_events.array.items) |event| {
        try std.testing.expect(event.object.get("col") != null);
    }
}

test "integration: Erlang grammar with position filtering" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.erl", "--grammar", "examples/grammars/erlang.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;
    try std.testing.expect(json_events.array.items.len > 0);

    // All events should have col field
    for (json_events.array.items) |event| {
        try std.testing.expect(event.object.get("col") != null);
    }
}

test "integration: invalid position value exits non-zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--grammar", "tests/fixtures/grammars/invalid_position.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| try std.testing.expect(code != 0),
        else => {},
    }
    try std.testing.expect(result.stderr.len > 0);
}

// Feature: composable-cli-primitives, Property 3: Node filter correctness
test "property: node filter correctness" {
    // Helper to create a StructuralEvent
    const createEvent = struct {
        fn create(allocator: std.mem.Allocator, type_name: []const u8, captures_len: usize) !events.StructuralEvent {
            var captures: []const events.CaptureEntry = &[_]events.CaptureEntry{};
            if (captures_len > 0) {
                const caps = try allocator.alloc(events.CaptureEntry, captures_len);
                for (caps) |*cap| {
                    cap.* = .{ .field_name = "name", .value = "test" };
                }
                captures = caps;
            }
            return .{
                .type_name = type_name,
                .captures = captures,
                .start = 0,
                .end = 10,
                .line = 1,
                .col = 0,
                .confidence = 1.0,
            };
        }
    }.create;

    // Generate random events with random type names
    const type_name_gen = gen.string(.{ .min_len = 1, .max_len = 16, .charset = .alphanumeric });

    try minish.check(std.testing.allocator, type_name_gen, struct {
        fn prop(type_name: []const u8) !void {
            const allocator = std.testing.allocator;
            const num_events = 5;

            // Create events with the same type name
            var events_list: std.ArrayList(events.StructuralEvent) = .empty;
            defer {
                for (events_list.items) |e| {
                    allocator.free(e.captures);
                }
                events_list.deinit(allocator);
            }

            var i: usize = 0;
            while (i < num_events) : (i += 1) {
                const event = try createEvent(allocator, type_name, 0);
                try events_list.append(allocator, event);
            }

            // Apply filter (case-insensitive)
            const filter = type_name;
            var filtered: std.ArrayList(events.StructuralEvent) = .empty;
            defer {
                for (filtered.items) |e| {
                    allocator.free(e.captures);
                }
                filtered.deinit(allocator);
            }

            for (events_list.items) |event| {
                if (std.ascii.eqlIgnoreCase(event.type_name, filter)) {
                    try filtered.append(allocator, event);
                }
            }

            // All events should match
            try std.testing.expectEqual(events_list.items.len, filtered.items.len);
        }
    }.prop, .{ .num_runs = 100 });

    // Test that non-matching filter returns empty
    try minish.check(std.testing.allocator, type_name_gen, struct {
        fn prop(type_name: []const u8) !void {
            const allocator = std.testing.allocator;
            const num_events = 5;

            var events_list: std.ArrayList(events.StructuralEvent) = .empty;
            defer {
                for (events_list.items) |e| {
                    allocator.free(e.captures);
                }
                events_list.deinit(allocator);
            }

            var i: usize = 0;
            while (i < num_events) : (i += 1) {
                const event = try createEvent(allocator, type_name, 0);
                try events_list.append(allocator, event);
            }

            // Apply non-matching filter
            const filter = "call";
            var filtered: std.ArrayList(events.StructuralEvent) = .empty;
            defer {
                for (filtered.items) |e| {
                    allocator.free(e.captures);
                }
                filtered.deinit(allocator);
            }

            for (events_list.items) |event| {
                if (std.ascii.eqlIgnoreCase(event.type_name, filter)) {
                    try filtered.append(allocator, event);
                }
            }

            // No events should match
            try std.testing.expectEqual(@as(usize, 0), filtered.items.len);
        }
    }.prop, .{ .num_runs = 100 });

    // Test case-insensitive matching
    try minish.check(std.testing.allocator, type_name_gen, struct {
        fn prop(type_name: []const u8) !void {
            const allocator = std.testing.allocator;
            const event = try createEvent(allocator, type_name, 0);
            defer allocator.free(event.captures);

            // Test that eqlIgnoreCase works with same case
            const matches_same = std.ascii.eqlIgnoreCase(event.type_name, type_name);
            try std.testing.expect(matches_same);

            // Test with uppercase version of the same string
            if (type_name.len > 0) {
                var upper_type_name = try allocator.alloc(u8, type_name.len);
                defer allocator.free(upper_type_name);
                for (type_name, 0..) |c, i| {
                    upper_type_name[i] = std.ascii.toUpper(c);
                }
                const matches_upper = std.ascii.eqlIgnoreCase(event.type_name, upper_type_name);
                try std.testing.expect(matches_upper);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: composable-cli-primitives, Property 4: Names-only output correctness
test "property: names-only output correctness" {
    // Helper to create a StructuralEvent with captures
    const createEventWithCaptures = struct {
        fn create(allocator: std.mem.Allocator, type_name: []const u8, capture_value: []const u8) !events.StructuralEvent {
            const captures = try allocator.alloc(events.CaptureEntry, 1);
            captures[0] = .{ .field_name = "name", .value = capture_value };
            return .{
                .type_name = type_name,
                .captures = captures,
                .start = 0,
                .end = 10,
                .line = 1,
                .col = 0,
                .confidence = 1.0,
            };
        }
    }.create;

    // Helper to create a StructuralEvent without captures
    const createEventNoCaptures = struct {
        fn create(_: std.mem.Allocator, type_name: []const u8) !events.StructuralEvent {
            return .{
                .type_name = type_name,
                .captures = &[_]events.CaptureEntry{},
                .start = 0,
                .end = 10,
                .line = 1,
                .col = 0,
                .confidence = 1.0,
            };
        }
    }.create;

    // Generate random capture values
    const value_gen = gen.string(.{ .min_len = 1, .max_len = 16, .charset = .alphanumeric });

    // Test: names-only output produces one line per event with captures
    try minish.check(std.testing.allocator, value_gen, struct {
        fn prop(capture_value: []const u8) !void {
            const allocator = std.testing.allocator;

            // Create events: some with captures, some without
            var events_list: std.ArrayList(events.StructuralEvent) = .empty;
            defer {
                for (events_list.items) |e| {
                    allocator.free(e.captures);
                }
                events_list.deinit(allocator);
            }

            // Add event with captures
            const event_with = try createEventWithCaptures(allocator, "function", capture_value);
            try events_list.append(allocator, event_with);

            // Add event without captures
            const event_without = try createEventNoCaptures(allocator, "function");
            try events_list.append(allocator, event_without);

            // Simulate names-only output - count lines and verify content
            var line_count: usize = 0;
            var first_capture_value: ?[]const u8 = null;
            for (events_list.items) |event| {
                if (event.captures.len > 0) {
                    line_count += 1;
                    if (first_capture_value == null) {
                        first_capture_value = event.captures[0].value;
                    }
                }
            }

            // Should have exactly one line (one event with captures)
            try std.testing.expectEqual(@as(usize, 1), line_count);
            try std.testing.expectEqualStrings(capture_value, first_capture_value.?);
        }
    }.prop, .{ .num_runs = 100 });

    // Test: all events with captures produces output lines equal to event count
    try minish.check(std.testing.allocator, value_gen, struct {
        fn prop(capture_value: []const u8) !void {
            const allocator = std.testing.allocator;
            const num_events = 3;

            var events_list: std.ArrayList(events.StructuralEvent) = .empty;
            defer {
                for (events_list.items) |e| {
                    allocator.free(e.captures);
                }
                events_list.deinit(allocator);
            }

            // Add events with captures
            var i: usize = 0;
            while (i < num_events) : (i += 1) {
                const event = try createEventWithCaptures(allocator, "function", capture_value);
                try events_list.append(allocator, event);
            }

            // Simulate names-only output - count lines
            var line_count: usize = 0;
            for (events_list.items) |event| {
                if (event.captures.len > 0) {
                    line_count += 1;
                    try std.testing.expectEqualStrings(capture_value, event.captures[0].value);
                }
            }

            // Should have exactly num_events lines
            try std.testing.expectEqual(num_events, line_count);
        }
    }.prop, .{ .num_runs = 100 });

    // Test: events without captures produce no output
    try minish.check(std.testing.allocator, value_gen, struct {
        fn prop(_: []const u8) !void {
            const allocator = std.testing.allocator;

            var events_list: std.ArrayList(events.StructuralEvent) = .empty;
            defer {
                for (events_list.items) |e| {
                    allocator.free(e.captures);
                }
                events_list.deinit(allocator);
            }

            // Add events without captures
            var i: usize = 0;
            while (i < 5) : (i += 1) {
                const event = try createEventNoCaptures(allocator, "function");
                try events_list.append(allocator, event);
            }

            // Simulate names-only output - count lines
            var line_count: usize = 0;
            for (events_list.items) |event| {
                if (event.captures.len > 0) {
                    line_count += 1;
                }
            }

            // Should have zero lines
            try std.testing.expectEqual(@as(usize, 0), line_count);
        }
    }.prop, .{ .num_runs = 100 });
}

// Helper: run lasp with data piped to stdin
fn runLaspWithStdin(allocator: std.mem.Allocator, args: []const []const u8, stdin_data: []const u8) !struct { stdout: []u8, stderr: []u8, term: std.process.Child.Term } {
    const io = std.testing.io;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "zig-out/bin/lasp");
    for (args) |a| try argv.append(allocator, a);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    // Write stdin data and close the pipe
    if (child.stdin) |stdin_file| {
        var wbuf: [4096]u8 = undefined;
        var writer = stdin_file.writer(io, &wbuf);
        try writer.interface.writeAll(stdin_data);
        try writer.interface.flush();
        stdin_file.close(io);
        child.stdin = null;
    }

    // Collect stdout and stderr concurrently (mirrors std.process.run).
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try multi_reader.checkAnyError();

    const term = try child.wait(io);

    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);

    return .{ .stdout = stdout_slice, .stderr = stderr_slice, .term = term };
}

// --- Integration Tests for Composable CLI Primitives ---

test "integration: stdin pipe support" {
    const allocator = std.testing.allocator;
    const source = "const std = @import(\"std\");\n\npub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n";

    const result = try runLaspWithStdin(allocator, &.{ "parse", "-", "--grammar", "tests/fixtures/grammars/zig.toml" }, source);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;
    try std.testing.expect(json_events.array.items.len > 0);

    // Should have at least one function event
    var has_function = false;
    for (json_events.array.items) |event| {
        const typ = event.object.get("type").?.string;
        if (std.mem.eql(u8, typ, "function")) has_function = true;
    }
    try std.testing.expect(has_function);
}

test "integration: stdin pipe with empty input" {
    const allocator = std.testing.allocator;

    const result = try runLaspWithStdin(allocator, &.{ "parse", "-", "--grammar", "tests/fixtures/grammars/zig.toml" }, "");
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;
    try std.testing.expectEqual(@as(usize, 0), json_events.array.items.len);
}

test "integration: --node filter with grammar" {
    const allocator = std.testing.allocator;

    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--grammar", "tests/fixtures/grammars/zig.toml", "--node", "function" });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    // All events should be of type "function"
    for (json_events.array.items) |event| {
        const typ = event.object.get("type").?.string;
        try std.testing.expect(std.mem.eql(u8, typ, "function"));
    }

    // Should have at least one function event
    try std.testing.expect(json_events.array.items.len > 0);
}

test "integration: --node filter with no grammar (flag ignored)" {
    const allocator = std.testing.allocator;

    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--node", "function" });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    // Should have raw token events (not filtered)
    try std.testing.expect(json_events.array.items.len > 0);

    // Raw tokens don't have "confidence" field
    const first = json_events.array.items[0].object;
    try std.testing.expect(first.get("confidence") == null);
}

test "integration: --names-only with grammar" {
    const allocator = std.testing.allocator;

    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--grammar", "tests/fixtures/grammars/zig.toml", "--names-only" });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    // Should be plain text output, not JSON (should not start with '{')
    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expect(result.stdout[0] != '{');

    // Collect non-empty lines
    var line_count: usize = 0;
    var has_add = false;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) {
            line_count += 1;
            if (std.mem.eql(u8, line, "add")) has_add = true;
        }
    }

    // Should have at least one line and include "add" from the function event
    try std.testing.expect(line_count > 0);
    try std.testing.expect(has_add);
}

test "integration: --names-only with no grammar (flag ignored)" {
    const allocator = std.testing.allocator;

    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--names-only" });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    // Should be JSON output (flag ignored)
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    // Should have raw token events
    try std.testing.expect(json_events.array.items.len > 0);
}

test "integration: combined stdin + --node + --names-only" {
    const allocator = std.testing.allocator;
    const source = "const std = @import(\"std\");\n\npub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n\npub fn sub(x: i32, y: i32) i32 {\n    return x - y;\n}\n";

    const result = try runLaspWithStdin(allocator, &.{ "parse", "-", "--grammar", "tests/fixtures/grammars/zig.toml", "--node", "function", "--names-only" }, source);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    // Should be plain text output with function names
    try std.testing.expect(result.stdout.len > 0);

    // Count lines and verify they contain function names
    var line_count: usize = 0;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) {
            line_count += 1;
            // Should be either "add" or "sub"
            try std.testing.expect(std.mem.eql(u8, line, "add") or std.mem.eql(u8, line, "sub"));
        }
    }

    // Should have 2 function names
    try std.testing.expectEqual(@as(usize, 2), line_count);
}

test "integration: --node filter matching zero events" {
    const allocator = std.testing.allocator;

    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--grammar", "tests/fixtures/grammars/zig.toml", "--node", "nonexistent" });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    // Should have empty events array
    try std.testing.expectEqual(@as(usize, 0), json_events.array.items.len);
}

// --- Integration Tests for Structural Query Command ---

test "integration: query type-only filter returns only function events" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "query", "function", "tests/fixtures/sample.zig", "-g", "tests/fixtures/grammars/zig.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    // sample.zig has 1 function (add) and 1 call (import) — only function should appear
    try std.testing.expect(json_events.array.items.len > 0);
    for (json_events.array.items) |event| {
        const typ = event.object.get("type").?.string;
        try std.testing.expectEqualStrings("function", typ);
    }
}

test "integration: query type + equality returns matching event" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "query", "function[name=\"add\"]", "tests/fixtures/sample.zig", "-g", "tests/fixtures/grammars/zig.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    try std.testing.expectEqual(@as(usize, 1), json_events.array.items.len);
    const event = json_events.array.items[0].object;
    try std.testing.expectEqualStrings("function", event.get("type").?.string);
    try std.testing.expectEqualStrings("add", event.get("name").?.string);
}

test "integration: query wildcard + confidence threshold" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "query", "*[confidence>0.5]", "tests/fixtures/sample.zig", "-g", "tests/fixtures/grammars/zig.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    // All events in sample.zig have confidence 1.0, so all should pass >0.5
    try std.testing.expect(json_events.array.items.len > 0);
    for (json_events.array.items) |event| {
        // Verify confidence field exists
        try std.testing.expect(event.object.get("confidence") != null);
    }
}

test "integration: query with --names-only output" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "query", "function", "tests/fixtures/sample.zig", "-g", "tests/fixtures/grammars/zig.toml", "--names-only" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    // Should be plain text, not JSON
    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expect(result.stdout[0] != '{');

    // Should contain "add" as a line
    var has_add = false;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "add")) has_add = true;
    }
    try std.testing.expect(has_add);
}

test "integration: query stdin pipe support" {
    const allocator = std.testing.allocator;
    const source = "fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n";

    const result = try runLaspWithStdin(allocator, &.{ "query", "function", "-", "-g", "tests/fixtures/grammars/zig.toml" }, source);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    try std.testing.expect(json_events.array.items.len > 0);
    const event = json_events.array.items[0].object;
    try std.testing.expectEqualStrings("function", event.get("type").?.string);
    try std.testing.expectEqualStrings("add", event.get("name").?.string);
}

test "integration: query with no args exits non-zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{"query"});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| try std.testing.expect(code != 0),
        else => {},
    }
    try std.testing.expect(result.stderr.len > 0);
}

test "integration: query without grammar exits non-zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "query", "function", "tests/fixtures/sample.zig" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| try std.testing.expect(code != 0),
        else => {},
    }
    try std.testing.expect(result.stderr.len > 0);
}

test "integration: query nonexistent name returns empty valid JSON" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "query", "function[name=\"nonexistent\"]", "tests/fixtures/sample.zig", "-g", "tests/fixtures/grammars/zig.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    // Should be valid JSON with empty events array
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;
    try std.testing.expectEqual(@as(usize, 0), json_events.array.items.len);
}

// --- Bug Condition Exploration Test (names-only-trailing-newline) ---

// Count lines terminated by '\n' in `out`.
fn newlineTerminatedLineCount(out: []const u8) usize {
    var count: usize = 0;
    for (out) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

// Count non-empty lines in `out` (the `grep -c .` equivalent).
fn nonEmptyLineCount(out: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }
    return count;
}

// Feature: names-only-trailing-newline, Property 1: Bug Condition
// Names-Only Has No Trailing Blank Line.
// CRITICAL: This test MUST FAIL on the current unfixed code — its failure confirms
// the bug (an unconditional end-of-main `writeAll("\n")` adds one extra newline in
// names-only mode). DO NOT fix the code to make it pass; the fix lands in a later task.
test "exploration: names-only output has no trailing blank line" {
    const allocator = std.testing.allocator;

    // A deterministic two-function source: names-only should emit exactly `a\nb\n`.
    const source = "fn a() void {}\nfn b() void {}\n";

    // Case 1: parse ... --node function --names-only — wc -l == grep -c .
    {
        const result = try runLaspWithStdin(allocator, &.{ "parse", "-", "-g", "examples/grammars/zig.toml", "--node", "function", "--names-only" }, source);
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

        const out = result.stdout;
        try std.testing.expectEqual(nonEmptyLineCount(out), newlineTerminatedLineCount(out));
        // Non-empty names-only output must end with exactly one '\n', never "\n\n".
        try std.testing.expect(out.len > 0);
        try std.testing.expect(!std.mem.endsWith(u8, out, "\n\n"));
        try std.testing.expect(std.mem.endsWith(u8, out, "\n"));
    }

    // Case 2: query 'function' ... --names-only — wc -l == grep -c .
    {
        const result = try runLaspWithStdin(allocator, &.{ "query", "function", "-", "-g", "examples/grammars/zig.toml", "--names-only" }, source);
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

        const out = result.stdout;
        try std.testing.expectEqual(nonEmptyLineCount(out), newlineTerminatedLineCount(out));
        try std.testing.expect(out.len > 0);
        try std.testing.expect(!std.mem.endsWith(u8, out, "\n\n"));
        try std.testing.expect(std.mem.endsWith(u8, out, "\n"));
    }

    // Case 3: zero-match edge case — a nonexistent node type yields zero names, so
    // names-only output must be exactly 0 bytes (today it is 1 byte: a stray '\n').
    {
        const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "-g", "examples/grammars/zig.toml", "--node", "nosuchtype", "--names-only" });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
    }
}

// Helper: assert `out` parses as valid JSON and ends with exactly one trailing '\n'.
fn expectValidJsonSingleTrailingNewline(allocator: std.mem.Allocator, out: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    try std.testing.expect(out.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, out, "\n"));
    try std.testing.expect(!std.mem.endsWith(u8, out, "\n\n"));
}

// Feature: names-only-trailing-newline, Property 2: Preservation
// JSON And Version Output Unchanged.
// These tests capture the characterizing invariants of the JSON and version output
// paths on the current (unfixed) binary. The later fix guards the end-of-main newline
// on `!parsed.names_only`, so every one of these paths must keep its single trailing
// '\n' byte-for-byte. These MUST PASS on the unfixed code.
test "preservation: parse with grammar emits valid JSON ending in one newline" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "-g", "examples/grammars/zig.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try expectValidJsonSingleTrailingNewline(allocator, result.stdout);
}

test "preservation: parse without grammar emits valid raw-token JSON ending in one newline" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try expectValidJsonSingleTrailingNewline(allocator, result.stdout);
}

test "preservation: query without names-only emits valid JSON ending in one newline" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "query", "function", "tests/fixtures/sample.zig", "-g", "examples/grammars/zig.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try expectValidJsonSingleTrailingNewline(allocator, result.stdout);
}

test "preservation: --version prints 'lasp ' prefix ending in exactly one newline" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{"--version"});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    const out = result.stdout;
    try std.testing.expect(std.mem.startsWith(u8, out, "lasp "));
    try std.testing.expect(std.mem.endsWith(u8, out, "\n"));
    try std.testing.expect(!std.mem.endsWith(u8, out, "\n\n"));
}

// --- Integration Tests for Configurable Comment Prefixes (Erlang) ---

// Helper: load a grammar file and tokenize source through the real
// loader -> tokenizer path, returning tokens. Uses an arena owned by the caller.
fn tokenizeWithGrammarFile(
    arena: std.mem.Allocator,
    grammar_path: []const u8,
    source: []const u8,
) ![]tokenizer.Token {
    const grammar_source = try readSourceFile(std.testing.io, arena, grammar_path);
    const grammar = try grammar_loader.parseGrammar(grammar_source, arena);
    return try tokenizer.tokenize(source, grammar.keyword_table, grammar.comments, arena);
}

test "integration: Erlang % lines produce comment tokens with erlang.toml" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = "% first comment\nfoo() -> ok.\n% second comment\n";
    const tokens = try tokenizeWithGrammarFile(a, "examples/grammars/erlang.toml", source);

    var comment_count: usize = 0;
    for (tokens) |tok| {
        if (tok.kind == .comment) comment_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), comment_count);
}

test "integration: Erlang % comment line is a single token, not many operators" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A single comment line. Pre-fix, `%` was tokenized as many operator tokens.
    const comment_line = "% a longer comment line with many words and symbols: foo/1 bar/2";
    const source = comment_line ++ "\n";
    const tokens = try tokenizeWithGrammarFile(a, "examples/grammars/erlang.toml", source);

    // Exactly one comment token, no operator tokens from the comment content.
    var comment_count: usize = 0;
    var operator_count: usize = 0;
    var comment_tok: ?tokenizer.Token = null;
    for (tokens) |tok| {
        switch (tok.kind) {
            .comment => {
                comment_count += 1;
                comment_tok = tok;
            },
            .operator => operator_count += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), comment_count);
    try std.testing.expectEqual(@as(usize, 0), operator_count);

    // The single comment token spans the whole comment line.
    try std.testing.expect(comment_tok != null);
    try std.testing.expectEqualStrings(comment_line, source[comment_tok.?.start..comment_tok.?.end]);
}

test "integration: Zig grammar (no [comments]) does not treat % as a comment" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Zig grammar has no [comments] section -> default C-style prefixes.
    // A line beginning with `%` must NOT become a comment token.
    const source = "% not a comment in zig\n";
    const tokens = try tokenizeWithGrammarFile(a, "examples/grammars/zig.toml", source);

    for (tokens) |tok| {
        try std.testing.expect(tok.kind != .comment);
    }
}

test "integration: Zig grammar still parses sample.zig (no regression)" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--grammar", "examples/grammars/zig.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;
    try std.testing.expect(json_events.array.items.len > 0);
}

test "integration: Erlang % comment via stdin tokenizes as single comment token" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Mirror the stdin-fed source `% hello` through the real loader+tokenizer
    // path (the CLI emits structural events, never tokens, when a grammar is set).
    const source = "% hello";
    const tokens = try tokenizeWithGrammarFile(a, "examples/grammars/erlang.toml", source);

    var comment_count: usize = 0;
    for (tokens) |tok| {
        if (tok.kind == .comment) comment_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), comment_count);
}

test "integration: Erlang % comment via CLI stdin pipe does not break parsing" {
    // Complementary CLI-level assertion for the actual `echo '...' | lasp parse -`
    // pipe. With a grammar set the CLI emits structural events, so we assert the
    // end-to-end effect: a leading `%` comment line is consumed (not mis-parsed)
    // and the following column-0 function head is still detected.
    const allocator = std.testing.allocator;
    const source = "% hello\nfoo() -> ok.\n";

    const result = try runLaspWithStdin(allocator, &.{ "parse", "-", "--grammar", "examples/grammars/erlang.toml", "--node", "function", "--names-only" }, source);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    // Exactly one function head (`foo`) survives the comment line.
    var count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (it.next()) |line| {
        if (line.len > 0) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "integration: apostrophe-in-comment does not swallow Erlang function heads" {
    // CORE REGRESSION (TODO Issues #9/#18): comments containing apostrophes
    // must not open a string that swallows the following code. With the
    // `%`-comment erlang.toml, ALL column-0 function heads must be detected.
    // The fixture authors exactly 6 function definitions at column 0.
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/comments.erl", "--grammar", "examples/grammars/erlang.toml", "--node", "function", "--names-only" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    // Count non-empty lines (one function name per line).
    var count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (it.next()) |line| {
        if (line.len > 0) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), count);
}

test "integration: colliding identical-sequence patterns emit both functions and calls" {
    const allocator = std.testing.allocator;

    // 1. --node function --names-only lists all 6 function heads
    {
        const result = try runLasp(allocator, &.{
            "parse",
            "tests/fixtures/colliding.erl",
            "--grammar",
            "tests/fixtures/grammars/colliding_function_call.toml",
            "--node",
            "function",
            "--names-only",
        });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

        const expected_heads = [_][]const u8{ "ann", "af_atom", "af_int", "af_var", "af_call", "af_list" };
        var idx: usize = 0;
        var it = std.mem.tokenizeScalar(u8, result.stdout, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            try std.testing.expect(idx < expected_heads.len);
            try std.testing.expectEqualStrings(expected_heads[idx], line);
            idx += 1;
        }
        try std.testing.expectEqual(expected_heads.len, idx);
    }

    // 2. --node call --names-only lists all 3 call sites
    {
        const result = try runLasp(allocator, &.{
            "parse",
            "tests/fixtures/colliding.erl",
            "--grammar",
            "tests/fixtures/grammars/colliding_function_call.toml",
            "--node",
            "call",
            "--names-only",
        });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

        const expected_calls = [_][]const u8{ "helper", "format", "done" };
        var idx: usize = 0;
        var it = std.mem.tokenizeScalar(u8, result.stdout, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            try std.testing.expect(idx < expected_calls.len);
            try std.testing.expectEqualStrings(expected_calls[idx], line);
            idx += 1;
        }
        try std.testing.expectEqual(expected_calls.len, idx);
    }

    // 3. query 'function[name="ann"]' and query 'call[callee="helper"]'
    {
        const result_fn = try runLasp(allocator, &.{
            "query",
            "function[name=\"ann\"]",
            "tests/fixtures/colliding.erl",
            "-g",
            "tests/fixtures/grammars/colliding_function_call.toml",
            "--names-only",
        });
        defer {
            allocator.free(result_fn.stdout);
            allocator.free(result_fn.stderr);
        }
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result_fn.term);
        try std.testing.expectEqualStrings("ann\n", result_fn.stdout);

        const result_call = try runLasp(allocator, &.{
            "query",
            "call[callee=\"helper\"]",
            "tests/fixtures/colliding.erl",
            "-g",
            "tests/fixtures/grammars/colliding_function_call.toml",
            "--names-only",
        });
        defer {
            allocator.free(result_call.stdout);
            allocator.free(result_call.stderr);
        }
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result_call.term);
        try std.testing.expectEqualStrings("helper\n", result_call.stdout);
    }
}

// Feature: same-type-pattern-union, Integration: a union/prefix grammar emits one primary
// per construct (Requirement 7.2). The `--alternatives` flag belongs to the separate
// competing-candidate-emission feature and is not part of this spec.
test "integration: same-type pattern union emits one primary per construct" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/union_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/union.toml",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    // "fn alpha (" matches both decl alternatives; longest-match collapses to one decl.
    // "fn beta ;" matches only the short decl. "use gamma" is a call.
    try std.testing.expectEqual(@as(usize, 3), json_events.array.items.len);

    const expected_types = [_][]const u8{ "decl", "decl", "call" };
    const expected_values = [_][]const u8{ "alpha", "beta", "gamma" };
    for (json_events.array.items, expected_types, expected_values) |ev, exp_type, exp_value| {
        try std.testing.expectEqualStrings(exp_type, ev.object.get("type").?.string);
        // No losers exposed without --alternatives: no "alternatives" key in the JSON.
        try std.testing.expect(ev.object.get("alternatives") == null);
        const cap_key = if (std.mem.eql(u8, exp_type, "call")) "callee" else "name";
        try std.testing.expectEqualStrings(exp_value, ev.object.get(cap_key).?.string);
    }
}
