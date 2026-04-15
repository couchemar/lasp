const std = @import("std");
const loader = @import("loader.zig");
const tokenizer = @import("../parser/tokenizer.zig");

const TokenMatcher = loader.TokenMatcher;
const Capture = loader.Capture;
const Pattern = loader.Pattern;
const Token = tokenizer.Token;
const TokenKind = tokenizer.TokenKind;

// --- Data Types ---

pub const Transition = struct {
    matcher: TokenMatcher,
    next_state: usize,
    capture: ?Capture = null,
    is_optional: bool = false,
};

pub const EventInfo = struct {
    type_name: []const u8,
    capture_fields: []const []const u8,
};

pub const State = struct {
    transitions: []const Transition,
    event: ?EventInfo = null,
};

pub const CaptureValue = struct {
    field_name: []const u8,
    value: []const u8,
};

pub const MatchResult = enum {
    no_match,
    full_match,
    relaxed_match,
};

pub const Automaton = struct {
    states: []const State,

    /// Check if a token matches a transition from the given state.
    pub fn step(self: Automaton, state_idx: usize, token: Token, source: []const u8) ?struct {
        next: usize,
        capture: ?CaptureValue,
        match_quality: MatchResult,
    } {
        const state = self.states[state_idx];
        const text = source[token.start..token.end];

        for (state.transitions) |tr| {
            const quality = matchesTransition(tr.matcher, token.kind, text);
            if (quality != .no_match) {
                const cap: ?CaptureValue = if (tr.capture) |c|
                    .{ .field_name = c.field_name, .value = text }
                else
                    null;
                return .{ .next = tr.next_state, .capture = cap, .match_quality = quality };
            }
        }
        return null;
    }
};

fn matchesTransition(matcher: TokenMatcher, kind: TokenKind, text: []const u8) MatchResult {
    return switch (matcher) {
        .keyword_literal => |kw| {
            if (kind == .keyword and std.mem.eql(u8, text, kw)) return .full_match;
            if (kind == .identifier and std.mem.eql(u8, text, kw)) return .relaxed_match;
            return .no_match;
        },
        .symbol_literal => |sym| if ((kind == .delimiter or kind == .symbol) and std.mem.eql(u8, text, sym)) .full_match else .no_match,
        .identifier => if (kind == .identifier) .full_match else .no_match,
        .capture => if (kind == .identifier) .full_match else .no_match,
        .identifier_literal => |id| if (kind == .identifier and std.mem.eql(u8, text, id)) .full_match else .no_match,
    };
}

// --- Mutable builder types used during compilation ---

const MutableTransition = struct {
    matcher: TokenMatcher,
    next_state: usize,
    capture: ?Capture,
    is_optional: bool,
};

const MutableState = struct {
    transitions: std.ArrayList(MutableTransition),
    event: ?EventInfo,

    fn init() MutableState {
        return .{ .transitions = .empty, .event = null };
    }
};

/// Compiles a list of patterns into a deterministic prefix trie automaton.
/// Reuses shared prefix states across patterns.
pub fn compile(patterns: []const Pattern, allocator: std.mem.Allocator) !Automaton {
    var builder: std.ArrayList(MutableState) = .empty;

    // State 0 = root (no event)
    try builder.append(allocator, MutableState.init());

    for (patterns) |pattern| {
        var current: usize = 0;

        // Walk/create path through trie
        for (pattern.sequence, 0..) |elem, seq_idx| {
            const matcher = elem.matcher;
            const existing = findTransition(builder.items[current].transitions.items, matcher);
            if (existing) |next_state| {
                current = next_state;
            } else {
                // Create new state
                const new_state = builder.items.len;
                try builder.append(allocator, MutableState.init());

                // Determine capture for this transition
                const cap = findCaptureAtPosition(pattern.captures, seq_idx);

                try builder.items[current].transitions.append(allocator, .{
                    .matcher = matcher,
                    .next_state = new_state,
                    .capture = cap,
                    .is_optional = elem.is_optional,
                });
                current = new_state;
            }
        }

        // Mark terminal state
        var cap_fields: std.ArrayList([]const u8) = .empty;
        for (pattern.captures) |c| {
            try cap_fields.append(allocator, c.field_name);
        }
        builder.items[current].event = .{
            .type_name = pattern.type_name,
            .capture_fields = try cap_fields.toOwnedSlice(allocator),
        };
    }

    // Freeze mutable states into const slices
    var states: std.ArrayList(State) = .empty;
    for (builder.items) |*ms| {
        try states.append(allocator, .{
            .transitions = try freezeTransitions(ms.transitions.items, allocator),
            .event = ms.event,
        });
    }

    return .{ .states = try states.toOwnedSlice(allocator) };
}

