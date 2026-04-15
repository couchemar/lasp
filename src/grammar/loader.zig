const std = @import("std");
const toml = @import("toml");

// --- Data Types ---

pub const EvidenceWeights = struct {
    keyword: f32 = 0.5,
    identifier: f32 = 0.2,
    symbol: f32 = 0.2,
    block: f32 = 0.3,
    relaxed_keyword: f32 = 0.1,
};

pub const Grammar = struct {
    language_name: ?[]const u8,
    keyword_categories: []const KeywordCategory,
    keyword_table: []const []const u8,
    patterns: []const Pattern,
    blocks: BlockConfig,
    weights: EvidenceWeights = .{},
};

pub const KeywordCategory = struct {
    name: []const u8,
    keywords: []const []const u8,
};

pub const PositionConstraint = enum {
    start, // column 0
};

pub const SequenceElement = struct {
    matcher: TokenMatcher,
    is_optional: bool = false,
};

pub const Pattern = struct {
    type_name: []const u8,
    sequence: []const SequenceElement,
    captures: []const Capture,
    position: ?PositionConstraint = null,
    exclude: []const []const u8 = &.{},
    not_preceded_by: []const []const u8 = &.{},
};

pub const TokenMatcher = union(enum) {
    keyword_literal: []const u8,
    symbol_literal: []const u8,
    identifier: void,
    capture: Capture,
    identifier_literal: []const u8,
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
    InvalidWeightValue,
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

/// Extracts an f32 from a TOML value that may be either .float or .integer.
/// Returns null if the value is neither type.
fn tomlToF32(v: anytype) ?f32 {
    // The TOML value is a tagged union pointer — dereference and switch on tag
    return switch (v.*) {
        .float => |f| @as(f32, @floatCast(f)),
        .integer => |i| @as(f32, @floatFromInt(i)),
        else => null,
    };
}

/// Parses a single pattern sequence string into a SequenceElement.
/// Handles trailing `?` suffix for optional elements.
fn parseSequenceElement(raw: []const u8, position: usize, allocator: std.mem.Allocator) GrammarError!struct { element: SequenceElement, capture: ?Capture } {
    // Check for trailing `?` suffix (optional element)
    var s = raw;
    var optional = false;
    if (s.len > 1 and s[s.len - 1] == '?') {
        optional = true;
        s = s[0 .. s.len - 1];
    }

    // Capture: $name:IDENTIFIER
    if (s.len > 0 and s[0] == '$') {
        const colon_idx = std.mem.indexOf(u8, s, ":") orelse return error.InvalidCaptureFormat;
        if (colon_idx < 2) return error.InvalidCaptureFormat; // need at least $x
        const suffix = s[colon_idx + 1 ..];
        if (!std.mem.eql(u8, suffix, "IDENTIFIER")) return error.InvalidCaptureFormat;
        const field_name = try allocator.dupe(u8, s[1..colon_idx]);
        const cap = Capture{ .field_name = field_name, .position = position };
        return .{ .element = .{ .matcher = .{ .capture = cap }, .is_optional = optional }, .capture = cap };
    }
    // Identifier wildcard
    if (std.mem.eql(u8, s, "identifier")) {
        return .{ .element = .{ .matcher = .{ .identifier = {} }, .is_optional = optional }, .capture = null };
    }
    // EXACT IDENTIFIER matching (Config:IDENTIFIER)
    if (std.mem.endsWith(u8, s, ":IDENTIFIER") and s.len > 11 and s[0] != '$') {
        const exact_text = try allocator.dupe(u8, s[0 .. s.len - 11]);
        return .{ .element = .{ .matcher = .{ .identifier_literal = exact_text }, .is_optional = optional }, .capture = null };
    }
    // Symbol/delimiter literal (single char)
    if (isSymbolOrDelimiter(s)) {
        return .{ .element = .{ .matcher = .{ .symbol_literal = try allocator.dupe(u8, s) }, .is_optional = optional }, .capture = null };
    }
    // Keyword literal
    return .{ .element = .{ .matcher = .{ .keyword_literal = try allocator.dupe(u8, s) }, .is_optional = optional }, .capture = null };
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

        var matchers: std.ArrayList(SequenceElement) = .empty;
        var captures: std.ArrayList(Capture) = .empty;

        for (seq_val.array.items, 0..) |item, idx| {
            const result = try parseSequenceElement(item.string, idx, allocator);
            try matchers.append(allocator, result.element);
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
            .not_preceded_by = blk: {
                if (pattern_table.get("not_preceded_by")) |npb_val| {
                    if (npb_val.array.items.len == 0) break :blk &.{};
                    var npb_list: std.ArrayList([]const u8) = .empty;
                    for (npb_val.array.items) |item| {
                        try npb_list.append(allocator, try allocator.dupe(u8, item.string));
                    }
                    break :blk try npb_list.toOwnedSlice(allocator);
                }
                break :blk &.{};
            },
        });
    }

    // --- [blocks] (optional) ---
    var blocks = BlockConfig{};
    if (root.get("blocks")) |blocks_table| {
        if (blocks_table.get("open")) |v| {
            if (v.string.len > 0) blocks.open = try allocator.dupe(u8, v.string);
        }
        if (blocks_table.get("close")) |v| {
            if (v.string.len > 0) blocks.close = try allocator.dupe(u8, v.string);
        }
        if (blocks_table.get("indentation")) |v| blocks.indentation = v.bool;
    }

    return Grammar{
        .language_name = language_name,
        .keyword_categories = try categories.toOwnedSlice(allocator),
        .keyword_table = try all_keywords.toOwnedSlice(allocator),
        .patterns = try patterns.toOwnedSlice(allocator),
        .blocks = blocks,
        .weights = blk: {
            var w = EvidenceWeights{};
            if (root.get("weights")) |wt| {
                if (wt.get("keyword")) |v| {
                    const val = tomlToF32(v) orelse return error.InvalidWeightValue;
                    if (val < 0.0) return error.InvalidWeightValue;
                    w.keyword = val;
                }
                if (wt.get("identifier")) |v| {
                    const val = tomlToF32(v) orelse return error.InvalidWeightValue;
                    if (val < 0.0) return error.InvalidWeightValue;
                    w.identifier = val;
                }
                if (wt.get("symbol")) |v| {
                    const val = tomlToF32(v) orelse return error.InvalidWeightValue;
                    if (val < 0.0) return error.InvalidWeightValue;
                    w.symbol = val;
                }
                if (wt.get("block")) |v| {
                    const val = tomlToF32(v) orelse return error.InvalidWeightValue;
                    if (val < 0.0) return error.InvalidWeightValue;
                    w.block = val;
                }
                if (wt.get("relaxed_keyword")) |v| {
                    const val = tomlToF32(v) orelse return error.InvalidWeightValue;
                    if (val < 0.0) return error.InvalidWeightValue;
                    w.relaxed_keyword = val;
                }
            }
            break :blk w;
        },
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
        for (pattern.sequence, 0..) |elem, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll("\"");
            switch (elem.matcher) {
                .keyword_literal => |kw| try w.writeAll(kw),
                .symbol_literal => |sym| try w.writeAll(sym),
                .identifier => try w.writeAll("identifier"),
                .capture => |cap| {
                    try w.writeAll("$");
                    try w.writeAll(cap.field_name);
                    try w.writeAll(":IDENTIFIER");
                },
                .identifier_literal => |id| {
                    try w.writeAll(id);
                    try w.writeAll(":IDENTIFIER");
                },
            }
            if (elem.is_optional) try w.writeAll("?");
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

        // not_preceded_by field
        if (pattern.not_preceded_by.len > 0) {
            try w.writeAll("not_preceded_by = [");
            for (pattern.not_preceded_by, 0..) |npb, j| {
                if (j > 0) try w.writeAll(", ");
                try w.writeAll("\"");
                try w.writeAll(npb);
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

    // [weights] — only serialize when values differ from defaults
    {
        const defaults = EvidenceWeights{};
        const wts = grammar.weights;
        if (wts.keyword != defaults.keyword or
            wts.identifier != defaults.identifier or
            wts.symbol != defaults.symbol or
            wts.block != defaults.block or
            wts.relaxed_keyword != defaults.relaxed_keyword)
        {
            try w.writeAll("\n[weights]\n");
            if (wts.keyword != defaults.keyword) {
                try std.fmt.format(w, "keyword = {d}\n", .{wts.keyword});
            }
            if (wts.identifier != defaults.identifier) {
                try std.fmt.format(w, "identifier = {d}\n", .{wts.identifier});
            }
            if (wts.symbol != defaults.symbol) {
                try std.fmt.format(w, "symbol = {d}\n", .{wts.symbol});
            }
            if (wts.block != defaults.block) {
                try std.fmt.format(w, "block = {d}\n", .{wts.block});
            }
            if (wts.relaxed_keyword != defaults.relaxed_keyword) {
                try std.fmt.format(w, "relaxed_keyword = {d}\n", .{wts.relaxed_keyword});
            }
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
    try testing.expect(seq[0].matcher == .keyword_literal);
    try testing.expect(seq[1].matcher == .capture);
    try testing.expectEqualStrings("name", seq[1].matcher.capture.field_name);
    try testing.expectEqual(@as(usize, 1), seq[1].matcher.capture.position);
    try testing.expect(seq[2].matcher == .symbol_literal);
}

test "parseGrammar: identifier_literal parsing" {
    const source =
        \\[[patterns]]
        \\type = "call"
        \\sequence = ["Config:IDENTIFIER", "identifier"]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    const seq = grammar.patterns[0].sequence;
    try testing.expectEqual(@as(usize, 2), seq.len);
    try testing.expect(seq[0].matcher == .identifier_literal);
    try testing.expectEqualStrings("Config", seq[0].matcher.identifier_literal);
    try testing.expect(seq[1].matcher == .identifier);
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

test "parseGrammar: not_preceded_by with non-empty array" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["$name:IDENTIFIER", "("]
        \\not_preceded_by = ["fun", "="]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqual(@as(usize, 2), grammar.patterns[0].not_preceded_by.len);
    try testing.expectEqualStrings("fun", grammar.patterns[0].not_preceded_by[0]);
    try testing.expectEqualStrings("=", grammar.patterns[0].not_preceded_by[1]);
}

test "parseGrammar: not_preceded_by with empty array" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["$name:IDENTIFIER", "("]
        \\not_preceded_by = []
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqual(@as(usize, 0), grammar.patterns[0].not_preceded_by.len);
}

test "parseGrammar: omitted not_preceded_by defaults to empty" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["$name:IDENTIFIER", "("]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqual(@as(usize, 0), grammar.patterns[0].not_preceded_by.len);
}

test "parseGrammar: combined exclude and not_preceded_by" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["$name:IDENTIFIER", "("]
        \\exclude = ["-spec", "-type"]
        \\not_preceded_by = ["fun", "="]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqual(@as(usize, 2), grammar.patterns[0].exclude.len);
    try testing.expectEqualStrings("-spec", grammar.patterns[0].exclude[0]);
    try testing.expectEqual(@as(usize, 2), grammar.patterns[0].not_preceded_by.len);
    try testing.expectEqualStrings("fun", grammar.patterns[0].not_preceded_by[0]);
    try testing.expectEqualStrings("=", grammar.patterns[0].not_preceded_by[1]);
}

test "formatGrammar: serializes non-empty not_preceded_by, omits when empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Pattern with not_preceded_by
    const with_npb = Grammar{
        .language_name = null,
        .keyword_categories = &.{},
        .keyword_table = &.{},
        .patterns = &.{
            .{
                .type_name = "function",
                .sequence = &.{
                    .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 0 } } },
                    .{ .matcher = .{ .symbol_literal = "(" } },
                },
                .captures = &.{
                    .{ .field_name = "name", .position = 0 },
                },
                .not_preceded_by = &.{ "fun", "=" },
            },
        },
        .blocks = .{},
    };

    const toml_with = try formatGrammar(with_npb, alloc);
    try testing.expect(std.mem.indexOf(u8, toml_with, "not_preceded_by = [\"fun\", \"=\"]") != null);

    // Pattern without not_preceded_by (empty)
    const without_npb = Grammar{
        .language_name = null,
        .keyword_categories = &.{},
        .keyword_table = &.{},
        .patterns = &.{
            .{
                .type_name = "function",
                .sequence = &.{
                    .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 0 } } },
                    .{ .matcher = .{ .symbol_literal = "(" } },
                },
                .captures = &.{
                    .{ .field_name = "name", .position = 0 },
                },
            },
        },
        .blocks = .{},
    };

    const toml_without = try formatGrammar(without_npb, alloc);
    try testing.expect(std.mem.indexOf(u8, toml_without, "not_preceded_by") == null);
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
                            .{ .matcher = .{ .keyword_literal = "fn" } },
                            .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } },
                            .{ .matcher = .{ .symbol_literal = "(" } },
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
                            .{ .matcher = .{ .keyword_literal = "fn" } },
                            .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } },
                            .{ .matcher = .{ .symbol_literal = "(" } },
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

