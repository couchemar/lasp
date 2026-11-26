const std = @import("std");
const cli = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const fatalError = diagnostics.fatalError;
const selectorErrorMessage = diagnostics.selectorErrorMessage;
const source_reader = @import("source.zig");
const grammar_set = @import("grammar_set.zig");
const output = @import("output.zig");
const LoadedGrammar = grammar_set.LoadedGrammar;
const tokenizer = @import("../parser/tokenizer.zig");
const engine = @import("../parser/engine.zig");
const events = @import("../parser/events.zig");
const query_filter = @import("../query/filter.zig");
const query_parser = @import("../query/parser.zig");

/// What `loadInputs` does when no grammar applies to the target.
pub const GrammarPolicy = enum { raw_tokens_if_none, require_grammar };

pub const Inputs = struct {
    source: []const u8,
    /// One element for an explicit `-g`; the matching default grammars
    /// otherwise. Empty only under `.raw_tokens_if_none`.
    grammars: []const LoadedGrammar,
};

/// The single owner of step order for single-target commands: explicit
/// grammar reads the source first, then the grammar; default grammars resolve
/// first (a malformed default is fatal), then `require_grammar` is checked,
/// then the source is read.
pub fn loadInputs(io: std.Io, allocator: std.mem.Allocator, parsed: cli.ParsedArgs, policy: GrammarPolicy) !Inputs {
    if (parsed.grammar_path) |gp| {
        const source = source_reader.readTargetOrFatal(io, allocator, parsed.target_path);
        const lg = try grammar_set.loadGrammarFile(io, allocator, gp, gp);
        const one = try allocator.alloc(LoadedGrammar, 1);
        one[0] = lg;
        return .{ .source = source, .grammars = one };
    }
    const set = try grammar_set.resolveDefaultGrammars(io, allocator, parsed.target_path);
    if (set.len == 0 and policy == .require_grammar) {
        fatalError("query command requires --grammar/-g flag", .{});
    }
    const source = source_reader.readTargetOrFatal(io, allocator, parsed.target_path);
    return .{ .source = source, .grammars = set };
}

/// Grammars for `parse-dir`: `--grammar-dir` (any load error is fatal), else
/// the default dir (absent is an empty set).
pub fn loadDirGrammars(io: std.Io, allocator: std.mem.Allocator, grammar_dir: ?[]const u8) ![]LoadedGrammar {
    if (grammar_dir) |gdir| {
        return grammar_set.loadGrammarsFromDir(io, allocator, gdir) catch {
            fatalError("grammar directory not found: {s}", .{gdir});
        };
    }
    return grammar_set.loadDefaultGrammars(io, allocator);
}

/// Source + compiled grammar to structural events: tokenize (vocabulary when
/// the grammar declares `[tokens]`), `engine.parse`, then the case-insensitive
/// `--node` filter.
pub fn parseEvents(
    allocator: std.mem.Allocator,
    lg: LoadedGrammar,
    source: []const u8,
    node_filter: ?[]const u8,
    alternatives: bool,
    resemble: bool,
) ![]events.StructuralEvent {
    const grammar = lg.grammar;
    const tokens = if (grammar.tokens) |vocab|
        try tokenizer.tokenizeWithVocab(source, vocab, grammar.keyword_table, grammar.comments, allocator)
    else
        try tokenizer.tokenize(source, grammar.keyword_table, grammar.comments, allocator);
    // --resemble implies collecting alternatives so resemblance candidates are
    // surfaced through the alternatives path.
    const collect_alternatives = alternatives or resemble;
    var structural_events = try engine.parse(lg.automaton, tokens, source, grammar.patterns, grammar.tokens, grammar.blocks, grammar.weights, resemble, collect_alternatives, allocator);

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

pub fn parseSelectorOrFatal(allocator: std.mem.Allocator, selector: ?[]const u8) query_filter.QueryFilter {
    const text = selector orelse {
        fatalError("query command requires a selector string", .{});
    };
    return query_parser.parse(text, allocator) catch |err| {
        const msg: []const u8 = selectorErrorMessage(err);
        fatalError("{s}", .{msg});
    };
}

pub fn rejectNamesOnlyMulti(framing: output.Framing, grammar_count: usize) void {
    if (framing == .names_only and grammar_count > 1) {
        fatalError("--names-only requires a single grammar (pass -g/--grammar)", .{});
    }
}

test "parseEvents equals the inline query sequence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const grammar_loader = @import("../grammar/loader.zig");
    const grammar_compiler = @import("../grammar/compiler.zig");
    const grammar_source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[[patterns]]
        \\type = "call"
        \\sequence = ["$callee:IDENTIFIER", "("]
        \\
    ;
    const grammar = try grammar_loader.parseGrammar(grammar_source, a);
    const automaton = try grammar_compiler.compile(grammar.patterns, a);
    const lg: LoadedGrammar = .{ .name = "t", .grammar = grammar, .automaton = automaton };
    const src = "fn add(a) {}\nfn sub(b) { add(b) }\n";

    const got = try parseEvents(a, lg, src, null, false, false);

    const tokens = try tokenizer.tokenize(src, grammar.keyword_table, grammar.comments, a);
    const want = try engine.parse(automaton, tokens, src, grammar.patterns, grammar.tokens, grammar.blocks, grammar.weights, false, false, a);

    try std.testing.expect(want.len > 0);
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try std.testing.expectEqualStrings(w.type_name, g.type_name);
        try std.testing.expectEqual(w.start, g.start);
        try std.testing.expectEqual(w.end, g.end);
        try std.testing.expectEqual(w.line, g.line);
        try std.testing.expectEqual(w.confidence, g.confidence);
        try std.testing.expectEqual(w.captures.len, g.captures.len);
        for (w.captures, g.captures) |wc, gc| try std.testing.expectEqualStrings(wc.value, gc.value);
    }
}
