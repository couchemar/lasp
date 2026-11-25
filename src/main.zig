const std = @import("std");
pub const cli = @import("cli/args.zig");
pub const tokenizer = @import("parser/tokenizer.zig");
pub const json = @import("output/json.zig");
pub const grammar_loader = @import("grammar/loader.zig");
pub const grammar_compiler = @import("grammar/compiler.zig");
pub const events = @import("parser/events.zig");
pub const engine = @import("parser/engine.zig");
pub const resemblance = @import("parser/resemblance.zig");
pub const query_filter = @import("query/filter.zig");
pub const query_parser = @import("query/parser.zig");
pub const query_evaluator = @import("query/evaluator.zig");
const build_options = @import("build_options");

/// The one place the `error: ` prefix is spliced in. Message strings carry none.
const error_prefix = "error: ";

/// Comptime line format: prefix + `fmt` + newline. Rejects a `fmt` that already
/// starts with `error:` so a second prefix cannot be written by accident.
fn errorLineFormat(comptime fmt: []const u8) []const u8 {
    comptime if (std.mem.startsWith(u8, fmt, "error:"))
        @compileError("error format must not start with \"error:\": " ++ fmt);
    return error_prefix ++ fmt ++ "\n";
}

/// Prints one prefixed error line to stderr and returns.
fn reportError(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(errorLineFormat(fmt), args);
}

/// Prints one prefixed error line to stderr and exits with code 1.
fn fatalError(comptime fmt: []const u8, args: anytype) noreturn {
    reportError(fmt, args);
    std.process.exit(1);
}
/// Single message for `error.InvalidCharSet` (empty, inverted, non-ASCII endpoint, or bad escape).
const invalid_char_set_message = "[tokens] invalid char set: ranges must have ASCII endpoints and run low-to-high, use \\- for a literal '-' and \\\\ for a literal '\\' (other escapes are not allowed)";

/// Prefix-free message body for an error from `parseGrammar`.
fn grammarErrorMessage(err: grammar_loader.GrammarError) []const u8 {
    return switch (err) {
        error.InvalidToml => "invalid TOML syntax in grammar file",
        error.MissingPatterns => "grammar file missing required [[patterns]] section",
        error.EmptyPatternSequence => "pattern has empty sequence",
        error.InvalidCaptureFormat => "invalid capture format, expected $name:IDENTIFIER",
        error.InvalidPositionValue => "invalid position value, expected 'start'",
        error.InvalidWeightValue => "invalid weight value, weights must be non-negative",
        error.InvalidPriorValue => "invalid prior value, prior must be greater than 0.0 and at most 2.0",
        error.InvalidKindName => "invalid kind name, expected IDENTIFIER, NUMBER, or STRING",
        error.InvalidConstraintType => "invalid constraint type",
        error.InvalidConstraintDepth => "invalid constraint depth",
        error.InvalidConstraintField => "invalid constraint field",
        error.InvalidConstraintValues => "invalid constraint values",
        error.DeprecatedField => "deprecated field (exclude/not_preceded_by), use [[patterns.constraints]] instead",
        error.InvalidCommentLineType => "[comments] line must be an array of strings",
        error.InvalidCommentBlockType => "[comments] block_open/block_close must be strings",
        error.UnpairedBlockDelimiter => "[comments] block_open and block_close must both be present or both absent",
        error.CommentPrefixTooLong => "[comments] line prefix too long (max 8 characters)",
        error.TooManyLinePrefixes => "[comments] too many line prefixes (max 16)",
        error.BlockDelimiterTooLong => "[comments] block delimiter too long (max 8 characters)",
        error.InvalidTokenSection => "[tokens] entries must be tables with exactly one recognizer (char_class_run, delimited_span, or literal_set)",
        error.DuplicateKindName => "[tokens] duplicate kind name",
        error.EmptyKindName => "[tokens] kind name must not be empty",
        error.InvalidRecognizer => "[tokens] recognizer must be exactly one of char_class_run, delimited_span, or literal_set",
        error.InvalidCharSet => invalid_char_set_message,
        error.EmptyLiteralSet => "[tokens] literal_set must contain non-empty strings",
        error.InvalidCountTable => "[[patterns.count]] must declare non-empty field, open, close, and separator strings (1-8 bytes)",
        error.TooManyCountTables => "too many [[patterns.count]] tables (max 16)",
        error.DuplicateCountField => "[[patterns.count]] field duplicates a capture or earlier count field",
        error.InvalidCaptureTable => "[[patterns.capture]] must declare a non-empty field and at least one of separator/suffix (1-8 bytes)",
        error.UnknownCaptureField => "[[patterns.capture]] field is not a declared capture",
        error.DuplicateCaptureField => "[[patterns.capture]] duplicate table for the same field",
        error.ParenthesizedCaptureParam => "parenthesized capture parameters are removed; use [[patterns.capture]] tables",
        error.ExtentModeConflict => "[[patterns.extent]] cannot combine terminator with open/close",
        error.ExtentNoMode => "[[patterns.extent]] must declare balanced open/close or a terminator",
        error.ExtentIncompleteBalanced => "[[patterns.extent]] balanced mode requires both open and close",
        error.InvalidExtentField => "[[patterns.extent]] field must be 1-64 bytes",
        error.InvalidExtentDelimiter => "[[patterns.extent]] open/close/terminator must be 1-8 bytes",
        error.DuplicateExtentField => "[[patterns.extent]] field duplicates a capture or count field",
        error.ExtentAtColumnWithoutTerminator => "[[patterns.extent]] at_column requires terminator mode",
        error.InvalidExtentAtColumn => "[[patterns.extent]] at_column must be an integer in 0..65535",
        error.TooManyExtentTables => "at most one [[patterns.extent]] table per pattern",
        error.InvalidExtensionsList => "[language] extensions must be an array of non-empty strings",
        error.OutOfMemory => "out of memory",
        else => "unknown grammar error",
    };
}

/// Prefix-free message body for an error from `query_parser.parse`.
fn selectorErrorMessage(err: query_parser.ParseError) []const u8 {
    return switch (err) {
        error.EmptySelector => "empty selector string",
        error.UnclosedBracket => "unclosed bracket in selector",
        error.MissingFieldName => "missing field name in attribute condition",
        error.MissingOperator => "missing or invalid operator in attribute condition",
        error.MissingValue => "missing value in attribute condition",
        error.UnclosedQuote => "unclosed quote in attribute value",
        error.InvalidOperator => "invalid operator, expected '=', '!=', '>', '~=', '^=', or '$='",
        error.ExpectedQuotedValue => "substring operators (~=, ^=, $=) require a quoted string value",
        error.InvalidNumericValue => "invalid numeric value for '>' operator",
        error.UnexpectedCharacter => "unexpected character in selector",
        error.OutOfMemory => "out of memory",
    };
}

/// Reads entire file into arena-allocated buffer.
/// Returns the file content as a byte slice.
/// Prints descriptive error messages to stderr for FileNotFound and AccessDenied.
fn readSourceFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
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
        fatalError("{s}", .{cli.formatCliError(err)});
    };

    // 4. Stdout setup
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    run(io, allocator, parsed, stdout) catch |err| switch (err) {
        error.WriteFailed => {
            // A broken pipe (downstream reader closed early) is a normal,
            // expected event in shell pipelines: exit quietly and successfully.
            // Any other write failure (or an unknown cause) stays fatal.
            if (shouldCleanExitOnWriteFailed(stdout_writer.err)) return;
            fatalError("{s}", .{@errorName(err)});
        },
        else => return err,
    };
}

/// True only when a stdout write failure's concrete cause is a broken pipe
/// (EPIPE). Unknown cause (null) or any other error → false, so those stay
/// fatal. Broken-pipe write failures are a normal, expected shell-pipeline
/// event and become a clean exit.
fn shouldCleanExitOnWriteFailed(cause: ?std.Io.File.Writer.Error) bool {
    return if (cause) |c| c == error.BrokenPipe else false;
}

// Property 1 (classifier): the one decision the fix adds.
// Broken pipe → clean exit; any other concrete cause or unknown (null) → fatal.
test "broken pipe classifier: BrokenPipe cleans, others stay fatal" {
    try std.testing.expect(shouldCleanExitOnWriteFailed(error.BrokenPipe));
    try std.testing.expect(!shouldCleanExitOnWriteFailed(error.NoSpaceLeft));
    try std.testing.expect(!shouldCleanExitOnWriteFailed(error.InputOutput));
    try std.testing.expect(!shouldCleanExitOnWriteFailed(null));
}

/// Everything after stdout setup: help/version early returns, source read,
/// command dispatch, trailing newline, and final flush — verbatim from the
/// original `main` body so non-broken-pipe behavior is byte-identical.
fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    parsed: cli.ParsedArgs,
    stdout: *std.Io.Writer,
) !void {

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

    // 7. Dispatch based on command (source reads live inside the arms that
    // need them: query and single-file parse; parse-dir never reads its target
    // path as a file).
    switch (parsed.command) {
        .query => {
            const resolved_default = if (parsed.grammar_path == null)
                try resolveDefaultGrammars(io, allocator, parsed.target_path)
            else
                null;

            if (parsed.grammar_path) |gp| {
                // Source read (moved from the shared step-6): stdin or file.
                const source = readSourceOrStdin(io, allocator, parsed.target_path) catch {
                    fatalError("failed to read file: {s}", .{parsed.target_path});
                };

                // Parse grammar, compile automaton, tokenize, run engine
                const grammar_source = readSourceFile(io, allocator, gp) catch {
                    fatalError("failed to read grammar file: {s}", .{gp});
                };
                const grammar = grammar_loader.parseGrammar(grammar_source, allocator) catch |err| {
                    const msg: []const u8 = grammarErrorMessage(err);
                    fatalError("{s}: {s}", .{ msg, gp });
                };
                const automaton = try grammar_compiler.compile(grammar.patterns, allocator);
                const tokens = if (grammar.tokens) |vocab|
                    try tokenizer.tokenizeWithVocab(source, vocab, grammar.keyword_table, grammar.comments, allocator)
                else
                    try tokenizer.tokenize(source, grammar.keyword_table, grammar.comments, allocator);
                const structural_events = try engine.parse(automaton, tokens, source, grammar.patterns, grammar.tokens, grammar.blocks, grammar.weights, parsed.resemble, false, allocator);

                // Parse selector string into QueryFilter
                const selector = parsed.query_selector orelse {
                    fatalError("query command requires a selector string", .{});
                };
                const filter = query_parser.parse(selector, allocator) catch |err| {
                    const msg: []const u8 = selectorErrorMessage(err);
                    fatalError("{s}", .{msg});
                };

                // Evaluate filter against structural events
                const filtered = try query_evaluator.evaluate(structural_events, filter, allocator);

                // Output: names-only or JSON
                if (parsed.names_only) {
                    for (filtered) |event| {
                        try writeNamesOnlyLine(stdout, event);
                    }
                } else {
                    if (parsed.jsonl)
                        try json.serializeEventsNdjson(filtered, false, stdout)
                    else
                        try json.serializeEvents(filtered, stdout);
                }
            } else {
                // Default grammar resolution (nullable: absent dir or stdin).
                const resolved = resolved_default orelse {
                    fatalError("query command requires --grammar/-g flag", .{});
                };
                if (resolved.len == 0) {
                    fatalError("query command requires --grammar/-g flag", .{});
                }

                const source = readSourceOrStdin(io, allocator, parsed.target_path) catch {
                    fatalError("failed to read file: {s}", .{parsed.target_path});
                };

                const selector = parsed.query_selector orelse {
                    fatalError("query command requires a selector string", .{});
                };
                const filter = query_parser.parse(selector, allocator) catch |err| {
                    const msg: []const u8 = selectorErrorMessage(err);
                    fatalError("{s}", .{msg});
                };

                if (resolved.len == 1) {
                    // Single match: byte-identical to explicit -g.
                    const lg = resolved[0];
                    const structural_events = try parseWithAutomaton(allocator, lg.grammar, lg.automaton, source, null, false, false);
                    const filtered = try query_evaluator.evaluate(structural_events, filter, allocator);
                    if (parsed.names_only) {
                        for (filtered) |event| {
                            try writeNamesOnlyLine(stdout, event);
                        }
                    } else {
                        if (parsed.jsonl)
                            try json.serializeEventsNdjson(filtered, false, stdout)
                        else
                            try json.serializeEvents(filtered, stdout);
                    }
                } else {
                    // Multi-grammar default: one array entry per matching grammar.
                    if (parsed.names_only) {
                        fatalError("--names-only requires a single grammar (pass -g/--grammar)", .{});
                    }
                    var entries: std.ArrayList(json.DirResult) = .empty;
                    for (resolved) |lg| {
                        const structural_events = try parseWithAutomaton(allocator, lg.grammar, lg.automaton, source, null, false, false);
                        const filtered = try query_evaluator.evaluate(structural_events, filter, allocator);
                        try entries.append(allocator, .{
                            .file = parsed.target_path,
                            .grammar = lg.name,
                            .events = filtered,
                        });
                    }
                    if (parsed.jsonl)
                        try json.serializeDirResultsNdjson(entries.items, false, stdout)
                    else
                        try json.serializeDirResults(entries.items, false, stdout);
                }
            }
        },
        .parse => {
            const resolved_default = if (parsed.grammar_path == null)
                try resolveDefaultGrammars(io, allocator, parsed.target_path)
            else
                null;

            if (parsed.grammar_path) |gp| {
                // Source read (moved from the shared step-6): stdin or file.
                const source = readSourceOrStdin(io, allocator, parsed.target_path) catch {
                    fatalError("failed to read file: {s}", .{parsed.target_path});
                };
                // Phase 2: TOML grammar → structural events
                const grammar_source = readSourceFile(io, allocator, gp) catch {
                    fatalError("failed to read grammar file: {s}", .{gp});
                };
                const grammar = grammar_loader.parseGrammar(grammar_source, allocator) catch |err| {
                    const msg: []const u8 = grammarErrorMessage(err);
                    fatalError("{s}: {s}", .{ msg, gp });
                };
                const collect_alternatives = parsed.alternatives or parsed.resemble;
                const structural_events = try parseOneFile(allocator, grammar, source, parsed.node_filter, parsed.alternatives, parsed.resemble);

                // Output dispatch: names-only or JSON
                if (parsed.names_only) {
                    for (structural_events) |event| {
                        try writeNamesOnlyLine(stdout, event);
                    }
                } else {
                    if (parsed.jsonl)
                        try json.serializeEventsNdjson(structural_events, collect_alternatives, stdout)
                    else
                        try json.serializeEventsWithAlternatives(structural_events, collect_alternatives, stdout);
                }
            } else if (resolved_default) |resolved| {
                const source = readSourceOrStdin(io, allocator, parsed.target_path) catch {
                    fatalError("failed to read file: {s}", .{parsed.target_path});
                };
                if (resolved.len == 0) {
                    // Default dir present but no grammar matches: raw token output.
                    const tokens = try tokenizer.tokenize(source, null, .{}, allocator);
                    if (parsed.jsonl)
                        try json.serializeTokensNdjson(tokens, stdout)
                    else
                        try json.serializeTokens(tokens, stdout);
                } else if (resolved.len == 1) {
                    // Single match: byte-identical to explicit -g.
                    const lg = resolved[0];
                    const structural_events = try parseWithAutomaton(allocator, lg.grammar, lg.automaton, source, parsed.node_filter, parsed.alternatives, parsed.resemble);
                    if (parsed.names_only) {
                        for (structural_events) |event| {
                            try writeNamesOnlyLine(stdout, event);
                        }
                    } else {
                        if (parsed.jsonl)
                            try json.serializeEventsNdjson(structural_events, parsed.alternatives or parsed.resemble, stdout)
                        else
                            try json.serializeEventsWithAlternatives(structural_events, parsed.alternatives or parsed.resemble, stdout);
                    }
                } else {
                    // Multi-grammar default: one array entry per matching grammar
                    // (user choice), reusing the existing DirResult schema.
                    if (parsed.names_only) {
                        fatalError("--names-only requires a single grammar (pass -g/--grammar)", .{});
                    }
                    const collect_alternatives = parsed.alternatives or parsed.resemble;
                    var entries: std.ArrayList(json.DirResult) = .empty;
                    for (resolved) |lg| {
                        const events_list = try parseWithAutomaton(allocator, lg.grammar, lg.automaton, source, parsed.node_filter, parsed.alternatives, parsed.resemble);
                        try entries.append(allocator, .{
                            .file = parsed.target_path,
                            .grammar = lg.name,
                            .events = events_list,
                        });
                    }
                    if (parsed.jsonl)
                        try json.serializeDirResultsNdjson(entries.items, collect_alternatives, stdout)
                    else
                        try json.serializeDirResults(entries.items, collect_alternatives, stdout);
                }
            } else {
                // No grammar: raw token output
                const source = readSourceOrStdin(io, allocator, parsed.target_path) catch {
                    fatalError("failed to read file: {s}", .{parsed.target_path});
                };
                const tokens = try tokenizer.tokenize(source, null, .{}, allocator);
                if (parsed.jsonl)
                    try json.serializeTokensNdjson(tokens, stdout)
                else
                    try json.serializeTokens(tokens, stdout);
            }
        },
        .parse_dir => {
            // A grammar loaded from --grammar-dir, compiled once and reused for
            // every file it matches.
            var loaded: []LoadedGrammar = &.{};
            if (parsed.grammar_dir) |gdir| {
                loaded = loadGrammarsFromDir(io, allocator, gdir) catch {
                    fatalError("grammar directory not found: {s}", .{gdir});
                };
            } else {
                // Default grammar dir: absent is silent (empty → [] output).
                loaded = loadGrammarsFromDir(io, allocator, default_grammar_dir) catch |e| switch (e) {
                    error.GrammarDirNotFound => &.{},
                    else => return e,
                };
            }

            // Open the target directory for walking. A non-directory or missing
            // target is an error (Req 2.8).
            var root = std.Io.Dir.cwd().openDir(io, parsed.target_path, .{ .iterate = true }) catch {
                fatalError("directory not found: {s}", .{parsed.target_path});
            };
            defer root.close(io);

            const collect_alternatives = parsed.alternatives or parsed.resemble;
            var entries: std.ArrayList(json.DirResult) = .empty;

            var walker = root.walk(allocator) catch {
                fatalError("directory not found: {s}", .{parsed.target_path});
            };
            defer walker.deinit();
            while (walker.next(io) catch null) |entry| {
                if (entry.kind != .file) continue;
                for (loaded) |lg| {
                    if (lg.grammar.extensions.len == 0) continue;
                    var matches = false;
                    for (lg.grammar.extensions) |ext| {
                        if (basenameMatchesExtension(entry.basename, ext)) {
                            matches = true;
                            break;
                        }
                    }
                    if (!matches) continue;
                    // Walker paths are relative to the walked root; read through
                    // the target path so cwd-relative and absolute targets both
                    // work (same readSourceFile as single-file mode).
                    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parsed.target_path, entry.path });
                    const source = readSourceFile(io, allocator, full_path) catch {
                        fatalError("failed to read file: {s}", .{full_path});
                    };
                    const events_list = try parseWithAutomaton(allocator, lg.grammar, lg.automaton, source, parsed.node_filter, parsed.alternatives, parsed.resemble);
                    // The walker reuses its path buffers on the next `next()`
                    // call, so entries must own their strings.
                    const file_copy = try allocator.dupe(u8, entry.path);
                    try entries.append(allocator, .{
                        .file = file_copy,
                        .grammar = lg.name,
                        .events = events_list,
                    });
                }
            }

            if (parsed.jsonl)
                try json.serializeDirResultsNdjson(entries.items, collect_alternatives, stdout)
            else
                try json.serializeDirResults(entries.items, collect_alternatives, stdout);
        },
        .version => unreachable,
        .help => unreachable,
    }

    if (!parsed.names_only and !parsed.jsonl) try stdout.writeAll("\n");
    try stdout.flush();
}

