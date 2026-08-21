const std = @import("std");

pub const Command = enum {
    parse,
    parse_dir,
    query,
    version,
};

pub const ParsedArgs = struct {
    command: Command,
    target_path: []const u8,
    grammar_path: ?[]const u8 = null,
    grammar_dir: ?[]const u8 = null,
    node_filter: ?[]const u8 = null,
    names_only: bool = false,
    query_selector: ?[]const u8 = null,
};

pub const CliError = error{
    NoCommand,
    UnrecognizedCommand,
    UnrecognizedFlag,
    MissingFilePath,
    MissingDirectoryPath,
    MissingFlagValue,
    MissingSelectorString,
};

/// Returns a human-readable error message for a CliError.
pub fn formatCliError(err: CliError) []const u8 {
    return switch (err) {
        error.NoCommand => "error: no command provided. Usage: lasp <parse|parse-dir|query> <path> [flags]",
        error.UnrecognizedCommand => "error: unrecognized command",
        error.UnrecognizedFlag => "error: unrecognized flag",
        error.MissingFilePath => "error: command requires a file path",
        error.MissingDirectoryPath => "error: parse-dir command requires a directory path",
        error.MissingFlagValue => "error: flag requires a value",
        error.MissingSelectorString => "error: query command requires a selector string",
    };
}

/// Parses command-line arguments into a ParsedArgs struct.
/// Receives args[1..] (binary name already stripped).
/// Returns CliError on invalid input. Does not allocate.
pub fn parseArgs(args: []const []const u8) CliError!ParsedArgs {
    if (args.len == 0) return error.NoCommand;

    // Parse command
    const command = parseCommand(args[0]) orelse return error.UnrecognizedCommand;

    // Version is a global flag: report and exit before any positional parsing.
    if (command == .version) {
        return ParsedArgs{ .command = .version, .target_path = "" };
    }

    // Query command has different positional arg structure:
    //   query <selector> <file_path> [flags]
    // Parse/parse-dir:
    //   parse <file_path> [flags]
    if (command == .query) {
        return parseQueryArgs(args);
    }

    // Must have at least a target path after the command
    if (args.len < 2) {
        return switch (command) {
            .parse => error.MissingFilePath,
            .parse_dir => error.MissingDirectoryPath,
            .query, .version => unreachable,
        };
    }

    const target_path = args[1];

    // Parse optional flags
    var grammar_path: ?[]const u8 = null;
    var grammar_dir: ?[]const u8 = null;
    var node_filter: ?[]const u8 = null;
    var names_only: bool = false;

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
        } else if (std.mem.eql(u8, arg, "--node") or std.mem.eql(u8, arg, "-n")) {
            i += 1;
            if (i >= args.len) return error.MissingFlagValue;
            node_filter = args[i];
        } else if (std.mem.eql(u8, arg, "--names-only")) {
            names_only = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            return ParsedArgs{ .command = .version, .target_path = "" };
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
        .node_filter = node_filter,
        .names_only = names_only,
    };
}

/// Parses arguments for the `query` command.
/// Expected format: query <selector> <file_path> [--grammar/-g <path>] [--names-only]
fn parseQueryArgs(args: []const []const u8) CliError!ParsedArgs {
    // args[0] is "query", need at least selector at args[1]
    if (args.len < 2) return error.MissingSelectorString;

    const query_selector = args[1];

    // Need file path at args[2]
    if (args.len < 3) return error.MissingFilePath;

    const target_path = args[2];

    // Parse optional flags starting from args[3]
    var grammar_path: ?[]const u8 = null;
    var names_only: bool = false;

    var i: usize = 3;
    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--grammar") or std.mem.eql(u8, arg, "-g")) {
            i += 1;
            if (i >= args.len) return error.MissingFlagValue;
            grammar_path = args[i];
        } else if (std.mem.eql(u8, arg, "--names-only")) {
            names_only = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            return ParsedArgs{ .command = .version, .target_path = "" };
        } else {
            return error.UnrecognizedFlag;
        }

        i += 1;
    }

    return ParsedArgs{
        .command = .query,
        .target_path = target_path,
        .grammar_path = grammar_path,
        .names_only = names_only,
        .query_selector = query_selector,
    };
}

