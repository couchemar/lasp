const std = @import("std");
const toml = @import("toml");

// --- Data Types ---

pub const Grammar = struct {
    language_name: ?[]const u8,
    keyword_categories: []const KeywordCategory,
    keyword_table: []const []const u8,
    patterns: []const Pattern,
    blocks: BlockConfig,
};

pub const KeywordCategory = struct {
    name: []const u8,
    keywords: []const []const u8,
};

pub const PositionConstraint = enum {
    start, // column 0
};

pub const Pattern = struct {
    type_name: []const u8,
    sequence: []const TokenMatcher,
    captures: []const Capture,
    position: ?PositionConstraint = null,
    exclude: []const []const u8 = &.{},
};

pub const TokenMatcher = union(enum) {
    keyword_literal: []const u8,
    symbol_literal: []const u8,
    identifier: void,
    capture: Capture,
};

pub const Capture = struct {
    field_name: []const u8,
    position: usize,
};

pub const BlockConfig = struct {
    open: ?[]const u8 = null,
    close: ?[]const u8 = null,
    indentation: bool = false,
};

pub const GrammarError = error{
    FileNotFound,
    InvalidToml,
    MissingPatterns,
    EmptyPatternSequence,
    InvalidCaptureFormat,
    InvalidPositionValue,
    OutOfMemory,
};

const delimiter_chars = "(){}[]";
const symbol_chars = ",;:.@?";

fn isSymbolOrDelimiter(s: []const u8) bool {
    if (s.len != 1) return false;
    for (delimiter_chars ++ symbol_chars) |c| {
        if (s[0] == c) return true;
    }
    return false;
}

/// Parses a single pattern sequence string into a TokenMatcher.
fn parseSequenceElement(s: []const u8, position: usize, allocator: std.mem.Allocator) GrammarError!struct { matcher: TokenMatcher, capture: ?Capture } {
    // Capture: $name:IDENTIFIER
    if (s.len > 0 and s[0] == '$') {
        const colon_idx = std.mem.indexOf(u8, s, ":") orelse return error.InvalidCaptureFormat;
        if (colon_idx < 2) return error.InvalidCaptureFormat; // need at least $x
        const suffix = s[colon_idx + 1 ..];
        if (!std.mem.eql(u8, suffix, "IDENTIFIER")) return error.InvalidCaptureFormat;
        const field_name = try allocator.dupe(u8, s[1..colon_idx]);
        const cap = Capture{ .field_name = field_name, .position = position };
        return .{ .matcher = .{ .capture = cap }, .capture = cap };
    }
    // Identifier wildcard
    if (std.mem.eql(u8, s, "identifier")) {
        return .{ .matcher = .{ .identifier = {} }, .capture = null };
    }
    // Symbol/delimiter literal (single char)
    if (isSymbolOrDelimiter(s)) {
        return .{ .matcher = .{ .symbol_literal = try allocator.dupe(u8, s) }, .capture = null };
    }
    // Keyword literal
    return .{ .matcher = .{ .keyword_literal = try allocator.dupe(u8, s) }, .capture = null };
}

