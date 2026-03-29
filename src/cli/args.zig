const std = @import("std");

pub const Command = enum {
    parse,
    parse_dir,
};

pub const ParsedArgs = struct {
    command: Command,
    target_path: []const u8,
    grammar_path: ?[]const u8 = null,
    grammar_dir: ?[]const u8 = null,
};

pub const CliError = error{
    NoCommand,
    UnrecognizedCommand,
    UnrecognizedFlag,
    MissingFilePath,
    MissingDirectoryPath,
    MissingFlagValue,
};

/// Returns a human-readable error message for a CliError.
pub fn formatCliError(err: CliError) []const u8 {
    return switch (err) {
        error.NoCommand => "error: no command provided. Usage: lasp <parse|parse-dir> <path> [flags]",
        error.UnrecognizedCommand => "error: unrecognized command",
        error.UnrecognizedFlag => "error: unrecognized flag",
        error.MissingFilePath => "error: parse command requires a file path",
        error.MissingDirectoryPath => "error: parse-dir command requires a directory path",
        error.MissingFlagValue => "error: flag requires a value",
    };
}

/// Parses command-line arguments into a ParsedArgs struct.
/// Receives args[1..] (binary name already stripped).
/// Returns CliError on invalid input. Does not allocate.
pub fn parseArgs(args: []const []const u8) CliError!ParsedArgs {
    if (args.len == 0) return error.NoCommand;

    // Parse command
    const command = parseCommand(args[0]) orelse return error.UnrecognizedCommand;

    // Must have at least a target path after the command
    if (args.len < 2) {
        return switch (command) {
            .parse => error.MissingFilePath,
            .parse_dir => error.MissingDirectoryPath,
        };
    }

    const target_path = args[1];

    // Parse optional flags
    var grammar_path: ?[]const u8 = null;
    var grammar_dir: ?[]const u8 = null;

    var i: usize = 2;
    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--grammar") or std.mem.eql(u8, arg, "-g")) {
            i += 1;
            if (i >= args.len) return error.MissingFlagValue;
            grammar_path = args[i];
        } else if (std.mem.eql(u8, arg, "--grammar-dir")) {
            i += 1;
            if (i >= args.len) return error.MissingFlagValue;
            grammar_dir = args[i];
        } else {
            return error.UnrecognizedFlag;
        }

        i += 1;
    }

    return ParsedArgs{
        .command = command,
        .target_path = target_path,
        .grammar_path = grammar_path,
        .grammar_dir = grammar_dir,
    };
}

fn parseCommand(arg: []const u8) ?Command {
    if (std.mem.eql(u8, arg, "parse")) return .parse;
    if (std.mem.eql(u8, arg, "parse-dir")) return .parse_dir;
    return null;
}

// --- Unit Tests ---

const testing = std.testing;

test "parse command with file path" {
    const args = &[_][]const u8{ "parse", "file.zig" };
    const result = try parseArgs(args);
    try testing.expectEqual(result.command, .parse);
    try testing.expectEqualStrings(result.target_path, "file.zig");
    try testing.expect(result.grammar_path == null);
    try testing.expect(result.grammar_dir == null);
}

test "parse-dir command with directory path" {
    const args = &[_][]const u8{ "parse-dir", "./src" };
    const result = try parseArgs(args);
    try testing.expectEqual(result.command, .parse_dir);
    try testing.expectEqualStrings(result.target_path, "./src");
}

test "parse with --grammar flag" {
    const args = &[_][]const u8{ "parse", "file.zig", "--grammar", "kw.txt" };
    const result = try parseArgs(args);
    try testing.expectEqualStrings(result.grammar_path.?, "kw.txt");
}

test "parse with -g short flag" {
    const args = &[_][]const u8{ "parse", "file.zig", "-g", "kw.txt" };
    const result = try parseArgs(args);
    try testing.expectEqualStrings(result.grammar_path.?, "kw.txt");
}

test "parse with --grammar-dir flag" {
    const args = &[_][]const u8{ "parse-dir", "./repo", "--grammar-dir", "grammars/" };
    const result = try parseArgs(args);
    try testing.expectEqualStrings(result.grammar_dir.?, "grammars/");
}

test "no command returns NoCommand" {
    const args = &[_][]const u8{};
    const result = parseArgs(args);
    try testing.expectError(error.NoCommand, result);
}