fn findTransition(transitions: []const MutableTransition, matcher: TokenMatcher) ?usize {
    for (transitions) |tr| {
        if (matchersEqual(tr.matcher, matcher)) return tr.next_state;
    }
    return null;
}

fn matchersEqual(a: TokenMatcher, b: TokenMatcher) bool {
    const tag_a: u3 = switch (a) {
        .keyword_literal => 0,
        .symbol_literal => 1,
        .identifier => 2,
        .capture => 3,
        .identifier_literal => 4,
    };
    const tag_b: u3 = switch (b) {
        .keyword_literal => 0,
        .symbol_literal => 1,
        .identifier => 2,
        .capture => 3,
        .identifier_literal => 4,
    };
    if (tag_a != tag_b) return false;

    return switch (a) {
        .keyword_literal => |ka| std.mem.eql(u8, ka, b.keyword_literal),
        .symbol_literal => |sa| std.mem.eql(u8, sa, b.symbol_literal),
        .identifier => true,
        .capture => true, // captures match any identifier, same as identifier
        .identifier_literal => |ia| std.mem.eql(u8, ia, b.identifier_literal),
    };
}

fn findCaptureAtPosition(captures: []const Capture, position: usize) ?Capture {
    for (captures) |c| {
        if (c.position == position) return c;
    }
    return null;
}

fn freezeTransitions(mutable: []const MutableTransition, allocator: std.mem.Allocator) ![]const Transition {
    var result: std.ArrayList(Transition) = .empty;
    for (mutable) |mt| {
        try result.append(allocator, .{
            .matcher = mt.matcher,
            .next_state = mt.next_state,
            .capture = mt.capture,
            .is_optional = mt.is_optional,
        });
    }
    return result.toOwnedSlice(allocator);
}

// --- Unit Tests ---

const testing = std.testing;

test "compile: single pattern produces correct state count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Pattern: "fn" identifier "(" → 4 states (root + 3)
    const patterns = &[_]Pattern{.{
        .type_name = "function",
        .sequence = &.{
            .{ .matcher = .{ .keyword_literal = "fn" } },
            .{ .matcher = .{ .identifier = {} } },
            .{ .matcher = .{ .symbol_literal = "(" } },
        },
        .captures = &.{},
    }};

    const automaton = try compile(patterns, alloc);
    try testing.expectEqual(@as(usize, 4), automaton.states.len);
    // Root has no event
    try testing.expect(automaton.states[0].event == null);
    // Terminal state has event
    try testing.expect(automaton.states[3].event != null);
    try testing.expectEqualStrings("function", automaton.states[3].event.?.type_name);
}

