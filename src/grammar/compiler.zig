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
    pattern_index: usize,
};

pub const State = struct {
    transitions: []const Transition,
    events: []const EventInfo = &.{},
};

pub const CaptureValue = struct {
    field_name: []const u8,
    value: []const u8,
    separator: ?[]const u8 = null,
    suffix_set: ?[]const u8 = null,
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
                    .{
                        .field_name = c.field_name,
                        .value = text,
                        .separator = c.separator,
                        .suffix_set = c.suffix_set,
                    }
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
        .symbol_literal => |sym| if ((kind == .delimiter or kind == .symbol or kind == .operator) and std.mem.eql(u8, text, sym)) .full_match else .no_match,
        .identifier => if (kind == .identifier) .full_match else .no_match,
        .capture => if (kind == .identifier) .full_match else .no_match,
        .identifier_literal => |id| if (kind == .identifier and std.mem.eql(u8, text, id)) .full_match else .no_match,
        .number => if (kind == .number) .full_match else .no_match,
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
    events: std.ArrayList(EventInfo),

    fn init() MutableState {
        return .{ .transitions = .empty, .events = .empty };
    }
};

/// Compiles a list of patterns into a deterministic prefix trie automaton.
/// Reuses shared prefix states across patterns.
pub fn compile(patterns: []const Pattern, allocator: std.mem.Allocator) !Automaton {
    var builder: std.ArrayList(MutableState) = .empty;

    // State 0 = root (no event)
    try builder.append(allocator, MutableState.init());

    for (patterns, 0..) |pattern, pattern_index| {
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
        try builder.items[current].events.append(allocator, .{
            .type_name = pattern.type_name,
            .capture_fields = try cap_fields.toOwnedSlice(allocator),
            .pattern_index = pattern_index,
        });
    }

    // Freeze mutable states into const slices
    var states: std.ArrayList(State) = .empty;
    for (builder.items) |*ms| {
        try states.append(allocator, .{
            .transitions = try freezeTransitions(ms.transitions.items, allocator),
            .events = try ms.events.toOwnedSlice(allocator),
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
        .number => 5,
    };
    const tag_b: u3 = switch (b) {
        .keyword_literal => 0,
        .symbol_literal => 1,
        .identifier => 2,
        .capture => 3,
        .identifier_literal => 4,
        .number => 5,
    };
    if (tag_a != tag_b) return false;

    return switch (a) {
        .keyword_literal => |ka| std.mem.eql(u8, ka, b.keyword_literal),
        .symbol_literal => |sa| std.mem.eql(u8, sa, b.symbol_literal),
        .identifier => true,
        .capture => true, // captures match any identifier, same as identifier
        .identifier_literal => |ia| std.mem.eql(u8, ia, b.identifier_literal),
        .number => true,
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
    try testing.expectEqual(@as(usize, 0), automaton.states[0].events.len);
    // Terminal state has event
    try testing.expectEqual(@as(usize, 1), automaton.states[3].events.len);
    try testing.expectEqualStrings("function", automaton.states[3].events[0].type_name);
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
    try testing.expectEqual(@as(usize, 0), automaton.states[0].events.len);
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
            try testing.expectEqual(@as(usize, 0), automaton.states[0].events.len);

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
            try testing.expectEqual(@as(usize, 1), automaton.states[state].events.len);
            try testing.expectEqualStrings("test_type", automaton.states[state].events[0].type_name);
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

// Feature: identical-sequence-pattern-shadowing, Property 2: Preservation - Non-colliding grammars have one event per terminal
// **Validates: Requirements 3.1, 3.5**
test "preservation: non-colliding grammars terminal state carries one event and root zero" {
    const prefix_gen = gen.intRange(u8, 1, 3);

    try minish.check(testing.allocator, prefix_gen, struct {
        fn prop(prefix_len: u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // Two patterns sharing a prefix of prefix_len keywords, then diverging to distinct terminals
            var seq1: std.ArrayList(loader.SequenceElement) = .empty;
            var seq2: std.ArrayList(loader.SequenceElement) = .empty;
            for (0..prefix_len) |_| {
                try seq1.append(alloc, .{ .matcher = .{ .keyword_literal = "shared" } });
                try seq2.append(alloc, .{ .matcher = .{ .keyword_literal = "shared" } });
            }
            try seq1.append(alloc, .{ .matcher = .{ .symbol_literal = "(" } });
            try seq2.append(alloc, .{ .matcher = .{ .symbol_literal = "{" } });

            const patterns = &[_]Pattern{
                .{ .type_name = "pattern_a", .sequence = seq1.items, .captures = &.{} },
                .{ .type_name = "pattern_b", .sequence = seq2.items, .captures = &.{} },
            };

            const automaton = try compile(patterns, alloc);

            // Root has no event
            try testing.expectEqual(@as(usize, 0), automaton.states[0].events.len);

            // Walk to terminal a
            var state_a: usize = 0;
            for (seq1.items) |elem| {
                const step_res = automaton.step(state_a, .{ .kind = if (elem.matcher == .symbol_literal) .delimiter else .keyword, .start = 0, .end = if (elem.matcher == .symbol_literal) 1 else 6, .line = 1, .col = 0 }, if (elem.matcher == .symbol_literal) "(" else "shared");
                try testing.expect(step_res != null);
                state_a = step_res.?.next;
            }
            try testing.expectEqual(@as(usize, 1), automaton.states[state_a].events.len);
            try testing.expectEqualStrings("pattern_a", automaton.states[state_a].events[0].type_name);

            // Walk to terminal b
            var state_b: usize = 0;
            for (seq2.items) |elem| {
                const step_res = automaton.step(state_b, .{ .kind = if (elem.matcher == .symbol_literal) .delimiter else .keyword, .start = 0, .end = if (elem.matcher == .symbol_literal) 1 else 6, .line = 1, .col = 0 }, if (elem.matcher == .symbol_literal) "{" else "shared");
                try testing.expect(step_res != null);
                state_b = step_res.?.next;
            }
            try testing.expectEqual(@as(usize, 1), automaton.states[state_b].events.len);
            try testing.expectEqualStrings("pattern_b", automaton.states[state_b].events[0].type_name);
            try testing.expect(state_a != state_b);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: identical-sequence-pattern-shadowing, Property 1: Identical-sequence patterns retain all events in grammar order
// **Validates: Requirements 2.1, 3.5**
test "property: identical-sequence patterns retain all events on shared terminal" {
    const tuple_gen = comptime gen.tuple3(
        u8,
        []const u8,
        []const u8,
        gen.intRange(u8, 1, 4),
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { u8, []const u8, []const u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const seq_len = vals[0];
            const type_a = vals[1];
            const type_b = vals[2];

            // Build identical sequence for both patterns
            var seq: std.ArrayList(loader.SequenceElement) = .empty;
            for (0..seq_len) |_| {
                try seq.append(alloc, .{ .matcher = .{ .keyword_literal = "kw" } });
            }

            const patterns = &[_]Pattern{
                .{ .type_name = type_a, .sequence = seq.items, .captures = &.{} },
                .{ .type_name = type_b, .sequence = seq.items, .captures = &.{} },
            };

            const automaton = try compile(patterns, alloc);

            // Root has 0 events
            try testing.expectEqual(@as(usize, 0), automaton.states[0].events.len);

            // Walk to terminal
            var state: usize = 0;
            for (0..seq_len) |_| {
                try testing.expectEqual(@as(usize, 1), automaton.states[state].transitions.len);
                state = automaton.states[state].transitions[0].next_state;
            }

            // Shared terminal state must retain both events in grammar order
            const term = automaton.states[state];
            try testing.expectEqual(@as(usize, 2), term.events.len);
            try testing.expectEqualStrings(type_a, term.events[0].type_name);
            try testing.expectEqual(@as(usize, 0), term.events[0].pattern_index);
            try testing.expectEqualStrings(type_b, term.events[1].type_name);
            try testing.expectEqual(@as(usize, 1), term.events[1].pattern_index);

            // Structural invariants: no state has duplicate transitions, root has 0 events
            for (automaton.states) |st| {
                for (st.transitions, 0..) |tr_a, i| {
                    for (st.transitions[i + 1 ..]) |tr_b| {
                        try testing.expect(!matchersEqual(tr_a.matcher, tr_b.matcher));
                    }
                }
            }
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

test "compile: two identical-sequence patterns produce shared terminal state with multiple events in grammar order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]Pattern{
        .{
            .type_name = "function",
            .sequence = &.{
                .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 0 } } },
                .{ .matcher = .{ .symbol_literal = "(" } },
            },
            .captures = &.{.{ .field_name = "name", .position = 0 }},
        },
        .{
            .type_name = "call",
            .sequence = &.{
                .{ .matcher = .{ .capture = .{ .field_name = "callee", .position = 0 } } },
                .{ .matcher = .{ .symbol_literal = "(" } },
            },
            .captures = &.{.{ .field_name = "callee", .position = 0 }},
        },
    };

    const automaton = try compile(patterns, alloc);

    // Root state 0 has 0 events
    try testing.expectEqual(@as(usize, 0), automaton.states[0].events.len);

    // Terminal state should have 2 events in grammar order
    try testing.expectEqual(@as(usize, 1), automaton.states[0].transitions.len);
    const state_1 = automaton.states[0].transitions[0].next_state;
    try testing.expectEqual(@as(usize, 1), automaton.states[state_1].transitions.len);
    const terminal_state = automaton.states[state_1].transitions[0].next_state;

    const term = automaton.states[terminal_state];
    try testing.expectEqual(@as(usize, 2), term.events.len);

    // Event 0: function
    try testing.expectEqualStrings("function", term.events[0].type_name);
    try testing.expectEqual(@as(usize, 0), term.events[0].pattern_index);
    try testing.expectEqual(@as(usize, 1), term.events[0].capture_fields.len);
    try testing.expectEqualStrings("name", term.events[0].capture_fields[0]);

    // Event 1: call
    try testing.expectEqualStrings("call", term.events[1].type_name);
    try testing.expectEqual(@as(usize, 1), term.events[1].pattern_index);
    try testing.expectEqual(@as(usize, 1), term.events[1].capture_fields.len);
    try testing.expectEqualStrings("callee", term.events[1].capture_fields[0]);
}

test "compile: single pattern terminal carries exactly one event and root zero" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]Pattern{.{
        .type_name = "function",
        .sequence = &.{
            .{ .matcher = .{ .keyword_literal = "fn" } },
        },
        .captures = &.{},
    }};

    const automaton = try compile(patterns, alloc);
    try testing.expectEqual(@as(usize, 0), automaton.states[0].events.len);
    try testing.expectEqual(@as(usize, 1), automaton.states[1].events.len);
    try testing.expectEqualStrings("function", automaton.states[1].events[0].type_name);
    try testing.expectEqual(@as(usize, 0), automaton.states[1].events[0].pattern_index);
}

test "compile: shared-prefix patterns create distinct terminals each with one event" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]Pattern{
        .{
            .type_name = "func",
            .sequence = &.{
                .{ .matcher = .{ .keyword_literal = "fn" } },
                .{ .matcher = .{ .symbol_literal = "(" } },
            },
            .captures = &.{},
        },
        .{
            .type_name = "block",
            .sequence = &.{
                .{ .matcher = .{ .keyword_literal = "fn" } },
                .{ .matcher = .{ .symbol_literal = "{" } },
            },
            .captures = &.{},
        },
    };

    const automaton = try compile(patterns, alloc);
    // Root state
    try testing.expectEqual(@as(usize, 0), automaton.states[0].events.len);

    // State 1 is shared "fn"
    const fn_state = automaton.states[0].transitions[0].next_state;
    try testing.expectEqual(@as(usize, 0), automaton.states[fn_state].events.len);
    try testing.expectEqual(@as(usize, 2), automaton.states[fn_state].transitions.len);

    const term_a = automaton.states[fn_state].transitions[0].next_state;
    const term_b = automaton.states[fn_state].transitions[1].next_state;
    try testing.expect(term_a != term_b);

    try testing.expectEqual(@as(usize, 1), automaton.states[term_a].events.len);
    try testing.expectEqual(@as(usize, 1), automaton.states[term_b].events.len);
}

// Feature: same-type-pattern-union, Unit: identical-sequence same-type alternatives land
// on one terminal with both events in grammar order (Requirement 8.1, 8.2).
test "compile: identical-sequence same-type alternatives land on one terminal in grammar order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]Pattern{
        .{
            .type_name = "same",
            .sequence = &.{
                .{ .matcher = .{ .capture = .{ .field_name = "a", .position = 0 } } },
            },
            .captures = &.{.{ .field_name = "a", .position = 0 }},
        },
        .{
            .type_name = "same",
            .sequence = &.{
                .{ .matcher = .{ .capture = .{ .field_name = "b", .position = 0 } } },
            },
            .captures = &.{.{ .field_name = "b", .position = 0 }},
        },
    };

    const automaton = try compile(patterns, alloc);
    const term = automaton.states[1];
    try testing.expectEqual(@as(usize, 2), term.events.len);
    try testing.expectEqualStrings("same", term.events[0].type_name);
    try testing.expectEqual(@as(usize, 0), term.events[0].pattern_index);
    try testing.expectEqualStrings("a", term.events[0].capture_fields[0]);
    try testing.expectEqualStrings("same", term.events[1].type_name);
    try testing.expectEqual(@as(usize, 1), term.events[1].pattern_index);
    try testing.expectEqualStrings("b", term.events[1].capture_fields[0]);
}