/// `--names-only` value selector: an event renders its first string capture;
/// an event with no string capture falls back to its leading integer field
/// (decimal digits); an event with neither renders nothing. No allocation,
/// no I/O — `writeNamesOnlyLine` delegates to this pure selector.
const NamesOnlyValue = union(enum) { text: []const u8, number: u32 };

fn namesOnlyValue(event: events.StructuralEvent) ?NamesOnlyValue {
    if (event.captures.len > 0) return .{ .text = event.captures[0].value };
    if (event.int_fields.len > 0) return .{ .number = event.int_fields[0].value };
    return null;
}

/// `--names-only` rendering: the first string capture renders; an event with
/// no string capture falls back to its leading integer field (decimal digits);
/// an event with neither prints nothing. Each value ends in a single '\n'.
fn writeNamesOnlyLine(stdout: *std.Io.Writer, event: events.StructuralEvent) !void {
    const value = namesOnlyValue(event) orelse return;
    switch (value) {
        .text => |t| {
            try stdout.writeAll(t);
            try stdout.writeAll("\n");
        },
        .number => |n| try stdout.print("{d}\n", .{n}),
    }
}
/// Shared "source + grammar → structural events" pipeline used by single-file
/// `parse` and by `parse-dir` per matched (file, grammar) pair. Verbatim
/// semantics of the former inline `.parse` grammar branch: compile, tokenize
/// (vocab when the grammar declares `[tokens]`), `engine.parse`, then the
/// `--node` filter loop.
fn parseOneFile(
    allocator: std.mem.Allocator,
    grammar: grammar_loader.Grammar,
    source: []const u8,
    node_filter: ?[]const u8,
    alternatives: bool,
    resemble: bool,
) ![]events.StructuralEvent {
    const automaton = try grammar_compiler.compile(grammar.patterns, allocator);
    return parseWithAutomaton(allocator, grammar, automaton, source, node_filter, alternatives, resemble);
}

/// The `parseOneFile` body after automaton compilation; parse-dir reuses one
/// compiled automaton across every file a grammar matches.
fn parseWithAutomaton(
    allocator: std.mem.Allocator,
    grammar: grammar_loader.Grammar,
    automaton: grammar_compiler.Automaton,
    source: []const u8,
    node_filter: ?[]const u8,
    alternatives: bool,
    resemble: bool,
) ![]events.StructuralEvent {
    const tokens = if (grammar.tokens) |vocab|
        try tokenizer.tokenizeWithVocab(source, vocab, grammar.keyword_table, grammar.comments, allocator)
    else
        try tokenizer.tokenize(source, grammar.keyword_table, grammar.comments, allocator);
    // --resemble implies collecting alternatives so resemblance candidates are
    // surfaced through the alternatives path.
    const collect_alternatives = alternatives or resemble;
    var structural_events = try engine.parse(automaton, tokens, source, grammar.patterns, grammar.tokens, grammar.blocks, grammar.weights, resemble, collect_alternatives, allocator);

    // Apply node filter if specified
    if (node_filter) |filter| {
        var filtered_events: std.ArrayList(events.StructuralEvent) = .empty;
        defer filtered_events.deinit(allocator);
        for (structural_events) |event| {
            if (std.ascii.eqlIgnoreCase(event.type_name, filter)) {
                try filtered_events.append(allocator, event);
            }
        }
        structural_events = try filtered_events.toOwnedSlice(allocator);
    }
    return structural_events;
}
/// Reads the target source: stdin when the path is `-`, else the file. Kept
/// as a helper because the read moved out of the shared pre-dispatch step into
/// the query and single-file parse arms (parse-dir never reads its target).
fn readSourceOrStdin(io: std.Io, allocator: std.mem.Allocator, target_path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, target_path, "-")) {
        var stdin_buffer: [4096]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
        return try stdin_reader.interface.allocRemaining(allocator, .unlimited);
    }
    return readSourceFile(io, allocator, target_path);
}

test {
    std.testing.refAllDecls(@This());
}

test {
    // Pull in tests from all modules.
    _ = cli;
    _ = tokenizer;
    _ = resemblance;
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
            const io = std.testing.io;
            var sb = try Sandbox.init(std.testing.allocator);
            defer sb.deinit();
            const tmp_path = try sb.join("roundtrip.tmp");
            defer std.testing.allocator.free(tmp_path);
            // Write random bytes to temp file
            const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
            var wbuf: [256]u8 = undefined;
            var writer = file.writer(io, &wbuf);
            try writer.interface.writeAll(data);
            try writer.interface.flush();
            file.close(io);
            // Read back with readSourceFile
            const content = try readSourceFile(std.testing.io, std.testing.allocator, tmp_path);
            defer std.testing.allocator.free(content);

            // Round trip: content must equal original data
            try std.testing.expectEqualSlices(u8, data, content);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: plain-toml-capture-tables, Integration
// **Validates: Requirements 4.1, 5.1, 7.1, 8.1, 8.2, 12.1**
test "integration: count tables emit integer fields in JSON" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/counts_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/counts.toml",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const events_arr = parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), events_arr.len);

    const args0 = events_arr[0].object.get("args").?;
    try std.testing.expect(args0 == .integer);
    try std.testing.expectEqual(@as(i64, 3), args0.integer);

    const args1 = events_arr[1].object.get("args").?;
    try std.testing.expectEqual(@as(i64, 0), args1.integer);

    const args2 = events_arr[2].object.get("args").?;
    try std.testing.expectEqual(@as(i64, 1), args2.integer);
}

test "integration: query on count field + names-only renders name, not count" {
    const allocator = std.testing.allocator;

    const q = try runLasp(allocator, &.{
        "query",
        "fn[args>1]",
        "tests/fixtures/counts_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/counts.toml",
    });
    defer {
        allocator.free(q.stdout);
        allocator.free(q.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, q.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, q.stdout, .{});
    defer parsed.deinit();
    const events_arr = parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), events_arr.len);
    try std.testing.expectEqual(@as(i64, 3), events_arr[0].object.get("args").?.integer);

    const n = try runLasp(allocator, &.{
        "query",
        "fn[args>0]",
        "tests/fixtures/counts_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/counts.toml",
        "--names-only",
    });
    defer {
        allocator.free(n.stdout);
        allocator.free(n.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, n.term);
    // String capture is preferred over the integer field → names, not counts.
    var lines: usize = 0;
    var all_digit: bool = false;
    var rest: []const u8 = n.stdout;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        const line = rest[0..nl];
        lines += 1;
        if (std.mem.eql(u8, line, "add") or std.mem.eql(u8, line, "one")) {} else if (std.mem.eql(u8, line, "3") or std.mem.eql(u8, line, "1")) all_digit = true;
        rest = rest[nl + 1 ..];
    }
    try std.testing.expectEqual(@as(usize, 2), lines);
    try std.testing.expectEqual(false, all_digit);
}

// Feature: region-extent, Integration
// **Validates: Requirements 4.1, 4.2, 4.3, 5.3, 9.4**

test "integration: brace extent emits bare-integer body field" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/extent_brace_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/extent_brace.toml",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const events_arr = parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), events_arr.len);

    const src = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/extent_brace_sample.txt", allocator, .limited(1 << 20));
    defer allocator.free(src);
    // Independent nested scan: foo's outer close is the '}' that balances the
    {
        var depth: u32 = 1;
        var i: usize = 17;
        while (i < src.len) : (i += 1) {
            if (src[i] == '{') {
                depth += 1;
            } else if (src[i] == '}') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        const first_close = i + 1;
        const body0 = events_arr[0].object.get("body").?;
        try std.testing.expect(body0 == .integer);
        try std.testing.expectEqual(@as(i64, @intCast(first_close)), body0.integer);
    }

    const second_close = std.mem.lastIndexOfScalar(u8, src, '}').? + 1; // bar's brace end
    const body1 = events_arr[1].object.get("body").?;
    try std.testing.expectEqual(@as(i64, @intCast(second_close)), body1.integer);
}

test "integration: terminator extent with at_column=0" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/extent_terminator_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/extent_terminator.toml",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const events_arr = parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), events_arr.len);

    const src = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/extent_terminator_sample.txt", allocator, .limited(1 << 20));
    defer allocator.free(src);
    const dot_end = std.mem.indexOf(u8, src, ".\n").? + 1;
    const region0 = events_arr[0].object.get("region").?;
    try std.testing.expect(region0 == .integer);
    try std.testing.expectEqual(@as(i64, @intCast(dot_end)), region0.integer);
}

test "integration: numeric query on extent field" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{
        "query",
        "function[body>50]",
        "tests/fixtures/extent_brace_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/extent_brace.toml",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const events_arr = parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), events_arr.len);
    try std.testing.expectEqualStrings("function", events_arr[0].object.get("type").?.string);
}

test "integration: no extent table ⇒ no extent field (P9 at CLI level)" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/extent_brace_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/extent_brace.toml",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"body\"") != null);

    // Same grammar without the extent table → no body field anywhere.
    const io = std.testing.io;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    const tmp_path = try sb.join("extent_noextent.toml");
    defer allocator.free(tmp_path);
    const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    var wbuf: [4096]u8 = undefined;
    var writer = file.writer(io, &wbuf);
    try writer.interface.writeAll("[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"$n:IDENTIFIER\", \"(\"]\n");
    try writer.interface.flush();
    file.close(io);
    const plain = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/extent_brace_sample.txt",
        "--grammar",
        tmp_path,
    });
    defer {
        allocator.free(plain.stdout);
        allocator.free(plain.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, plain.term);
    try std.testing.expect(std.mem.indexOf(u8, plain.stdout, "\"body\"") == null);
}

