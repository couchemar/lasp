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

// --- LookbackBuffer: fixed-size circular buffer of capacity 4 ---

const lookback_capacity = 4;

const LookbackBuffer = struct {
    entries: [lookback_capacity][]const u8 = .{&.{}} ** lookback_capacity,
    count: usize = 0,
    write_pos: usize = 0,

    fn push(self: *LookbackBuffer, text: []const u8) void {
        self.entries[self.write_pos] = text;
        self.write_pos = (self.write_pos + 1) % lookback_capacity;
        if (self.count < lookback_capacity) self.count += 1;
    }

    fn contains(self: LookbackBuffer, text: []const u8) bool {
        const valid = @min(self.count, lookback_capacity);
        for (0..valid) |i| {
            // Read from oldest to newest
            const idx = if (self.count >= lookback_capacity)
                (self.write_pos + i) % lookback_capacity
            else
                i;
            if (std.mem.eql(u8, self.entries[idx], text)) return true;
        }
        return false;
    }
};

// --- BlockStack: tracks nested open/close delimiter byte offsets ---

const BlockStack = struct {
    offsets: std.ArrayList(usize) = .empty,

    fn push(self: *BlockStack, allocator: std.mem.Allocator, offset: usize) !void {
        try self.offsets.append(allocator, offset);
    }

    fn pop(self: *BlockStack) void {
        if (self.offsets.items.len > 0) {
            _ = self.offsets.pop();
        }
    }

    fn top(self: BlockStack) ?usize {
        if (self.offsets.items.len == 0) return null;
        return self.offsets.items[self.offsets.items.len - 1];
    }
};

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
    blocks: loader.BlockConfig,
    allocator: std.mem.Allocator,
) ![]StructuralEvent {
    var result: std.ArrayList(StructuralEvent) = .empty;
    var pending_captures: std.ArrayList(CaptureEntry) = .empty;
    var matched_kinds: std.ArrayList(TokenKind) = .empty;

    var lookback = LookbackBuffer{};
    var block_stack = BlockStack{};

    var state: usize = 0;
    var pattern_start: usize = 0;
    var pattern_col: usize = 0;

    for (tokens) |token| {
        const text = source[token.start..token.end];

        // Block tracking (before skip check)
        if (blocks.open) |open| {
            if (std.mem.eql(u8, text, open)) {
                try block_stack.push(allocator, token.start);
            }
        }
        if (blocks.close) |close| {
            if (std.mem.eql(u8, text, close)) {
                block_stack.pop();
            }
        }

        if (shouldSkip(token.kind)) continue;

        // Push to lookback before automaton stepping
        lookback.push(text);

        if (automaton.step(state, token, source)) |step_result| {
            if (state == 0) {
                pattern_start = token.start;
                pattern_col = token.col;
            }
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
                const pattern = findPattern(patterns, event_info.type_name);

                // Position constraint check
                if (pattern) |p| {
                    if (p.position) |pos| {
                        switch (pos) {
                            .start => {
                                if (pattern_col != 0) {
                                    // Discard match
                                    state = 0;
                                    pending_captures.clearRetainingCapacity();
                                    matched_kinds.clearRetainingCapacity();
                                    continue;
                                }
                            },
                        }
                    }
                }

                // Exclusion check
                if (pattern) |p| {
                    if (p.exclude.len > 0) {
                        var excluded = false;
                        for (p.exclude) |exc| {
                            if (lookback.contains(exc)) {
                                excluded = true;
                                break;
                            }
                        }
                        if (excluded) {
                            state = 0;
                            pending_captures.clearRetainingCapacity();
                            matched_kinds.clearRetainingCapacity();
                            continue;
                        }
                    }
                }

                // Compute confidence
                const max_score = if (pattern) |p| patternMaxScore(p.sequence) else 1.0;
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
                        .col = pattern_col,
                        .confidence = confidence,
                        .block_start = block_stack.top(),
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

fn findPattern(patterns: []const loader.Pattern, type_name: []const u8) ?loader.Pattern {
    for (patterns) |p| {
        if (std.mem.eql(u8, p.type_name, type_name)) return p;
    }
    return null;
}

fn findPatternMaxScore(patterns: []const loader.Pattern, type_name: []const u8) f32 {
    if (findPattern(patterns, type_name)) |p| return patternMaxScore(p.sequence);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("call", result[0].type_name);
    try testing.expectEqualStrings("call", result[1].type_name);
}

// --- LookbackBuffer Unit Tests ---

test "LookbackBuffer: push/contains with fewer than 4 entries" {
    var lb = LookbackBuffer{};
    lb.push("hello");
    lb.push("world");
    try testing.expect(lb.contains("hello"));
    try testing.expect(lb.contains("world"));
    try testing.expect(!lb.contains("missing"));
}

test "LookbackBuffer: circular overwrite after 4+ pushes" {
    var lb = LookbackBuffer{};
    lb.push("a");
    lb.push("b");
    lb.push("c");
    lb.push("d");
    // Buffer full: [a, b, c, d]
    try testing.expect(lb.contains("a"));
    lb.push("e");
    // "a" should be overwritten: [e, b, c, d]
    try testing.expect(!lb.contains("a"));
    try testing.expect(lb.contains("e"));
    try testing.expect(lb.contains("b"));
}

// --- BlockStack Unit Tests ---

test "BlockStack: push/pop/top basic operations" {
    var bs = BlockStack{};
    try bs.push(testing.allocator, 10);
    try bs.push(testing.allocator, 20);
    try testing.expectEqual(@as(?usize, 20), bs.top());
    bs.pop();
    try testing.expectEqual(@as(?usize, 10), bs.top());
    bs.pop();
    try testing.expectEqual(@as(?usize, null), bs.top());
    bs.offsets.deinit(testing.allocator);
}

test "BlockStack: pop on empty stack is no-op" {
    var bs = BlockStack{};
    bs.pop(); // should not crash
    try testing.expectEqual(@as(?usize, null), bs.top());
}

// --- Extended Parse Unit Tests ---

test "parse: position = start at col 0 emits event" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]loader.Pattern{.{
        .type_name = "function",
        .sequence = &.{ .{ .keyword_literal = "fn" }, .{ .identifier = {} } },
        .captures = &.{},
        .position = .start,
    }};

    const automaton = try compiler.compile(patterns, alloc);
    const source = "fn add";
    const tokens = &[_]Token{
        .{ .kind = .keyword, .start = 0, .end = 2, .line = 1, .col = 0 },
        .{ .kind = .identifier, .start = 3, .end = 6, .line = 1, .col = 3 },
    };

    const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(usize, 0), result[0].col);
}

