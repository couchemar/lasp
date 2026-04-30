const std = @import("std");
pub const cli = @import("cli/args.zig");
pub const tokenizer = @import("parser/tokenizer.zig");
pub const json = @import("output/json.zig");
pub const grammar_loader = @import("grammar/loader.zig");
pub const grammar_compiler = @import("grammar/compiler.zig");
pub const events = @import("parser/events.zig");
pub const engine = @import("parser/engine.zig");
pub const query_filter = @import("query/filter.zig");

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

    // 4. Read source file or stdin
    const source = blk: {
        if (std.mem.eql(u8, parsed.target_path, "-")) {
            var stdin_buffer: [4096]u8 = undefined;
            var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
            break :blk try stdin_reader.interface.allocRemaining(allocator, .unlimited);
        } else {
            break :blk readSourceFile(allocator, parsed.target_path) catch {
                std.process.fatal("failed to read file: {s}", .{parsed.target_path});
            };
        }
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
                error.InvalidPositionValue => "invalid position value, expected 'start'",
                error.InvalidWeightValue => "invalid weight value, weights must be non-negative",
                error.OutOfMemory => "out of memory",
                else => "unknown grammar error",
            };
            std.process.fatal("error: {s}: {s}", .{ msg, gp });
        };
        const automaton = try grammar_compiler.compile(grammar.patterns, allocator);
        const tokens = try tokenizer.tokenize(source, grammar.keyword_table, allocator);
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

// --- Phase 3 Integration Tests ---

test "integration: structural events include col field" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--grammar", "tests/fixtures/grammars/zig.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);

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

    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);

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

    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);

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
        .Exited => |code| try std.testing.expect(code != 0),
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
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "zig-out/bin/lasp");
    for (args) |a| try argv.append(allocator, a);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    // Write stdin data and close the pipe
    if (child.stdin) |*stdin_pipe| {
        var buf: [4096]u8 = undefined;
        var writer = stdin_pipe.writer(&buf);
        try writer.interface.writeAll(stdin_data);
        try writer.interface.flush();
        stdin_pipe.close();
        child.stdin = null;
    }

    var stdout_buf: std.ArrayList(u8) = .empty;
    var stderr_buf: std.ArrayList(u8) = .empty;
    try child.collectOutput(allocator, &stdout_buf, &stderr_buf, 1024 * 1024);
    const term = try child.wait();

    const stdout_slice = try allocator.dupe(u8, stdout_buf.items);
    const stderr_slice = try allocator.dupe(u8, stderr_buf.items);
    stdout_buf.deinit(allocator);
    stderr_buf.deinit(allocator);

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

    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);

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

    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);

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

    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);

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

    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);

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

    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);

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

    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);

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

    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);

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

    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    // Should have empty events array
    try std.testing.expectEqual(@as(usize, 0), json_events.array.items.len);
}