// Feature: region-extent, Property 13: grammar-variation half
test "integration: differing extent delimiters yield differing Region_Extent" {
    const allocator = std.testing.allocator;
    // Bracket-bounded variant: same source, a delimiter pair that does not occur
    // in the body (so both events report EOF = source length).
    const io = std.testing.io;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    const tmp_path = try sb.join("extent_variant.toml");
    defer allocator.free(tmp_path);
    const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    var wbuf: [4096]u8 = undefined;
    var writer = file.writer(io, &wbuf);
    try writer.interface.writeAll("[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"$n:IDENTIFIER\", \"(\"]\n\n[[patterns.extent]]\nfield = \"body\"\nopen = \"[\"\nclose = \"]\"\n");
    try writer.interface.flush();
    file.close(io);
    const result = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/extent_brace_sample.txt",
        "--grammar",
        tmp_path,
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const events_arr = parsed.value.object.get("events").?.array.items;
    const src = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/extent_brace_sample.txt", allocator, .limited(1 << 20));
    defer allocator.free(src);
    const body0 = events_arr[0].object.get("body").?.integer;
    // No bracket in the source → EOF (source length), which differs from the
    // brace grammar's body value (37) for the same event.
    try std.testing.expectEqual(@as(i64, @intCast(src.len)), body0);
}

// --- Integration Tests ---

/// Scratch directory for CLI tests that must create files (fixture trees,
/// throwaway grammars, `.lasp/grammars`). It lives under `.zig-cache/tmp`
/// (`std.testing.tmpDir`: unique random name, removed by `deinit`), never in the
/// repo root. `tests` and `examples` are symlinked into it, so after `enter()`
/// the spawned binary runs with the sandbox as its cwd and repo-relative
/// arguments (`tests/fixtures/...`, `examples/grammars/...`) plus sandbox-relative
/// ones (`tree/a.erl`, `.lasp/grammars`) resolve exactly as they did from the
/// repo root, so output and error-message assertions are unchanged.
const Sandbox = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    /// Absolute sandbox path.
    abs: []u8,
    /// Absolute path of the binary under test (the child's cwd is not the repo root).
    bin: []u8,

    fn init(allocator: std.mem.Allocator) !Sandbox {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const abs = try allocator.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
        errdefer allocator.free(abs);
        const repo = buf[0..try std.Io.Dir.cwd().realPathFile(io, ".", &buf)];
        const bin = try std.fmt.allocPrint(allocator, "{s}/zig-out/bin/lasp", .{repo});
        errdefer allocator.free(bin);
        for ([_][]const u8{ "tests", "examples" }) |name| {
            const target = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo, name });
            defer allocator.free(target);
            try tmp.dir.symLink(io, target, name, .{ .is_directory = true });
        }
        return .{ .allocator = allocator, .tmp = tmp, .abs = abs, .bin = bin };
    }

    /// Makes `runLasp`/`runLaspWithStdin`/`runLaspEarlyClose` spawn with this
    /// sandbox as cwd until `deinit`. Tests run serially, so one active at a time.
    fn enter(self: *const Sandbox) void {
        active_sandbox = .{ .cwd = self.abs, .bin = self.bin };
    }

    fn deinit(self: *Sandbox) void {
        active_sandbox = null;
        self.tmp.cleanup();
        self.allocator.free(self.abs);
        self.allocator.free(self.bin);
    }

    /// Caller-owned absolute path of `rel` inside the sandbox.
    fn join(self: *const Sandbox, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.abs, rel });
    }
};
const ActiveSandbox = struct { cwd: []const u8, bin: []const u8 };
var active_sandbox: ?ActiveSandbox = null;
fn laspBinary() []const u8 {
    return if (active_sandbox) |a| a.bin else "zig-out/bin/lasp";
}
fn laspCwd() std.process.Child.Cwd {
    return if (active_sandbox) |a| .{ .path = a.cwd } else .inherit;
}
fn runLasp(allocator: std.mem.Allocator, args: []const []const u8) !struct { stdout: []u8, stderr: []u8, term: std.process.Child.Term } {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, laspBinary());
    for (args) |a| try argv.append(allocator, a);
    const result = try std.process.run(allocator, std.testing.io, .{ .argv = argv.items, .cwd = laspCwd() });
    return .{ .stdout = result.stdout, .stderr = result.stderr, .term = result.term };
}

// --- parse-dir directory-walk tests (spec: parse-dir-directory-walk) ---
// Task 1 (exploration) + Task 2 (preservation) land BEFORE the fix: Property 1
// MUST fail on the unfixed binary (the directory-read abort), Property 2 MUST
// pass (single-file baseline captured).

fn writeFixtureFile(dir: std.Io.Dir, io: std.Io, path: []const u8, content: []const u8) !void {
    const file = try dir.createFile(io, path, .{});
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(content);
    try w.interface.flush();
    file.close(io);
}

/// Best-effort removal of a fixture directory tree (two passes: files, then
/// directories — walk order is undefined).
fn removeDirTree(dir: std.Io.Dir, allocator: std.mem.Allocator, io: std.Io, path: []const u8) void {
    var root = dir.openDir(io, path, .{ .iterate = true }) catch return;
    defer root.close(io);

    var walker = root.walk(allocator) catch return;
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind == .file) root.deleteFile(io, entry.path) catch {};
    }
    var walker2 = root.walk(allocator) catch return;
    defer walker2.deinit();
    while (walker2.next(io) catch null) |entry| {
        if (entry.kind == .directory) root.deleteDir(io, entry.path) catch {};
    }
    dir.deleteDir(io, path) catch {};
}
/// Suffix match test in `--grammar-dir` extension matching. The dot-less form
/// (e.g. `erl`) is the broader documented suffix.
fn basenameMatchesExtension(basename: []const u8, ext: []const u8) bool {
    return std.mem.endsWith(u8, basename, ext);
}

const default_grammar_dir = ".lasp/grammars";

const LoadedGrammar = struct {
    name: []const u8,
    grammar: grammar_loader.Grammar,
    automaton: grammar_compiler.Automaton,
};

/// Loads every *.toml from gdir (sorted by filename), compiling each automaton
/// once. Fatal (existing messages, naming the offending path) on read/parse
/// failure; only a missing/not-a-directory gdir yields error.GrammarDirNotFound.
fn loadGrammarsFromDir(io: std.Io, allocator: std.mem.Allocator, gdir: []const u8) ![]LoadedGrammar {
    var handle = std.Io.Dir.cwd().openDir(io, gdir, .{ .iterate = true }) catch return error.GrammarDirNotFound;
    defer handle.close(io);

    // Deterministic order: sort the *.toml basenames.
    var names: std.ArrayList([]const u8) = .empty;
    var it = handle.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var loaded: std.ArrayList(LoadedGrammar) = .empty;
    for (names.items) |name| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ gdir, name });
        const grammar_source = readSourceFile(io, allocator, path) catch {
            fatalError("failed to read grammar file: {s}", .{path});
        };
        const grammar = grammar_loader.parseGrammar(grammar_source, allocator) catch |err| {
            const msg: []const u8 = grammarErrorMessage(err);
            fatalError("{s}: {s}", .{ msg, path });
        };
        try loaded.append(allocator, .{
            .name = name,
            .grammar = grammar,
            .automaton = try grammar_compiler.compile(grammar.patterns, allocator),
        });
    }
    return try loaded.toOwnedSlice(allocator);
}

/// Last path segment; posix separator only (targets are CLI paths).
fn fileBasename(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
}

/// Default grammar set for a single target file: all grammars from
/// .lasp/grammars whose extensions suffix-match the target's basename.
/// null when target is "-" (stdin, no basename) or the default dir is absent.
fn resolveDefaultGrammars(io: std.Io, allocator: std.mem.Allocator, target_path: []const u8) !?[]LoadedGrammar {
    if (std.mem.eql(u8, target_path, "-")) return null;
    const loaded = loadGrammarsFromDir(io, allocator, default_grammar_dir) catch |e| switch (e) {
        error.GrammarDirNotFound => return null,
        else => return e,
    };
    var matches: std.ArrayList(LoadedGrammar) = .empty;
    for (loaded) |lg| {
        if (lg.grammar.extensions.len == 0) continue;
        const base = fileBasename(target_path);
        for (lg.grammar.extensions) |ext| {
            if (basenameMatchesExtension(base, ext)) {
                try matches.append(allocator, lg);
                break;
            }
        }
    }
    return try matches.toOwnedSlice(allocator);
}

/// Creates (inside the given sandbox) a dir tree with a `.erl`, a `.py`, an unmatched `.txt`, a
/// recursive `.erl` in a subdirectory, and a grammar dir where the Erlang
/// grammar declares `.erl` and the Python grammar `.py`.
const ParseDirFixture = struct {
    tree: []const u8,
    grammars: []const u8,
};

fn makeParseDirFixture(allocator: std.mem.Allocator, sb: *const Sandbox) !ParseDirFixture {
    const io = std.testing.io;
    const dir = sb.tmp.dir;
    const tree = "test_parsedir_tree";
    const grammars = "test_parsedir_grammars";
    try dir.createDir(io, tree, .default_dir);
    try dir.createDir(io, tree ++ "/sub", .default_dir);
    try dir.createDir(io, grammars, .default_dir);
    try writeFixtureFile(dir, io, tree ++ "/a.erl", "foo() -> 1.\n");
    try writeFixtureFile(dir, io, tree ++ "/b.py", "bar()\n");
    try writeFixtureFile(dir, io, tree ++ "/notes.txt", "irrelevant\n");
    try writeFixtureFile(dir, io, tree ++ "/sub/c.erl", "baz() -> 2.\n");

    const erlang = try std.fmt.allocPrint(allocator, "[language]\nname = \"erlang\"\nextensions = [\".erl\"]\n\n[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"(\"]\n", .{});
    const python = try std.fmt.allocPrint(allocator, "[language]\nname = \"python\"\nextensions = [\".py\"]\n\n[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"(\", \")\"]\n", .{});
    try writeFixtureFile(dir, io, grammars ++ "/erlang.toml", erlang);
    try writeFixtureFile(dir, io, grammars ++ "/python.toml", python);
    allocator.free(erlang);
    allocator.free(python);

    return .{ .tree = tree, .grammars = grammars };
}

/// Asserts the EXPECTED post-fix behavior for one parse-dir form:
/// exit zero, valid JSON array, every entry's `file` is `.erl`/`.py`, the
/// `.txt` appears in no entry, and no `failed to read file` on stderr.
fn expectParseDirOk(result: anytype, allocator: std.mem.Allocator) !void {
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "failed to read file") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "notes.txt") == null);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    for (parsed.value.array.items) |entry| {
        const f = entry.object.get("file").?.string;
        try std.testing.expect(
            std.mem.endsWith(u8, f, ".erl") or std.mem.endsWith(u8, f, ".py"),
        );
        try std.testing.expect(entry.object.get("grammar").? == .string);
        try std.testing.expect(entry.object.get("events").? == .array);
        try std.testing.expect(std.mem.indexOf(u8, f, "notes.txt") == null);
    }
}

// Feature: parse-dir-directory-walk, Property 1: parse-dir walks the tree and
// parses matching files (bug condition). MUST FAIL on the unfixed code.
test "parse-dir: walks tree, parses matching files, skips unmatched (P1)" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    const fixture = try makeParseDirFixture(allocator, &sb);
    // The no-grammar-dir form below expects [] (Req 2.12); that holds because
    // the sandbox cwd has no default .lasp/grammars.
    const abs_tree = try sb.join(fixture.tree);
    defer allocator.free(abs_tree);
    const slash_tree = try std.fmt.allocPrint(allocator, "{s}/", .{fixture.tree});
    defer allocator.free(slash_tree);

    const forms = [_]struct { args: []const []const u8 }{
        .{ .args = &.{ "parse-dir", fixture.tree, "--grammar-dir", fixture.grammars } },
        .{ .args = &.{ "parse-dir", slash_tree, "--grammar-dir", fixture.grammars } },
        .{ .args = &.{ "parse-dir", abs_tree, "--grammar-dir", fixture.grammars } },
        .{ .args = &.{ "parse-dir", fixture.tree } },
    };

    for (forms, 0..) |form, i| {
        const result = try runLasp(allocator, form.args);
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        if (i == 3) {
            // No --grammar-dir ⇒ no grammars ⇒ [] + exit zero (Req 2.12).
            try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
            defer parsed.deinit();
            try std.testing.expect(parsed.value == .array);
            try std.testing.expectEqual(@as(usize, 0), parsed.value.array.items.len);
        } else {
            try expectParseDirOk(result, allocator);
        }
    }
}

// Feature: parse-dir-directory-walk, Property 2: non-parse-dir behavior is
// byte-identical (preservation baseline). Runs on the unfixed binary today and
// must keep passing after the parseOneFile refactor and dispatch split.
test "property: single-file parse/query is deterministic and well-formed (P2)" {
    const tuple_gen = comptime gen.tuple2(
        []const u8,
        u8,
        gen.string(.{ .min_len = 4, .max_len = 200, .charset = .custom, .custom_chars = "abcdefghijklmnopqrstuvwxyz0123456789(){}[];=+*/_ \n\t" }),
        gen.intRange(u8, 0, 3),
    );

    try minish.check(std.testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { []const u8, u8 }) !void {
            const allocator = std.testing.allocator;
            const src = vals[0];
            const flag = vals[1];
            const io = std.testing.io;
            var sb = try Sandbox.init(allocator);
            defer sb.deinit();
            const tmp_path = try sb.join("parsedir_prop.tmp");
            defer allocator.free(tmp_path);
            const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
            var wbuf: [4096]u8 = undefined;
            var writer = file.writer(io, &wbuf);
            try writer.interface.writeAll(src);
            try writer.interface.flush();
            file.close(io);
            const args: []const []const u8 = switch (flag) {
                0 => &.{ "parse", tmp_path },
                1 => &.{ "parse", tmp_path, "-g", "examples/grammars/zig.toml" },
                2 => &.{ "parse", tmp_path, "-g", "examples/grammars/zig.toml", "--node", "function", "--names-only" },
                else => &.{ "query", "*", tmp_path, "-g", "examples/grammars/zig.toml" },
            };

            const r1 = try runLasp(allocator, args);
            const r2 = try runLasp(allocator, args);
            defer {
                allocator.free(r1.stdout);
                allocator.free(r1.stderr);
            }

            defer {
                allocator.free(r2.stdout);
                allocator.free(r2.stderr);
            }

            try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r1.term);
            // Determinism: repeated runs are byte-identical.
            try std.testing.expectEqualStrings(r1.stdout, r2.stdout);
            try std.testing.expectEqualStrings(r1.stderr, r2.stderr);
            // Raw tokens and unfiltered JSON always emit; a filtered query may
            // legitimately emit nothing when no node matches.
            if (flag == 0 or flag == 1) try std.testing.expect(r1.stdout.len > 0);
        }
    }.prop, .{ .num_runs = 100 });
}
/// Recursive structural JSON equality used by the parse-dir union property.
fn expectJsonValueEqual(a: std.json.Value, b: std.json.Value) !void {
    switch (a) {
        .null, .bool, .integer, .float => try std.testing.expectEqual(a, b),
        .number_string => try std.testing.expectEqualStrings(a.number_string, b.number_string),
        .string => try std.testing.expectEqualStrings(a.string, b.string),
        .array => |aa| {
            try std.testing.expect(b == .array);
            try std.testing.expectEqual(aa.items.len, b.array.items.len);
            for (aa.items, b.array.items) |x, y| try expectJsonValueEqual(x, y);
        },
        .object => |ao| {
            try std.testing.expect(b == .object);
            var it = ao.iterator();
            while (it.next()) |e| {
                const child = b.object.get(e.key_ptr.*) orelse return error.MissingJsonField;
                try expectJsonValueEqual(e.value_ptr.*, child);
            }
            try std.testing.expectEqual(ao.count(), b.object.count());
        },
    }
}