test "compile: shared prefix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Pattern 1: "fn" identifier "("
    // Pattern 2: "fn" identifier "{"
    // Should share "fn" → identifier states, diverge at "(" vs "{"
    const patterns = &[_]Pattern{
        .{
            .type_name = "function",
            .sequence = &.{
                .{ .matcher = .{ .keyword_literal = "fn" } },
                .{ .matcher = .{ .identifier = {} } },
                .{ .matcher = .{ .symbol_literal = "(" } },
            },
            .captures = &.{},
        },
        .{
            .type_name = "fn_block",
            .sequence = &.{
                .{ .matcher = .{ .keyword_literal = "fn" } },
                .{ .matcher = .{ .identifier = {} } },
                .{ .matcher = .{ .symbol_literal = "{" } },
            },
            .captures = &.{},
        },
    };

    const automaton = try compile(patterns, alloc);
    // root → (fn) → state1 → (id) → state2 → (( or {) → state3 or state4
    // 5 states total: root, after-fn, after-id, after-(, after-{
    try testing.expectEqual(@as(usize, 5), automaton.states.len);
    // Root has 1 transition (fn)
    try testing.expectEqual(@as(usize, 1), automaton.states[0].transitions.len);
    // State after identifier has 2 transitions (divergence)
    try testing.expectEqual(@as(usize, 2), automaton.states[2].transitions.len);
}

test "compile: empty patterns produces root-only automaton" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const automaton = try compile(&.{}, arena.allocator());
    try testing.expectEqual(@as(usize, 1), automaton.states.len);
    try testing.expect(automaton.states[0].event == null);
    try testing.expectEqual(@as(usize, 0), automaton.states[0].transitions.len);
}

test "step: matching token returns next state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const patterns = &[_]Pattern{.{
        .type_name = "function",
        .sequence = &.{.{ .matcher = .{ .keyword_literal = "fn" } }},
        .captures = &.{},
    }};

    const automaton = try compile(patterns, arena.allocator());
    const source = "fn";
    const token = Token{ .kind = .keyword, .start = 0, .end = 2, .line = 1, .col = 0 };

    const result = automaton.step(0, token, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 1), result.?.next);
}

test "step: matching identifier_literal returns next state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const patterns = &[_]loader.Pattern{.{
        .type_name = "test",
        .sequence = &.{.{ .matcher = .{ .identifier_literal = "Config" } }},
        .captures = &.{},
    }};

    const automaton = try compile(patterns, arena.allocator());
    const source = "Config";
    const token = Token{ .kind = .identifier, .start = 0, .end = 6, .line = 1, .col = 0 };

    const result = automaton.step(0, token, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 1), result.?.next);

    const fail_source = "Other";
    const fail_token = Token{ .kind = .identifier, .start = 0, .end = 5, .line = 1, .col = 0 };
    const fail_result = automaton.step(0, fail_token, fail_source);
    try testing.expect(fail_result == null);
}

test "step: non-matching token returns null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const patterns = &[_]Pattern{.{
        .type_name = "function",
        .sequence = &.{.{ .matcher = .{ .keyword_literal = "fn" } }},
        .captures = &.{},
    }};

    const automaton = try compile(patterns, arena.allocator());
    const source = "let";
    const token = Token{ .kind = .keyword, .start = 0, .end = 3, .line = 1, .col = 0 };

    const result = automaton.step(0, token, source);
    try testing.expect(result == null);
}

test "step: capture returns value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const patterns = &[_]Pattern{.{
        .type_name = "function",
        .sequence = &.{
            .{ .matcher = .{ .keyword_literal = "fn" } },
            .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } },
        },
        .captures = &.{.{ .field_name = "name", .position = 1 }},
    }};

    const automaton = try compile(patterns, arena.allocator());
    const source = "fn add";

    // Step 1: match "fn"
    const r1 = automaton.step(0, .{ .kind = .keyword, .start = 0, .end = 2, .line = 1, .col = 0 }, source);
    try testing.expect(r1 != null);
    try testing.expect(r1.?.capture == null);

    // Step 2: match identifier "add" with capture
    const r2 = automaton.step(r1.?.next, .{ .kind = .identifier, .start = 3, .end = 6, .line = 1, .col = 3 }, source);
    try testing.expect(r2 != null);
    try testing.expect(r2.?.capture != null);
    try testing.expectEqualStrings("name", r2.?.capture.?.field_name);
    try testing.expectEqualStrings("add", r2.?.capture.?.value);
}