test "parse: position = start at col > 0 discards event" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]loader.Pattern{.{
        .type_name = "function",
        .sequence = &.{ .{ .keyword_literal = "fn" }, .{ .identifier = {} } },
        .captures = &.{},
        .position = .start,
    }};

    const automaton = try compiler.compile(patterns, alloc);
    const source = "  fn add";
    const tokens = &[_]Token{
        .{ .kind = .keyword, .start = 2, .end = 4, .line = 1, .col = 2 },
        .{ .kind = .identifier, .start = 5, .end = 8, .line = 1, .col = 5 },
    };

    const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "parse: exclude with matching lookback discards event" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]loader.Pattern{.{
        .type_name = "function",
        .sequence = &.{ .{ .identifier = {} }, .{ .symbol_literal = "(" } },
        .captures = &.{},
        .exclude = &.{"-spec"},
    }};

    const automaton = try compiler.compile(patterns, alloc);
    // "-spec add(" — "-spec" is a keyword preceding the match
    const source = "-spec add(";
    const tokens = &[_]Token{
        .{ .kind = .keyword, .start = 0, .end = 5, .line = 1, .col = 0 },
        .{ .kind = .identifier, .start = 6, .end = 9, .line = 1, .col = 6 },
        .{ .kind = .delimiter, .start = 9, .end = 10, .line = 1, .col = 9 },
    };

    const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "parse: exclude with no matching lookback emits event" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]loader.Pattern{.{
        .type_name = "function",
        .sequence = &.{ .{ .identifier = {} }, .{ .symbol_literal = "(" } },
        .captures = &.{},
        .exclude = &.{"-spec"},
    }};

    const automaton = try compiler.compile(patterns, alloc);
    const source = "add(";
    const tokens = &[_]Token{
        .{ .kind = .identifier, .start = 0, .end = 3, .line = 1, .col = 0 },
        .{ .kind = .delimiter, .start = 3, .end = 4, .line = 1, .col = 3 },
    };

    const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
    try testing.expectEqual(@as(usize, 1), result.len);
}