// Feature: parse-dir-directory-walk, Property 3: parse-dir equals the
// single-file per-grammar union — one entry per (file, grammar) pair for every
// grammar whose declared extensions match, no entry for unmatched files.
test "property: parse-dir equals single-file per-grammar union (P3)" {
    const FilePool = enum { a_erl, b_py, notes_txt, sub_c_erl };
    const list_gen = comptime gen.list(FilePool, gen.enumValue(FilePool), 1, 5);
    try minish.check(std.testing.allocator, list_gen, struct {
        fn prop(selected: []const FilePool) !void {
            const allocator = std.testing.allocator;
            const io = std.testing.io;
            var sb = try Sandbox.init(allocator);
            defer sb.deinit();
            sb.enter();
            const dir = sb.tmp.dir;
            const tree = "test_parsedir_prop3_tree";
            const grammars = "test_parsedir_prop3_grammars";
            try dir.createDir(io, tree, .default_dir);
            try dir.createDir(io, tree ++ "/sub", .default_dir);
            try dir.createDir(io, grammars, .default_dir);

            var seen = [_]bool{false} ** 4;
            for (selected) |f| seen[@intFromEnum(f)] = true;
            if (seen[@intFromEnum(FilePool.a_erl)])
                try writeFixtureFile(dir, io, tree ++ "/a.erl", "foo() -> 1.\n");
            if (seen[@intFromEnum(FilePool.b_py)])
                try writeFixtureFile(dir, io, tree ++ "/b.py", "bar()\n");
            if (seen[@intFromEnum(FilePool.notes_txt)])
                try writeFixtureFile(dir, io, tree ++ "/notes.txt", "irrelevant\n");
            if (seen[@intFromEnum(FilePool.sub_c_erl)])
                try writeFixtureFile(dir, io, tree ++ "/sub/c.erl", "baz() -> 2.\n");

            const erlang = "[language]\nname = \"erlang\"\nextensions = [\".erl\"]\n\n[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"(\"]\n";
            const erlang2 = "[language]\nname = \"erlang2\"\nextensions = [\".erl\"]\n\n[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"(\"]\n";
            const python = "[language]\nname = \"python\"\nextensions = [\".py\"]\n\n[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"(\", \")\"]\n";
            try writeFixtureFile(dir, io, grammars ++ "/erlang.toml", erlang);
            try writeFixtureFile(dir, io, grammars ++ "/erlang2.toml", erlang2);
            try writeFixtureFile(dir, io, grammars ++ "/python.toml", python);

            const args = [_][]const u8{ "parse-dir", tree, "--grammar-dir", grammars };
            const result = try runLasp(allocator, &args);
            defer {
                allocator.free(result.stdout);
                allocator.free(result.stderr);
            }
            try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
            defer parsed.deinit();
            const arr = parsed.value.array;

            var expected: usize = 0;
            if (seen[@intFromEnum(FilePool.a_erl)]) expected += 2;
            if (seen[@intFromEnum(FilePool.sub_c_erl)]) expected += 2;
            if (seen[@intFromEnum(FilePool.b_py)]) expected += 1;
            try std.testing.expectEqual(expected, arr.items.len);

            for (arr.items) |entry| {
                const file = entry.object.get("file").?.string;
                const grammar = entry.object.get("grammar").?.string;
                const gpath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ grammars, grammar });
                defer allocator.free(gpath);
                const fpath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tree, file });
                defer allocator.free(fpath);
                const sargs = [_][]const u8{ "parse", fpath, "-g", gpath };
                const single = try runLasp(allocator, &sargs);
                defer {
                    allocator.free(single.stdout);
                    allocator.free(single.stderr);
                }
                const single_parsed = try std.json.parseFromSlice(std.json.Value, allocator, single.stdout, .{});
                defer single_parsed.deinit();
                try expectJsonValueEqual(
                    entry.object.get("events").?,
                    single_parsed.value.object.get("events").?,
                );
            }
        }
    }.prop, .{ .num_runs = 50 });
}

// Feature: parse-dir-directory-walk, Property 4: directory and grammar errors
// exit non-zero with descriptive stderr; the no-grammar-dir case exits zero
// with `[]` and never touches the target as a file.
test "property: directory and grammar errors exit non-zero (P4)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    // The no-grammar-dir case below (Req 2.12) expects [] — as with P1,
    // only true without a default .lasp/grammars, which the sandbox cwd lacks.
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    const dir = sb.tmp.dir;
    const tree = "test_parsedir_prop4_tree";
    const grammars = "test_parsedir_prop4_grammars";
    const bad_grammars = "test_parsedir_prop4_bad_grammars";
    try dir.createDir(io, tree, .default_dir);
    try dir.createDir(io, grammars, .default_dir);
    try dir.createDir(io, bad_grammars, .default_dir);
    try writeFixtureFile(dir, io, tree ++ "/a.erl", "foo() -> 1.\n");
    try writeFixtureFile(dir, io, grammars ++ "/erlang.toml", "[language]\nname = \"erlang\"\nextensions = [\".erl\"]\n\n[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"(\"]\n");
    try writeFixtureFile(dir, io, bad_grammars ++ "/broken.toml", "not valid toml [");

    // Req 2.8: missing target directory → non-zero, descriptive stderr.
    const r1 = try runLasp(allocator, &.{ "parse-dir", "test_parsedir_nope", "--grammar-dir", grammars });
    defer {
        allocator.free(r1.stdout);
        allocator.free(r1.stderr);
    }
    try std.testing.expect(!std.meta.eql(r1.term, std.process.Child.Term{ .exited = 0 }));
    try std.testing.expect(std.mem.indexOf(u8, r1.stderr, "directory not found") != null);
    // Preservation (error-prefix fix): exactly one prefix, exact bytes, exit 1, empty stdout.
    try expectFatalResultOnePrefix(r1.term, r1.stdout, r1.stderr, "error: directory not found: test_parsedir_nope\n");

    // Req 2.9: missing grammar dir → non-zero, descriptive stderr.
    const r2 = try runLasp(allocator, &.{ "parse-dir", tree, "--grammar-dir", "test_parsedir_nope_grammars" });
    defer {
        allocator.free(r2.stdout);
        allocator.free(r2.stderr);
    }
    try std.testing.expect(!std.meta.eql(r2.term, std.process.Child.Term{ .exited = 0 }));
    try std.testing.expect(std.mem.indexOf(u8, r2.stderr, "grammar directory not found") != null);
    try expectFatalResultOnePrefix(r2.term, r2.stdout, r2.stderr, "error: grammar directory not found: test_parsedir_nope_grammars\n");

    // Req 2.10: malformed grammar names the offending path.
    const r3 = try runLasp(allocator, &.{ "parse-dir", tree, "--grammar-dir", bad_grammars });
    defer {
        allocator.free(r3.stdout);
        allocator.free(r3.stderr);
    }
    try std.testing.expect(!std.meta.eql(r3.term, std.process.Child.Term{ .exited = 0 }));
    try std.testing.expect(std.mem.indexOf(u8, r3.stderr, "broken.toml") != null);

    // Req 2.12: no --grammar-dir ⇒ [] + exit zero, never a file read.
    const r4 = try runLasp(allocator, &.{ "parse-dir", tree });
    defer {
        allocator.free(r4.stdout);
        allocator.free(r4.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r4.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, r4.stdout, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.array.items.len);
    try std.testing.expect(std.mem.indexOf(u8, r4.stderr, "failed to read file") == null);
}
test "parse-dir: extension suffix match helper (P5)" {
    try std.testing.expect(basenameMatchesExtension("foo.erl", ".erl"));
    try std.testing.expect(!basenameMatchesExtension("foo.py", ".erl"));
    // Dot-less form is the broader suffix.
    try std.testing.expect(basenameMatchesExtension("file.cxx", "cxx"));
    try std.testing.expect(!basenameMatchesExtension("file.cx", "cxx"));
    // Whole-name suffix still matches.
    try std.testing.expect(basenameMatchesExtension("notes", "notes"));
    try std.testing.expect(!basenameMatchesExtension("notes.txt", "notes"));
}
// Feature: parse-dir-directory-walk, task 7.1: committed-fixture integration
// against the freshly built binary.
test "parse-dir (integration): committed fixtures, recursion, multi-grammar, --node, empty" {
    const allocator = std.testing.allocator;
    const dir = "tests/fixtures/dir_sample";
    const io = std.testing.io;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    const gdir = "tests/fixtures/grammars_dir";
    const multi_gdir = "tests/fixtures/grammars_multi_dir";

    // Happy path + recursion: a.erl, sub/c.erl, b.py matched; notes.txt skipped.
    const happy = try runLasp(allocator, &.{ "parse-dir", dir, "--grammar-dir", gdir });
    defer {
        allocator.free(happy.stdout);
        allocator.free(happy.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, happy.term);
    const happy_parsed = try std.json.parseFromSlice(std.json.Value, allocator, happy.stdout, .{});
    defer happy_parsed.deinit();
    const happy_arr = happy_parsed.value.array;
    try std.testing.expectEqual(@as(usize, 3), happy_arr.items.len);
    var count_erl: usize = 0;
    var count_py: usize = 0;
    for (happy_arr.items) |entry| {
        const file = entry.object.get("file").?.string;
        try std.testing.expect(std.mem.endsWith(u8, file, ".erl") or std.mem.endsWith(u8, file, ".py"));
        if (std.mem.endsWith(u8, file, ".erl")) count_erl += 1;
        if (std.mem.endsWith(u8, file, ".py")) count_py += 1;
        try std.testing.expect(std.mem.indexOf(u8, happy.stderr, "failed to read file") == null);
    }
    try std.testing.expectEqual(@as(usize, 2), count_erl);
    try std.testing.expectEqual(@as(usize, 1), count_py);
    try std.testing.expect(std.mem.indexOf(u8, happy.stdout, "notes.txt") == null);
    try std.testing.expect(std.mem.indexOf(u8, happy.stdout, "sub/c.erl") != null);

    // Multi-grammar per extension: two grammars declare .erl ⇒ two entries
    // per .erl file, each attributable via "grammar".
    const multi = try runLasp(allocator, &.{ "parse-dir", dir, "--grammar-dir", multi_gdir });
    defer {
        allocator.free(multi.stdout);
        allocator.free(multi.stderr);
    }
    const multi_parsed = try std.json.parseFromSlice(std.json.Value, allocator, multi.stdout, .{});
    defer multi_parsed.deinit();
    const multi_arr = multi_parsed.value.array;
    var erl_entries: usize = 0;
    for (multi_arr.items) |entry| {
        const file = entry.object.get("file").?.string;
        if (std.mem.endsWith(u8, file, ".erl")) erl_entries += 1;
        const grammar = entry.object.get("grammar").?.string;
        try std.testing.expect(std.mem.eql(u8, grammar, "erlang.toml") or std.mem.eql(u8, grammar, "erlang2.toml"));
    }
    try std.testing.expectEqual(@as(usize, 4), erl_entries); // a.erl + sub/c.erl × 2 grammars

    // --node in dir mode: filtered events only.
    const filtered = try runLasp(allocator, &.{ "parse-dir", dir, "--grammar-dir", gdir, "--node", "class" });
    defer {
        allocator.free(filtered.stdout);
        allocator.free(filtered.stderr);
    }
    const filtered_parsed = try std.json.parseFromSlice(std.json.Value, allocator, filtered.stdout, .{});
    defer filtered_parsed.deinit();
    for (filtered_parsed.value.array.items) |entry| {
        try std.testing.expectEqual(@as(usize, 0), entry.object.get("events").?.array.items.len);
    }

    // All-.txt dir ⇒ exit zero, [].
    const txt_dir = "dir_txt_only";
    try sb.tmp.dir.createDir(io, txt_dir, .default_dir);
    try writeFixtureFile(sb.tmp.dir, std.testing.io, txt_dir ++ "/notes.txt", "irrelevant\n");
    const txt = try runLasp(allocator, &.{ "parse-dir", txt_dir, "--grammar-dir", gdir });
    defer {
        allocator.free(txt.stdout);
        allocator.free(txt.stderr);
    }
    const txt_parsed = try std.json.parseFromSlice(std.json.Value, allocator, txt.stdout, .{});
    defer txt_parsed.deinit();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, txt.term);
    try std.testing.expectEqual(@as(usize, 0), txt_parsed.value.array.items.len);
}

// --- Default grammar search tests (spec: default-grammar-search) ---
// With no -g/--grammar-dir, `.lasp/grammars` in the cwd is the default grammar
// source; several matching grammars all run (one DirResult entry each).

const erlang_grammar_toml = "[language]\nname = \"erlang\"\nextensions = [\".erl\"]\n\n[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"(\"]\n";
const erlang2_grammar_toml = "[language]\nname = \"erlang2\"\nextensions = [\".erl\"]\n\n[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"(\"]\n";
const python_grammar_toml = "[language]\nname = \"python\"\nextensions = [\".py\"]\n\n[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"(\", \")\"]\n";

const SeedGrammar = struct {
    name: []const u8,
    content: []const u8,
};

/// Recreates `.lasp/grammars` inside the sandbox (removing any pre-existing
/// `.lasp` there) with the given grammar files.
fn seedDefaultGrammars(allocator: std.mem.Allocator, sb: *const Sandbox, seeds: []const SeedGrammar) !void {
    const io = std.testing.io;
    const dir = sb.tmp.dir;
    removeDirTree(dir, allocator, io, ".lasp");
    try dir.createDir(io, ".lasp", .default_dir);
    try dir.createDir(io, ".lasp/grammars", .default_dir);
    for (seeds) |s| {
        const path = try std.fmt.allocPrint(allocator, ".lasp/grammars/{s}", .{s.name});
        defer allocator.free(path);
        try writeFixtureFile(dir, io, path, s.content);
    }
}

test "default grammar: parse single match is byte-identical to explicit -g" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedDefaultGrammars(allocator, &sb, &.{.{ .name = "erlang.toml", .content = erlang_grammar_toml }});

    const def = try runLasp(allocator, &.{ "parse", "tests/fixtures/dir_sample/a.erl" });
    defer {
        allocator.free(def.stdout);
        allocator.free(def.stderr);
    }
    const expl = try runLasp(allocator, &.{ "parse", "tests/fixtures/dir_sample/a.erl", "-g", ".lasp/grammars/erlang.toml" });
    defer {
        allocator.free(expl.stdout);
        allocator.free(expl.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, def.term);
    try std.testing.expectEqualStrings(expl.stdout, def.stdout);
}

test "default grammar: parse multi-match returns one array entry per grammar, sorted" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedDefaultGrammars(allocator, &sb, &.{
        .{ .name = "erlang.toml", .content = erlang_grammar_toml },
        .{ .name = "erlang2.toml", .content = erlang2_grammar_toml },
    });

    const def = try runLasp(allocator, &.{ "parse", "tests/fixtures/dir_sample/a.erl" });
    defer {
        allocator.free(def.stdout);
        allocator.free(def.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, def.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, def.stdout, .{});
    defer parsed.deinit();
    const arr = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 2), arr.items.len);
    try std.testing.expectEqualStrings("erlang.toml", arr.items[0].object.get("grammar").?.string);
    try std.testing.expectEqualStrings("erlang2.toml", arr.items[1].object.get("grammar").?.string);

    // Each entry's events match the corresponding explicit -g run.
    const expl0 = try runLasp(allocator, &.{ "parse", "tests/fixtures/dir_sample/a.erl", "-g", ".lasp/grammars/erlang.toml" });
    defer {
        allocator.free(expl0.stdout);
        allocator.free(expl0.stderr);
    }
    const expl1 = try runLasp(allocator, &.{ "parse", "tests/fixtures/dir_sample/a.erl", "-g", ".lasp/grammars/erlang2.toml" });
    defer {
        allocator.free(expl1.stdout);
        allocator.free(expl1.stderr);
    }
    const p0 = try std.json.parseFromSlice(std.json.Value, allocator, expl0.stdout, .{});
    defer p0.deinit();
    const p1 = try std.json.parseFromSlice(std.json.Value, allocator, expl1.stdout, .{});
    defer p1.deinit();
    try expectJsonValueEqual(arr.items[0].object.get("events").?, p0.value.object.get("events").?);
    try expectJsonValueEqual(arr.items[1].object.get("events").?, p1.value.object.get("events").?);

    // notes.txt matches no extension → raw token fallback.
    const notes = try runLasp(allocator, &.{ "parse", "tests/fixtures/dir_sample/notes.txt" });
    defer {
        allocator.free(notes.stdout);
        allocator.free(notes.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, notes.term);
    const notes_parsed = try std.json.parseFromSlice(std.json.Value, allocator, notes.stdout, .{});
    defer notes_parsed.deinit();
    const note_events = notes_parsed.value.object.get("events").?.array.items;
    try std.testing.expect(note_events.len > 0);
    try std.testing.expect(note_events[0].object.get("col") != null); // token object, not structural event
}

test "default grammar: --names-only + multi-match is fatal" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedDefaultGrammars(allocator, &sb, &.{
        .{ .name = "erlang.toml", .content = erlang_grammar_toml },
        .{ .name = "erlang2.toml", .content = erlang2_grammar_toml },
    });

    const r = try runLasp(allocator, &.{ "parse", "tests/fixtures/dir_sample/a.erl", "--names-only" });
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expect(!std.meta.eql(r.term, std.process.Child.Term{ .exited = 0 }));
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "--names-only requires a single grammar") != null);
}

