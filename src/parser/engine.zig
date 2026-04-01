const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const events_mod = @import("events.zig");
const compiler = @import("../grammar/compiler.zig");
const loader = @import("../grammar/loader.zig");

const Token = tokenizer.Token;
const TokenKind = tokenizer.TokenKind;
const Automaton = compiler.Automaton;
const CaptureValue = compiler.CaptureValue;
const StructuralEvent = events_mod.StructuralEvent;
const CaptureEntry = events_mod.CaptureEntry;
const TokenMatcher = loader.TokenMatcher;

/// Returns true for token kinds the engine should skip.
fn shouldSkip(kind: TokenKind) bool {
    return switch (kind) {
        .newline, .indent, .comment, .string => true,
        else => false,
    };
}

/// Computes the max possible confidence score for a pattern's matchers.
fn patternMaxScore(sequence: []const TokenMatcher) f32 {
    var total: f32 = 0.0;
    for (sequence) |m| {
        total += switch (m) {
            .keyword_literal => events_mod.evidence_weights.keyword,
            .symbol_literal => events_mod.evidence_weights.symbol,
            .identifier, .capture => events_mod.evidence_weights.identifier,
        };
    }
    return total;
}

/// Runs the automaton against the token stream, emitting structural events.
/// Skips tokens with kind: newline, indent, comment, string.
/// Processes each non-skipped token exactly once (O(N), no backtracking).
pub fn parse(
    automaton: Automaton,
    tokens: []const Token,
    source: []const u8,
    patterns: []const loader.Pattern,
    allocator: std.mem.Allocator,
) ![]StructuralEvent {
    var result: std.ArrayList(StructuralEvent) = .empty;
    var pending_captures: std.ArrayList(CaptureEntry) = .empty;
    var matched_kinds: std.ArrayList(TokenKind) = .empty;

    var state: usize = 0;
    var pattern_start: usize = 0;

    for (tokens) |token| {
        if (shouldSkip(token.kind)) continue;

        if (automaton.step(state, token, source)) |step_result| {
            if (state == 0) pattern_start = token.start;
            state = step_result.next;
            try matched_kinds.append(allocator, token.kind);

            if (step_result.capture) |cap| {
                try pending_captures.append(allocator, .{
                    .field_name = cap.field_name,
                    .value = cap.value,
                });
            }

            // Check terminal state
            if (automaton.states[state].event) |event_info| {
                // Find the pattern to compute max score
                const max_score = findPatternMaxScore(patterns, event_info.type_name);
                const confidence = events_mod.computeConfidence(matched_kinds.items, max_score);

                if (confidence >= 0.3) {
                    // Find the line number from the first token in the pattern
                    var pattern_line: usize = 1;
                    for (tokens) |t| {
                        if (t.start == pattern_start) {
                            pattern_line = t.line;
                            break;
                        }
                    }

                    try result.append(allocator, .{
                        .type_name = event_info.type_name,
                        .captures = try pending_captures.toOwnedSlice(allocator),
                        .start = pattern_start,
                        .end = token.end,
                        .line = pattern_line,
                        .col = 0,
                        .confidence = confidence,
                    });
                } else {
                    pending_captures.clearRetainingCapacity();
                }

                state = 0;
                matched_kinds.clearRetainingCapacity();
            }
        } else {
            state = 0;
            pending_captures.clearRetainingCapacity();
            matched_kinds.clearRetainingCapacity();
        }
    }

    return result.toOwnedSlice(allocator);
}

fn findPatternMaxScore(patterns: []const loader.Pattern, type_name: []const u8) f32 {
    for (patterns) |p| {
        if (std.mem.eql(u8, p.type_name, type_name)) return patternMaxScore(p.sequence);
    }
    return 1.0; // fallback
}

// --- Unit Tests ---

const testing = std.testing;

test "parse: single pattern match emits event" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]loader.Pattern{.{
        .type_name = "function",
        .sequence = &.{
            .{ .keyword_literal = "fn" },
            .{ .capture = .{ .field_name = "name", .position = 1 } },
            .{ .symbol_literal = "(" },
        },
        .captures = &.{.{ .field_name = "name", .position = 1 }},
    }};

    const automaton = try compiler.compile(patterns, alloc);
    const source = "fn add(";
    const tokens = &[_]Token{
        .{ .kind = .keyword, .start = 0, .end = 2, .line = 1, .col = 0 },
        .{ .kind = .identifier, .start = 3, .end = 6, .line = 1, .col = 3 },
        .{ .kind = .delimiter, .start = 6, .end = 7, .line = 1, .col = 6 },
    };

    const result = try parse(automaton, tokens, source, patterns, alloc);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("function", result[0].type_name);
    try testing.expectEqual(@as(usize, 0), result[0].start);
    try testing.expectEqual(@as(usize, 7), result[0].end);
    try testing.expectEqual(@as(usize, 1), result[0].captures.len);
    try testing.expectEqualStrings("name", result[0].captures[0].field_name);
    try testing.expectEqualStrings("add", result[0].captures[0].value);
    try testing.expect(result[0].confidence > 0.3);
}