test "parse: block delimiters set block_start on events" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]loader.Pattern{.{
        .type_name = "call",
        .sequence = &.{ .{ .identifier = {} }, .{ .symbol_literal = "(" } },
        .captures = &.{},
    }};

    const automaton = try compiler.compile(patterns, alloc);
    // "{ foo(" — open brace at byte 0, then call inside block
    const source = "{ foo(";
    const tokens = &[_]Token{
        .{ .kind = .delimiter, .start = 0, .end = 1, .line = 1, .col = 0 },
        .{ .kind = .identifier, .start = 2, .end = 5, .line = 1, .col = 2 },
        .{ .kind = .delimiter, .start = 5, .end = 6, .line = 1, .col = 5 },
    };

    const result = try parse(automaton, tokens, source, patterns, .{ .open = "{", .close = "}" }, alloc);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(?usize, 0), result[0].block_start);
}

test "parse: no blocks section means block_start is null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]loader.Pattern{.{
        .type_name = "call",
        .sequence = &.{ .{ .identifier = {} }, .{ .symbol_literal = "(" } },
        .captures = &.{},
    }};

    const automaton = try compiler.compile(patterns, alloc);
    const source = "foo(";
    const tokens = &[_]Token{
        .{ .kind = .identifier, .start = 0, .end = 3, .line = 1, .col = 0 },
        .{ .kind = .delimiter, .start = 3, .end = 4, .line = 1, .col = 3 },
    };

    const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(?usize, null), result[0].block_start);
}

test "parse: unmatched close delimiter does not crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]loader.Pattern{.{
        .type_name = "call",
        .sequence = &.{ .{ .identifier = {} }, .{ .symbol_literal = "(" } },
        .captures = &.{},
    }};

    const automaton = try compiler.compile(patterns, alloc);
    const source = "} foo(";
    const tokens = &[_]Token{
        .{ .kind = .delimiter, .start = 0, .end = 1, .line = 1, .col = 0 },
        .{ .kind = .identifier, .start = 2, .end = 5, .line = 1, .col = 2 },
        .{ .kind = .delimiter, .start = 5, .end = 6, .line = 1, .col = 5 },
    };

    // Should not crash even with unmatched close delimiter
    const result = try parse(automaton, tokens, source, patterns, .{ .open = "{", .close = "}" }, alloc);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(?usize, null), result[0].block_start);
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

            const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
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

            const result = try parse(automaton, tokens.items, source, patterns, .{}, alloc);
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

            const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
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