test "default grammar: query single match is byte-identical to explicit -g" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedDefaultGrammars(allocator, &sb, &.{.{ .name = "erlang.toml", .content = erlang_grammar_toml }});

    const def = try runLasp(allocator, &.{ "query", "function", "tests/fixtures/dir_sample/a.erl" });
    defer {
        allocator.free(def.stdout);
        allocator.free(def.stderr);
    }
    const expl = try runLasp(allocator, &.{ "query", "function", "tests/fixtures/dir_sample/a.erl", "-g", ".lasp/grammars/erlang.toml" });
    defer {
        allocator.free(expl.stdout);
        allocator.free(expl.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, def.term);
    try std.testing.expectEqualStrings(expl.stdout, def.stdout);
}

test "default grammar: query multi-match returns filtered array entries" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedDefaultGrammars(allocator, &sb, &.{
        .{ .name = "erlang.toml", .content = erlang_grammar_toml },
        .{ .name = "erlang2.toml", .content = erlang2_grammar_toml },
    });

    const r = try runLasp(allocator, &.{ "query", "function", "tests/fixtures/dir_sample/a.erl" });
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, r.stdout, .{});
    defer parsed.deinit();
    const arr = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 2), arr.items.len);
    try std.testing.expectEqualStrings("erlang.toml", arr.items[0].object.get("grammar").?.string);
    try std.testing.expectEqualStrings("erlang2.toml", arr.items[1].object.get("grammar").?.string);
    for (arr.items) |entry| {
        try std.testing.expectEqual(@as(usize, 1), entry.object.get("events").?.array.items.len);
    }
}

test "default grammar: parse-dir default == explicit --grammar-dir; absent default falls back" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedDefaultGrammars(allocator, &sb, &.{
        .{ .name = "erlang.toml", .content = erlang_grammar_toml },
        .{ .name = "python.toml", .content = python_grammar_toml },
    });

    // With the default dir present, parse-dir == explicit --grammar-dir.
    const def = try runLasp(allocator, &.{ "parse-dir", "tests/fixtures/dir_sample" });
    defer {
        allocator.free(def.stdout);
        allocator.free(def.stderr);
    }
    const expl = try runLasp(allocator, &.{ "parse-dir", "tests/fixtures/dir_sample", "--grammar-dir", ".lasp/grammars" });
    defer {
        allocator.free(expl.stdout);
        allocator.free(expl.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, def.term);
    try std.testing.expectEqualStrings(expl.stdout, def.stdout);

    // Absent default dir: parse-dir emits [], exit zero; query still requires
    // -g; parse falls back to raw tokens (file and stdin).
    removeDirTree(sb.tmp.dir, allocator, std.testing.io, ".lasp");
    const empty = try runLasp(allocator, &.{ "parse-dir", "tests/fixtures/dir_sample" });
    defer {
        allocator.free(empty.stdout);
        allocator.free(empty.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, empty.term);
    const empty_parsed = try std.json.parseFromSlice(std.json.Value, allocator, empty.stdout, .{});
    defer empty_parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_parsed.value.array.items.len);

    const q = try runLasp(allocator, &.{ "query", "function", "tests/fixtures/dir_sample/a.erl" });
    defer {
        allocator.free(q.stdout);
        allocator.free(q.stderr);
    }
    try std.testing.expect(!std.meta.eql(q.term, std.process.Child.Term{ .exited = 0 }));
    try std.testing.expect(std.mem.indexOf(u8, q.stderr, "requires --grammar") != null);

    const parse_fb = try runLasp(allocator, &.{ "parse", "tests/fixtures/dir_sample/a.erl" });
    defer {
        allocator.free(parse_fb.stdout);
        allocator.free(parse_fb.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, parse_fb.term);
    const fb_parsed = try std.json.parseFromSlice(std.json.Value, allocator, parse_fb.stdout, .{});
    defer fb_parsed.deinit();
    const fb_events = fb_parsed.value.object.get("events").?.array.items;
    try std.testing.expect(fb_events.len > 0);
    try std.testing.expect(fb_events[0].object.get("col") != null);

    const stdin_r = try runLaspWithStdin(allocator, &.{ "parse", "-" }, "fn f() {}");
    defer {
        allocator.free(stdin_r.stdout);
        allocator.free(stdin_r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, stdin_r.term);
    const stdin_parsed = try std.json.parseFromSlice(std.json.Value, allocator, stdin_r.stdout, .{});
    defer stdin_parsed.deinit();
    const stdin_events = stdin_parsed.value.object.get("events").?.array.items;
    try std.testing.expect(stdin_events.len > 0);
    try std.testing.expect(stdin_events[0].object.get("col") != null);
}

// --- Broken-pipe clean-exit tests (spec: broken-pipe-clean-exit) ---
// The binary under test is `zig-out/bin/lasp` (freshly built). The large
// fixture guarantees the child's stdout stream exceeds the OS pipe buffer
// (~64 KiB), so closing the read end early forces a real EPIPE on the child's
// subsequent writes (deterministic bug reproduction).

fn makeLargeZigFixture(io: std.Io, sb: *const Sandbox) ![]const u8 {
    const path = "broken_pipe_large.zig";
    const file = try sb.tmp.dir.createFile(io, path, .{});
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        try w.interface.print("pub fn f{d}() void {{ var x: i32 = {d}; }}\n", .{ i, i });
    }
    try w.interface.flush();
    file.close(io);
    return path;
}

/// Spawns LASP, reads exactly `prefix_len` bytes of stdout, closes the read end
/// (simulating `head -c N`), then waits. Returns the term and captured stderr.
fn runLaspEarlyClose(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    prefix_len: usize,
) !struct { term: std.process.Child.Term, stderr: []u8 } {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, laspBinary());
    for (args) |a| try argv.append(allocator, a);
    var child = try std.process.spawn(std.testing.io, .{
        .argv = argv.items,
        .cwd = laspCwd(),
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer if (child.stdout) |f| f.close(std.testing.io);
    defer if (child.stderr) |f| f.close(std.testing.io);

    // Drain a small prefix of stdout, then close the read end.
    var buf: [4096]u8 = undefined;
    if (child.stdout) |out| {
        var prefix_read: usize = 0;
        var r = out.reader(std.testing.io, &buf);
        while (prefix_read < prefix_len) {
            var slices = [1][]u8{buf[prefix_read..]};
            const n = try r.interface.readVec(&slices);
            if (n == 0) break;
            prefix_read += n;
        }
        out.close(std.testing.io);
        child.stdout = null;
    }

    const term = try child.wait(std.testing.io);

    var stderr_out: []u8 = &[_]u8{};
    if (child.stderr) |err_f| {
        var ebuf: [4096]u8 = undefined;
        var er = err_f.reader(std.testing.io, &ebuf);
        stderr_out = try er.interface.allocRemaining(allocator, .limited(1 << 20));
        child.stderr = null;
    }
    return .{ .term = term, .stderr = stderr_out };
}

// Property 1 (bug condition): a downstream reader that closes the pipe early
// must not be a fatal error — clean exit 0 with empty stderr. On the unfixed
// binary these tests FAIL (non-zero term, stderr contains `WriteFailed`),
// confirming the bug; the same tests validate the fix later.

test "broken pipe: parse (JSON) with early-closing reader exits cleanly" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    const fixture = try makeLargeZigFixture(std.testing.io, &sb);

    const result = try runLaspEarlyClose(allocator, &.{
        "parse", fixture, "-g", "examples/grammars/zig.toml",
    }, 64);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqual(@as(usize, 0), result.stderr.len);
}

test "broken pipe: query with early-closing reader exits cleanly" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    const fixture = try makeLargeZigFixture(std.testing.io, &sb);

    const result = try runLaspEarlyClose(allocator, &.{
        "query", "*", fixture, "-g", "examples/grammars/zig.toml",
    }, 64);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqual(@as(usize, 0), result.stderr.len);
}

test "broken pipe: --jsonl with early-closing reader exits cleanly" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    const fixture = try makeLargeZigFixture(std.testing.io, &sb);

    const result = try runLaspEarlyClose(allocator, &.{
        "parse", fixture, "-g", "examples/grammars/zig.toml", "--jsonl",
    }, 64);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqual(@as(usize, 0), result.stderr.len);
}

test "broken pipe: --names-only with early-closing reader exits cleanly" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    const fixture = try makeLargeZigFixture(std.testing.io, &sb);

    const result = try runLaspEarlyClose(allocator, &.{
        "parse", fixture, "-g", "examples/grammars/zig.toml", "--names-only",
    }, 64);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqual(@as(usize, 0), result.stderr.len);
}

// Property 2 (preservation): full-reading consumers keep complete output and
// exit 0 — asserted across random valid-ish Zig sources (full-write domain).