test "unrecognized command returns UnrecognizedCommand" {
    const args = &[_][]const u8{ "tokenize", "file.zig" };
    const result = parseArgs(args);
    try testing.expectError(error.UnrecognizedCommand, result);
}

test "parse without file path returns MissingFilePath" {
    const args = &[_][]const u8{"parse"};
    const result = parseArgs(args);
    try testing.expectError(error.MissingFilePath, result);
}

test "parse-dir without directory path returns MissingDirectoryPath" {
    const args = &[_][]const u8{"parse-dir"};
    const result = parseArgs(args);
    try testing.expectError(error.MissingDirectoryPath, result);
}

test "unrecognized flag returns UnrecognizedFlag" {
    const args = &[_][]const u8{ "parse", "file.zig", "--verbose" };
    const result = parseArgs(args);
    try testing.expectError(error.UnrecognizedFlag, result);
}

test "missing flag value returns MissingFlagValue" {
    const args = &[_][]const u8{ "parse", "file.zig", "--grammar" };
    const result = parseArgs(args);
    try testing.expectError(error.MissingFlagValue, result);
}

// --- Property Tests ---

const minish = @import("minish");
const gen = minish.gen;

// Feature: phase1-tokenizer-cli, Property 1: Valid command parsing
test "property: valid command parsing" {
    const path_gen = gen.string(.{ .min_len = 1, .max_len = 64, .charset = .alphanumeric });

    // Test "parse" command with random paths
    try minish.check(testing.allocator, path_gen, struct {
        fn prop(path: []const u8) !void {
            const args = &[_][]const u8{ "parse", path };
            const result = try parseArgs(args);
            try testing.expectEqual(result.command, .parse);
            try testing.expectEqualStrings(result.target_path, path);
        }
    }.prop, .{ .num_runs = 100 });

    // Test "parse-dir" command with random paths
    try minish.check(testing.allocator, path_gen, struct {
        fn prop(path: []const u8) !void {
            const args = &[_][]const u8{ "parse-dir", path };
            const result = try parseArgs(args);
            try testing.expectEqual(result.command, .parse_dir);
            try testing.expectEqualStrings(result.target_path, path);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase1-tokenizer-cli, Property 2: Valid flag parsing
test "property: valid flag parsing" {
    const path_gen = gen.string(.{ .min_len = 1, .max_len = 64, .charset = .alphanumeric });

    // --grammar flag
    try minish.check(testing.allocator, path_gen, struct {
        fn prop(grammar_path: []const u8) !void {
            const args = &[_][]const u8{ "parse", "file.zig", "--grammar", grammar_path };
            const result = try parseArgs(args);
            try testing.expectEqualStrings(result.grammar_path.?, grammar_path);
            try testing.expect(result.grammar_dir == null);
        }
    }.prop, .{ .num_runs = 100 });

    // -g short flag
    try minish.check(testing.allocator, path_gen, struct {
        fn prop(grammar_path: []const u8) !void {
            const args = &[_][]const u8{ "parse", "file.zig", "-g", grammar_path };
            const result = try parseArgs(args);
            try testing.expectEqualStrings(result.grammar_path.?, grammar_path);
        }
    }.prop, .{ .num_runs = 100 });

    // --grammar-dir flag
    try minish.check(testing.allocator, path_gen, struct {
        fn prop(grammar_dir: []const u8) !void {
            const args = &[_][]const u8{ "parse-dir", "./repo", "--grammar-dir", grammar_dir };
            const result = try parseArgs(args);
            try testing.expectEqualStrings(result.grammar_dir.?, grammar_dir);
            try testing.expect(result.grammar_path == null);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase1-tokenizer-cli, Property 3: Invalid CLI input rejection
test "property: invalid CLI input rejection" {
    const str_gen = gen.string(.{ .min_len = 1, .max_len = 32, .charset = .alphanumeric });

    try minish.check(testing.allocator, str_gen, struct {
        fn prop(cmd: []const u8) !void {
            // Skip if the random string happens to be a valid command
            if (std.mem.eql(u8, cmd, "parse") or std.mem.eql(u8, cmd, "parse-dir")) return;

            const args = &[_][]const u8{ cmd, "some/path" };
            const result = parseArgs(args);
            try testing.expectError(error.UnrecognizedCommand, result);
        }
    }.prop, .{ .num_runs = 100 });
}