// Feature: not-preceded-by-constraint, Property 1: Grammar TOML round-trip with not_preceded_by
// **Validates: Requirements 1.1, 1.4, 3.1, 3.3**
test "property: grammar TOML round-trip with not_preceded_by" {
    // Generate a random boolean for position, a random exclude string, and a random not_preceded_by string
    const triple_gen = comptime gen.tuple3(
        bool,
        []const u8,
        []const u8,
        gen.boolean(),
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
    );

    try minish.check(testing.allocator, triple_gen, struct {
        fn prop(vals: struct { bool, []const u8, []const u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const has_position = vals[0];
            const exc_token = vals[1];
            const npb_token = vals[2];

            const original = Grammar{
                .language_name = "test",
                .keyword_categories = &.{},
                .keyword_table = &.{},
                .patterns = &.{
                    .{
                        .type_name = "function",
                        .sequence = &.{
                            .{ .matcher = .{ .keyword_literal = "fn" } },
                            .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } },
                            .{ .matcher = .{ .symbol_literal = "(" } },
                        },
                        .captures = &.{
                            .{ .field_name = "name", .position = 1 },
                        },
                        .position = if (has_position) .start else null,
                        .exclude = &.{exc_token},
                        .not_preceded_by = &.{npb_token},
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

            // Verify not_preceded_by round-trips
            try testing.expectEqual(@as(usize, 1), parsed.patterns[0].not_preceded_by.len);
            try testing.expectEqualStrings(npb_token, parsed.patterns[0].not_preceded_by[0]);
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
            try testing.expect(p.not_preceded_by.len == 2);
            try testing.expectEqualStrings("fun", p.not_preceded_by[0]);
            try testing.expectEqualStrings("=", p.not_preceded_by[1]);
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

// --- Phase 2: Optional Element Tests ---

// Feature: probabilistic-confidence-scoring, Property 4: Optional element parsing round-trip
// **Validates: Requirements 2.1, 2.5, 2.6**
test "property: optional element parsing round-trip" {
    // Generate a random boolean for is_optional and a random matcher type (0-3)
    // 0 = keyword_literal, 1 = symbol_literal, 2 = identifier, 3 = identifier_literal
    const pair_gen = comptime gen.tuple2(
        bool,
        u8,
        gen.boolean(),
        gen.intRange(u8, 0, 3),
    );

    try minish.check(testing.allocator, pair_gen, struct {
        fn prop(vals: struct { bool, u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const is_optional = vals[0];
            const matcher_type = vals[1];

            // Build a Grammar with a single pattern containing one element
            const elem: SequenceElement = switch (matcher_type) {
                0 => .{ .matcher = .{ .keyword_literal = "fn" }, .is_optional = is_optional },
                1 => .{ .matcher = .{ .symbol_literal = "{" }, .is_optional = is_optional },
                2 => .{ .matcher = .{ .identifier = {} }, .is_optional = is_optional },
                3 => .{ .matcher = .{ .identifier_literal = "Config" }, .is_optional = is_optional },
                else => unreachable,
            };

            // We need at least one required element for a valid pattern,
            // so add a required keyword before the test element
            const original = Grammar{
                .language_name = "test",
                .keyword_categories = &.{},
                .keyword_table = &.{},
                .patterns = &.{
                    .{
                        .type_name = "test_pattern",
                        .sequence = &.{
                            .{ .matcher = .{ .keyword_literal = "def" } },
                            elem,
                        },
                        .captures = &.{},
                    },
                },
                .blocks = .{},
            };

            // Round-trip: format → parse
            const toml_str = try formatGrammar(original, alloc);
            const parsed = try parseGrammar(toml_str, alloc);

            // Verify the second element's is_optional flag is preserved
            try testing.expectEqual(@as(usize, 1), parsed.patterns.len);
            try testing.expectEqual(@as(usize, 2), parsed.patterns[0].sequence.len);

            const parsed_elem = parsed.patterns[0].sequence[1];
            try testing.expectEqual(is_optional, parsed_elem.is_optional);

            // Verify the matcher type is preserved
            const orig_tag: u3 = switch (elem.matcher) {
                .keyword_literal => 0,
                .symbol_literal => 1,
                .identifier => 2,
                .capture => 3,
                .identifier_literal => 4,
            };
            const parsed_tag: u3 = switch (parsed_elem.matcher) {
                .keyword_literal => 0,
                .symbol_literal => 1,
                .identifier => 2,
                .capture => 3,
                .identifier_literal => 4,
            };
            try testing.expectEqual(orig_tag, parsed_tag);
        }
    }.prop, .{ .num_runs = 100 });
}

// --- Phase 2: Optional Element Unit Tests (loader) ---

test "parseGrammar: optional symbol_literal with ? suffix" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "{?"]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    const seq = grammar.patterns[0].sequence;
    try testing.expectEqual(@as(usize, 3), seq.len);
    // "{?" → symbol_literal "{" with is_optional = true
    try testing.expect(seq[2].matcher == .symbol_literal);
    try testing.expectEqualStrings("{", seq[2].matcher.symbol_literal);
    try testing.expect(seq[2].is_optional);
    // First two elements should NOT be optional
    try testing.expect(!seq[0].is_optional);
    try testing.expect(!seq[1].is_optional);
}

test "parseGrammar: optional keyword_literal with ? suffix" {
    const source =
        \\[[patterns]]
        \\type = "test"
        \\sequence = ["fn?", "identifier"]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    const seq = grammar.patterns[0].sequence;
    try testing.expectEqual(@as(usize, 2), seq.len);
    // "fn?" → keyword_literal "fn" with is_optional = true
    try testing.expect(seq[0].matcher == .keyword_literal);
    try testing.expectEqualStrings("fn", seq[0].matcher.keyword_literal);
    try testing.expect(seq[0].is_optional);
    // "identifier" → identifier with is_optional = false
    try testing.expect(seq[1].matcher == .identifier);
    try testing.expect(!seq[1].is_optional);
}

test "parseGrammar: optional identifier with ? suffix" {
    const source =
        \\[[patterns]]
        \\type = "test"
        \\sequence = ["fn", "identifier?"]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    const seq = grammar.patterns[0].sequence;
    try testing.expectEqual(@as(usize, 2), seq.len);
    // "identifier?" → identifier with is_optional = true
    try testing.expect(seq[1].matcher == .identifier);
    try testing.expect(seq[1].is_optional);
}

test "formatGrammar: round-trip preserves optional elements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const original = Grammar{
        .language_name = null,
        .keyword_categories = &.{},
        .keyword_table = &.{},
        .patterns = &.{
            .{
                .type_name = "function",
                .sequence = &.{
                    .{ .matcher = .{ .keyword_literal = "fn" } },
                    .{ .matcher = .{ .identifier = {} } },
                    .{ .matcher = .{ .symbol_literal = "{" }, .is_optional = true },
                },
                .captures = &.{},
            },
        },
        .blocks = .{},
    };

    const toml_str = try formatGrammar(original, alloc);
    const parsed = try parseGrammar(toml_str, alloc);

    try testing.expectEqual(@as(usize, 3), parsed.patterns[0].sequence.len);
    try testing.expect(!parsed.patterns[0].sequence[0].is_optional);
    try testing.expect(!parsed.patterns[0].sequence[1].is_optional);
    try testing.expect(parsed.patterns[0].sequence[2].is_optional);
    try testing.expect(parsed.patterns[0].sequence[2].matcher == .symbol_literal);
    try testing.expectEqualStrings("{", parsed.patterns[0].sequence[2].matcher.symbol_literal);
}

// --- Phase 5: Configurable Weights Property Tests ---

// Feature: probabilistic-confidence-scoring, Property 9: Weight parsing with defaults
// **Validates: Requirements 5.1, 5.2, 5.3**
test "property: weight parsing with defaults" {
    // Generate a random bitmask (0-31) to select which weight keys to include,
    // and random percentage values (0-100) for each key.
    const tuple_gen = comptime gen.tuple2(
        u8,
        u8,
        gen.intRange(u8, 0, 31),
        gen.intRange(u8, 0, 100),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { u8, u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const bitmask = vals[0];
            const pct = vals[1];
            const weight_val: f32 = @as(f32, @floatFromInt(pct)) / 100.0;

            const keys = [_][]const u8{ "keyword", "identifier", "symbol", "block", "relaxed_keyword" };
            const defaults = [_]f32{ 0.5, 0.2, 0.2, 0.3, 0.1 };

            // Build TOML with a [weights] section containing only selected keys
            var buf: std.ArrayList(u8) = .empty;
            const w = buf.writer(alloc);
            try w.writeAll("[[patterns]]\ntype = \"test\"\nsequence = [\"identifier\", \"(\"]\n\n");

            var has_any = false;
            for (0..5) |i| {
                if (bitmask & (@as(u8, 1) << @intCast(i)) != 0) {
                    if (!has_any) {
                        try w.writeAll("[weights]\n");
                        has_any = true;
                    }
                    try std.fmt.format(w, "{s} = {d:.2}\n", .{ keys[i], weight_val });
                }
            }

            const source = buf.items;
            const grammar = try parseGrammar(source, alloc);

            // Verify: specified keys have custom values, omitted keys have defaults
            const parsed_vals = [_]f32{
                grammar.weights.keyword,
                grammar.weights.identifier,
                grammar.weights.symbol,
                grammar.weights.block,
                grammar.weights.relaxed_keyword,
            };

            for (0..5) |i| {
                if (bitmask & (@as(u8, 1) << @intCast(i)) != 0) {
                    // Specified key: should have custom value
                    try testing.expectApproxEqAbs(weight_val, parsed_vals[i], 0.01);
                } else {
                    // Omitted key: should have default value
                    try testing.expectApproxEqAbs(defaults[i], parsed_vals[i], 0.001);
                }
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: probabilistic-confidence-scoring, Property 10: Negative weight rejection
// **Validates: Requirements 5.5**
test "property: negative weight rejection" {
    // Generate a random key index (0-4) and a random negative percentage (1-100)
    const tuple_gen = comptime gen.tuple2(
        u8,
        u8,
        gen.intRange(u8, 0, 4),
        gen.intRange(u8, 1, 100),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { u8, u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const key_idx = vals[0];
            const pct = vals[1];
            const neg_val: f32 = -@as(f32, @floatFromInt(pct)) / 100.0;

            const keys = [_][]const u8{ "keyword", "identifier", "symbol", "block", "relaxed_keyword" };

            // Build TOML with a negative weight value
            var buf: std.ArrayList(u8) = .empty;
            const w = buf.writer(alloc);
            try w.writeAll("[[patterns]]\ntype = \"test\"\nsequence = [\"identifier\", \"(\"]\n\n[weights]\n");
            try std.fmt.format(w, "{s} = {d:.2}\n", .{ keys[key_idx], neg_val });

            const source = buf.items;
            const result = parseGrammar(source, alloc);
            try testing.expectError(error.InvalidWeightValue, result);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: probabilistic-confidence-scoring, Property 11: Grammar TOML round-trip with weights
// **Validates: Requirements 5.6**
test "property: grammar TOML round-trip with weights" {
    // Generate 5 random percentage values (0-100) for each weight key
    const tuple_gen = comptime gen.tuple3(
        u8,
        u8,
        u8,
        gen.intRange(u8, 0, 100),
        gen.intRange(u8, 0, 100),
        gen.intRange(u8, 0, 100),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { u8, u8, u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // Use the 3 generated values to derive 5 weight values
            const w_keyword: f32 = @as(f32, @floatFromInt(vals[0])) / 100.0;
            const w_identifier: f32 = @as(f32, @floatFromInt(vals[1])) / 100.0;
            const w_symbol: f32 = @as(f32, @floatFromInt(vals[2])) / 100.0;
            // Derive block and relaxed_keyword from combinations
            const w_block: f32 = @as(f32, @floatFromInt((vals[0] +% vals[1]) % 101)) / 100.0;
            const w_relaxed: f32 = @as(f32, @floatFromInt((vals[1] +% vals[2]) % 101)) / 100.0;

            const original = Grammar{
                .language_name = "test",
                .keyword_categories = &.{},
                .keyword_table = &.{},
                .patterns = &.{
                    .{
                        .type_name = "function",
                        .sequence = &.{
                            .{ .matcher = .{ .keyword_literal = "fn" } },
                            .{ .matcher = .{ .identifier = {} } },
                            .{ .matcher = .{ .symbol_literal = "(" } },
                        },
                        .captures = &.{},
                    },
                },
                .blocks = .{},
                .weights = .{
                    .keyword = w_keyword,
                    .identifier = w_identifier,
                    .symbol = w_symbol,
                    .block = w_block,
                    .relaxed_keyword = w_relaxed,
                },
            };

            // Round-trip: format → parse
            const toml_str = try formatGrammar(original, alloc);
            const parsed = try parseGrammar(toml_str, alloc);

            // Verify weight values are preserved
            try testing.expectApproxEqAbs(w_keyword, parsed.weights.keyword, 0.01);
            try testing.expectApproxEqAbs(w_identifier, parsed.weights.identifier, 0.01);
            try testing.expectApproxEqAbs(w_symbol, parsed.weights.symbol, 0.01);
            try testing.expectApproxEqAbs(w_block, parsed.weights.block, 0.01);
            try testing.expectApproxEqAbs(w_relaxed, parsed.weights.relaxed_keyword, 0.01);
        }
    }.prop, .{ .num_runs = 100 });
}

// --- Phase 5: Configurable Weights Unit Tests (loader) ---

test "parseGrammar: partial weight spec uses defaults for omitted keys" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[weights]
        \\keyword = 0.6
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    // keyword overridden
    try testing.expectApproxEqAbs(@as(f32, 0.6), grammar.weights.keyword, 0.001);
    // others use defaults
    try testing.expectApproxEqAbs(@as(f32, 0.2), grammar.weights.identifier, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.2), grammar.weights.symbol, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.3), grammar.weights.block, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.1), grammar.weights.relaxed_keyword, 0.001);
}

test "parseGrammar: negative weight returns InvalidWeightValue" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[weights]
        \\keyword = -0.5
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());
    try testing.expectError(error.InvalidWeightValue, result);
}

test "parseGrammar: round-trip with all weight fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const original = Grammar{
        .language_name = null,
        .keyword_categories = &.{},
        .keyword_table = &.{},
        .patterns = &.{
            .{
                .type_name = "function",
                .sequence = &.{
                    .{ .matcher = .{ .keyword_literal = "fn" } },
                    .{ .matcher = .{ .identifier = {} } },
                },
                .captures = &.{},
            },
        },
        .blocks = .{},
        .weights = .{
            .keyword = 0.7,
            .identifier = 0.3,
            .symbol = 0.15,
            .block = 0.4,
            .relaxed_keyword = 0.05,
        },
    };

    const toml_str = try formatGrammar(original, alloc);
    const parsed = try parseGrammar(toml_str, alloc);

    try testing.expectApproxEqAbs(@as(f32, 0.7), parsed.weights.keyword, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.3), parsed.weights.identifier, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.15), parsed.weights.symbol, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.4), parsed.weights.block, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.05), parsed.weights.relaxed_keyword, 0.01);
}

test "parseGrammar: omitted weights section uses all defaults" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    const defaults = EvidenceWeights{};
    try testing.expectApproxEqAbs(defaults.keyword, grammar.weights.keyword, 0.001);
    try testing.expectApproxEqAbs(defaults.identifier, grammar.weights.identifier, 0.001);
    try testing.expectApproxEqAbs(defaults.symbol, grammar.weights.symbol, 0.001);
    try testing.expectApproxEqAbs(defaults.block, grammar.weights.block, 0.001);
    try testing.expectApproxEqAbs(defaults.relaxed_keyword, grammar.weights.relaxed_keyword, 0.001);
}