/// Parses a TOML grammar file from bytes into a Grammar struct.
/// All allocations use the provided arena allocator.
/// The TOML Document's internal arena is freed before returning;
/// all strings are duped into the caller's allocator.
pub fn parseGrammar(source: []const u8, allocator: std.mem.Allocator) GrammarError!Grammar {
    var doc = toml.parse(allocator, source, .{}) catch return error.InvalidToml;
    defer doc.deinit();

    const root = doc.root;

    // --- [language] (optional) ---
    const language_name: ?[]const u8 = if (root.get("language")) |lang_table| blk: {
        if (lang_table.get("name")) |name_val| {
            break :blk try allocator.dupe(u8, name_val.string);
        }
        break :blk null;
    } else null;

    // --- [keywords] (optional) ---
    var categories: std.ArrayList(KeywordCategory) = .empty;
    var all_keywords: std.ArrayList([]const u8) = .empty;

    if (root.get("keywords")) |kw_table| {
        for (kw_table.table.entries) |entry| {
            var kws: std.ArrayList([]const u8) = .empty;
            for (entry.value.array.items) |item| {
                const kw = try allocator.dupe(u8, item.string);
                try kws.append(allocator, kw);
                try all_keywords.append(allocator, kw);
            }
            try categories.append(allocator, .{
                .name = try allocator.dupe(u8, entry.key),
                .keywords = try kws.toOwnedSlice(allocator),
            });
        }
    }

    // --- [[patterns]] (required) ---
    const patterns_val = root.get("patterns") orelse return error.MissingPatterns;
    var patterns: std.ArrayList(Pattern) = .empty;

    for (patterns_val.array.items) |pattern_table| {
        const type_name = if (pattern_table.get("type")) |t|
            try allocator.dupe(u8, t.string)
        else
            return error.MissingPatterns;

        const seq_val = pattern_table.get("sequence") orelse return error.EmptyPatternSequence;
        if (seq_val.array.items.len == 0) return error.EmptyPatternSequence;

        var matchers: std.ArrayList(TokenMatcher) = .empty;
        var captures: std.ArrayList(Capture) = .empty;

        for (seq_val.array.items, 0..) |item, idx| {
            const result = try parseSequenceElement(item.string, idx, allocator);
            try matchers.append(allocator, result.matcher);
            if (result.capture) |cap| {
                try captures.append(allocator, cap);
            }
        }

        try patterns.append(allocator, .{
            .type_name = type_name,
            .sequence = try matchers.toOwnedSlice(allocator),
            .captures = try captures.toOwnedSlice(allocator),
            .position = blk: {
                if (pattern_table.get("position")) |pos_val| {
                    if (std.mem.eql(u8, pos_val.string, "start")) {
                        break :blk .start;
                    } else {
                        return error.InvalidPositionValue;
                    }
                }
                break :blk null;
            },
            .exclude = blk: {
                if (pattern_table.get("exclude")) |exc_val| {
                    if (exc_val.array.items.len == 0) break :blk &.{};
                    var exc_list: std.ArrayList([]const u8) = .empty;
                    for (exc_val.array.items) |item| {
                        try exc_list.append(allocator, try allocator.dupe(u8, item.string));
                    }
                    break :blk try exc_list.toOwnedSlice(allocator);
                }
                break :blk &.{};
            },
        });
    }

    // --- [blocks] (optional) ---
    var blocks = BlockConfig{};
    if (root.get("blocks")) |blocks_table| {
        if (blocks_table.get("open")) |v| blocks.open = try allocator.dupe(u8, v.string);
        if (blocks_table.get("close")) |v| blocks.close = try allocator.dupe(u8, v.string);
        if (blocks_table.get("indentation")) |v| blocks.indentation = v.bool;
    }

    return Grammar{
        .language_name = language_name,
        .keyword_categories = try categories.toOwnedSlice(allocator),
        .keyword_table = try all_keywords.toOwnedSlice(allocator),
        .patterns = try patterns.toOwnedSlice(allocator),
        .blocks = blocks,
    };
}

/// Formats a Grammar struct back into a TOML string.
/// Used for round-trip testing.
pub fn formatGrammar(grammar: Grammar, allocator: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(allocator);

    // [language]
    if (grammar.language_name) |name| {
        try w.writeAll("[language]\nname = \"");
        try w.writeAll(name);
        try w.writeAll("\"\n\n");
    }

    // [keywords]
    if (grammar.keyword_categories.len > 0) {
        try w.writeAll("[keywords]\n");
        for (grammar.keyword_categories) |cat| {
            try w.writeAll(cat.name);
            try w.writeAll(" = [");
            for (cat.keywords, 0..) |kw, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll("\"");
                try w.writeAll(kw);
                try w.writeAll("\"");
            }
            try w.writeAll("]\n");
        }
        try w.writeAll("\n");
    }

    // [[patterns]]
    for (grammar.patterns) |pattern| {
        try w.writeAll("[[patterns]]\ntype = \"");
        try w.writeAll(pattern.type_name);
        try w.writeAll("\"\nsequence = [");
        for (pattern.sequence, 0..) |matcher, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll("\"");
            switch (matcher) {
                .keyword_literal => |kw| try w.writeAll(kw),
                .symbol_literal => |sym| try w.writeAll(sym),
                .identifier => try w.writeAll("identifier"),
                .capture => |cap| {
                    try w.writeAll("$");
                    try w.writeAll(cap.field_name);
                    try w.writeAll(":IDENTIFIER");
                },
            }
            try w.writeAll("\"");
        }
        try w.writeAll("]\n");

        // position field
        if (pattern.position) |pos| {
            switch (pos) {
                .start => try w.writeAll("position = \"start\"\n"),
            }
        }

        // exclude field
        if (pattern.exclude.len > 0) {
            try w.writeAll("exclude = [");
            for (pattern.exclude, 0..) |exc, j| {
                if (j > 0) try w.writeAll(", ");
                try w.writeAll("\"");
                try w.writeAll(exc);
                try w.writeAll("\"");
            }
            try w.writeAll("]\n");
        }

        try w.writeAll("\n");
    }

    // [blocks]
    if (grammar.blocks.open != null or grammar.blocks.close != null or grammar.blocks.indentation) {
        try w.writeAll("[blocks]\n");
        if (grammar.blocks.open) |open| {
            try w.writeAll("open = \"");
            try w.writeAll(open);
            try w.writeAll("\"\n");
        }
        if (grammar.blocks.close) |close| {
            try w.writeAll("close = \"");
            try w.writeAll(close);
            try w.writeAll("\"\n");
        }
        if (grammar.blocks.indentation) {
            try w.writeAll("indentation = true\n");
        }
    }

    return buf.toOwnedSlice(allocator);
}