// --- Property Tests ---

const minish = @import("minish");
const gen = minish.gen;

// Feature: phase2-grammar-automaton, Property 4: Automaton structural invariants
test "property: automaton structural invariants" {
    // Generate random pattern length (1-4)
    const len_gen = gen.intRange(u8, 1, 4);

    try minish.check(testing.allocator, len_gen, struct {
        fn prop(pattern_len: u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // Build a pattern of the given length with alternating keyword/identifier
            var seq: std.ArrayList(loader.SequenceElement) = .empty;
            for (0..pattern_len) |i| {
                if (i % 2 == 0) {
                    try seq.append(alloc, .{ .matcher = .{ .keyword_literal = "kw" } });
                } else {
                    try seq.append(alloc, .{ .matcher = .{ .identifier = {} } });
                }
            }

            const patterns = &[_]Pattern{.{
                .type_name = "test",
                .sequence = seq.items,
                .captures = &.{},
            }};

            const automaton = try compile(patterns, alloc);

            // (a) Root has no event
            try testing.expect(automaton.states[0].event == null);

            // (b) No state has duplicate matchers
            for (automaton.states) |state| {
                for (state.transitions, 0..) |tr_a, i| {
                    for (state.transitions[i + 1 ..]) |tr_b| {
                        try testing.expect(!matchersEqual(tr_a.matcher, tr_b.matcher));
                    }
                }
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase2-grammar-automaton, Property 5: Pattern path correctness
test "property: pattern path correctness" {
    const len_gen = gen.intRange(u8, 1, 4);

    try minish.check(testing.allocator, len_gen, struct {
        fn prop(pattern_len: u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            var seq: std.ArrayList(loader.SequenceElement) = .empty;
            for (0..pattern_len) |_| {
                try seq.append(alloc, .{ .matcher = .{ .keyword_literal = "x" } });
            }

            const patterns = &[_]Pattern{.{
                .type_name = "test_type",
                .sequence = seq.items,
                .captures = &.{},
            }};

            const automaton = try compile(patterns, alloc);

            // Walk the path: should be exactly pattern_len transitions to terminal
            var state: usize = 0;
            for (0..pattern_len) |_| {
                try testing.expectEqual(@as(usize, 1), automaton.states[state].transitions.len);
                state = automaton.states[state].transitions[0].next_state;
            }
            // Terminal state
            try testing.expect(automaton.states[state].event != null);
            try testing.expectEqualStrings("test_type", automaton.states[state].event.?.type_name);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase2-grammar-automaton, Property 6: Prefix sharing
test "property: prefix sharing" {
    const prefix_gen = gen.intRange(u8, 1, 3);

    try minish.check(testing.allocator, prefix_gen, struct {
        fn prop(prefix_len: u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // Two patterns sharing a prefix of prefix_len keywords, then diverging
            var seq1: std.ArrayList(loader.SequenceElement) = .empty;
            var seq2: std.ArrayList(loader.SequenceElement) = .empty;
            for (0..prefix_len) |_| {
                try seq1.append(alloc, .{ .matcher = .{ .keyword_literal = "shared" } });
                try seq2.append(alloc, .{ .matcher = .{ .keyword_literal = "shared" } });
            }
            try seq1.append(alloc, .{ .matcher = .{ .symbol_literal = "(" } });
            try seq2.append(alloc, .{ .matcher = .{ .symbol_literal = "{" } });

            const patterns = &[_]Pattern{
                .{ .type_name = "a", .sequence = seq1.items, .captures = &.{} },
                .{ .type_name = "b", .sequence = seq2.items, .captures = &.{} },
            };

            const automaton = try compile(patterns, alloc);

            // Walk shared prefix: each state should have exactly 1 transition
            var state: usize = 0;
            for (0..prefix_len) |_| {
                try testing.expectEqual(@as(usize, 1), automaton.states[state].transitions.len);
                state = automaton.states[state].transitions[0].next_state;
            }
            // Divergence point: should have 2 transitions
            try testing.expectEqual(@as(usize, 2), automaton.states[state].transitions.len);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: probabilistic-confidence-scoring, Property 1: matchesTransition correctness
// **Validates: Requirements 1.1, 1.2, 1.3, 1.4**
test "property: matchesTransition correctness for keyword_literal" {
    const text_gen = gen.string(.{ .min_len = 1, .max_len = 12, .charset = .alpha });

    try minish.check(testing.allocator, text_gen, struct {
        fn prop(keyword_text: []const u8) !void {
            const matcher: TokenMatcher = .{ .keyword_literal = keyword_text };

            // Case 1: kind=.keyword, text matches → full_match
            try testing.expectEqual(MatchResult.full_match, matchesTransition(matcher, .keyword, keyword_text));

            // Case 2: kind=.identifier, text matches → relaxed_match
            try testing.expectEqual(MatchResult.relaxed_match, matchesTransition(matcher, .identifier, keyword_text));

            // Case 3: kind=.identifier, text does NOT match → no_match
            try testing.expectEqual(MatchResult.no_match, matchesTransition(matcher, .identifier, "ZZZZZ_NOMATCH"));

            // Case 4: other kinds → no_match
            try testing.expectEqual(MatchResult.no_match, matchesTransition(matcher, .delimiter, keyword_text));
            try testing.expectEqual(MatchResult.no_match, matchesTransition(matcher, .symbol, keyword_text));
            try testing.expectEqual(MatchResult.no_match, matchesTransition(matcher, .string, keyword_text));
            try testing.expectEqual(MatchResult.no_match, matchesTransition(matcher, .number, keyword_text));
            try testing.expectEqual(MatchResult.no_match, matchesTransition(matcher, .operator, keyword_text));
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: probabilistic-confidence-scoring: step returns match_quality
test "step: keyword match returns full_match quality" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const patterns = &[_]Pattern{.{
        .type_name = "function",
        .sequence = &.{.{ .matcher = .{ .keyword_literal = "fn" } }},
        .captures = &.{},
    }};

    const automaton = try compile(patterns, arena.allocator());
    const source = "fn";
    const token = Token{ .kind = .keyword, .start = 0, .end = 2, .line = 1, .col = 0 };

    const result = automaton.step(0, token, source);
    try testing.expect(result != null);
    try testing.expectEqual(MatchResult.full_match, result.?.match_quality);
}

test "step: identifier matching keyword_literal returns relaxed_match quality" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const patterns = &[_]Pattern{.{
        .type_name = "function",
        .sequence = &.{.{ .matcher = .{ .keyword_literal = "fn" } }},
        .captures = &.{},
    }};

    const automaton = try compile(patterns, arena.allocator());
    const source = "fn";
    // Token kind is .identifier but text matches "fn"
    const token = Token{ .kind = .identifier, .start = 0, .end = 2, .line = 1, .col = 0 };

    const result = automaton.step(0, token, source);
    try testing.expect(result != null);
    try testing.expectEqual(MatchResult.relaxed_match, result.?.match_quality);
}

test "step: non-keyword non-identifier token does not match keyword_literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const patterns = &[_]Pattern{.{
        .type_name = "function",
        .sequence = &.{.{ .matcher = .{ .keyword_literal = "fn" } }},
        .captures = &.{},
    }};

    const automaton = try compile(patterns, arena.allocator());
    const source = "fn";
    // Token kind is .delimiter — should not match keyword_literal
    const token = Token{ .kind = .delimiter, .start = 0, .end = 2, .line = 1, .col = 0 };

    const result = automaton.step(0, token, source);
    try testing.expect(result == null);
}