test "parse: no matching pattern emits nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]loader.Pattern{.{
        .type_name = "function",
        .sequence = &.{ .{ .keyword_literal = "fn" }, .{ .identifier = {} } },
        .captures = &.{},
    }};

    const automaton = try compiler.compile(patterns, alloc);
    const source = "let x";
    const tokens = &[_]Token{
        .{ .kind = .keyword, .start = 0, .end = 3, .line = 1, .col = 0 },
        .{ .kind = .identifier, .start = 4, .end = 5, .line = 1, .col = 4 },
    };

    const result = try parse(automaton, tokens, source, patterns, alloc);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "parse: skip tokens between structural tokens" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]loader.Pattern{.{
        .type_name = "function",
        .sequence = &.{ .{ .keyword_literal = "fn" }, .{ .identifier = {} } },
        .captures = &.{},
    }};

    const automaton = try compiler.compile(patterns, alloc);
    // "fn\n  add" — newline and indent between fn and add
    const source = "fn\n  add";
    const tokens = &[_]Token{
        .{ .kind = .keyword, .start = 0, .end = 2, .line = 1, .col = 0 },
        .{ .kind = .newline, .start = 2, .end = 3, .line = 1, .col = 2 },
        .{ .kind = .indent, .start = 3, .end = 5, .line = 2, .col = 0 },
        .{ .kind = .identifier, .start = 5, .end = 8, .line = 2, .col = 2 },
    };

    const result = try parse(automaton, tokens, source, patterns, alloc);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("function", result[0].type_name);
}

test "parse: confidence computation for known tokens" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Pattern: keyword + identifier + symbol → max = 0.5 + 0.2 + 0.2 = 0.9
    const patterns = &[_]loader.Pattern{.{
        .type_name = "function",
        .sequence = &.{
            .{ .keyword_literal = "fn" },
            .{ .identifier = {} },
            .{ .symbol_literal = "(" },
        },
        .captures = &.{},
    }};

    const automaton = try compiler.compile(patterns, alloc);
    const source = "fn add(";
    const tokens = &[_]Token{
        .{ .kind = .keyword, .start = 0, .end = 2, .line = 1, .col = 0 },
        .{ .kind = .identifier, .start = 3, .end = 6, .line = 1, .col = 3 },
        .{ .kind = .delimiter, .start = 6, .end = 7, .line = 1, .col = 6 },
    };

    const result = try parse(automaton, tokens, source, patterns, alloc);
    try testing.expectEqual(@as(usize, 1), result.len);
    // All tokens matched their expected kinds, so confidence = 1.0
    try testing.expectApproxEqRel(@as(f32, 1.0), result[0].confidence, 0.01);
}

test "parse: multiple pattern matches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]loader.Pattern{.{
        .type_name = "call",
        .sequence = &.{ .{ .identifier = {} }, .{ .symbol_literal = "(" } },
        .captures = &.{},
    }};

    const automaton = try compiler.compile(patterns, alloc);
    const source = "foo( bar(";
    const tokens = &[_]Token{
        .{ .kind = .identifier, .start = 0, .end = 3, .line = 1, .col = 0 },
        .{ .kind = .delimiter, .start = 3, .end = 4, .line = 1, .col = 3 },
        .{ .kind = .identifier, .start = 5, .end = 8, .line = 1, .col = 5 },
        .{ .kind = .delimiter, .start = 8, .end = 9, .line = 1, .col = 8 },
    };

    const result = try parse(automaton, tokens, source, patterns, alloc);
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("call", result[0].type_name);
    try testing.expectEqualStrings("call", result[1].type_name);
}

// --- Property Tests ---

const minish = @import("minish");
const gen = minish.gen;