// --- Unit Tests ---

const testing = std.testing;

test "parseGrammar: full Rust-style grammar" {
    const source =
        \\[language]
        \\name = "rust"
        \\
        \\[keywords]
        \\function = ["fn"]
        \\struct = ["struct"]
        \\import = ["use"]
        \\
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[[patterns]]
        \\type = "struct"
        \\sequence = ["struct", "$name:IDENTIFIER"]
        \\
        \\[blocks]
        \\open = "{"
        \\close = "}"
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqualStrings("rust", grammar.language_name.?);
    try testing.expectEqual(@as(usize, 3), grammar.keyword_categories.len);
    try testing.expectEqual(@as(usize, 3), grammar.keyword_table.len);
    try testing.expectEqual(@as(usize, 2), grammar.patterns.len);
    try testing.expectEqualStrings("function", grammar.patterns[0].type_name);
    try testing.expectEqual(@as(usize, 3), grammar.patterns[0].sequence.len);
    try testing.expectEqual(@as(usize, 1), grammar.patterns[0].captures.len);
    try testing.expectEqualStrings("name", grammar.patterns[0].captures[0].field_name);
    try testing.expectEqualStrings("{", grammar.blocks.open.?);
    try testing.expectEqualStrings("}", grammar.blocks.close.?);
}

test "parseGrammar: patterns only (minimal grammar)" {
    const source =
        \\[[patterns]]
        \\type = "call"
        \\sequence = ["identifier", "("]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expect(grammar.language_name == null);
    try testing.expectEqual(@as(usize, 0), grammar.keyword_categories.len);
    try testing.expectEqual(@as(usize, 0), grammar.keyword_table.len);
    try testing.expectEqual(@as(usize, 1), grammar.patterns.len);
    try testing.expectEqualStrings("call", grammar.patterns[0].type_name);
}

test "parseGrammar: capture parsing" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    const seq = grammar.patterns[0].sequence;
    try testing.expectEqual(@as(usize, 3), seq.len);
    try testing.expect(seq[0] == .keyword_literal);
    try testing.expect(seq[1] == .capture);
    try testing.expectEqualStrings("name", seq[1].capture.field_name);
    try testing.expectEqual(@as(usize, 1), seq[1].capture.position);
    try testing.expect(seq[2] == .symbol_literal);
}

test "parseGrammar: missing patterns returns error" {
    const source =
        \\[language]
        \\name = "test"
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());
    try testing.expectError(error.MissingPatterns, result);
}

test "parseGrammar: empty sequence returns error" {
    const source =
        \\[[patterns]]
        \\type = "bad"
        \\sequence = []
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());
    try testing.expectError(error.EmptyPatternSequence, result);
}