test "property: full-read parse preserves complete output and exit 0" {
    const source_gen = gen.string(.{ .min_len = 16, .max_len = 512, .charset = .custom, .custom_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789(){}[];=+*/_ \n\t" });

    try minish.check(std.testing.allocator, source_gen, struct {
        fn prop(src: []const u8) !void {
            const allocator = std.testing.allocator;
            const io = std.testing.io;
            var sb = try Sandbox.init(allocator);
            defer sb.deinit();
            const tmp_path = try sb.join("broken_pipe_prop.tmp");
            defer allocator.free(tmp_path);
            const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
            var wbuf: [4096]u8 = undefined;
            var writer = file.writer(io, &wbuf);
            try writer.interface.writeAll(src);
            try writer.interface.flush();
            file.close(io);
            const result = try runLasp(allocator, &.{ "parse", tmp_path, "-g", "examples/grammars/zig.toml" });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
            try std.testing.expect(result.stdout.len > 0);
        }
    }.prop, .{ .num_runs = 100 });
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
    // Exactly one line: `lasp <version>\n`, where the version is the plain semver
    // or a dev build `X.Y.Z-dev+<short-commit>`.
    try std.testing.expect(std.mem.endsWith(u8, result.stdout, "\n"));
    try std.testing.expect(std.mem.indexOfScalar(u8, result.stdout, '\n') == result.stdout.len - 1);
    var it = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() == null);
    const version_str = std.mem.trim(u8, result.stdout["lasp ".len..], " \n");
    try std.testing.expect(version_str.len > 0);
    const dev_marker = std.mem.indexOf(u8, version_str, "-dev+");
    if (dev_marker) |idx| {
        // `-dev+` must be followed by a non-empty hex-ish short commit.
        try std.testing.expect(version_str.len > idx + 5);
    }
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
// Feature: names-only-prefer-string-capture
// Test-only copy of the unfixed helper (the F reference): integer first, then capture.
fn referenceWriteNamesOnlyLine(stdout: *std.Io.Writer, event: events.StructuralEvent) !void {
    if (event.int_fields.len > 0) {
        try stdout.print("{d}\n", .{event.int_fields[0].value});
        return;
    }
    if (event.captures.len > 0) {
        try stdout.writeAll(event.captures[0].value);
        try stdout.writeAll("\n");
    }
}

fn namesOnlyTestEvent(captures: []const events.CaptureEntry, ints: []const events.IntegerField) events.StructuralEvent {
    return .{
        .type_name = "test",
        .captures = captures,
        .start = 0,
        .end = 10,
        .line = 1,
        .col = 0,
        .confidence = 1.0,
        .int_fields = ints,
    };
}

fn renderNamesOnly(allocator: std.mem.Allocator, event: events.StructuralEvent, reference: bool) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    if (reference) {
        try referenceWriteNamesOnlyLine(&aw.writer, event);
    } else {
        try writeNamesOnlyLine(&aw.writer, event);
    }
    return aw.toOwnedSlice();
}

/// Generated event storage: captures "c<seed>_<i>" and u32 integer fields.
const NamesOnlyGen = struct {
    captures: []events.CaptureEntry,
    ints: []events.IntegerField,
    values: [][]u8,

    fn init(allocator: std.mem.Allocator, ncap: usize, nint: usize, seed: u32) !NamesOnlyGen {
        const captures = try allocator.alloc(events.CaptureEntry, ncap);
        errdefer allocator.free(captures);
        const values = try allocator.alloc([]u8, ncap);
        errdefer allocator.free(values);
        var made: usize = 0;
        errdefer for (values[0..made]) |v| allocator.free(v);
        while (made < ncap) : (made += 1) {
            values[made] = try std.fmt.allocPrint(allocator, "c{d}_{d}", .{ seed, made });
            captures[made] = .{ .field_name = "name", .value = values[made] };
        }
        const ints = try allocator.alloc(events.IntegerField, nint);
        for (ints, 0..) |*f, i| f.* = .{ .field_name = "n", .value = seed *% 2654435761 +% @as(u32, @intCast(i)) };
        return .{ .captures = captures, .ints = ints, .values = values };
    }

    fn deinit(self: NamesOnlyGen, allocator: std.mem.Allocator) void {
        for (self.values) |v| allocator.free(v);
        allocator.free(self.values);
        allocator.free(self.captures);
        allocator.free(self.ints);
    }
};

test "unit: namesOnlyValue prefers first string capture over integer fields" {
    const caps = [_]events.CaptureEntry{.{ .field_name = "name", .value = "add" }};
    const ints = [_]events.IntegerField{.{ .field_name = "args", .value = 3 }};
    const v = namesOnlyValue(namesOnlyTestEvent(&caps, &ints)).?;
    try std.testing.expectEqualStrings("add", v.text);
}

test "unit: namesOnlyValue extent shape (capture n + integer body) returns text" {
    const caps = [_]events.CaptureEntry{.{ .field_name = "n", .value = "foo" }};
    const ints = [_]events.IntegerField{.{ .field_name = "body", .value = 10815 }};
    const v = namesOnlyValue(namesOnlyTestEvent(&caps, &ints)).?;
    try std.testing.expectEqualStrings("foo", v.text);
}

test "unit: namesOnlyValue several captures and integers returns first capture" {
    const caps = [_]events.CaptureEntry{
        .{ .field_name = "a", .value = "first" },
        .{ .field_name = "b", .value = "second" },
    };
    const ints = [_]events.IntegerField{
        .{ .field_name = "x", .value = 0 },
        .{ .field_name = "y", .value = 9 },
    };
    const v = namesOnlyValue(namesOnlyTestEvent(&caps, &ints)).?;
    try std.testing.expectEqualStrings("first", v.text);
}

test "unit: namesOnlyValue integer-only returns number, including 0" {
    const zero = [_]events.IntegerField{.{ .field_name = "body", .value = 0 }};
    const v0 = namesOnlyValue(namesOnlyTestEvent(&.{}, &zero)).?;
    try std.testing.expectEqual(@as(u32, 0), v0.number);
    const some = [_]events.IntegerField{ .{ .field_name = "body", .value = 42 }, .{ .field_name = "z", .value = 7 } };
    const v1 = namesOnlyValue(namesOnlyTestEvent(&.{}, &some)).?;
    try std.testing.expectEqual(@as(u32, 42), v1.number);
}

test "unit: namesOnlyValue string-only returns text; neither returns null" {
    const caps = [_]events.CaptureEntry{.{ .field_name = "name", .value = "solo" }};
    const v = namesOnlyValue(namesOnlyTestEvent(&caps, &.{})).?;
    try std.testing.expectEqualStrings("solo", v.text);
    try std.testing.expect(namesOnlyValue(namesOnlyTestEvent(&.{}, &.{})) == null);
}

test "unit: writeNamesOnlyLine renders text, number, nothing, and empty capture" {
    const allocator = std.testing.allocator;
    const caps = [_]events.CaptureEntry{.{ .field_name = "name", .value = "name" }};
    const out_text = try renderNamesOnly(allocator, namesOnlyTestEvent(&caps, &.{}), false);
    defer allocator.free(out_text);
    try std.testing.expectEqualStrings("name\n", out_text);

    const ints = [_]events.IntegerField{.{ .field_name = "body", .value = 12 }};
    const out_num = try renderNamesOnly(allocator, namesOnlyTestEvent(&.{}, &ints), false);
    defer allocator.free(out_num);
    try std.testing.expectEqualStrings("12\n", out_num);

    const out_none = try renderNamesOnly(allocator, namesOnlyTestEvent(&.{}, &.{}), false);
    defer allocator.free(out_none);
    try std.testing.expectEqual(@as(usize, 0), out_none.len);

    const empty_caps = [_]events.CaptureEntry{.{ .field_name = "name", .value = "" }};
    const out_empty = try renderNamesOnly(allocator, namesOnlyTestEvent(&empty_caps, &.{}), false);
    defer allocator.free(out_empty);
    try std.testing.expectEqualStrings("\n", out_empty);
}

test "unit: writeNamesOnlyLine both kinds incl. integer 0 prints the name (bug condition)" {
    const allocator = std.testing.allocator;
    const caps = [_]events.CaptureEntry{.{ .field_name = "n", .value = "add" }};
    const ints = [_]events.IntegerField{ .{ .field_name = "args", .value = 0 }, .{ .field_name = "body", .value = 99 } };
    const out = try renderNamesOnly(allocator, namesOnlyTestEvent(&caps, &ints), false);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("add\n", out);
}

// Feature: names-only-prefer-string-capture, Property 1: events with a string capture and
// an integer field render captures[0].value ++ "\n"
test "property: names-only prefers first string capture (Property 1)" {
    const t = comptime gen.tuple3(u8, u8, u32, gen.intRange(u8, 1, 3), gen.intRange(u8, 1, 3), gen.intRange(u32, 0, std.math.maxInt(u32)));
    try minish.check(std.testing.allocator, t, struct {
        fn prop(v: struct { u8, u8, u32 }) !void {
            const allocator = std.testing.allocator;
            const g = try NamesOnlyGen.init(allocator, v[0], v[1], v[2]);
            defer g.deinit(allocator);
            const out = try renderNamesOnly(allocator, namesOnlyTestEvent(g.captures, g.ints), false);
            defer allocator.free(out);
            const expected = try std.fmt.allocPrint(allocator, "{s}\n", .{g.captures[0].value});
            defer allocator.free(expected);
            try std.testing.expectEqualStrings(expected, out);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: names-only-prefer-string-capture, Property 2: non-bug events render as the
// unfixed reference helper does
test "property: names-only preserves non-buggy events (Property 2)" {
    const t = comptime gen.tuple3(u8, u8, u32, gen.intRange(u8, 0, 3), gen.intRange(u8, 0, 3), gen.intRange(u32, 0, std.math.maxInt(u32)));
    try minish.check(std.testing.allocator, t, struct {
        fn prop(v: struct { u8, u8, u32 }) !void {
            // Restrict to captures.len == 0 or int_fields.len == 0.
            const ncap: usize = v[0];
            const nint: usize = if (ncap > 0) 0 else v[1];
            const allocator = std.testing.allocator;
            const g = try NamesOnlyGen.init(allocator, ncap, nint, v[2]);
            defer g.deinit(allocator);
            const ev = namesOnlyTestEvent(g.captures, g.ints);
            const fixed = try renderNamesOnly(allocator, ev, false);
            defer allocator.free(fixed);
            const ref = try renderNamesOnly(allocator, ev, true);
            defer allocator.free(ref);
            try std.testing.expectEqualStrings(ref, fixed);
            if (ncap == 0 and nint > 0) {
                const digits = try std.fmt.allocPrint(allocator, "{d}\n", .{g.ints[0].value});
                defer allocator.free(digits);
                try std.testing.expectEqualStrings(digits, fixed);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: names-only-prefer-string-capture, Property 3: framing over mixed event lists
test "property: names-only framing (Property 3)" {
    const t = comptime gen.tuple2(u8, u32, gen.intRange(u8, 0, 6), gen.intRange(u32, 0, std.math.maxInt(u32)));
    try minish.check(std.testing.allocator, t, struct {
        fn prop(v: struct { u8, u32 }) !void {
            const allocator = std.testing.allocator;
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            var renderable: usize = 0;
            var i: usize = 0;
            while (i < v[0]) : (i += 1) {
                const sel: u32 = (v[1] +% @as(u32, @intCast(i)) *% 7) % 4;
                const ncap: usize = sel & 1;
                const nint: usize = (sel >> 1) & 1;
                const g = try NamesOnlyGen.init(allocator, ncap, nint, v[1] +% @as(u32, @intCast(i)));
                defer g.deinit(allocator);
                if (ncap > 0 or nint > 0) renderable += 1;
                try writeNamesOnlyLine(&aw.writer, namesOnlyTestEvent(g.captures, g.ints));
            }
            const out = aw.written();
            try std.testing.expectEqual(renderable, std.mem.count(u8, out, "\n"));
            try std.testing.expect(out.len == 0 or out[out.len - 1] == '\n');
            try std.testing.expect(std.mem.indexOf(u8, out, "\n\n") == null);
            if (renderable == 0) try std.testing.expectEqual(@as(usize, 0), out.len);
        }
    }.prop, .{ .num_runs = 100 });
}

fn allLinesNonDigit(text: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var digits = true;
        for (line) |c| {
            if (c < '0' or c > '9') digits = false;
        }
        if (digits) return false;
    }
    return true;
}

test "integration: names-only extent_brace prints function names, not offsets" {
    const allocator = std.testing.allocator;
    const r = try runLaspWithStdin(allocator, &.{ "parse", "-", "-g", "tests/fixtures/grammars/extent_brace.toml", "--names-only" }, "fn alpha() { x }\nfn beta() { y }\n");
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    try std.testing.expectEqualStrings("alpha\nbeta\n", r.stdout);
    try std.testing.expect(allLinesNonDigit(r.stdout));
}

test "integration: names-only extent_terminator (no captures) prints offsets as digits" {
    const allocator = std.testing.allocator;
    const r = try runLaspWithStdin(allocator, &.{ "parse", "-", "-g", "tests/fixtures/grammars/extent_terminator.toml", "--names-only" }, "foo()\nbody.\nbar()\nx.\n");
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    try std.testing.expect(r.stdout.len > 0);
    var it = std.mem.splitScalar(u8, r.stdout, '\n');
    var lines: usize = 0;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        lines += 1;
        _ = try std.fmt.parseInt(u32, line, 10);
    }
    try std.testing.expect(lines >= 1);
    try std.testing.expect(!std.mem.endsWith(u8, r.stdout, "\n\n"));
}

test "integration: names-only default-grammar sites print names (parse and query)" {
    const allocator = std.testing.allocator;
    const counts_toml =
        \\[language]
        \\name = "counts"
        \\extensions = [".cnt"]
        \\
        \\[[patterns]]
        \\type = "fn"
        \\sequence = ["identifier", "$n:IDENTIFIER"]
        \\
        \\[[patterns.count]]
        \\field = "args"
        \\open = "("
        \\close = ")"
        \\separator = ","
        \\
    ;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedDefaultGrammars(allocator, &sb, &.{.{ .name = "counts.toml", .content = counts_toml }});
    const src = "names_only_default.cnt";
    try writeFixtureFile(sb.tmp.dir, std.testing.io, src, "fn add(a, b, c) {}\nfn one(x) {}\n");
    const p = try runLasp(allocator, &.{ "parse", src, "--names-only" });
    defer {
        allocator.free(p.stdout);
        allocator.free(p.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, p.term);
    try std.testing.expectEqualStrings("add\none\n", p.stdout);

    const q = try runLasp(allocator, &.{ "query", "fn[args>0]", src, "--names-only" });
    defer {
        allocator.free(q.stdout);
        allocator.free(q.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, q.term);
    try std.testing.expectEqualStrings("add\none\n", q.stdout);
}

test "integration: names-only --node nosuchtype is zero bytes; JSON and --jsonl guard preserved" {
    const allocator = std.testing.allocator;
    const none = try runLasp(allocator, &.{ "parse", "tests/fixtures/counts_sample.txt", "-g", "tests/fixtures/grammars/counts.toml", "--node", "nosuchtype", "--names-only" });
    defer {
        allocator.free(none.stdout);
        allocator.free(none.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, none.term);
    try std.testing.expectEqual(@as(usize, 0), none.stdout.len);

    const names = try runLasp(allocator, &.{ "parse", "tests/fixtures/counts_sample.txt", "-g", "tests/fixtures/grammars/counts.toml", "--names-only" });
    defer {
        allocator.free(names.stdout);
        allocator.free(names.stderr);
    }
    try std.testing.expect(!std.mem.endsWith(u8, names.stdout, "\n\n"));

    const plain = try runLasp(allocator, &.{ "parse", "tests/fixtures/counts_sample.txt", "-g", "tests/fixtures/grammars/counts.toml" });
    defer {
        allocator.free(plain.stdout);
        allocator.free(plain.stderr);
    }
    try std.testing.expect(std.mem.indexOf(u8, plain.stdout, "\"args\": 3") != null);

    const bad = try runLasp(allocator, &.{ "parse", "tests/fixtures/counts_sample.txt", "-g", "tests/fixtures/grammars/counts.toml", "--jsonl", "--names-only" });
    defer {
        allocator.free(bad.stdout);
        allocator.free(bad.stderr);
    }
    try std.testing.expect(!std.meta.eql(bad.term, std.process.Child.Term{ .exited = 0 }));
    try std.testing.expect(std.mem.indexOf(u8, bad.stderr, "mutually exclusive") != null);
}
// Helper: run lasp with data piped to stdin
fn runLaspWithStdin(allocator: std.mem.Allocator, args: []const []const u8, stdin_data: []const u8) !struct { stdout: []u8, stderr: []u8, term: std.process.Child.Term } {
    const io = std.testing.io;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, laspBinary());
    for (args) |a| try argv.append(allocator, a);
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = laspCwd(),
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
test "names-only on a multi-line string capture is plain unescaped text" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    try writeFixtureFile(sb.tmp.dir, std.testing.io, "str.toml", explore_str_grammar);
    sb.enter();
    const input = "\"a\nb\tc\"";
    const r = try runLaspWithStdin(allocator, &.{ "parse", "-", "-g", "str.toml", "--names-only" }, input);
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    try std.testing.expectEqualStrings(input ++ "\n", r.stdout);
}
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

// Feature: number-token-primitive, Integration: the number primitive emits events with
// confidence 1.0 end-to-end (Requirements 4.1, 6.3).
test "integration: number primitive emits events end-to-end" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/number_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/number.toml",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    // "42" → num event; "x 7" → decl event (name=x, optional number present).
    try std.testing.expectEqual(@as(usize, 2), json_events.array.items.len);
    try std.testing.expectEqualStrings("num", json_events.array.items[0].object.get("type").?.string);
    try std.testing.expectEqual(@as(f64, 1.0), json_events.array.items[0].object.get("confidence").?.float);
    try std.testing.expectEqualStrings("decl", json_events.array.items[1].object.get("type").?.string);
    try std.testing.expectEqual(@as(f64, 1.0), json_events.array.items[1].object.get("confidence").?.float);
    try std.testing.expectEqualStrings("x", json_events.array.items[1].object.get("name").?.string);
}

// Feature: per-pattern-priors, Integration: out-of-range prior is rejected with a
// descriptive message for both parse and query (Requirement 2.5).
test "integration: invalid prior value rejected with descriptive message" {
    const allocator = std.testing.allocator;

    {
        const result = try runLasp(allocator, &.{
            "parse",
            "tests/fixtures/sample.zig",
            "--grammar",
            "tests/fixtures/grammars/bad_prior.toml",
        });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        switch (result.term) {
            .exited => |code| try std.testing.expect(code != 0),
            else => {},
        }
        try std.testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "prior must be greater than 0.0 and at most 2.0"));
    }

    {
        const result = try runLasp(allocator, &.{
            "query",
            "function",
            "tests/fixtures/sample.zig",
            "-g",
            "tests/fixtures/grammars/bad_prior.toml",
        });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        switch (result.term) {
            .exited => |code| try std.testing.expect(code != 0),
            else => {},
        }
        try std.testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "prior must be greater than 0.0 and at most 2.0"));
    }
}

// Feature: competing-candidate-emission, Integration
// **Validates: Requirements 2.1, 7.1, 8.2, 9.2**
test "integration: --alternatives emits alternatives array; off emits none" {
    const allocator = std.testing.allocator;
    const src = "tests/fixtures/union_sample.txt";
    const grammar = "tests/fixtures/grammars/union.toml";

    {
        const result = try runLasp(allocator, &.{ "parse", src, "-g", grammar, "--alternatives" });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
        defer parsed.deinit();
        const events_arr = parsed.value.object.get("events").?.array.items;
        var saw_key = false;
        for (events_arr) |ev| {
            if (ev.object.get("alternatives") != null) saw_key = true;
        }
        try std.testing.expect(saw_key);
    }

    {
        const result = try runLasp(allocator, &.{ "parse", src, "-g", grammar });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "alternatives") == null);
    }

    {
        const result = try runLasp(allocator, &.{ "query", "decl", src, "-g", grammar, "--alternatives" });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        switch (result.term) {
            .exited => |code| try std.testing.expect(code != 0),
            else => {},
        }
        try std.testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "--alternatives is supported on the parse command only"));
    }
}

test "integration: --alternatives leaves names-only output unchanged" {
    const allocator = std.testing.allocator;
    const src = "tests/fixtures/union_sample.txt";
    const grammar = "tests/fixtures/grammars/union.toml";

    const plain = try runLasp(allocator, &.{ "parse", src, "-g", grammar, "--names-only" });
    defer {
        allocator.free(plain.stdout);
        allocator.free(plain.stderr);
    }
    const with_flag = try runLasp(allocator, &.{ "parse", src, "-g", grammar, "--names-only", "--alternatives" });
    defer {
        allocator.free(with_flag.stdout);
        allocator.free(with_flag.stderr);
    }
    try std.testing.expectEqualStrings(plain.stdout, with_flag.stdout);
}

// Feature: composable-matcher-model, Integration: typed captures emit values
// **Validates: Requirements 3.5, 4.1, 8.2**
test "integration: typed captures and string wildcard emit values" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/typed_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/typed.toml",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const events_arr = parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), events_arr.len);
    try std.testing.expectEqualStrings("msg", events_arr[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("\"hello\"", events_arr[0].object.get("s").?.string);
    try std.testing.expectEqualStrings("num", events_arr[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("42", events_arr[1].object.get("n").?.string);
    try std.testing.expectEqualStrings("msg", events_arr[2].object.get("type").?.string);
    try std.testing.expectEqualStrings("\"key\"", events_arr[2].object.get("s").?.string);
}

// Feature: configurable-token-kinds, Integration: Erlang vocabulary
// **Validates: Requirements 6.2, 6.5, 10.1**
test "integration: Erlang tokens grammar detects calls and quoted atoms" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/sample.erl",
        "--grammar",
        "examples/grammars/erlang_tokens.toml",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const events_arr = parsed.value.object.get("events").?.array.items;

    // sample.erl contains at least one function head `foo() -> ok.`; the call
    // pattern is atom "(" atom ")" and the head contains atom "(" ")" only.
    var call_count: usize = 0;
    for (events_arr) |ev| {
        if (std.mem.eql(u8, ev.object.get("type").?.string, "call")) call_count += 1;
    }
    try std.testing.expect(call_count >= 1);
}

test "integration: Erlang tokens grammar treats 'atom' as quoted atom, not string" {
    const allocator = std.testing.allocator;
    const result = try runLaspWithStdin(allocator, &.{
        "parse",
        "-",
        "--grammar",
        "examples/grammars/erlang_tokens.toml",
    }, "'hello'\n");
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const events_arr = parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), events_arr.len);
    try std.testing.expectEqualStrings("quoted", events_arr[0].object.get("type").?.string);
}

test "integration: Forth tokens grammar detects : name ; definition" {
    const allocator = std.testing.allocator;
    const result = try runLaspWithStdin(allocator, &.{
        "parse",
        "-",
        "--grammar",
        "examples/grammars/forth_tokens.toml",
    }, ": double ;\n");
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const events_arr = parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), events_arr.len);
    try std.testing.expectEqualStrings("definition", events_arr[0].object.get("type").?.string);
}