// Feature: phase3-multi-language-patterns, Property 3: Position constraint enforcement
test "property: position constraint enforcement" {
    // For any pattern with position = "start", events emitted only when first token col == 0
    const col_gen = gen.intRange(u16, 0, 20);

    try minish.check(testing.allocator, col_gen, struct {
        fn prop(col_val: u16) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const col: usize = @intCast(col_val);

            const patterns = &[_]loader.Pattern{.{
                .type_name = "function",
                .sequence = &.{ .{ .keyword_literal = "fn" }, .{ .identifier = {} } },
                .captures = &.{},
                .position = .start,
            }};

            const automaton = try compiler.compile(patterns, alloc);
            const source = "fn add";
            const tokens = &[_]Token{
                .{ .kind = .keyword, .start = 0, .end = 2, .line = 1, .col = col },
                .{ .kind = .identifier, .start = 3, .end = 6, .line = 1, .col = col + 3 },
            };

            const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
            if (col == 0) {
                try testing.expectEqual(@as(usize, 1), result.len);
            } else {
                try testing.expectEqual(@as(usize, 0), result.len);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase3-multi-language-patterns, Property 4: Exclusion pattern discards matches
test "property: exclusion pattern discards matches" {
    const exc_gen = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha });

    try minish.check(testing.allocator, exc_gen, struct {
        fn prop(exc_token: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const patterns = &[_]loader.Pattern{.{
                .type_name = "call",
                .sequence = &.{ .{ .identifier = {} }, .{ .symbol_literal = "(" } },
                .captures = &.{},
                .exclude = &.{exc_token},
            }};

            const automaton = try compiler.compile(patterns, alloc);

            // Build source with exclude token preceding the match
            var buf: [256]u8 = undefined;
            const source = std.fmt.bufPrint(&buf, "{s} add(", .{exc_token}) catch return;
            const exc_end = exc_token.len;
            const id_start = exc_end + 1;
            const id_end = id_start + 3;

            const tokens = &[_]Token{
                .{ .kind = .keyword, .start = 0, .end = exc_end, .line = 1, .col = 0 },
                .{ .kind = .identifier, .start = id_start, .end = id_end, .line = 1, .col = id_start },
                .{ .kind = .delimiter, .start = id_end, .end = id_end + 1, .line = 1, .col = id_end },
            };

            const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
            // Should be discarded because lookback contains the exclude token
            try testing.expectEqual(@as(usize, 0), result.len);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase3-multi-language-patterns, Property 5: Lookback buffer stores last N non-skip tokens
test "property: lookback buffer stores last N non-skip tokens" {
    const count_gen = gen.intRange(u8, 0, 10);

    try minish.check(testing.allocator, count_gen, struct {
        fn prop(num_tokens: u8) !void {
            var lb = LookbackBuffer{};

            // Push num_tokens entries
            var expected: std.ArrayList([]const u8) = .empty;
            defer expected.deinit(testing.allocator);

            const names = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" };
            for (0..num_tokens) |i| {
                lb.push(names[i]);
                try expected.append(testing.allocator, names[i]);
            }

            // The buffer should contain the last min(count, 4) entries
            const window_start = if (num_tokens > lookback_capacity) num_tokens - lookback_capacity else 0;
            for (window_start..num_tokens) |i| {
                try testing.expect(lb.contains(names[i]));
            }

            // Entries before the window should not be present (if overwritten)
            if (num_tokens > lookback_capacity) {
                for (0..window_start) |i| {
                    try testing.expect(!lb.contains(names[i]));
                }
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase3-multi-language-patterns, Property 6: Block stack annotates events correctly
test "property: block stack annotates events correctly" {
    // Generate whether to wrap the match in a block or not
    const wrap_gen = gen.boolean();

    try minish.check(testing.allocator, wrap_gen, struct {
        fn prop(in_block: bool) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const patterns = &[_]loader.Pattern{.{
                .type_name = "call",
                .sequence = &.{ .{ .identifier = {} }, .{ .symbol_literal = "(" } },
                .captures = &.{},
            }};

            const automaton = try compiler.compile(patterns, alloc);

            if (in_block) {
                // "{ foo(" — open brace at byte 0
                const source = "{ foo(";
                const tokens = &[_]Token{
                    .{ .kind = .delimiter, .start = 0, .end = 1, .line = 1, .col = 0 },
                    .{ .kind = .identifier, .start = 2, .end = 5, .line = 1, .col = 2 },
                    .{ .kind = .delimiter, .start = 5, .end = 6, .line = 1, .col = 5 },
                };
                const result = try parse(automaton, tokens, source, patterns, .{ .open = "{", .close = "}" }, alloc);
                try testing.expectEqual(@as(usize, 1), result.len);
                try testing.expectEqual(@as(?usize, 0), result[0].block_start);
            } else {
                // "foo(" — no block
                const source = "foo(";
                const tokens = &[_]Token{
                    .{ .kind = .identifier, .start = 0, .end = 3, .line = 1, .col = 0 },
                    .{ .kind = .delimiter, .start = 3, .end = 4, .line = 1, .col = 3 },
                };
                const result = try parse(automaton, tokens, source, patterns, .{ .open = "{", .close = "}" }, alloc);
                try testing.expectEqual(@as(usize, 1), result.len);
                try testing.expectEqual(@as(?usize, null), result[0].block_start);
            }
        }
    }.prop, .{ .num_runs = 100 });
}