// Feature: operator-token-matching, Unit: matchesTransition punctuation matching
// **Validates: Requirements 1.1, 1.2, 1.3, 1.4, 2.1, 2.2, 2.3, 7.2, 8.1, 8.2, 8.3**
test "matchesTransition: operator tokens full-match equal-text punctuation literal" {
    try testing.expect(matchesTransition(.{ .symbol_literal = "-" }, .operator, "-") == .full_match);
    try testing.expect(matchesTransition(.{ .symbol_literal = "-" }, .operator, "+") == .no_match);
    try testing.expect(matchesTransition(.{ .symbol_literal = "&" }, .operator, "&") == .full_match);
    try testing.expect(matchesTransition(.{ .symbol_literal = "?" }, .operator, "?") == .full_match);
}

test "matchesTransition: punctuation literals reject non-punctuation tokens" {
    try testing.expect(matchesTransition(.{ .symbol_literal = "-" }, .identifier, "-") == .no_match);
    try testing.expect(matchesTransition(.{ .symbol_literal = "-" }, .keyword, "-") == .no_match);
    try testing.expect(matchesTransition(.{ .symbol_literal = "-" }, .string, "-") == .no_match);
    try testing.expect(matchesTransition(.{ .symbol_literal = "-" }, .number, "-") == .no_match);
    try testing.expect(matchesTransition(.{ .symbol_literal = "-" }, .newline, "-") == .no_match);
    try testing.expect(matchesTransition(.{ .symbol_literal = "-" }, .indent, "-") == .no_match);
    try testing.expect(matchesTransition(.{ .symbol_literal = "-" }, .comment, "-") == .no_match);
}

