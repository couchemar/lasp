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
pub const diagnostics = @import("cli/diagnostics.zig");
const reportError = diagnostics.reportError;
const fatalError = diagnostics.fatalError;
const grammarErrorMessage = diagnostics.grammarErrorMessage;
const selectorErrorMessage = diagnostics.selectorErrorMessage;
pub const source_reader = @import("cli/source.zig");
const readSourceFile = source_reader.readSourceFile;
const readSourceOrStdin = source_reader.readSourceOrStdin;
pub const grammar_set = @import("cli/grammar_set.zig");
const LoadedGrammar = grammar_set.LoadedGrammar;
const loadGrammarsFromDir = grammar_set.loadGrammarsFromDir;
const resolveDefaultGrammars = grammar_set.resolveDefaultGrammars;
const default_grammar_dir = grammar_set.default_grammar_dir;
const basenameMatchesExtension = grammar_set.basenameMatchesExtension;

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

test {
    std.testing.refAllDecls(@This());
}

test {
    // Pull in tests from all modules.
    _ = cli;
    _ = tokenizer;
    _ = resemblance;
    _ = @import("main_test.zig");
}
const minish = @import("minish");
const gen = minish.gen;
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