// Feature: phase2-grammar-automaton, Property 7: Engine pattern match correctness
test "property: engine pattern match correctness" {
    const name_gen = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha });

    try minish.check(testing.allocator, name_gen, struct {
        fn prop(ident: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const patterns = &[_]loader.Pattern{.{
                .type_name = "function",
                .sequence = &.{
                    .{ .keyword_literal = "fn" },
                    .{ .capture = .{ .field_name = "name", .position = 1 } },
                },
                .captures = &.{.{ .field_name = "name", .position = 1 }},
            }};

            const automaton = try compiler.compile(patterns, alloc);

            // Build source: "fn <ident>"
            var buf: [256]u8 = undefined;
            const source = std.fmt.bufPrint(&buf, "fn {s}", .{ident}) catch return;
            const tokens = &[_]Token{
                .{ .kind = .keyword, .start = 0, .end = 2, .line = 1, .col = 0 },
                .{ .kind = .identifier, .start = 3, .end = 3 + ident.len, .line = 1, .col = 3 },
            };

            const result = try parse(automaton, tokens, source, patterns, alloc);
            try testing.expectEqual(@as(usize, 1), result.len);
            try testing.expectEqualStrings("function", result[0].type_name);
            try testing.expectEqual(@as(usize, 1), result[0].captures.len);
            try testing.expectEqualStrings(ident, result[0].captures[0].value);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase2-grammar-automaton, Property 8: Engine skip token transparency
test "property: engine skip token transparency" {
    // Generate number of skip tokens to insert (0-5)
    const skip_gen = gen.intRange(u8, 0, 5);

    try minish.check(testing.allocator, skip_gen, struct {
        fn prop(num_skips: u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const patterns = &[_]loader.Pattern{.{
                .type_name = "function",
                .sequence = &.{ .{ .keyword_literal = "fn" }, .{ .identifier = {} } },
                .captures = &.{},
            }};

            const automaton = try compiler.compile(patterns, alloc);
            const source = "fn add";

            // Build token stream with skip tokens inserted between fn and add
            var tokens: std.ArrayList(Token) = .empty;
            try tokens.append(alloc, .{ .kind = .keyword, .start = 0, .end = 2, .line = 1, .col = 0 });
            for (0..num_skips) |_| {
                try tokens.append(alloc, .{ .kind = .newline, .start = 2, .end = 3, .line = 1, .col = 2 });
            }
            try tokens.append(alloc, .{ .kind = .identifier, .start = 3, .end = 6, .line = 2, .col = 0 });

            const result = try parse(automaton, tokens.items, source, patterns, alloc);
            // Should always match regardless of skip tokens
            try testing.expectEqual(@as(usize, 1), result.len);
            try testing.expectEqualStrings("function", result[0].type_name);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase2-grammar-automaton, Property 9: Event field invariants
test "property: event field invariants" {
    const name_gen = gen.string(.{ .min_len = 1, .max_len = 16, .charset = .alpha });

    try minish.check(testing.allocator, name_gen, struct {
        fn prop(ident: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const patterns = &[_]loader.Pattern{.{
                .type_name = "call",
                .sequence = &.{ .{ .identifier = {} }, .{ .symbol_literal = "(" } },
                .captures = &.{},
            }};

            const automaton = try compiler.compile(patterns, alloc);
            var buf: [256]u8 = undefined;
            const source = std.fmt.bufPrint(&buf, "{s}(", .{ident}) catch return;
            const tokens = &[_]Token{
                .{ .kind = .identifier, .start = 0, .end = ident.len, .line = 1, .col = 0 },
                .{ .kind = .delimiter, .start = ident.len, .end = ident.len + 1, .line = 1, .col = ident.len },
            };

            const result = try parse(automaton, tokens, source, patterns, alloc);
            for (result) |event| {
                try testing.expect(event.start <= event.end);
                try testing.expect(event.end <= source.len);
                try testing.expect(event.confidence >= 0.3);
                try testing.expect(event.confidence <= 1.0);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase2-grammar-automaton, Property 10: Confidence computation correctness
test "property: confidence computation correctness" {
    // Test that confidence = sum(weights) / max_score
    const len_gen = gen.intRange(u8, 1, 4);

    try minish.check(testing.allocator, len_gen, struct {
        fn prop(pattern_len: u8) !void {
            // Build a pattern of all keywords → each contributes 0.5
            const expected_score: f32 = 1.0; // all match perfectly

            var kinds: std.ArrayList(TokenKind) = .empty;
            defer kinds.deinit(testing.allocator);
            var max: f32 = 0.0;
            for (0..pattern_len) |_| {
                try kinds.append(testing.allocator, .keyword);
                max += events_mod.evidence_weights.keyword;
            }

            const confidence = events_mod.computeConfidence(kinds.items, max);
            try testing.expectApproxEqRel(expected_score, confidence, 0.01);
        }
    }.prop, .{ .num_runs = 100 });
}