test "parseGrammar: invalid TOML returns error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar("this is not valid toml [[[", arena.allocator());
    try testing.expectError(error.InvalidToml, result);
}

test "parseGrammar: keyword flattening" {
    const source =
        \\[keywords]
        \\function = ["fn", "def"]
        \\class = ["class", "struct"]
        \\
        \\[[patterns]]
        \\type = "x"
        \\sequence = ["fn", "identifier"]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqual(@as(usize, 4), grammar.keyword_table.len);
    // All keywords from both categories should be in the flat table
    var found_fn = false;
    var found_def = false;
    var found_class = false;
    var found_struct = false;
    for (grammar.keyword_table) |kw| {
        if (std.mem.eql(u8, kw, "fn")) found_fn = true;
        if (std.mem.eql(u8, kw, "def")) found_def = true;
        if (std.mem.eql(u8, kw, "class")) found_class = true;
        if (std.mem.eql(u8, kw, "struct")) found_struct = true;
    }
    try testing.expect(found_fn);
    try testing.expect(found_def);
    try testing.expect(found_class);
    try testing.expect(found_struct);
}

test "parseGrammar: position = start" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["$name:IDENTIFIER", "("]
        \\position = "start"
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqual(@as(usize, 1), grammar.patterns.len);
    try testing.expect(grammar.patterns[0].position != null);
    try testing.expectEqual(PositionConstraint.start, grammar.patterns[0].position.?);
}

test "parseGrammar: exclude list" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["$name:IDENTIFIER", "("]
        \\exclude = ["-spec", "-type"]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqual(@as(usize, 2), grammar.patterns[0].exclude.len);
    try testing.expectEqualStrings("-spec", grammar.patterns[0].exclude[0]);
    try testing.expectEqualStrings("-type", grammar.patterns[0].exclude[1]);
}

test "parseGrammar: invalid position value returns error" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["$name:IDENTIFIER", "("]
        \\position = "invalid"
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());
    try testing.expectError(error.InvalidPositionValue, result);
}

test "parseGrammar: empty exclude array means no exclusions" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["$name:IDENTIFIER", "("]
        \\exclude = []
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqual(@as(usize, 0), grammar.patterns[0].exclude.len);
}

test "parseGrammar: Phase 2 grammar backward compatibility (no position/exclude)" {
    const source =
        \\[[patterns]]
        \\type = "call"
        \\sequence = ["identifier", "("]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expect(grammar.patterns[0].position == null);
    try testing.expectEqual(@as(usize, 0), grammar.patterns[0].exclude.len);
}

// --- Property Tests ---

const minish = @import("minish");
const gen = minish.gen;