fn parseCommand(arg: []const u8) ?Command {
    if (std.mem.eql(u8, arg, "parse")) return .parse;
    if (std.mem.eql(u8, arg, "parse-dir")) return .parse_dir;
    if (std.mem.eql(u8, arg, "query")) return .query;
    if (std.mem.eql(u8, arg, "version")) return .version;
    if (std.mem.eql(u8, arg, "--version")) return .version;
    if (std.mem.eql(u8, arg, "-V")) return .version;
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

// Tests for new --node/-n and --names-only flags

test "parse with --node flag stores in node_filter" {
    const args = &[_][]const u8{ "parse", "file.zig", "--node", "function" };
    const result = try parseArgs(args);
    try testing.expectEqualStrings(result.node_filter.?, "function");
}

test "parse with -n short flag stores in node_filter" {
    const args = &[_][]const u8{ "parse", "file.zig", "-n", "call" };
    const result = try parseArgs(args);
    try testing.expectEqualStrings(result.node_filter.?, "call");
}

test "parse with --names-only flag sets names_only true" {
    const args = &[_][]const u8{ "parse", "file.zig", "--names-only" };
    const result = try parseArgs(args);
    try testing.expect(result.names_only == true);
}

test "--node as last arg returns MissingFlagValue" {
    const args = &[_][]const u8{ "parse", "file.zig", "--node" };
    const result = parseArgs(args);
    try testing.expectError(error.MissingFlagValue, result);
}

test "-n as last arg returns MissingFlagValue" {
    const args = &[_][]const u8{ "parse", "file.zig", "-n" };
    const result = parseArgs(args);
    try testing.expectError(error.MissingFlagValue, result);
}

test "\"-\" accepted as valid target_path" {
    const args = &[_][]const u8{ "parse", "-" };
    const result = try parseArgs(args);
    try testing.expectEqualStrings(result.target_path, "-");
}

test "new flags combined with existing --grammar/-g flags" {
    const args = &[_][]const u8{ "parse", "file.zig", "-g", "grammars/zig.toml", "--node", "function", "--names-only" };
    const result = try parseArgs(args);
    try testing.expectEqualStrings(result.grammar_path.?, "grammars/zig.toml");
    try testing.expectEqualStrings(result.node_filter.?, "function");
    try testing.expect(result.names_only == true);
}

// Tests for query command

test "query with selector + path + grammar" {
    const args = &[_][]const u8{ "query", "function[name=\"foo\"]", "file.zig", "-g", "grammars/zig.toml" };
    const result = try parseArgs(args);
    try testing.expectEqual(result.command, .query);
    try testing.expectEqualStrings(result.query_selector.?, "function[name=\"foo\"]");
    try testing.expectEqualStrings(result.target_path, "file.zig");
    try testing.expectEqualStrings(result.grammar_path.?, "grammars/zig.toml");
}

test "query missing selector returns MissingSelectorString" {
    const args = &[_][]const u8{"query"};
    const result = parseArgs(args);
    try testing.expectError(error.MissingSelectorString, result);
}

test "query missing path returns MissingFilePath" {
    const args = &[_][]const u8{ "query", "function" };
    const result = parseArgs(args);
    try testing.expectError(error.MissingFilePath, result);
}

test "query missing grammar value returns MissingFlagValue" {
    const args = &[_][]const u8{ "query", "function", "file.zig", "--grammar" };
    const result = parseArgs(args);
    try testing.expectError(error.MissingFlagValue, result);
}

test "query with --names-only" {
    const args = &[_][]const u8{ "query", "function", "file.zig", "-g", "grammar.toml", "--names-only" };
    const result = try parseArgs(args);
    try testing.expectEqual(result.command, .query);
    try testing.expectEqualStrings(result.query_selector.?, "function");
    try testing.expectEqualStrings(result.target_path, "file.zig");
    try testing.expectEqualStrings(result.grammar_path.?, "grammar.toml");
    try testing.expect(result.names_only == true);
}

test "query with stdin pipe" {
    const args = &[_][]const u8{ "query", "*[confidence>0.5]", "-", "-g", "grammar.toml" };
    const result = try parseArgs(args);
    try testing.expectEqual(result.command, .query);
    try testing.expectEqualStrings(result.query_selector.?, "*[confidence>0.5]");
    try testing.expectEqualStrings(result.target_path, "-");
}

test "query unrecognized flag returns UnrecognizedFlag" {
    const args = &[_][]const u8{ "query", "function", "file.zig", "--node", "call" };
    const result = parseArgs(args);
    try testing.expectError(error.UnrecognizedFlag, result);
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
            if (std.mem.eql(u8, cmd, "parse") or std.mem.eql(u8, cmd, "parse-dir") or std.mem.eql(u8, cmd, "query") or std.mem.eql(u8, cmd, "version")) return;

            const args = &[_][]const u8{ cmd, "some/path" };
            const result = parseArgs(args);
            try testing.expectError(error.UnrecognizedCommand, result);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: composable-cli-primitives, Property 1: New flag parsing round-trip
test "property: new flag parsing round-trip" {
    const node_filter_gen = gen.string(.{ .min_len = 1, .max_len = 32, .charset = .alphanumeric });

    // Test --node flag with random node filter values
    try minish.check(testing.allocator, node_filter_gen, struct {
        fn prop(node_filter: []const u8) !void {
            const args = &[_][]const u8{ "parse", "file.zig", "--node", node_filter };
            const result = try parseArgs(args);
            try testing.expectEqualStrings(result.node_filter.?, node_filter);
            try testing.expect(result.names_only == false);
        }
    }.prop, .{ .num_runs = 100 });

    // Test -n short flag produces identical results to --node
    try minish.check(testing.allocator, node_filter_gen, struct {
        fn prop(node_filter: []const u8) !void {
            const args_long = &[_][]const u8{ "parse", "file.zig", "--node", node_filter };
            const args_short = &[_][]const u8{ "parse", "file.zig", "-n", node_filter };
            const result_long = try parseArgs(args_long);
            const result_short = try parseArgs(args_short);
            try testing.expectEqualStrings(result_long.node_filter.?, result_short.node_filter.?);
        }
    }.prop, .{ .num_runs = 100 });

    // Test --names-only flag (always true when present, so just verify it works)
    {
        const args = &[_][]const u8{ "parse", "file.zig", "--names-only" };
        const result = try parseArgs(args);
        try testing.expect(result.names_only == true);
        try testing.expect(result.node_filter == null);
    }

    // Test combined --node and --names-only
    try minish.check(testing.allocator, node_filter_gen, struct {
        fn prop(node_filter: []const u8) !void {
            const args = &[_][]const u8{ "parse", "file.zig", "--node", node_filter, "--names-only" };
            const result = try parseArgs(args);
            try testing.expectEqualStrings(result.node_filter.?, node_filter);
            try testing.expect(result.names_only == true);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: composable-cli-primitives, Property 2: Flag order independence
test "property: flag order independence" {
    // Test that --grammar, --node, --names-only can appear in any order
    const grammar_path = "grammars/zig.toml";
    const node_filter = "function";

    // All permutations of flags
    const perm1 = &[_][]const u8{ "parse", "file.zig", "--grammar", grammar_path, "--node", node_filter, "--names-only" };
    const perm2 = &[_][]const u8{ "parse", "file.zig", "--node", node_filter, "--grammar", grammar_path, "--names-only" };
    const perm3 = &[_][]const u8{ "parse", "file.zig", "--names-only", "--grammar", grammar_path, "--node", node_filter };
    const perm4 = &[_][]const u8{ "parse", "file.zig", "--node", node_filter, "--names-only", "--grammar", grammar_path };
    const perm5 = &[_][]const u8{ "parse", "file.zig", "--names-only", "--node", node_filter, "--grammar", grammar_path };
    const perm6 = &[_][]const u8{ "parse", "file.zig", "--grammar", grammar_path, "--names-only", "--node", node_filter };

    const r1 = try parseArgs(perm1);
    const r2 = try parseArgs(perm2);
    const r3 = try parseArgs(perm3);
    const r4 = try parseArgs(perm4);
    const r5 = try parseArgs(perm5);
    const r6 = try parseArgs(perm6);

    // All should have identical values
    try testing.expectEqualStrings(r1.grammar_path.?, r2.grammar_path.?);
    try testing.expectEqualStrings(r1.grammar_path.?, r3.grammar_path.?);
    try testing.expectEqualStrings(r1.grammar_path.?, r4.grammar_path.?);
    try testing.expectEqualStrings(r1.grammar_path.?, r5.grammar_path.?);
    try testing.expectEqualStrings(r1.grammar_path.?, r6.grammar_path.?);

    try testing.expectEqualStrings(r1.node_filter.?, r2.node_filter.?);
    try testing.expectEqualStrings(r1.node_filter.?, r3.node_filter.?);
    try testing.expectEqualStrings(r1.node_filter.?, r4.node_filter.?);
    try testing.expectEqualStrings(r1.node_filter.?, r5.node_filter.?);
    try testing.expectEqualStrings(r1.node_filter.?, r6.node_filter.?);

    try testing.expect(r1.names_only == r2.names_only);
    try testing.expect(r1.names_only == r3.names_only);
    try testing.expect(r1.names_only == r4.names_only);
    try testing.expect(r1.names_only == r5.names_only);
    try testing.expect(r1.names_only == r6.names_only);
}

// --- Version Command Tests ---

test "--version flag returns version command" {
    const args = &[_][]const u8{"--version"};
    const result = try parseArgs(args);
    try testing.expectEqual(result.command, .version);
}

test "-V short flag returns version command" {
    const args = &[_][]const u8{"-V"};
    const result = try parseArgs(args);
    try testing.expectEqual(result.command, .version);
}

test "version subcommand returns version command" {
    const args = &[_][]const u8{"version"};
    const result = try parseArgs(args);
    try testing.expectEqual(result.command, .version);
}

test "--version accepted among parse flags" {
    const args = &[_][]const u8{ "parse", "file.zig", "-g", "grammar.toml", "--version" };
    const result = try parseArgs(args);
    try testing.expectEqual(result.command, .version);
}

test "--version accepted among query flags" {
    const args = &[_][]const u8{ "query", "function", "file.zig", "-V" };
    const result = try parseArgs(args);
    try testing.expectEqual(result.command, .version);
}