test "integration: existing zig grammar output unchanged (no [tokens])" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/sample.zig",
        "--grammar",
        "examples/grammars/zig.toml",
        "--node",
        "pub_function",
        "--names-only",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "add") != null);
}

// Feature: grammar-projected-resemblance, Integration
// **Validates: Requirements 4.1, 5.1, 6.1**
test "integration: --resemble surfaces number resemblance alternatives end-to-end" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/resemblance_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/resemblance.toml",
        "--resemble",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const events_arr = parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), events_arr.len);

    // Hex/bin literals → grammar `literal` primary with a `number` resemblance alternative.
    for (events_arr[0..2]) |ev| {
        try std.testing.expectEqualStrings("literal", ev.object.get("type").?.string);
        const alts = ev.object.get("alternatives").?.array.items;
        var saw_number = false;
        for (alts) |alt| {
            if (std.mem.eql(u8, alt.object.get("type").?.string, "number") and
                std.mem.eql(u8, alt.object.get("source").?.string, "resemblance"))
            {
                saw_number = true;
                try std.testing.expect(alt.object.get("membership").?.float < 1.0);
            }
        }
        try std.testing.expect(saw_number);
    }

    // "42" → exact `num` primary.
    const num_ev = events_arr[2].object;
    try std.testing.expectEqualStrings("num", num_ev.get("type").?.string);
}

test "integration: parse without --resemble is unchanged for resemblance fixture" {
    const allocator = std.testing.allocator;
    const plain = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/resemblance_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/resemblance.toml",
    });
    defer {
        allocator.free(plain.stdout);
        allocator.free(plain.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, plain.term);
    try std.testing.expect(std.mem.indexOf(u8, plain.stdout, "alternatives") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain.stdout, "source") == null);
}

// --- tokenizer-line-tracking regressions (spec: tokenizer-line-tracking, task 4.4) ---

/// Independent ground truth for a byte offset: 1-based line and 0-based col.
fn truthLineCol(source: []const u8, start: usize) struct { line: i64, col: i64 } {
    var line: i64 = 1;
    var line_start: usize = 0;
    for (source[0..start], 0..) |b, k| {
        if (b == '\n') {
            line += 1;
            line_start = k + 1;
        }
    }
    return .{ .line = line, .col = @intCast(start - line_start) };
}

fn expectEventsGroundTruth(source: []const u8, evs: []const std.json.Value) !void {
    for (evs) |ev| {
        const o = ev.object;
        const start: usize = @intCast(o.get("start").?.integer);
        const t = truthLineCol(source, start);
        try std.testing.expectEqual(t.line, o.get("line").?.integer);
        try std.testing.expectEqual(t.col, o.get("col").?.integer);
    }
}

test "integration: default tokenizer reports true line after multi-line string (Repro 1)" {
    const allocator = std.testing.allocator;
    const r = try runLaspWithStdin(allocator, &.{ "parse", "-", "--jsonl" }, "\"a\nb\nc\"\nx\n");
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    var found = false;
    var it = std.mem.splitScalar(u8, r.stdout, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const o = parsed.value.object;
        if (std.mem.eql(u8, o.get("type").?.string, "identifier")) {
            found = true;
            try std.testing.expectEqual(@as(i64, 4), o.get("line").?.integer);
        }
    }
    try std.testing.expect(found);
}

test "integration: trailing backslash with a grammar does not abort" {
    const allocator = std.testing.allocator;
    const r = try runLaspWithStdin(allocator, &.{ "parse", "-", "-g", "examples/grammars/zig.toml" }, "\"abc\\");
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "index out of bounds") == null);
}

test "integration: events after a multi-line delimited_span have ground-truth line/col" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const source = try std.Io.Dir.cwd().readFileAlloc(io, "tests/fixtures/multiline_span.txt", allocator, .limited(1 << 20));
    defer allocator.free(source);

    // Wrapped JSON.
    const w = try runLasp(allocator, &.{ "parse", "tests/fixtures/multiline_span.txt", "-g", "tests/fixtures/grammars/multiline_span.toml" });
    defer {
        allocator.free(w.stdout);
        allocator.free(w.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, w.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, w.stdout, .{});
    defer parsed.deinit();
    const evs = parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 5), evs.len);
    try expectEventsGroundTruth(source, evs);
    // "delta" follows a two-line span on the line it ends.
    try std.testing.expectEqual(@as(i64, 5), evs[3].object.get("line").?.integer);

    // NDJSON.
    const j = try runLasp(allocator, &.{ "parse", "tests/fixtures/multiline_span.txt", "-g", "tests/fixtures/grammars/multiline_span.toml", "--jsonl" });
    defer {
        allocator.free(j.stdout);
        allocator.free(j.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, j.term);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, j.stdout, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const p = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer p.deinit();
        try expectEventsGroundTruth(source, &.{p.value});
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), n);
}

// charset-escape-and-nonascii-ranges E6 (Property 1). Encodes the FIXED behavior.
fn expectSetupLabelEvent(fixture: []const u8) !void {
    const allocator = std.testing.allocator;
    const r = try runLaspWithStdin(allocator, &.{ "parse", "-", "-g", fixture }, "```{r setup}\n");
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, r.stdout, .{});
    defer parsed.deinit();
    const evs = parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqualStrings("setup", evs[0].object.get("label").?.string);
}

test "charset exploration E6: escaped dash in continue set captures label 'setup'" {
    try expectSetupLabelEvent("tests/fixtures/grammars/charset_escape.toml");
}

test "charset exploration E6b: escaped dash before a non-ASCII literal does not swallow '}'" {
    try expectSetupLabelEvent("tests/fixtures/grammars/charset_escape_nonascii.toml");
}

// charset-escape-and-nonascii-ranges: CLI / integration tests (U12, I1, I3).
// Writes a one-kind grammar with the given char-set TOML fragment to a temp
// file, runs `parse` on it, and removes the file.
const CharSetRun = struct { stdout: []u8, stderr: []u8, term: std.process.Child.Term };

fn runWithCharSetGrammar(allocator: std.mem.Allocator, kind_body: []const u8) !CharSetRun {
    const io = std.testing.io;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    const path = "charset_tmp_grammar.toml";
    const toml_text = try std.fmt.allocPrint(
        allocator,
        "[[patterns]]\ntype = \"t\"\nsequence = [\"ident\"]\n\n[tokens]\nident = {{ char_class_run = {{ {s} }} }}\n",
        .{kind_body},
    );
    defer allocator.free(toml_text);
    try writeFixtureFile(sb.tmp.dir, io, path, toml_text);
    const r = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "-g", path });
    return .{ .stdout = r.stdout, .stderr = r.stderr, .term = r.term };
}

test "charset U12: non-ASCII range endpoint fails with an actionable message" {
    const allocator = std.testing.allocator;
    const r = try runWithCharSetGrammar(allocator, "start = \"a-é\"");
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expect(!std.meta.eql(r.term, std.process.Child.Term{ .exited = 0 }));
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "ASCII endpoints") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "\\-") != null);
}

test "charset I1: the old non-ASCII-range workaround fails to load with the new message" {
    const allocator = std.testing.allocator;
    const r = try runWithCharSetGrammar(allocator, "start = \"a-zA-Z_\", continue = \"a-zA-Z0-9_Ѐ-ӿ-\"");
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expect(!std.meta.eql(r.term, std.process.Child.Term{ .exited = 0 }));
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "ASCII endpoints") != null);
}

test "charset I3: example and valid fixture grammars still load" {
    const allocator = std.testing.allocator;
    const dir = try runLasp(allocator, &.{ "parse-dir", "tests/fixtures", "--grammar-dir", "examples/grammars" });
    defer {
        allocator.free(dir.stdout);
        allocator.free(dir.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, dir.term);

    // Intentionally malformed fixtures (malformed, invalid_position, bad_prior) are excluded.
    const valid = [_][]const u8{
        "charset_escape", "charset_escape_nonascii", "colliding_function_call",
        "counts",         "extent_brace",            "extent_terminator",
        "multiline_span", "multiline_span_position", "number",
        "resemblance",    "typed",                   "union",
        "zig",
    };
    for (valid) |name| {
        const path = try std.fmt.allocPrint(allocator, "tests/fixtures/grammars/{s}.toml", .{name});
        defer allocator.free(path);
        const r = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "-g", path });
        defer {
            allocator.free(r.stdout);
            allocator.free(r.stderr);
        }
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    }
}

