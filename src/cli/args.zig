const std = @import("std");

pub const Command = enum {
    parse,
    parse_dir,
    query,
    version,
    help,
};

pub const ParsedArgs = struct {
    command: Command,
    target_path: []const u8,
    grammar_path: ?[]const u8 = null,
    grammar_dir: ?[]const u8 = null,
    node_filter: ?[]const u8 = null,
    names_only: bool = false,
    query_selector: ?[]const u8 = null,
    help_topic: ?Command = null,
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

pub const general_help_text =
    \\lasp - Language-Agnostic Structural Parser
    \\
    \\Usage:
    \\  lasp parse <file|-> [-g <grammar.toml>] [-n <type>] [--names-only]
    \\  lasp parse-dir <dir> [--grammar-dir <dir>]
    \\  lasp query <selector> <file|-> -g <grammar.toml> [--names-only]
    \\  lasp version
    \\  lasp help
    \\
    \\Commands:
    \\  parse       Parse a single file into structural or token events
    \\  parse-dir   Parse all files in a directory
    \\  query       Filter structural events with a CSS-like selector
    \\  version     Print the version and exit
    \\  help        Print this help and exit
    \\
    \\Flags:
    \\  -g, --grammar <path>   Grammar TOML file (structural parsing)
    \\      --grammar-dir <d>  Grammar directory (parse-dir)
    \\  -n, --node <type>      Emit only events of this type (case-insensitive)
    \\      --names-only       Emit first capture value per event, one per line
    \\  -V, --version          Print the version and exit
    \\  -h, --help             Print help and exit
    \\
    \\Stdin: use '-' as the file path to read source from standard input.
    \\
    \\Grammars are TOML files with sections [language], [keywords], [[patterns]],
    \\[blocks], [weights], [comments], and [[patterns.constraints]].
    \\
;

pub const parse_help_text =
    \\lasp parse - parse a single file into structural or token events
    \\
    \\Usage:
    \\  lasp parse <file|-> [-g <grammar.toml>] [-n <type>] [--names-only]
    \\
    \\Arguments:
    \\  <file|->   Source file path, or '-' to read from standard input
    \\
    \\Flags:
    \\  -g, --grammar <path>   Grammar TOML file; omit for raw token output
    \\  -n, --node <type>      Emit only events of this type (case-insensitive)
    \\      --names-only       Emit first capture value per event, one per line
    \\
;

pub const parse_dir_help_text =
    \\lasp parse-dir - parse all files in a directory
    \\
    \\Usage:
    \\  lasp parse-dir <dir> [--grammar-dir <dir>]
    \\
    \\Arguments:
    \\  <dir>   Directory to parse
    \\
    \\Flags:
    \\      --grammar-dir <dir>   Directory of grammar TOML files
    \\
;

pub const query_help_text =
    \\lasp query - filter structural events with a CSS-like selector
    \\
    \\Usage:
    \\  lasp query <selector> <file|-> -g <grammar.toml> [--names-only]
    \\
    \\Arguments:
    \\  <selector>   e.g. 'function', 'function[name="foo"]', '*[confidence>0.8]'
    \\  <file|->     Source file path, or '-' to read from standard input
    \\
    \\Flags:
    \\  -g, --grammar <path>   Grammar TOML file (required)
    \\      --names-only       Emit first capture value per event, one per line
    \\
;

/// Returns the help text for a given topic. null → general help.
pub fn helpText(topic: ?Command) []const u8 {
    return switch (topic orelse return general_help_text) {
        .parse => parse_help_text,
        .parse_dir => parse_dir_help_text,
        .query => query_help_text,
        else => general_help_text,
    };
}

/// Returns a human-readable error message for a CliError.
pub fn formatCliError(err: CliError) []const u8 {
    return switch (err) {
        error.NoCommand => general_help_text,
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

    // Help pre-scan: a Help_Flag anywhere wins over everything except NoCommand,
    // and takes precedence over Version_Flag (Requirement 5, 6).
    if (helpScan(args)) {
        return ParsedArgs{
            .command = .help,
            .target_path = "",
            .help_topic = parseSubcommand(args[0]),
        };
    }

    // Parse command
    const command = parseCommand(args[0]) orelse return error.UnrecognizedCommand;

    // Version and help are global commands: report and exit before any positional parsing.
    if (command == .version) {
        return ParsedArgs{ .command = .version, .target_path = "" };
    }
    if (command == .help) {
        return ParsedArgs{ .command = .help, .target_path = "", .help_topic = null };
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
            .query, .version, .help => unreachable,
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
    if (std.mem.eql(u8, arg, "help")) return .help;
    return null;
}

/// Returns true if `arg` is the `--help` or `-h` flag (exact string equality).
pub fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

/// Returns true if any argument in `args` is a Help_Flag.
/// Pure, allocation-free linear scan.
pub fn helpScan(args: []const []const u8) bool {
    for (args) |arg| {
        if (isHelpFlag(arg)) return true;
    }
    return false;
}

/// Maps a token to a subcommand topic (only `parse`/`parse-dir`/`query`).
/// Returns `null` for any other input (including `help`, `version`, `--help`, etc.).
pub fn parseSubcommand(arg: []const u8) ?Command {
    if (std.mem.eql(u8, arg, "parse")) return .parse;
    if (std.mem.eql(u8, arg, "parse-dir")) return .parse_dir;
    if (std.mem.eql(u8, arg, "query")) return .query;
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

// --- Help Command Tests ---

test "lasp help command returns help with no topic" {
    const args = &[_][]const u8{"help"};
    const result = try parseArgs(args);
    try testing.expectEqual(result.command, .help);
    try testing.expect(result.help_topic == null);
}

test "lone -h flag returns help with no topic" {
    const args = &[_][]const u8{"-h"};
    const result = try parseArgs(args);
    try testing.expectEqual(result.command, .help);
    try testing.expect(result.help_topic == null);
}

test "lone --help flag returns help with no topic" {
    const args = &[_][]const u8{"--help"};
    const result = try parseArgs(args);
    try testing.expectEqual(result.command, .help);
    try testing.expect(result.help_topic == null);
}

test "parse --help returns help with parse topic" {
    const args = &[_][]const u8{ "parse", "--help" };
    const result = try parseArgs(args);
    try testing.expectEqual(result.command, .help);
    try testing.expect(result.help_topic == .parse);
}

test "query --help returns help with query topic" {
    const args = &[_][]const u8{ "query", "--help" };
    const result = try parseArgs(args);
    try testing.expectEqual(result.command, .help);
    try testing.expect(result.help_topic == .query);
}

test "parse-dir --help returns help with parse_dir topic" {
    const args = &[_][]const u8{ "parse-dir", "--help" };
    const result = try parseArgs(args);
    try testing.expectEqual(result.command, .help);
    try testing.expect(result.help_topic == .parse_dir);
}

test "help flag after other flags returns correct topic" {
    const args = &[_][]const u8{ "parse", "file.zig", "-g", "grammar.toml", "--help" };
    const result = try parseArgs(args);
    try testing.expectEqual(result.command, .help);
    try testing.expect(result.help_topic == .parse);
}

test "both flags --help --version returns help (help wins)" {
    const args = &[_][]const u8{ "--help", "--version" };
    const result = try parseArgs(args);
    try testing.expectEqual(result.command, .help);
    try testing.expect(result.help_topic == null);
}

test "both flags --version --help returns help (help wins)" {
    const args = &[_][]const u8{ "--version", "--help" };
    const result = try parseArgs(args);
    try testing.expectEqual(result.command, .help);
    try testing.expect(result.help_topic == null);
}

test "parseArgs with empty array returns NoCommand" {
    const args = &[_][]const u8{};
    const result = parseArgs(args);
    try testing.expectError(error.NoCommand, result);
}

test "formatCliError for NoCommand returns general help text" {
    const error_text = formatCliError(error.NoCommand);
    try testing.expectEqualStrings(error_text, general_help_text);
}

test "isHelpFlag recognizes --help and -h" {
    try testing.expect(isHelpFlag("--help") == true);
    try testing.expect(isHelpFlag("-h") == true);
    try testing.expect(isHelpFlag("help") == false);
    try testing.expect(isHelpFlag("--version") == false);
    try testing.expect(isHelpFlag("parse") == false);
    try testing.expect(isHelpFlag("") == false);
}

test "helpScan detects help flags in array" {
    try testing.expect(helpScan(&.{"--help"}) == true);
    try testing.expect(helpScan(&.{"-h"}) == true);
    try testing.expect(helpScan(&.{ "parse", "--help" }) == true);
    try testing.expect(helpScan(&.{ "parse", "file.zig", "-h", "-g", "grammar.toml" }) == true);
    try testing.expect(helpScan(&.{ "parse", "file.zig" }) == false);
    try testing.expect(helpScan(&.{"--version"}) == false);
    try testing.expect(helpScan(&.{}) == false);
}

test "parseSubcommand maps subcommands correctly" {
    try testing.expect(parseSubcommand("parse") == .parse);
    try testing.expect(parseSubcommand("parse-dir") == .parse_dir);
    try testing.expect(parseSubcommand("query") == .query);
    try testing.expect(parseSubcommand("help") == null);
    try testing.expect(parseSubcommand("version") == null);
    try testing.expect(parseSubcommand("--help") == null);
    try testing.expect(parseSubcommand("foo") == null);
    try testing.expect(parseSubcommand("") == null);
}

// --- Help Text Content Assertion Tests ---

test "general_help_text contains all command names" {
    const help = general_help_text;
    try testing.expect(std.mem.indexOf(u8, help, "parse") != null);
    try testing.expect(std.mem.indexOf(u8, help, "parse-dir") != null);
    try testing.expect(std.mem.indexOf(u8, help, "query") != null);
    try testing.expect(std.mem.indexOf(u8, help, "version") != null);
    try testing.expect(std.mem.indexOf(u8, help, "help") != null);
}

test "general_help_text contains all flag spellings" {
    const help = general_help_text;
    // -g/--grammar flags
    try testing.expect(std.mem.indexOf(u8, help, "-g") != null);
    try testing.expect(std.mem.indexOf(u8, help, "--grammar") != null);
    // --grammar-dir flag
    try testing.expect(std.mem.indexOf(u8, help, "--grammar-dir") != null);
    // -n/--node flags
    try testing.expect(std.mem.indexOf(u8, help, "-n") != null);
    try testing.expect(std.mem.indexOf(u8, help, "--node") != null);
    // --names-only flag
    try testing.expect(std.mem.indexOf(u8, help, "--names-only") != null);
    // -V/--version flags
    try testing.expect(std.mem.indexOf(u8, help, "-V") != null);
    try testing.expect(std.mem.indexOf(u8, help, "--version") != null);
    // -h/--help flags
    try testing.expect(std.mem.indexOf(u8, help, "-h") != null);
    try testing.expect(std.mem.indexOf(u8, help, "--help") != null);
}

test "general_help_text contains stdin '-' note" {
    const help = general_help_text;
    try testing.expect(std.mem.indexOf(u8, help, "Stdin:") != null);
    try testing.expect(std.mem.indexOf(u8, help, "'-'") != null);
}

test "general_help_text contains all grammar section tokens" {
    const help = general_help_text;
    try testing.expect(std.mem.indexOf(u8, help, "[language]") != null);
    try testing.expect(std.mem.indexOf(u8, help, "[keywords]") != null);
    try testing.expect(std.mem.indexOf(u8, help, "[[patterns]]") != null);
    try testing.expect(std.mem.indexOf(u8, help, "[blocks]") != null);
    try testing.expect(std.mem.indexOf(u8, help, "[weights]") != null);
    try testing.expect(std.mem.indexOf(u8, help, "[comments]") != null);
    try testing.expect(std.mem.indexOf(u8, help, "[[patterns.constraints]]") != null);
}

test "query_help_text mentions selector argument and -g flag" {
    const help = query_help_text;
    try testing.expect(std.mem.indexOf(u8, help, "<selector>") != null);
    try testing.expect(std.mem.indexOf(u8, help, "-g") != null);
    try testing.expect(std.mem.indexOf(u8, help, "--grammar") != null);
}

test "parse_help_text mentions -n/--node and --names-only flags" {
    const help = parse_help_text;
    try testing.expect(std.mem.indexOf(u8, help, "-n") != null);
    try testing.expect(std.mem.indexOf(u8, help, "--node") != null);
    try testing.expect(std.mem.indexOf(u8, help, "--names-only") != null);
}

test "parse_dir_help_text mentions --grammar-dir flag" {
    const help = parse_dir_help_text;
    try testing.expect(std.mem.indexOf(u8, help, "--grammar-dir") != null);
}

test "helpText function returns correct texts for various inputs" {
    // null returns general help text
    try testing.expect(std.mem.eql(u8, helpText(null), general_help_text));

    // .parse returns parse_help_text
    try testing.expect(std.mem.eql(u8, helpText(.parse), parse_help_text));

    // .parse_dir returns parse_dir_help_text
    try testing.expect(std.mem.eql(u8, helpText(.parse_dir), parse_dir_help_text));

    // .query returns query_help_text
    try testing.expect(std.mem.eql(u8, helpText(.query), query_help_text));

    // .version returns general_help_text (else clause)
    try testing.expect(std.mem.eql(u8, helpText(.version), general_help_text));

    // .help returns general_help_text (else clause)
    try testing.expect(std.mem.eql(u8, helpText(.help), general_help_text));
}

test "helpText function edge cases" {
    // Verify that all Command enum values are handled
    const commands = std.enums.values(Command);
    for (commands) |cmd| {
        _ = helpText(cmd); // Should not crash
    }

    // Verify null returns general help (already tested above)
    const null_help = helpText(null);
    try testing.expect(std.mem.eql(u8, null_help, general_help_text));
}

// --- CLI Help Text Property Tests ---

// Feature: cli-help-text, Property 1: Help flag short-circuits to the help command
test "property: help flag short-circuits to the help command" {
    const string_gen = gen.string(.{ .min_len = 1, .max_len = 16, .charset = .alphanumeric });

    try minish.check(testing.allocator, string_gen, struct {
        fn prop(random_string: []const u8) !void {
            // Generate a random position for help flag (0-2)
            // Use a deterministic hash of the string to choose position
            var hash: u32 = 0;
            for (random_string) |c| {
                hash = hash *% 31 + @as(u32, c);
            }
            const help_pos = hash % 3; // 0, 1, or 2

            // Choose which help flag to use
            const use_long_help = (hash >> 8) % 2 == 0;
            const help_flag = if (use_long_help) "--help" else "-h";

            // Build args array with help flag at chosen position
            var args_buf: [4][]const u8 = undefined;
            var args_len: usize = 0;

            // Add some dummy tokens
            const dummy1 = "dummy1";
            const dummy2 = "dummy2";

            switch (help_pos) {
                0 => {
                    args_buf[0] = help_flag;
                    args_buf[1] = dummy1;
                    args_buf[2] = dummy2;
                    args_len = 3;
                },
                1 => {
                    args_buf[0] = dummy1;
                    args_buf[1] = help_flag;
                    args_buf[2] = dummy2;
                    args_len = 3;
                },
                2 => {
                    args_buf[0] = dummy1;
                    args_buf[1] = dummy2;
                    args_buf[2] = help_flag;
                    args_len = 3;
                },
                else => unreachable,
            }

            const args = args_buf[0..args_len];
            const result = try parseArgs(args);
            try testing.expectEqual(result.command, .help);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: cli-help-text, Property 2: Per-subcommand help routing
test "property: per-subcommand help routing" {
    const subcommand_gen = gen.string(.{ .min_len = 1, .max_len = 16, .charset = .alphanumeric });

    try minish.check(testing.allocator, subcommand_gen, struct {
        fn prop(random_string: []const u8) !void {
            // Map random string to one of the subcommands
            var hash: u32 = 0;
            for (random_string) |c| {
                hash = hash *% 31 + @as(u32, c);
            }

            const subcommands = [_][]const u8{ "parse", "parse-dir", "query" };
            const sub_idx = hash % subcommands.len;
            const subcommand = subcommands[sub_idx];

            // Choose which help flag to use
            const use_long_help = (hash >> 8) % 2 == 0;
            const help_flag = if (use_long_help) "--help" else "-h";

            // Build args: subcommand followed by help flag
            const args = &[_][]const u8{ subcommand, help_flag };

            // Parse and verify
            const result = try parseArgs(args);
            try testing.expectEqual(result.command, .help);

            // Check help_topic matches subcommand
            const expected_topic = switch (sub_idx) {
                0 => Command.parse,
                1 => Command.parse_dir,
                2 => Command.query,
                else => unreachable,
            };
            try testing.expect(result.help_topic == expected_topic);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: cli-help-text, Property 3: Help takes precedence over version
test "property: help takes precedence over version" {
    const string_gen = gen.string(.{ .min_len = 1, .max_len = 16, .charset = .alphanumeric });

    try minish.check(testing.allocator, string_gen, struct {
        fn prop(random_string: []const u8) !void {
            // Use hash to determine flag choices and order
            var hash: u32 = 0;
            for (random_string) |c| {
                hash = hash *% 31 + @as(u32, c);
            }

            // Choose flag types
            const use_long_help = (hash >> 8) % 2 == 0;
            const use_long_version = (hash >> 9) % 2 == 0;
            const help_first = (hash >> 10) % 2 == 0;

            const help_flag = if (use_long_help) "--help" else "-h";
            const version_flag = if (use_long_version) "--version" else "-V";

            // Build args with both flags
            const args = if (help_first)
                &[_][]const u8{ help_flag, version_flag }
            else
                &[_][]const u8{ version_flag, help_flag };

            // Parse and verify help takes precedence
            const result = try parseArgs(args);
            try testing.expectEqual(result.command, .help);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: cli-help-text, Property 4: Non-subcommand help requests yield general help
test "property: non-subcommand help requests yield general help" {
    const string_gen = gen.string(.{ .min_len = 1, .max_len = 16, .charset = .alphanumeric });

    try minish.check(testing.allocator, string_gen, struct {
        fn prop(random_string: []const u8) !void {
            // Use hash to determine type of help request
            var hash: u32 = 0;
            for (random_string) |c| {
                hash = hash *% 31 + @as(u32, c);
            }

            const request_type = hash % 3; // 0, 1, or 2

            const args = switch (request_type) {
                0 => &[_][]const u8{"--help"},
                1 => &[_][]const u8{"-h"},
                2 => &[_][]const u8{"help"},
                else => unreachable,
            };

            // Parse and verify
            const result = try parseArgs(args);
            try testing.expectEqual(result.command, .help);
            try testing.expect(result.help_topic == null);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: cli-help-text, Property 5: Non-help parsing is preserved
test "property: non-help parsing is preserved" {
    const string_gen = gen.string(.{ .min_len = 1, .max_len = 16, .charset = .alphanumeric });

    try minish.check(testing.allocator, string_gen, struct {
        fn prop(random_string: []const u8) !void {
            // Use hash to generate different argument patterns
            var hash: u32 = 0;
            for (random_string) |c| {
                hash = hash *% 31 + @as(u32, c);
            }

            // Generate different argument patterns that don't contain help flags
            // and don't start with "help"
            const pattern = hash % 4;

            switch (pattern) {
                0 => {
                    // Empty args -> NoCommand error
                    const args = &[_][]const u8{};
                    const result = parseArgs(args);
                    try testing.expectError(error.NoCommand, result);
                },
                1 => {
                    // Valid parse command
                    const args = &[_][]const u8{ "parse", "file.zig" };
                    const result = try parseArgs(args);
                    try testing.expectEqual(result.command, .parse);
                    try testing.expect(result.help_topic == null);
                },
                2 => {
                    // Valid parse-dir command
                    const args = &[_][]const u8{ "parse-dir", "src/" };
                    const result = try parseArgs(args);
                    try testing.expectEqual(result.command, .parse_dir);
                    try testing.expect(result.help_topic == null);
                },
                3 => {
                    // Valid query command
                    const args = &[_][]const u8{ "query", "function", "file.zig", "-g", "grammar.toml" };
                    const result = try parseArgs(args);
                    try testing.expectEqual(result.command, .query);
                    try testing.expect(result.help_topic == null);
                },
                else => unreachable,
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: same-type-pattern-union, Requirement 7.3: union semantics add no new CLI flag.
test "--union style flags are unrecognized" {
    const parse_args = &[_][]const u8{ "parse", "file.zig", "--union" };
    try testing.expectError(error.UnrecognizedFlag, parseArgs(parse_args));
    const query_args = &[_][]const u8{ "query", "function", "file.zig", "-g", "grammar.toml", "--union" };
    try testing.expectError(error.UnrecognizedFlag, parseArgs(query_args));
}