test "matchesTransition: symbol and delimiter matching preserved" {
    try testing.expect(matchesTransition(.{ .symbol_literal = "(" }, .delimiter, "(") == .full_match);
    try testing.expect(matchesTransition(.{ .symbol_literal = ":" }, .symbol, ":") == .full_match);
    try testing.expect(matchesTransition(.{ .symbol_literal = "(" }, .delimiter, ")") == .no_match);
    try testing.expect(matchesTransition(.{ .symbol_literal = ":" }, .symbol, ";") == .no_match);
}

// Feature: operator-token-matching, Property 1: Operator tokens full-match an equal-text
// punctuation literal
// **Validates: Requirements 1.1, 1.2**
test "property: operator tokens full-match an equal-text punctuation literal" {
    const ops = "+-*/=<>!&|^%~";
    const idx_gen = gen.intRange(u8, 0, ops.len - 1);

    try minish.check(testing.allocator, idx_gen, struct {
        fn prop(idx: u8) !void {
            const c = ops[idx];
            const m: TokenMatcher = .{ .symbol_literal = &[1]u8{c} };
            try testing.expect(matchesTransition(m, .operator, &[1]u8{c}) == .full_match);
            // Different operator text → no match, never relaxed.
            const other = ops[(idx + 1) % ops.len];
            try testing.expect(matchesTransition(m, .operator, &[1]u8{other}) == .no_match);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: operator-token-matching, Property 2: Symbol and delimiter matching is preserved
// **Validates: Requirements 1.3, 1.4, 7.2**
test "property: symbol and delimiter matching is preserved" {
    const syms = ",;:.@?";
    const delims = "(){}[]";
    const idx_gen = gen.intRange(u8, 0, syms.len + delims.len - 1);

    try minish.check(testing.allocator, idx_gen, struct {
        fn prop(idx: u8) !void {
            const c = if (idx < syms.len) syms[idx] else delims[idx - syms.len];
            const kind: TokenKind = if (idx < syms.len) .symbol else .delimiter;
            const m: TokenMatcher = .{ .symbol_literal = &[1]u8{c} };
            try testing.expect(matchesTransition(m, kind, &[1]u8{c}) == .full_match);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: operator-token-matching, Property 3: Punctuation literals reject non-punctuation tokens
// **Validates: Requirements 2.1, 2.2, 2.3, 8.1, 8.2**
test "property: punctuation literals reject non-punctuation tokens" {
    const punct = "(){}[],;:.@?+-*/=<>!&|^%~";
    const kinds = [_]TokenKind{ .identifier, .keyword, .string, .number, .newline, .indent, .comment };
    const tuple_gen = comptime gen.tuple2(
        u8,
        u8,
        gen.intRange(u8, 0, punct.len - 1),
        gen.intRange(u8, 0, kinds.len - 1),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { u8, u8 }) !void {
            const c = punct[vals[0]];
            const kind = kinds[vals[1]];
            const m: TokenMatcher = .{ .symbol_literal = &[1]u8{c} };
            // Even when the token text equals the literal, non-punctuation kinds reject.
            try testing.expect(matchesTransition(m, kind, &[1]u8{c}) == .no_match);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: operator-token-matching, Property 6: Punctuation matching is single-token and exact
// **Validates: Requirements 3.1, 3.2, 8.3**
test "property: punctuation matching is single-token and exact" {
    const punct = "(){}[],;:.@?+-*/=<>!&|^%~";
    const all_kinds = [_]TokenKind{ .identifier, .keyword, .symbol, .string, .number, .operator, .newline, .indent, .comment, .delimiter };
    const tuple_gen = comptime gen.tuple2(
        u8,
        u8,
        gen.intRange(u8, 0, punct.len - 1),
        gen.intRange(u8, 0, all_kinds.len - 1),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { u8, u8 }) !void {
            const c = punct[vals[0]];
            const kind = all_kinds[vals[1]];
            const m: TokenMatcher = .{ .symbol_literal = &[1]u8{c} };
            const is_punct_kind = kind == .operator or kind == .symbol or kind == .delimiter;
            const expected: MatchResult = if (is_punct_kind) .full_match else .no_match;
            try testing.expect(matchesTransition(m, kind, &[1]u8{c}) == expected);
            try testing.expect(matchesTransition(m, kind, "x") == .no_match);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: number-token-primitive, Unit: compiler match and equality
// **Validates: Requirements 4.1, 4.2, 5.1, 5.2**
test "matchesTransition: number matcher matches numeric tokens only" {
    try testing.expect(matchesTransition(.{ .number = {} }, .number, "42") == .full_match);
    try testing.expect(matchesTransition(.{ .number = {} }, .number, "x") == .full_match); // kind wildcard, text ignored
    try testing.expect(matchesTransition(.{ .number = {} }, .identifier, "42") == .no_match);
    try testing.expect(matchesTransition(.{ .number = {} }, .keyword, "42") == .no_match);
    try testing.expect(matchesTransition(.{ .number = {} }, .symbol, "42") == .no_match);
    try testing.expect(matchesTransition(.{ .number = {} }, .delimiter, "42") == .no_match);
    try testing.expect(matchesTransition(.{ .number = {} }, .operator, "42") == .no_match);
    try testing.expect(matchesTransition(.{ .number = {} }, .string, "42") == .no_match);
}

test "matchersEqual: number matchers equal each other, never other variants" {
    try testing.expect(matchersEqual(.{ .number = {} }, .{ .number = {} }));
    const variants = [_]TokenMatcher{
        .{ .keyword_literal = "fn" },
        .{ .symbol_literal = "(" },
        .{ .identifier = {} },
        .{ .capture = .{ .field_name = "n", .position = 0 } },
        .{ .identifier_literal = "Config" },
    };
    for (variants) |v| {
        try testing.expect(!matchersEqual(v, .{ .number = {} }));
        try testing.expect(!matchersEqual(.{ .number = {} }, v));
    }
}

test "automaton step: number matcher advances one token with no capture" {
    const auto = Automaton{ .states = &.{
        .{ .transitions = &.{.{
            .matcher = .{ .number = {} },
            .next_state = 1,
        }}, .events = &.{} },
        .{ .transitions = &.{}, .events = &.{} },
    } };
    const res = auto.step(0, .{ .kind = .number, .start = 0, .end = 2, .line = 1, .col = 0 }, "42");
    try testing.expect(res != null);
    try testing.expectEqual(@as(usize, 1), res.?.next);
    try testing.expect(res.?.capture == null);
    const no = auto.step(0, .{ .kind = .identifier, .start = 0, .end = 2, .line = 1, .col = 0 }, "42");
    try testing.expect(no == null);
}

// Feature: number-token-primitive, Property 3: the number matcher matches numeric tokens
// only, by kind, without capture
// **Validates: Requirements 4.1, 4.2, 4.3, 4.4**
test "property: number matcher matches numeric tokens only, by kind, without capture" {
    const kinds = [_]TokenKind{ .identifier, .keyword, .symbol, .string, .number, .operator, .newline, .indent, .comment, .delimiter };
    const tuple_gen = comptime gen.tuple2(
        u8,
        []const u8,
        gen.intRange(u8, 0, kinds.len - 1),
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alphanumeric }),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { u8, []const u8 }) !void {
            const kind = kinds[vals[0]];
            const m: TokenMatcher = .{ .number = {} };
            const expected: MatchResult = if (kind == .number) .full_match else .no_match;
            try testing.expect(matchesTransition(m, kind, vals[1]) == expected);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: number-token-primitive, Property 4: number-matcher equality
// **Validates: Requirements 5.1, 5.2**
test "property: number-matcher equality" {
    const samples = [_]TokenMatcher{
        .{ .keyword_literal = "fn" },
        .{ .symbol_literal = "(" },
        .{ .identifier = {} },
        .{ .capture = .{ .field_name = "n", .position = 0 } },
        .{ .identifier_literal = "Config" },
        .{ .number = {} },
    };
    const tuple_gen = comptime gen.tuple2(
        u8,
        u8,
        gen.intRange(u8, 0, samples.len - 1),
        gen.intRange(u8, 0, samples.len - 1),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { u8, u8 }) !void {
            const a = samples[vals[0]];
            const b = samples[vals[1]];
            const expected = vals[0] == vals[1];
            try testing.expectEqual(expected, matchersEqual(a, b));
            const a_is_number = a == .number;
            const b_is_number = b == .number;
            if (a_is_number != b_is_number) {
                try testing.expect(!matchersEqual(a, b));
            }
            if (a_is_number and b_is_number) {
                try testing.expect(matchersEqual(a, b));
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: multi-token-captures, Unit: compiled transition retains sep/suffix
// **Validates: Requirements 2.1**
test "compile: parameterized capture transition carries sep/suffix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]Pattern{.{
        .type_name = "t",
        .sequence = &.{
            .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 0, .separator = ".", .suffix_set = "!?" } } },
        },
        .captures = &.{.{ .field_name = "name", .position = 0, .separator = ".", .suffix_set = "!?" }},
    }};
    const automaton = try compile(patterns, alloc);
    const cap = automaton.states[0].transitions[0].capture.?;
    try testing.expectEqualStrings("name", cap.field_name);
    try testing.expectEqualStrings(".", cap.separator.?);
    try testing.expectEqualStrings("!?", cap.suffix_set.?);
}

test "automaton step: surfaces capture metadata on the transition" {
    const auto = Automaton{ .states = &.{
        .{ .transitions = &.{.{
            .matcher = .{ .capture = .{ .field_name = "name", .position = 0, .separator = ".", .suffix_set = null } },
            .next_state = 1,
            .capture = .{ .field_name = "name", .position = 0, .separator = ".", .suffix_set = null },
        }}, .events = &.{} },
        .{ .transitions = &.{}, .events = &.{} },
    } };
    const res = auto.step(0, .{ .kind = .identifier, .start = 0, .end = 1, .line = 1, .col = 0 }, "A");
    try testing.expect(res != null);
    try testing.expectEqualStrings("A", res.?.capture.?.value);
    try testing.expectEqualStrings(".", res.?.capture.?.separator.?);
    try testing.expect(res.?.capture.?.suffix_set == null);
}