// Feature: phase2-grammar-automaton, Property 1: Grammar TOML round-trip
test "property: grammar TOML round-trip" {
    // Generate a random language name
    const name_gen = gen.string(.{ .min_len = 1, .max_len = 16, .charset = .alpha });

    try minish.check(testing.allocator, name_gen, struct {
        fn prop(lang_name: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // Build a Grammar struct with the random name and a fixed pattern
            const original = Grammar{
                .language_name = lang_name,
                .keyword_categories = &.{
                    .{ .name = "function", .keywords = &.{"fn"} },
                },
                .keyword_table = &.{"fn"},
                .patterns = &.{
                    .{
                        .type_name = "function",
                        .sequence = &.{
                            .{ .keyword_literal = "fn" },
                            .{ .capture = .{ .field_name = "name", .position = 1 } },
                            .{ .symbol_literal = "(" },
                        },
                        .captures = &.{
                            .{ .field_name = "name", .position = 1 },
                        },
                    },
                },
                .blocks = .{ .open = "{", .close = "}" },
            };

            // Round-trip: format → parse
            const toml_str = try formatGrammar(original, alloc);
            const parsed = try parseGrammar(toml_str, alloc);

            // Verify equivalence
            try testing.expectEqualStrings(lang_name, parsed.language_name.?);
            try testing.expectEqual(original.keyword_categories.len, parsed.keyword_categories.len);
            try testing.expectEqual(original.keyword_table.len, parsed.keyword_table.len);
            try testing.expectEqual(original.patterns.len, parsed.patterns.len);
            try testing.expectEqualStrings("function", parsed.patterns[0].type_name);
            try testing.expectEqual(original.patterns[0].sequence.len, parsed.patterns[0].sequence.len);
            try testing.expectEqual(original.patterns[0].captures.len, parsed.patterns[0].captures.len);
            try testing.expectEqualStrings("{", parsed.blocks.open.?);
            try testing.expectEqualStrings("}", parsed.blocks.close.?);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase3-multi-language-patterns, Property 2: Grammar TOML round-trip with position and exclude
test "property: grammar TOML round-trip with position and exclude" {
    // Generate a random boolean for position (true = .start, false = null)
    // and a random exclude string
    const pair_gen = comptime gen.tuple2(
        bool,
        []const u8,
        gen.boolean(),
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
    );

    try minish.check(testing.allocator, pair_gen, struct {
        fn prop(vals: struct { bool, []const u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const has_position = vals[0];
            const exc_token = vals[1];

            const original = Grammar{
                .language_name = "test",
                .keyword_categories = &.{},
                .keyword_table = &.{},
                .patterns = &.{
                    .{
                        .type_name = "function",
                        .sequence = &.{
                            .{ .keyword_literal = "fn" },
                            .{ .capture = .{ .field_name = "name", .position = 1 } },
                            .{ .symbol_literal = "(" },
                        },
                        .captures = &.{
                            .{ .field_name = "name", .position = 1 },
                        },
                        .position = if (has_position) .start else null,
                        .exclude = &.{exc_token},
                    },
                },
                .blocks = .{},
            };

            // Round-trip: format → parse
            const toml_str = try formatGrammar(original, alloc);
            const parsed = try parseGrammar(toml_str, alloc);

            // Verify position round-trips
            if (has_position) {
                try testing.expect(parsed.patterns[0].position != null);
                try testing.expectEqual(PositionConstraint.start, parsed.patterns[0].position.?);
            } else {
                try testing.expect(parsed.patterns[0].position == null);
            }

            // Verify exclude round-trips
            try testing.expectEqual(@as(usize, 1), parsed.patterns[0].exclude.len);
            try testing.expectEqualStrings(exc_token, parsed.patterns[0].exclude[0]);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase2-grammar-automaton, Property 2: Keyword table flattening
test "property: keyword table flattening" {
    // Generate random keyword strings
    const kw_gen = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha });

    try minish.check(testing.allocator, kw_gen, struct {
        fn prop(kw: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // Build TOML with two categories each containing the random keyword
            var buf: std.ArrayList(u8) = .empty;
            const w = buf.writer(alloc);
            try w.writeAll("[keywords]\ncat_a = [\"");
            try w.writeAll(kw);
            try w.writeAll("\"]\ncat_b = [\"other\"]\n\n[[patterns]]\ntype = \"x\"\nsequence = [\"identifier\"]\n");
            const source = buf.items;

            const grammar = try parseGrammar(source, alloc);

            // Flat table should contain both keywords
            try testing.expectEqual(@as(usize, 2), grammar.keyword_table.len);
            var found_kw = false;
            var found_other = false;
            for (grammar.keyword_table) |k| {
                if (std.mem.eql(u8, k, kw)) found_kw = true;
                if (std.mem.eql(u8, k, "other")) found_other = true;
            }
            try testing.expect(found_kw);
            try testing.expect(found_other);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase2-grammar-automaton, Property 3: Invalid TOML rejection
test "property: invalid TOML rejection" {
    // Generate random strings that are unlikely to be valid TOML with [[patterns]]
    const garbage_gen = gen.string(.{ .min_len = 1, .max_len = 64, .charset = .ascii });

    try minish.check(testing.allocator, garbage_gen, struct {
        fn prop(input: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();

            const result = parseGrammar(input, arena.allocator());
            // Should either fail with InvalidToml or MissingPatterns (valid TOML but no patterns)
            // It should NOT succeed unless the random string happens to be a valid grammar
            if (result) |grammar| {
                // If it somehow parsed, it must at least have patterns
                try testing.expect(grammar.patterns.len > 0);
            } else |err| {
                try testing.expect(err == error.InvalidToml or err == error.MissingPatterns);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// --- Example Grammar File Verification Tests ---

test "example grammar: erlang.toml parses without errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const file = try std.fs.cwd().openFile("examples/grammars/erlang.toml", .{});
    defer file.close();
    const source = try file.readToEndAlloc(alloc, 1024 * 1024);
    const grammar = try parseGrammar(source, alloc);
    try testing.expectEqualStrings("erlang", grammar.language_name.?);
    try testing.expect(grammar.patterns.len >= 7);
    try testing.expect(grammar.keyword_table.len > 0);
    try testing.expectEqualStrings("begin", grammar.blocks.open.?);
    try testing.expectEqualStrings("end", grammar.blocks.close.?);
    // Verify function pattern has position and exclude
    for (grammar.patterns) |p| {
        if (std.mem.eql(u8, p.type_name, "function")) {
            try testing.expect(p.position != null);
            try testing.expectEqual(PositionConstraint.start, p.position.?);
            try testing.expect(p.exclude.len == 2);
            break;
        }
    }
}

test "example grammar: zig.toml parses without errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const file = try std.fs.cwd().openFile("examples/grammars/zig.toml", .{});
    defer file.close();
    const source = try file.readToEndAlloc(alloc, 1024 * 1024);
    const grammar = try parseGrammar(source, alloc);
    try testing.expectEqualStrings("zig", grammar.language_name.?);
    try testing.expect(grammar.patterns.len >= 5);
    try testing.expect(grammar.keyword_table.len > 0);
    try testing.expectEqualStrings("{", grammar.blocks.open.?);
    try testing.expectEqualStrings("}", grammar.blocks.close.?);
}

// --- Bug Condition Exploration Tests (empty-blocks-misleading-error) ---
// Property 1: Empty Block Delimiters Cause Misleading Error
// These tests encode the EXPECTED (correct) behavior.
// They MUST FAIL on unfixed code — failure confirms the bug exists.

// Concrete unit test: both open and close empty
test "bug exploration: both empty block delimiters treated as absent" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[blocks]
        \\open = ""
        \\close = ""
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());

    // Expected: parsing succeeds (no MissingPatterns error)
    const grammar = result catch |err| {
        std.debug.print("COUNTEREXAMPLE: both empty delimiters caused {s}\n", .{@errorName(err)});
        return err;
    };

    // Expected: empty strings become null, not non-null empty slices
    if (grammar.blocks.open) |open| {
        std.debug.print("COUNTEREXAMPLE: blocks.open is non-null with len={d}\n", .{open.len});
        return error.TestUnexpectedResult;
    }
    if (grammar.blocks.close) |close| {
        std.debug.print("COUNTEREXAMPLE: blocks.close is non-null with len={d}\n", .{close.len});
        return error.TestUnexpectedResult;
    }
}

// Concrete unit test: empty open only
test "bug exploration: empty open delimiter treated as absent" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[blocks]
        \\open = ""
        \\close = "}"
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());

    const grammar = result catch |err| {
        std.debug.print("COUNTEREXAMPLE: empty open + non-empty close caused {s}\n", .{@errorName(err)});
        return err;
    };

    // Expected: open = null (was empty string)
    if (grammar.blocks.open) |open| {
        std.debug.print("COUNTEREXAMPLE: blocks.open is non-null with len={d}\n", .{open.len});
        return error.TestUnexpectedResult;
    }

    // Expected: close = "}" (preserved)
    try testing.expectEqualStrings("}", grammar.blocks.close.?);
}

// Concrete unit test: empty close only
test "bug exploration: empty close delimiter treated as absent" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[blocks]
        \\open = "{"
        \\close = ""
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());

    const grammar = result catch |err| {
        std.debug.print("COUNTEREXAMPLE: non-empty open + empty close caused {s}\n", .{@errorName(err)});
        return err;
    };

    // Expected: open = "{" (preserved)
    try testing.expectEqualStrings("{", grammar.blocks.open.?);

    // Expected: close = null (was empty string)
    if (grammar.blocks.close) |close| {
        std.debug.print("COUNTEREXAMPLE: blocks.close is non-null with len={d}\n", .{close.len});
        return error.TestUnexpectedResult;
    }
}

// Property-based test: empty block delimiters should be treated as absent
test "property: empty block delimiters treated as absent" {
    // Generate a boolean (true = open empty, false = close empty) and a random pattern type
    const pair_gen = comptime gen.tuple2(
        bool,
        []const u8,
        gen.boolean(),
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
    );

    try minish.check(testing.allocator, pair_gen, struct {
        fn prop(vals: struct { bool, []const u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const open_empty = vals[0];
            const pattern_type = vals[1];

            // Build TOML with empty delimiter(s) and a valid [[patterns]] section
            var buf: std.ArrayList(u8) = .empty;
            const w = buf.writer(alloc);

            try w.writeAll("[[patterns]]\ntype = \"");
            try w.writeAll(pattern_type);
            try w.writeAll("\"\nsequence = [\"identifier\", \"(\"]\n\n[blocks]\n");

            if (open_empty) {
                try w.writeAll("open = \"\"\nclose = \"}\"\n");
            } else {
                try w.writeAll("open = \"{\"\nclose = \"\"\n");
            }

            const source = buf.items;
            const result = parseGrammar(source, alloc);

            // Expected: parsing succeeds (no MissingPatterns)
            const grammar = result catch |err| {
                std.debug.print("COUNTEREXAMPLE: pattern_type=\"{s}\" open_empty={} caused {s}\n", .{ pattern_type, open_empty, @errorName(err) });
                return err;
            };

            // Expected: empty delimiter becomes null
            if (open_empty) {
                if (grammar.blocks.open) |open| {
                    std.debug.print("COUNTEREXAMPLE: open_empty=true but blocks.open is non-null len={d}\n", .{open.len});
                    return error.TestUnexpectedResult;
                }
                // Non-empty delimiter preserved
                try testing.expectEqualStrings("}", grammar.blocks.close.?);
            } else {
                if (grammar.blocks.close) |close| {
                    std.debug.print("COUNTEREXAMPLE: close_empty=true but blocks.close is non-null len={d}\n", .{close.len});
                    return error.TestUnexpectedResult;
                }
                // Non-empty delimiter preserved
                try testing.expectEqualStrings("{", grammar.blocks.open.?);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// --- Preservation Property Tests (empty-blocks-misleading-error) ---
// Property 2: Non-Empty Delimiter Behavior Unchanged
// These tests capture baseline behavior on UNFIXED code for non-buggy inputs.
// They MUST PASS on both unfixed and fixed code.

// Concrete preservation test: non-empty delimiters preserved
test "preservation: non-empty delimiters preserved correctly" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[blocks]
        \\open = "{"
        \\close = "}"
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqualStrings("{", grammar.blocks.open.?);
    try testing.expectEqualStrings("}", grammar.blocks.close.?);
}

// Concrete preservation test: multi-char delimiters preserved
test "preservation: multi-char delimiters preserved correctly" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["$name:IDENTIFIER", "("]
        \\
        \\[blocks]
        \\open = "begin"
        \\close = "end"
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqualStrings("begin", grammar.blocks.open.?);
    try testing.expectEqualStrings("end", grammar.blocks.close.?);
}

// Concrete preservation test: no [blocks] section → null defaults
test "preservation: no blocks section returns null defaults" {
    const source =
        \\[[patterns]]
        \\type = "call"
        \\sequence = ["identifier", "("]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expect(grammar.blocks.open == null);
    try testing.expect(grammar.blocks.close == null);
    try testing.expect(grammar.blocks.indentation == false);
}

// Concrete preservation test: missing [[patterns]] still returns error
test "preservation: missing patterns still returns MissingPatterns" {
    const source =
        \\[language]
        \\name = "test"
        \\
        \\[blocks]
        \\open = "{"
        \\close = "}"
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());
    try testing.expectError(error.MissingPatterns, result);
}

// Concrete preservation test: indentation-only blocks
test "preservation: indentation-only blocks with null delimiters" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["def", "$name:IDENTIFIER", "("]
        \\
        \\[blocks]
        \\indentation = true
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expect(grammar.blocks.open == null);
    try testing.expect(grammar.blocks.close == null);
    try testing.expect(grammar.blocks.indentation == true);
}

// Property-based test: non-empty delimiters are always preserved
test "property: non-empty block delimiters preserved" {
    // Generate random non-empty delimiter strings (alpha, len 1-8)
    const pair_gen = comptime gen.tuple2(
        []const u8,
        []const u8,
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
    );

    try minish.check(testing.allocator, pair_gen, struct {
        fn prop(vals: struct { []const u8, []const u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const open_delim = vals[0];
            const close_delim = vals[1];

            // Build TOML with non-empty delimiters and a valid [[patterns]] section
            var buf: std.ArrayList(u8) = .empty;
            const w = buf.writer(alloc);

            try w.writeAll("[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"(\"]\n\n[blocks]\nopen = \"");
            try w.writeAll(open_delim);
            try w.writeAll("\"\nclose = \"");
            try w.writeAll(close_delim);
            try w.writeAll("\"\n");

            const source = buf.items;
            const grammar = try parseGrammar(source, alloc);

            // Non-empty delimiters must be preserved exactly
            try testing.expectEqualStrings(open_delim, grammar.blocks.open.?);
            try testing.expectEqualStrings(close_delim, grammar.blocks.close.?);
        }
    }.prop, .{ .num_runs = 100 });
}