// Regression guard: passes before AND after the fix. markdown_tasks.toml has no
// string kind, so a stray quote is an unknown byte and never swallows lines.
test "integration: markdown_tasks reports true lines with stray quotes in prose" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "tests/fixtures/markdown_stray_quotes.md";
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
    defer allocator.free(source);

    const r = try runLasp(allocator, &.{ "parse", path, "-g", "examples/grammars/markdown_tasks.toml" });
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, r.stdout, .{});
    defer parsed.deinit();
    const evs = parsed.value.object.get("events").?.array.items;
    try expectEventsGroundTruth(source, evs);

    // Expected open-task lines come from the fixture bytes, not from lasp.
    var want: std.ArrayList(i64) = .empty;
    defer want.deinit(allocator);
    var line_no: i64 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |l| {
        line_no += 1;
        if (std.mem.indexOf(u8, l, "- [ ]") != null) try want.append(allocator, line_no);
    }
    var got: std.ArrayList(i64) = .empty;
    defer got.deinit(allocator);
    for (evs) |ev| {
        if (std.mem.eql(u8, ev.object.get("type").?.string, "task_open"))
            try got.append(allocator, ev.object.get("line").?.integer);
    }
    try std.testing.expectEqualSlices(i64, want.items, got.items);
    try std.testing.expectEqual(@as(usize, 3), got.items.len);
}

test "integration: position=start and extent at_column see true columns after a multi-line span" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "tests/fixtures/multiline_span_position.txt";
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
    defer allocator.free(source);

    const r = try runLasp(allocator, &.{ "parse", path, "-g", "tests/fixtures/grammars/multiline_span_position.toml" });
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, r.stdout, .{});
    defer parsed.deinit();
    const evs = parsed.value.object.get("events").?.array.items;

    // `bar` and `qux` start at true column 0; `baz` (col 8) is rejected.
    try std.testing.expectEqual(@as(usize, 2), evs.len);
    try std.testing.expectEqualStrings("bar", evs[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("qux", evs[1].object.get("name").?.string);
    try expectEventsGroundTruth(source, evs);

    // The extent stops at the column-0 `.` on its own line, not the mid-line one.
    const dot_line = std.mem.indexOf(u8, source, "\n.\n").? + 2;
    try std.testing.expectEqual(@as(i64, @intCast(dot_line)), evs[0].object.get("region").?.integer);
}

// --- grammar-error-prefix-fix: Task 1, bug condition exploration (Property 1) ---
// Every stderr error line must start with exactly one `error: `. These tests
// encode the FIXED behavior and fail on code that repeats the prefix.

/// Asserts every non-empty stderr line starts with `error: ` and that
/// `error: error:` occurs nowhere.
fn expectOnePrefixPerLine(stderr: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, stderr, "error: error:") == null);
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(std.mem.startsWith(u8, line, "error: "));
    }
}

/// Runs lasp and asserts: exit code 1, empty stdout, one prefix per error
/// line, and (when given) the exact stderr bytes.
fn expectFatalOnePrefix(allocator: std.mem.Allocator, args: []const []const u8, expected_stderr: ?[]const u8) !void {
    const r = try runLasp(allocator, args);
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try expectFatalResultOnePrefix(r.term, r.stdout, r.stderr, expected_stderr);
}

fn expectFatalResultOnePrefix(term: std.process.Child.Term, stdout: []const u8, stderr: []const u8, expected_stderr: ?[]const u8) !void {
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, term);
    try std.testing.expectEqual(@as(usize, 0), stdout.len);
    try expectOnePrefixPerLine(stderr);
    if (expected_stderr) |exp| try std.testing.expectEqualStrings(exp, stderr);
}

const err_prefix_dir = "test_errprefix_tmp";
/// Creates `test_errprefix_tmp` in the sandbox, holding the throwaway grammars the cases use.
fn seedErrPrefixFixtures(sb: *const Sandbox) !void {
    const io = std.testing.io;
    const dir = sb.tmp.dir;
    try dir.createDir(io, err_prefix_dir, .default_dir);
    const pat = "[[patterns]]\ntype = \"t\"\nsequence = [\"ident\"]\n\n";
    try writeFixtureFile(dir, io, err_prefix_dir ++ "/bad_charset.toml", pat ++ "[tokens]\nident = { char_class_run = { start = \"z-a\" } }\n");
    try writeFixtureFile(dir, io, err_prefix_dir ++ "/bad_comments.toml", pat ++ "[comments]\nline = \"x\"\n");
    try writeFixtureFile(dir, io, err_prefix_dir ++ "/bad_toml.toml", "this is [[ not toml");
    try writeFixtureFile(dir, io, err_prefix_dir ++ "/good.toml", "[[patterns]]\ntype = \"function\"\nsequence = [\"fn\", \"$name:IDENTIFIER\", \"(\"]\n");
}

const err_prefix_charset_body = "error: [tokens] invalid char set: ranges must have ASCII endpoints and run low-to-high, use \\- for a literal '-' and \\\\ for a literal '\\' (other escapes are not allowed): ";

test "error prefix P1: grammar charset error is one exact line (parse)" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedErrPrefixFixtures(&sb);
    const gp = err_prefix_dir ++ "/bad_charset.toml";
    try expectFatalOnePrefix(allocator, &.{ "parse", "tests/fixtures/sample.zig", "-g", gp }, err_prefix_charset_body ++ gp ++ "\n");
}

test "error prefix P1: grammar charset error is one exact line (stdin parse)" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedErrPrefixFixtures(&sb);
    const gp = err_prefix_dir ++ "/bad_charset.toml";
    const r = try runLaspWithStdin(allocator, &.{ "parse", "-", "-g", gp }, "a\n");
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try expectFatalResultOnePrefix(r.term, r.stdout, r.stderr, err_prefix_charset_body ++ gp ++ "\n");
}

test "error prefix P1: grammar charset error is one exact line (query)" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedErrPrefixFixtures(&sb);
    const gp = err_prefix_dir ++ "/bad_charset.toml";
    try expectFatalOnePrefix(allocator, &.{ "query", "function", "tests/fixtures/sample.zig", "-g", gp }, err_prefix_charset_body ++ gp ++ "\n");
}

test "error prefix P1: [comments] grammar error has one prefix" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedErrPrefixFixtures(&sb);
    const gp = err_prefix_dir ++ "/bad_comments.toml";
    try expectFatalOnePrefix(allocator, &.{ "parse", "tests/fixtures/sample.zig", "-g", gp }, "error: [comments] line must be an array of strings: " ++ gp ++ "\n");
}

test "error prefix P1: malformed TOML grammar has one prefix" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedErrPrefixFixtures(&sb);
    const gp = err_prefix_dir ++ "/bad_toml.toml";
    try expectFatalOnePrefix(allocator, &.{ "parse", "tests/fixtures/sample.zig", "-g", gp }, "error: invalid TOML syntax in grammar file: " ++ gp ++ "\n");
}

test "error prefix P1: unrecognized flag has one prefix" {
    const allocator = std.testing.allocator;
    try expectFatalOnePrefix(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--bogus" }, "error: unrecognized flag\n");
}

test "error prefix P1: --jsonl with --names-only has one prefix" {
    const allocator = std.testing.allocator;
    try expectFatalOnePrefix(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--jsonl", "--names-only" }, "error: --jsonl and --names-only are mutually exclusive\n");
}

test "error prefix P1: --jsonl --version has one prefix" {
    const allocator = std.testing.allocator;
    try expectFatalOnePrefix(allocator, &.{ "--jsonl", "--version" }, "error: --jsonl is only supported on parse, parse-dir, and query commands\n");
}

test "error prefix P1: malformed query selector has one prefix" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedErrPrefixFixtures(&sb);
    try expectFatalOnePrefix(allocator, &.{ "query", "function[", "tests/fixtures/sample.zig", "-g", err_prefix_dir ++ "/good.toml" }, "error: missing field name in attribute condition\n");
}

test "error prefix P1: query without a grammar has one prefix" {
    const allocator = std.testing.allocator;
    try expectFatalOnePrefix(allocator, &.{ "query", "function", "tests/fixtures/sample.zig" }, "error: query command requires --grammar/-g flag\n");
}

test "error prefix P1: --alternatives on query has one prefix" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedErrPrefixFixtures(&sb);
    try expectFatalOnePrefix(allocator, &.{ "query", "function", "tests/fixtures/sample.zig", "-g", err_prefix_dir ++ "/good.toml", "--alternatives" }, "error: --alternatives is supported on the parse command only\n");
}

test "error prefix P1: malformed default grammar has one prefix" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedDefaultGrammars(allocator, &sb, &.{.{ .name = "bad.toml", .content = "[language]\nextensions = [\".erl\"]\n\n[[patterns]]\ntype = \"t\"\nsequence = [\"ident\"]\n\n[tokens]\nident = { char_class_run = { start = \"z-a\" } }\n" }});
    try expectFatalOnePrefix(allocator, &.{ "parse", "tests/fixtures/dir_sample/a.erl" }, null);
    try expectFatalOnePrefix(allocator, &.{ "parse-dir", "tests/fixtures/dir_sample" }, err_prefix_charset_body ++ ".lasp/grammars/bad.toml\n");
}

test "error prefix P1: --names-only with several default grammars has one prefix" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedDefaultGrammars(allocator, &sb, &.{
        .{ .name = "erlang.toml", .content = erlang_grammar_toml },
        .{ .name = "erlang2.toml", .content = erlang2_grammar_toml },
    });
    try expectFatalOnePrefix(allocator, &.{ "parse", "tests/fixtures/dir_sample/a.erl", "--names-only" }, "error: --names-only requires a single grammar (pass -g/--grammar)\n");
}

test "error prefix P1: missing source file yields two lines, one prefix each" {
    const allocator = std.testing.allocator;
    const p = "tests/fixtures/definitely_missing_source.zig";
    try expectFatalOnePrefix(allocator, &.{ "parse", p }, "error: file not found: " ++ p ++ "\nerror: failed to read file: " ++ p ++ "\n");
}

// --- grammar-error-prefix-fix: Task 2, preservation (Property 2) ---
// Observed on unfixed code; these paths must stay byte-identical after the fix.

test "error prefix P2: no-args prints one prefix then the help text, exit 1, empty stdout" {
    const allocator = std.testing.allocator;
    const r = try runLasp(allocator, &.{});
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, r.term);
    try std.testing.expectEqual(@as(usize, 0), r.stdout.len);
    try std.testing.expect(std.mem.startsWith(u8, r.stderr, "error: " ++ cli.general_help_text));
    try std.testing.expect(std.mem.startsWith(u8, r.stderr, "error: lasp - Language-Agnostic Structural Parser\n"));
    // The only `error: ` in the whole stream is the leading one.
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfPos(u8, r.stderr, 1, "error:"));
}

test "error prefix P2: help and version invocations write stdout only, exit 0, no error text" {
    const allocator = std.testing.allocator;
    const cases = [_][]const []const u8{
        &.{"--help"},
        &.{"-h"},
        &.{"help"},
        &.{"--version"},
        &.{"-V"},
        &.{"version"},
        &.{ "parse", "--help" },
        &.{ "query", "--help" },
        &.{ "parse-dir", "--help" },
        &.{ "--help", "--version" },
    };
    for (cases) |args| {
        const r = try runLasp(allocator, args);
        defer {
            allocator.free(r.stdout);
            allocator.free(r.stderr);
        }
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
        try std.testing.expect(r.stdout.len > 0);
        try std.testing.expectEqual(@as(usize, 0), r.stderr.len);
        try std.testing.expect(std.mem.indexOf(u8, r.stdout, "error:") == null);
    }
}

test "error prefix P2: missing grammar file yields two lines, one prefix each" {
    const allocator = std.testing.allocator;
    const gp = "tests/fixtures/grammars/definitely_missing.toml";
    try expectFatalOnePrefix(allocator, &.{ "parse", "tests/fixtures/sample.zig", "-g", gp }, "error: file not found: " ++ gp ++ "\nerror: failed to read grammar file: " ++ gp ++ "\n");
}

test "error prefix P2: missing source file with a valid grammar keeps the two-line structure" {
    const allocator = std.testing.allocator;
    const p = "tests/fixtures/definitely_missing_source.zig";
    try expectFatalOnePrefix(allocator, &.{ "parse", p, "-g", "tests/fixtures/grammars/zig.toml" }, "error: file not found: " ++ p ++ "\nerror: failed to read file: " ++ p ++ "\n");
}

// --- Bug condition exploration tests (spec: json-string-escaping, task 1) ---
// Encode the EXPECTED (fixed) behavior; MUST FAIL on unfixed code.

const explore_str_grammar =
    \\[tokens]
    \\str = { delimited_span = { open = "\"", close = "\"" } }
    \\
    \\[[patterns]]
    \\type = "lit"
    \\sequence = ["$s:str"]
    \\
;

test "exploration: multi-line string capture, parse --jsonl is one parseable line" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    try writeFixtureFile(sb.tmp.dir, std.testing.io, "str.toml", explore_str_grammar);
    sb.enter();

    const input = "\"a\nb\tc\"";
    const r = try runLaspWithStdin(allocator, &.{ "parse", "-", "-g", "str.toml", "--jsonl" }, input);
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.stdout, "\n"));
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, r.stdout, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(input, parsed.value.object.get("s").?.string);
}

test "exploration: multi-line string capture, wrapped parse and query parse" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    try writeFixtureFile(sb.tmp.dir, std.testing.io, "str.toml", explore_str_grammar);
    sb.enter();

    const input = "\"a\nb\tc\"";
    const cmds = [_][]const []const u8{
        &.{ "parse", "-", "-g", "str.toml" },
        &.{ "query", "lit", "-", "-g", "str.toml" },
    };
    for (cmds) |args| {
        const r = try runLaspWithStdin(allocator, args, input);
        defer {
            allocator.free(r.stdout);
            allocator.free(r.stderr);
        }
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, r.stdout, .{});
        defer parsed.deinit();
        const ev = parsed.value.object.get("events").?.array.items[0].object;
        try std.testing.expectEqualStrings(input, ev.get("s").?.string);
    }
}

test "exploration: grammar type name containing a quote yields parseable output" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    try writeFixtureFile(sb.tmp.dir, std.testing.io, "q.toml",
        \\[[patterns]]
        \\type = "a\"b"
        \\sequence = ["fn", "$name:IDENTIFIER"]
        \\
    );
    sb.enter();

    const r = try runLaspWithStdin(allocator, &.{ "parse", "-", "-g", "q.toml", "--jsonl" }, "fn foo");
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, r.stdout, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a\"b", parsed.value.object.get("type").?.string);
}
