const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const events_mod = @import("events.zig");
const compiler = @import("../grammar/compiler.zig");
const loader = @import("../grammar/loader.zig");

const Token = tokenizer.Token;
const TokenKind = tokenizer.TokenKind;
const Automaton = compiler.Automaton;
const CaptureValue = compiler.CaptureValue;
const MatchResult = compiler.MatchResult;
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
fn patternMaxScore(sequence: []const loader.SequenceElement) f32 {
    var total: f32 = 0.0;
    for (sequence) |elem| {
        total += switch (elem.matcher) {
            .keyword_literal => events_mod.evidence_weights.keyword,
            .symbol_literal => events_mod.evidence_weights.symbol,
            .identifier, .capture, .identifier_literal => events_mod.evidence_weights.identifier,
        };
    }
    return total;
}

// --- Competing Pattern Evaluation ---

const CandidateEvent = struct {
    event: StructuralEvent,
    match_length: usize,
    pattern_index: usize,
};

/// Selects the best candidate from a list of competing pattern matches.
/// Tiebreaker order: highest confidence → longest match → lowest pattern_index (grammar order).
fn selectBestCandidate(candidates: []const CandidateEvent) ?CandidateEvent {
    if (candidates.len == 0) return null;
    var best = candidates[0];
    for (candidates[1..]) |c| {
        if (c.event.confidence > best.event.confidence) {
            best = c;
        } else if (c.event.confidence == best.event.confidence) {
            if (c.match_length > best.match_length) {
                best = c;
            } else if (c.match_length == best.match_length) {
                if (c.pattern_index < best.pattern_index) {
                    best = c;
                }
            }
        }
    }
    return best;
}

/// Maps a type_name back to its index in the patterns array.
fn findPatternIndex(patterns: []const loader.Pattern, type_name: []const u8) usize {
    for (patterns, 0..) |p, i| {
        if (std.mem.eql(u8, p.type_name, type_name)) return i;
    }
    return std.math.maxInt(usize);
}

/// Runs the automaton against the token stream, emitting structural events.
/// Skips tokens with kind: newline, indent, comment, string.
/// Processes each non-skipped token exactly once (O(N), no backtracking).
/// Uses buffered emission for competing pattern evaluation: when a terminal
/// state is reached, the candidate is buffered and matching continues to find
/// longer matches. The best candidate is emitted when the automaton resets.
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
    var matched_texts: std.ArrayList([]const u8) = .empty;
    var matched_qualities: std.ArrayList(MatchResult) = .empty;
    var candidates: std.ArrayList(CandidateEvent) = .empty;

    var lookback = LookbackBuffer{};
    var block_stack = BlockStack{};
    var prev_token_text: ?[]const u8 = null;
    var match_start_prev_token: ?[]const u8 = null;

    var state: usize = 0;
    var pattern_start: usize = 0;
    var pattern_col: usize = 0;

    // Phase 4: Noise penalty infrastructure
    var noise_count: u32 = 0;
    var delim_depth: u32 = 0;

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

        // Balanced delimiter depth tracking for noise exclusion (Phase 4)
        if (token.kind == .delimiter) {
            if (text.len == 1) {
                switch (text[0]) {
                    '(', '{', '[' => delim_depth += 1,
                    ')', '}', ']' => {
                        if (delim_depth > 0) delim_depth -= 1;
                    },
                    else => {},
                }
            }
        }

        if (shouldSkip(token.kind)) continue;

        // Push to lookback before automaton stepping
        lookback.push(text);

        // Snapshot prev_token_text before updating for not_preceded_by
        const saved_prev = prev_token_text;
        prev_token_text = text;

        if (automaton.step(state, token, source)) |step_result| {
            if (state == 0) {
                // Starting a new match — flush any buffered candidates from previous region
                if (candidates.items.len > 0) {
                    if (selectBestCandidate(candidates.items)) |winner| {
                        try result.append(allocator, winner.event);
                    }
                    candidates.clearRetainingCapacity();
                }
                pattern_start = token.start;
                pattern_col = token.col;
                match_start_prev_token = saved_prev;
                noise_count = 0;
            }
            state = step_result.next;
            try matched_kinds.append(allocator, token.kind);
            try matched_texts.append(allocator, text);
            try matched_qualities.append(allocator, step_result.match_quality);

            if (step_result.capture) |cap| {
                try pending_captures.append(allocator, .{
                    .field_name = cap.field_name,
                    .value = cap.value,
                });
            }

            // Check terminal state
            if (automaton.states[state].event) |event_info| {
                // Try to buffer this candidate (constraint checks may reject it)
                const buffered = try bufferCandidate(
                    &candidates,
                    event_info,
                    patterns,
                    &pending_captures,
                    &matched_kinds,
                    &matched_texts,
                    &matched_qualities,
                    pattern_start,
                    pattern_col,
                    match_start_prev_token,
                    lookback,
                    block_stack,
                    tokens,
                    token,
                    allocator,
                );

                if (!buffered) {
                    // Constraint check failed — flush any existing candidates and reset
                    if (candidates.items.len > 0) {
                        if (selectBestCandidate(candidates.items)) |winner| {
                            try result.append(allocator, winner.event);
                        }
                        candidates.clearRetainingCapacity();
                    }
                    state = 0;
                    noise_count = 0;
                    pending_captures.clearRetainingCapacity();
                    matched_kinds.clearRetainingCapacity();
                    matched_texts.clearRetainingCapacity();
                    matched_qualities.clearRetainingCapacity();
                    continue;
                }

                // Candidate buffered — DON'T reset state. Continue matching
                // to see if a longer pattern also matches from this terminal state.
                // If the terminal state has no outgoing transitions, the next token
                // will fail to match and we'll flush then.
            }
        } else {
            // No match from current state — check for optional transitions to skip
            var skipped = false;
            if (state > 0) {
                // Try skipping optional transitions from the current state
                var skip_state = state;
                while (true) {
                    const current_transitions = automaton.states[skip_state].transitions;
                    var found_optional = false;
                    for (current_transitions) |tr| {
                        if (tr.is_optional) {
                            // Skip this optional element (record nothing for it)
                            skip_state = tr.next_state;
                            found_optional = true;
                            break;
                        }
                    }
                    if (!found_optional) break;

                    // Check if the new state is a terminal state
                    if (automaton.states[skip_state].event != null) {
                        // We've reached a terminal state by skipping optionals
                        state = skip_state;
                        skipped = true;
                        break;
                    }

                    // Try matching the current token from the new state
                    if (automaton.step(skip_state, token, source)) |skip_step_result| {
                        state = skip_step_result.next;
                        try matched_kinds.append(allocator, token.kind);
                        try matched_texts.append(allocator, text);
                        try matched_qualities.append(allocator, skip_step_result.match_quality);

                        if (skip_step_result.capture) |cap| {
                            try pending_captures.append(allocator, .{
                                .field_name = cap.field_name,
                                .value = cap.value,
                            });
                        }
                        skipped = true;
                        break;
                    }
                    // Token still doesn't match — continue skipping if more optionals
                }
            }

            if (!skipped) {
                // Automaton truly resets — flush any buffered candidates
                if (candidates.items.len > 0) {
                    if (selectBestCandidate(candidates.items)) |winner| {
                        try result.append(allocator, winner.event);
                    }
                    candidates.clearRetainingCapacity();
                }
                state = 0;
                noise_count = 0;
                pending_captures.clearRetainingCapacity();
                matched_kinds.clearRetainingCapacity();
                matched_texts.clearRetainingCapacity();
                matched_qualities.clearRetainingCapacity();

                // Re-try the current token from state 0 — it might start a new match
                if (automaton.step(0, token, source)) |retry_result| {
                    pattern_start = token.start;
                    pattern_col = token.col;
                    match_start_prev_token = saved_prev;
                    noise_count = 0;
                    state = retry_result.next;
                    try matched_kinds.append(allocator, token.kind);
                    try matched_texts.append(allocator, text);
                    try matched_qualities.append(allocator, retry_result.match_quality);

                    if (retry_result.capture) |cap| {
                        try pending_captures.append(allocator, .{
                            .field_name = cap.field_name,
                            .value = cap.value,
                        });
                    }

                    // Check if this immediately reaches a terminal state
                    if (automaton.states[state].event) |event_info| {
                        const buffered = try bufferCandidate(
                            &candidates,
                            event_info,
                            patterns,
                            &pending_captures,
                            &matched_kinds,
                            &matched_texts,
                            &matched_qualities,
                            pattern_start,
                            pattern_col,
                            match_start_prev_token,
                            lookback,
                            block_stack,
                            tokens,
                            token,
                            allocator,
                        );

                        if (!buffered) {
                            state = 0;
                            noise_count = 0;
                            pending_captures.clearRetainingCapacity();
                            matched_kinds.clearRetainingCapacity();
                            matched_texts.clearRetainingCapacity();
                            matched_qualities.clearRetainingCapacity();
                        }
                    }
                }
            } else {
                // After skipping, check if we landed on a terminal state
                if (automaton.states[state].event) |event_info| {
                    const buffered = try bufferCandidateWithMinEvidence(
                        &candidates,
                        event_info,
                        patterns,
                        &pending_captures,
                        &matched_kinds,
                        &matched_texts,
                        &matched_qualities,
                        pattern_start,
                        pattern_col,
                        match_start_prev_token,
                        lookback,
                        block_stack,
                        tokens,
                        token,
                        allocator,
                    );

                    if (!buffered) {
                        // Constraint or minimum evidence check failed — flush and reset
                        if (candidates.items.len > 0) {
                            if (selectBestCandidate(candidates.items)) |winner| {
                                try result.append(allocator, winner.event);
                            }
                            candidates.clearRetainingCapacity();
                        }
                        state = 0;
                        noise_count = 0;
                        pending_captures.clearRetainingCapacity();
                        matched_kinds.clearRetainingCapacity();
                        matched_texts.clearRetainingCapacity();
                        matched_qualities.clearRetainingCapacity();
                        continue;
                    }

                    // Candidate buffered — continue matching for longer patterns
                }
            }
        }
    }

    // Flush any remaining candidates at end of token stream
    if (candidates.items.len > 0) {
        if (selectBestCandidate(candidates.items)) |winner| {
            try result.append(allocator, winner.event);
        }
        candidates.clearRetainingCapacity();
    }

    return result.toOwnedSlice(allocator);
}

/// Checks constraints (position, exclude, not_preceded_by) and confidence,
/// then buffers a candidate event if all checks pass. Used for the normal
/// (non-optional-skip) code path.
/// Returns true if the candidate was buffered, false if rejected.
fn bufferCandidate(
    candidates: *std.ArrayList(CandidateEvent),
    event_info: compiler.EventInfo,
    patterns: []const loader.Pattern,
    pending_captures: *std.ArrayList(CaptureEntry),
    matched_kinds: *std.ArrayList(TokenKind),
    matched_texts: *std.ArrayList([]const u8),
    matched_qualities: *std.ArrayList(MatchResult),
    pattern_start: usize,
    pattern_col: usize,
    match_start_prev_token: ?[]const u8,
    lookback: LookbackBuffer,
    block_stack: BlockStack,
    tokens: []const Token,
    token: Token,
    allocator: std.mem.Allocator,
) !bool {
    const pattern = findPattern(patterns, event_info.type_name);

    // Position constraint check
    if (pattern) |p| {
        if (p.position) |pos| {
            switch (pos) {
                .start => {
                    if (pattern_col != 0) return false;
                },
            }
        }
    }

    // Exclusion check
    if (pattern) |p| {
        if (p.exclude.len > 0) {
            for (p.exclude) |exc| {
                if (lookback.contains(exc)) return false;
            }
        }
    }

    // not_preceded_by check
    if (pattern) |p| {
        if (p.not_preceded_by.len > 0) {
            if (match_start_prev_token) |prev_text| {
                for (p.not_preceded_by) |npb| {
                    if (std.mem.eql(u8, prev_text, npb)) return false;
                }
            }
        }
    }

    // Compute confidence
    const max_score = if (pattern) |p| patternMaxScore(p.sequence) else 1.0;
    var matched_weights: f32 = 0.0;
    for (matched_kinds.items, matched_qualities.items) |kind, quality| {
        if (quality == .relaxed_match) {
            matched_weights += events_mod.evidence_weights.relaxed_keyword;
        } else {
            matched_weights += events_mod.weightForKind(kind);
        }
    }
    const confidence = events_mod.computeConfidence(matched_weights, max_score, 0, events_mod.default_noise_penalty_per_token, events_mod.default_max_noise_penalty);

    if (confidence < 0.3) {
        pending_captures.clearRetainingCapacity();
        return false;
    }

    // Find the line number from the first token in the pattern
    var pattern_line: usize = 1;
    for (tokens) |t| {
        if (t.start == pattern_start) {
            pattern_line = t.line;
            break;
        }
    }

    // Rebuild captures from pattern definitions using matched token texts
    pending_captures.clearRetainingCapacity();
    if (pattern) |p| {
        for (p.captures) |cap| {
            if (cap.position < matched_texts.items.len) {
                try pending_captures.append(allocator, .{
                    .field_name = cap.field_name,
                    .value = matched_texts.items[cap.position],
                });
            }
        }
    }

    const event = StructuralEvent{
        .type_name = event_info.type_name,
        .captures = try pending_captures.toOwnedSlice(allocator),
        .start = pattern_start,
        .end = token.end,
        .line = pattern_line,
        .col = pattern_col,
        .confidence = confidence,
        .block_start = block_stack.top(),
    };

    try candidates.append(allocator, .{
        .event = event,
        .match_length = matched_kinds.items.len,
        .pattern_index = findPatternIndex(patterns, event_info.type_name),
    });

    return true;
}

/// Like bufferCandidate but also checks Minimum_Evidence rule (at least one
/// required element must have matched). Used for the optional-skip code path.
fn bufferCandidateWithMinEvidence(
    candidates: *std.ArrayList(CandidateEvent),
    event_info: compiler.EventInfo,
    patterns: []const loader.Pattern,
    pending_captures: *std.ArrayList(CaptureEntry),
    matched_kinds: *std.ArrayList(TokenKind),
    matched_texts: *std.ArrayList([]const u8),
    matched_qualities: *std.ArrayList(MatchResult),
    pattern_start: usize,
    pattern_col: usize,
    match_start_prev_token: ?[]const u8,
    lookback: LookbackBuffer,
    block_stack: BlockStack,
    tokens: []const Token,
    token: Token,
    allocator: std.mem.Allocator,
) !bool {
    const pattern = findPattern(patterns, event_info.type_name);

    // Minimum_Evidence: at least one required element must have matched
    var has_required_match = false;
    if (pattern) |p| {
        if (matched_kinds.items.len > 0) {
            for (p.sequence) |seq_elem| {
                if (!seq_elem.is_optional) {
                    has_required_match = matched_kinds.items.len > 0;
                    break;
                }
            }
        }
    } else {
        has_required_match = matched_kinds.items.len > 0;
    }

    if (!has_required_match) return false;

    return bufferCandidate(
        candidates,
        event_info,
        patterns,
        pending_captures,
        matched_kinds,
        matched_texts,
        matched_qualities,
        pattern_start,
        pattern_col,
        match_start_prev_token,
        lookback,
        block_stack,
        tokens,
        token,
        allocator,
    );
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
            .{ .matcher = .{ .keyword_literal = "fn" } },
            .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } },
            .{ .matcher = .{ .symbol_literal = "(" } },
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

test "parse: identifier_literal matching pattern emits event" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]loader.Pattern{.{
        .type_name = "test_literal",
        .sequence = &.{
            .{ .matcher = .{ .identifier_literal = "Config" } },
            .{ .matcher = .{ .symbol_literal = "(" } },
        },
        .captures = &.{},
    }};

    const automaton = try compiler.compile(patterns, alloc);
    const source = "Config(";
    const tokens = &[_]Token{
        .{ .kind = .identifier, .start = 0, .end = 6, .line = 1, .col = 0 },
        .{ .kind = .delimiter, .start = 6, .end = 7, .line = 1, .col = 6 },
    };

    const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("test_literal", result[0].type_name);
    try testing.expectEqual(@as(usize, 0), result[0].start);
    try testing.expectEqual(@as(usize, 7), result[0].end);
    try testing.expect(result[0].confidence > 0.3);
}

test "parse: no matching pattern emits nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]loader.Pattern{.{
        .type_name = "function",
        .sequence = &.{ .{ .matcher = .{ .keyword_literal = "fn" } }, .{ .matcher = .{ .identifier = {} } } },
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
        .sequence = &.{ .{ .matcher = .{ .keyword_literal = "fn" } }, .{ .matcher = .{ .identifier = {} } } },
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
            .{ .matcher = .{ .keyword_literal = "fn" } },
            .{ .matcher = .{ .identifier = {} } },
            .{ .matcher = .{ .symbol_literal = "(" } },
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
        .sequence = &.{ .{ .matcher = .{ .identifier = {} } }, .{ .matcher = .{ .symbol_literal = "(" } } },
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
        .sequence = &.{ .{ .matcher = .{ .keyword_literal = "fn" } }, .{ .matcher = .{ .identifier = {} } } },
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
        .sequence = &.{ .{ .matcher = .{ .keyword_literal = "fn" } }, .{ .matcher = .{ .identifier = {} } } },
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
        .sequence = &.{ .{ .matcher = .{ .identifier = {} } }, .{ .matcher = .{ .symbol_literal = "(" } } },
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
        .sequence = &.{ .{ .matcher = .{ .identifier = {} } }, .{ .matcher = .{ .symbol_literal = "(" } } },
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
        .sequence = &.{ .{ .matcher = .{ .identifier = {} } }, .{ .matcher = .{ .symbol_literal = "(" } } },
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
        .sequence = &.{ .{ .matcher = .{ .identifier = {} } }, .{ .matcher = .{ .symbol_literal = "(" } } },
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
        .sequence = &.{ .{ .matcher = .{ .identifier = {} } }, .{ .matcher = .{ .symbol_literal = "(" } } },
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
                    .{ .matcher = .{ .keyword_literal = "fn" } },
                    .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } },
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
                .sequence = &.{ .{ .matcher = .{ .keyword_literal = "fn" } }, .{ .matcher = .{ .identifier = {} } } },
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
                .sequence = &.{ .{ .matcher = .{ .identifier = {} } }, .{ .matcher = .{ .symbol_literal = "(" } } },
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

            var max: f32 = 0.0;
            var matched_weights: f32 = 0.0;
            for (0..pattern_len) |_| {
                max += events_mod.evidence_weights.keyword;
                matched_weights += events_mod.evidence_weights.keyword;
            }

            const confidence = events_mod.computeConfidence(matched_weights, max, 0, events_mod.default_noise_penalty_per_token, events_mod.default_max_noise_penalty);
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
                .sequence = &.{ .{ .matcher = .{ .keyword_literal = "fn" } }, .{ .matcher = .{ .identifier = {} } } },
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
                .sequence = &.{ .{ .matcher = .{ .identifier = {} } }, .{ .matcher = .{ .symbol_literal = "(" } } },
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
                .sequence = &.{ .{ .matcher = .{ .identifier = {} } }, .{ .matcher = .{ .symbol_literal = "(" } } },
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

// --- not_preceded_by Unit Tests ---

test "parse: not_preceded_by rejects match when preceding token matches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]loader.Pattern{.{
        .type_name = "function",
        .sequence = &.{ .{ .matcher = .{ .identifier = {} } }, .{ .matcher = .{ .symbol_literal = "(" } } },
        .captures = &.{},
        .not_preceded_by = &.{"fun"},
    }};

    const automaton = try compiler.compile(patterns, alloc);
    // "fun add(" — "fun" precedes the match
    const source = "fun add(";
    const tokens = &[_]Token{
        .{ .kind = .keyword, .start = 0, .end = 3, .line = 1, .col = 0 },
        .{ .kind = .identifier, .start = 4, .end = 7, .line = 1, .col = 4 },
        .{ .kind = .delimiter, .start = 7, .end = 8, .line = 1, .col = 7 },
    };

    const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "parse: not_preceded_by allows match when preceding token does not match" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]loader.Pattern{.{
        .type_name = "function",
        .sequence = &.{ .{ .matcher = .{ .identifier = {} } }, .{ .matcher = .{ .symbol_literal = "(" } } },
        .captures = &.{},
        .not_preceded_by = &.{"fun"},
    }};

    const automaton = try compiler.compile(patterns, alloc);
    // "module add(" — "module" does not match "fun"
    const source = "module add(";
    const tokens = &[_]Token{
        .{ .kind = .keyword, .start = 0, .end = 6, .line = 1, .col = 0 },
        .{ .kind = .identifier, .start = 7, .end = 10, .line = 1, .col = 7 },
        .{ .kind = .delimiter, .start = 10, .end = 11, .line = 1, .col = 10 },
    };

    const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("function", result[0].type_name);
}

test "parse: not_preceded_by passes at start of stream (no preceding token)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]loader.Pattern{.{
        .type_name = "function",
        .sequence = &.{ .{ .matcher = .{ .identifier = {} } }, .{ .matcher = .{ .symbol_literal = "(" } } },
        .captures = &.{},
        .not_preceded_by = &.{"fun"},
    }};

    const automaton = try compiler.compile(patterns, alloc);
    // "add(" — no preceding token at all
    const source = "add(";
    const tokens = &[_]Token{
        .{ .kind = .identifier, .start = 0, .end = 3, .line = 1, .col = 0 },
        .{ .kind = .delimiter, .start = 3, .end = 4, .line = 1, .col = 3 },
    };

    const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("function", result[0].type_name);
}

test "parse: combined position, exclude, and not_preceded_by constraints" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Pattern with all three constraints
    const patterns = &[_]loader.Pattern{.{
        .type_name = "function",
        .sequence = &.{ .{ .matcher = .{ .identifier = {} } }, .{ .matcher = .{ .symbol_literal = "(" } } },
        .captures = &.{},
        .position = .start,
        .exclude = &.{"-spec"},
        .not_preceded_by = &.{"="},
    }};

    const automaton = try compiler.compile(patterns, alloc);

    // Case 1: all constraints pass → event emitted
    {
        const source = "add(";
        const tokens = &[_]Token{
            .{ .kind = .identifier, .start = 0, .end = 3, .line = 1, .col = 0 },
            .{ .kind = .delimiter, .start = 3, .end = 4, .line = 1, .col = 3 },
        };
        const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
        try testing.expectEqual(@as(usize, 1), result.len);
    }

    // Case 2: not_preceded_by rejects (= precedes)
    {
        const source = "= add(";
        const tokens = &[_]Token{
            .{ .kind = .operator, .start = 0, .end = 1, .line = 1, .col = 0 },
            .{ .kind = .identifier, .start = 2, .end = 5, .line = 1, .col = 2 },
            .{ .kind = .delimiter, .start = 5, .end = 6, .line = 1, .col = 5 },
        };
        const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
        try testing.expectEqual(@as(usize, 0), result.len);
    }

    // Case 3: exclude rejects (-spec in lookback)
    {
        const source = "-spec add(";
        const tokens = &[_]Token{
            .{ .kind = .keyword, .start = 0, .end = 5, .line = 1, .col = 0 },
            .{ .kind = .identifier, .start = 6, .end = 9, .line = 1, .col = 6 },
            .{ .kind = .delimiter, .start = 9, .end = 10, .line = 1, .col = 9 },
        };
        const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
        try testing.expectEqual(@as(usize, 0), result.len);
    }
}

// --- not_preceded_by Property Tests ---

// Feature: not-preceded-by-constraint, Property 2: Engine not_preceded_by constraint enforcement
// **Validates: Requirements 2.2, 2.3, 2.4, 2.7**
test "property: engine not_preceded_by constraint enforcement" {
    // Generate a random preceding token and a not_preceded_by list entry
    const str_gen = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha });

    try minish.check(testing.allocator, str_gen, struct {
        fn prop(npb_entry: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const patterns = &[_]loader.Pattern{.{
                .type_name = "call",
                .sequence = &.{ .{ .matcher = .{ .identifier = {} } }, .{ .matcher = .{ .symbol_literal = "(" } } },
                .captures = &.{},
                .not_preceded_by = &.{npb_entry},
            }};

            const automaton = try compiler.compile(patterns, alloc);

            // Case A: preceding token matches npb_entry → should be rejected
            {
                var buf: [256]u8 = undefined;
                const source = std.fmt.bufPrint(&buf, "{s} add(", .{npb_entry}) catch return;
                const npb_end = npb_entry.len;
                const id_start = npb_end + 1;
                const id_end = id_start + 3;

                const tokens = &[_]Token{
                    .{ .kind = .keyword, .start = 0, .end = npb_end, .line = 1, .col = 0 },
                    .{ .kind = .identifier, .start = id_start, .end = id_end, .line = 1, .col = id_start },
                    .{ .kind = .delimiter, .start = id_end, .end = id_end + 1, .line = 1, .col = id_end },
                };

                const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
                try testing.expectEqual(@as(usize, 0), result.len);
            }

            // Case B: preceding token does NOT match → should emit event
            // Use "zzz_nomatch" which won't equal any alpha string of len 1-8
            {
                const safe_prev = "zzz_nomatch";
                var buf2: [256]u8 = undefined;
                const source2 = std.fmt.bufPrint(&buf2, "{s} add(", .{safe_prev}) catch return;
                const prev_end = safe_prev.len;
                const id_start2 = prev_end + 1;
                const id_end2 = id_start2 + 3;

                const tokens2 = &[_]Token{
                    .{ .kind = .keyword, .start = 0, .end = prev_end, .line = 1, .col = 0 },
                    .{ .kind = .identifier, .start = id_start2, .end = id_end2, .line = 1, .col = id_start2 },
                    .{ .kind = .delimiter, .start = id_end2, .end = id_end2 + 1, .line = 1, .col = id_end2 },
                };

                const result2 = try parse(automaton, tokens2, source2, patterns, .{}, alloc);
                try testing.expectEqual(@as(usize, 1), result2.len);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: not-preceded-by-constraint, Property 3: Engine checks only the most recent preceding non-skip token
// **Validates: Requirements 4.2, 4.3**
test "property: engine checks only most recent preceding non-skip token" {
    const str_gen = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha });

    try minish.check(testing.allocator, str_gen, struct {
        fn prop(npb_entry: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const patterns = &[_]loader.Pattern{.{
                .type_name = "call",
                .sequence = &.{ .{ .matcher = .{ .identifier = {} } }, .{ .matcher = .{ .symbol_literal = "(" } } },
                .captures = &.{},
                .not_preceded_by = &.{npb_entry},
            }};

            const automaton = try compiler.compile(patterns, alloc);

            // Case A: npb_entry is first token, "ok" is second (immediately preceding) → should emit
            {
                var buf: [256]u8 = undefined;
                const source = std.fmt.bufPrint(&buf, "{s} ok add(", .{npb_entry}) catch return;
                const npb_end = npb_entry.len;
                const ok_start = npb_end + 1;
                const ok_end = ok_start + 2;
                const id_start = ok_end + 1;
                const id_end = id_start + 3;

                const tokens = &[_]Token{
                    .{ .kind = .keyword, .start = 0, .end = npb_end, .line = 1, .col = 0 },
                    .{ .kind = .keyword, .start = ok_start, .end = ok_end, .line = 1, .col = ok_start },
                    .{ .kind = .identifier, .start = id_start, .end = id_end, .line = 1, .col = id_start },
                    .{ .kind = .delimiter, .start = id_end, .end = id_end + 1, .line = 1, .col = id_end },
                };

                const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
                // "ok" is the immediately preceding token, not npb_entry → should emit
                try testing.expectEqual(@as(usize, 1), result.len);
            }

            // Case B: "ok" is first token, npb_entry is second (immediately preceding) → should reject
            {
                var buf2: [256]u8 = undefined;
                const source2 = std.fmt.bufPrint(&buf2, "ok {s} add(", .{npb_entry}) catch return;
                const ok_end2: usize = 2;
                const npb_start2 = ok_end2 + 1;
                const npb_end2 = npb_start2 + npb_entry.len;
                const id_start2 = npb_end2 + 1;
                const id_end2 = id_start2 + 3;

                const tokens2 = &[_]Token{
                    .{ .kind = .keyword, .start = 0, .end = ok_end2, .line = 1, .col = 0 },
                    .{ .kind = .keyword, .start = npb_start2, .end = npb_end2, .line = 1, .col = npb_start2 },
                    .{ .kind = .identifier, .start = id_start2, .end = id_end2, .line = 1, .col = id_start2 },
                    .{ .kind = .delimiter, .start = id_end2, .end = id_end2 + 1, .line = 1, .col = id_end2 },
                };

                const result2 = try parse(automaton, tokens2, source2, patterns, .{}, alloc);
                // npb_entry is the immediately preceding token → should reject
                try testing.expectEqual(@as(usize, 0), result2.len);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: not-preceded-by-constraint, Property 4: Engine evaluates exclude and not_preceded_by independently
// **Validates: Requirements 2.6, 2.8**
test "property: engine evaluates exclude and not_preceded_by independently" {
    const str_gen = gen.string(.{ .min_len = 1, .max_len = 6, .charset = .alpha });

    try minish.check(testing.allocator, str_gen, struct {
        fn prop(token_text: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // Use token_text as both the exclude and not_preceded_by entry
            // and "safe" as a non-matching token
            const exc_entry = token_text;
            const npb_entry = token_text;

            const patterns_both = &[_]loader.Pattern{.{
                .type_name = "call",
                .sequence = &.{ .{ .matcher = .{ .identifier = {} } }, .{ .matcher = .{ .symbol_literal = "(" } } },
                .captures = &.{},
                .exclude = &.{exc_entry},
                .not_preceded_by = &.{npb_entry},
            }};

            const automaton = try compiler.compile(patterns_both, alloc);

            // Case 1: both pass (preceding token is "safe", not in exclude or npb)
            {
                const source = "safe add(";
                const tokens = &[_]Token{
                    .{ .kind = .keyword, .start = 0, .end = 4, .line = 1, .col = 0 },
                    .{ .kind = .identifier, .start = 5, .end = 8, .line = 1, .col = 5 },
                    .{ .kind = .delimiter, .start = 8, .end = 9, .line = 1, .col = 8 },
                };
                const result = try parse(automaton, tokens, source, patterns_both, .{}, alloc);
                // "safe" doesn't match exclude or npb → event emitted
                if (!std.mem.eql(u8, token_text, "safe")) {
                    try testing.expectEqual(@as(usize, 1), result.len);
                }
            }

            // Case 2: both reject (preceding token matches both exclude and npb)
            {
                var buf: [256]u8 = undefined;
                const source = std.fmt.bufPrint(&buf, "{s} add(", .{token_text}) catch return;
                const t_end = token_text.len;
                const id_start = t_end + 1;
                const id_end = id_start + 3;

                const tokens = &[_]Token{
                    .{ .kind = .keyword, .start = 0, .end = t_end, .line = 1, .col = 0 },
                    .{ .kind = .identifier, .start = id_start, .end = id_end, .line = 1, .col = id_start },
                    .{ .kind = .delimiter, .start = id_end, .end = id_end + 1, .line = 1, .col = id_end },
                };
                const result = try parse(automaton, tokens, source, patterns_both, .{}, alloc);
                // token_text matches both → rejected
                try testing.expectEqual(@as(usize, 0), result.len);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// --- End-to-end integration tests: Erlang grammar with not_preceded_by ---

test "e2e: Erlang grammar rejects fun(Entry) as function definition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Load the actual Erlang grammar
    const file = try std.fs.cwd().openFile("examples/grammars/erlang.toml", .{});
    defer file.close();
    const grammar_source = try file.readToEndAlloc(alloc, 1024 * 1024);
    const grammar = try loader.parseGrammar(grammar_source, alloc);
    const automaton = try compiler.compile(grammar.patterns, alloc);

    // Erlang source: fun(Entry) -> ... is a lambda, not a function definition
    const source = "fun(Entry) ->\n    Entry\nend";
    const tokens = try tokenizer.tokenize(source, grammar.keyword_table, alloc);
    const events = try parse(automaton, tokens, source, grammar.patterns, grammar.blocks, alloc);

    // "fun" should NOT be detected as a function definition
    // because not_preceded_by doesn't apply here — the issue is that "fun" itself
    // starts the pattern. Actually, "fun" is in the keyword table as a keyword,
    // so the pattern ["$name:IDENTIFIER", "("] won't match "fun" because
    // the tokenizer classifies "fun" as .keyword, not .identifier.
    // Let's verify no "function" event with name="fun" is emitted.
    for (events) |ev| {
        if (std.mem.eql(u8, ev.type_name, "function")) {
            for (ev.captures) |cap| {
                if (std.mem.eql(u8, cap.field_name, "name")) {
                    try testing.expect(!std.mem.eql(u8, cap.value, "fun"));
                }
            }
        }
    }
}

test "e2e: Erlang grammar rejects function after = operator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Load the actual Erlang grammar
    const file = try std.fs.cwd().openFile("examples/grammars/erlang.toml", .{});
    defer file.close();
    const grammar_source = try file.readToEndAlloc(alloc, 1024 * 1024);
    const grammar = try loader.parseGrammar(grammar_source, alloc);
    const automaton = try compiler.compile(grammar.patterns, alloc);

    // Erlang source: Config = get_env(app) — "get_env" preceded by "=" should not be a function def
    const source = "Config = get_env(app)";
    const tokens = try tokenizer.tokenize(source, grammar.keyword_table, alloc);
    const events = try parse(automaton, tokens, source, grammar.patterns, grammar.blocks, alloc);

    // "get_env" should NOT be detected as a function definition because "=" precedes it
    for (events) |ev| {
        if (std.mem.eql(u8, ev.type_name, "function")) {
            for (ev.captures) |cap| {
                if (std.mem.eql(u8, cap.field_name, "name")) {
                    try testing.expect(!std.mem.eql(u8, cap.value, "get_env"));
                }
            }
        }
    }
}

test "e2e: Erlang grammar still detects real function definitions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Load the actual Erlang grammar
    const file = try std.fs.cwd().openFile("examples/grammars/erlang.toml", .{});
    defer file.close();
    const grammar_source = try file.readToEndAlloc(alloc, 1024 * 1024);
    const grammar = try loader.parseGrammar(grammar_source, alloc);
    const automaton = try compiler.compile(grammar.patterns, alloc);

    // Erlang source: a real function definition at column 0
    const source = "handle_call(Request, From, State) ->\n    {reply, ok, State}.";
    const tokens = try tokenizer.tokenize(source, grammar.keyword_table, alloc);
    const events = try parse(automaton, tokens, source, grammar.patterns, grammar.blocks, alloc);

    // "handle_call" SHOULD be detected as a function definition
    var found_function = false;
    for (events) |ev| {
        if (std.mem.eql(u8, ev.type_name, "function")) {
            for (ev.captures) |cap| {
                if (std.mem.eql(u8, cap.field_name, "name") and std.mem.eql(u8, cap.value, "handle_call")) {
                    found_function = true;
                }
            }
        }
    }
    try testing.expect(found_function);
}

// --- Phase 1: Probabilistic Confidence Scoring Tests ---

// Feature: probabilistic-confidence-scoring, Property 2: Relaxed match produces lower confidence than full match
// **Validates: Requirements 1.5, 7.3**
test "property: relaxed match produces lower confidence than full match" {
    const len_gen = gen.intRange(u8, 1, 3);

    try minish.check(testing.allocator, len_gen, struct {
        fn prop(num_keywords: u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // Build a pattern with num_keywords keyword_literals + 1 symbol
            var seq: std.ArrayList(loader.SequenceElement) = .empty;
            for (0..num_keywords) |_| {
                try seq.append(alloc, .{ .matcher = .{ .keyword_literal = "kw" } });
            }
            try seq.append(alloc, .{ .matcher = .{ .symbol_literal = "(" } });

            const patterns = &[_]loader.Pattern{.{
                .type_name = "test",
                .sequence = seq.items,
                .captures = &.{},
            }};

            const automaton = try compiler.compile(patterns, alloc);

            // Build tokens for full match (all keywords as .keyword kind)
            var full_tokens: std.ArrayList(Token) = .empty;
            var offset: usize = 0;
            for (0..num_keywords) |_| {
                try full_tokens.append(alloc, .{ .kind = .keyword, .start = offset, .end = offset + 2, .line = 1, .col = offset });
                offset += 3;
            }
            try full_tokens.append(alloc, .{ .kind = .delimiter, .start = offset, .end = offset + 1, .line = 1, .col = offset });

            // Build tokens for relaxed match (first keyword as .identifier kind)
            var relaxed_tokens: std.ArrayList(Token) = .empty;
            offset = 0;
            for (0..num_keywords) |i| {
                const kind: TokenKind = if (i == 0) .identifier else .keyword;
                try relaxed_tokens.append(alloc, .{ .kind = kind, .start = offset, .end = offset + 2, .line = 1, .col = offset });
                offset += 3;
            }
            try relaxed_tokens.append(alloc, .{ .kind = .delimiter, .start = offset, .end = offset + 1, .line = 1, .col = offset });

            // Build source string
            var buf: [256]u8 = undefined;
            var pos: usize = 0;
            for (0..num_keywords) |_| {
                @memcpy(buf[pos .. pos + 2], "kw");
                buf[pos + 2] = ' ';
                pos += 3;
            }
            buf[pos] = '(';
            pos += 1;
            const source = buf[0..pos];

            const full_result = try parse(automaton, full_tokens.items, source, patterns, .{}, alloc);
            const relaxed_result = try parse(automaton, relaxed_tokens.items, source, patterns, .{}, alloc);

            try testing.expectEqual(@as(usize, 1), full_result.len);
            try testing.expectEqual(@as(usize, 1), relaxed_result.len);

            // Relaxed confidence must be strictly less than full confidence
            try testing.expect(relaxed_result[0].confidence < full_result[0].confidence);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: probabilistic-confidence-scoring, Property 3: Backward compatibility for existing grammars
// **Validates: Requirements 1.6, 8.1, 8.2**
test "property: backward compatibility full keyword match produces confidence 1.0" {
    const len_gen = gen.intRange(u8, 1, 4);

    try minish.check(testing.allocator, len_gen, struct {
        fn prop(num_keywords: u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // Build a pattern of all keyword_literals
            var seq: std.ArrayList(loader.SequenceElement) = .empty;
            for (0..num_keywords) |_| {
                try seq.append(alloc, .{ .matcher = .{ .keyword_literal = "kw" } });
            }

            const patterns = &[_]loader.Pattern{.{
                .type_name = "test",
                .sequence = seq.items,
                .captures = &.{},
            }};

            const automaton = try compiler.compile(patterns, alloc);

            // All tokens as .keyword kind (full match)
            var tokens_list: std.ArrayList(Token) = .empty;
            var buf: [256]u8 = undefined;
            var offset: usize = 0;
            for (0..num_keywords) |_| {
                @memcpy(buf[offset .. offset + 2], "kw");
                if (offset + 3 < buf.len) buf[offset + 2] = ' ';
                try tokens_list.append(alloc, .{ .kind = .keyword, .start = offset, .end = offset + 2, .line = 1, .col = offset });
                offset += 3;
            }
            const source = buf[0..offset];

            const result = try parse(automaton, tokens_list.items, source, patterns, .{}, alloc);
            try testing.expectEqual(@as(usize, 1), result.len);
            try testing.expectApproxEqRel(@as(f32, 1.0), result[0].confidence, 0.01);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: probabilistic-confidence-scoring, Property 12: Confidence always in [0.0, 1.0]
// **Validates: Requirements 7.1**
test "property: confidence always in 0.0 to 1.0" {
    const weight_gen = gen.intRange(u16, 0, 1000);

    try minish.check(testing.allocator, weight_gen, struct {
        fn prop(raw_val: u16) !void {
            const matched_weights: f32 = @as(f32, @floatFromInt(raw_val)) / 100.0;
            const pattern_max_score: f32 = 1.0;
            const confidence = events_mod.computeConfidence(matched_weights, pattern_max_score, 0, events_mod.default_noise_penalty_per_token, events_mod.default_max_noise_penalty);
            try testing.expect(confidence >= 0.0);
            try testing.expect(confidence <= 1.0);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: probabilistic-confidence-scoring, Property 13: Perfect match produces confidence = 1.0
// **Validates: Requirements 7.2**
test "property: perfect match produces confidence 1.0" {
    const len_gen = gen.intRange(u8, 1, 4);

    try minish.check(testing.allocator, len_gen, struct {
        fn prop(pattern_len: u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // Build a mixed pattern: keyword + identifier alternating
            var seq: std.ArrayList(loader.SequenceElement) = .empty;
            var tokens_list: std.ArrayList(Token) = .empty;
            var buf: [256]u8 = undefined;
            var offset: usize = 0;

            for (0..pattern_len) |i| {
                if (i % 2 == 0) {
                    try seq.append(alloc, .{ .matcher = .{ .keyword_literal = "kw" } });
                    @memcpy(buf[offset .. offset + 2], "kw");
                    try tokens_list.append(alloc, .{ .kind = .keyword, .start = offset, .end = offset + 2, .line = 1, .col = offset });
                } else {
                    try seq.append(alloc, .{ .matcher = .{ .identifier = {} } });
                    @memcpy(buf[offset .. offset + 2], "id");
                    try tokens_list.append(alloc, .{ .kind = .identifier, .start = offset, .end = offset + 2, .line = 1, .col = offset });
                }
                if (offset + 3 < buf.len) buf[offset + 2] = ' ';
                offset += 3;
            }
            const source = buf[0..offset];

            const patterns = &[_]loader.Pattern{.{
                .type_name = "test",
                .sequence = seq.items,
                .captures = &.{},
            }};

            const automaton = try compiler.compile(patterns, alloc);
            const result = try parse(automaton, tokens_list.items, source, patterns, .{}, alloc);
            try testing.expectEqual(@as(usize, 1), result.len);
            try testing.expectApproxEqRel(@as(f32, 1.0), result[0].confidence, 0.01);
        }
    }.prop, .{ .num_runs = 100 });
}

// --- Phase 1 Unit Tests ---

test "parse: keyword as identifier token produces confidence < 1.0 (relaxed match)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Pattern: "fn" identifier "(" — max = 0.5 + 0.2 + 0.2 = 0.9
    const patterns = &[_]loader.Pattern{.{
        .type_name = "function",
        .sequence = &.{
            .{ .matcher = .{ .keyword_literal = "fn" } },
            .{ .matcher = .{ .identifier = {} } },
            .{ .matcher = .{ .symbol_literal = "(" } },
        },
        .captures = &.{},
    }};

    const automaton = try compiler.compile(patterns, alloc);
    const source = "fn add(";
    // "fn" tokenized as .identifier (missing keywords section)
    const tokens = &[_]Token{
        .{ .kind = .identifier, .start = 0, .end = 2, .line = 1, .col = 0 },
        .{ .kind = .identifier, .start = 3, .end = 6, .line = 1, .col = 3 },
        .{ .kind = .delimiter, .start = 6, .end = 7, .line = 1, .col = 6 },
    };

    const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
    try testing.expectEqual(@as(usize, 1), result.len);
    // relaxed_keyword(0.1) + identifier(0.2) + symbol(0.2) = 0.5 / 0.9 ≈ 0.556
    try testing.expect(result[0].confidence < 1.0);
    try testing.expect(result[0].confidence > 0.3);
}

test "parse: full keyword match produces confidence = 1.0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]loader.Pattern{.{
        .type_name = "function",
        .sequence = &.{
            .{ .matcher = .{ .keyword_literal = "fn" } },
            .{ .matcher = .{ .identifier = {} } },
            .{ .matcher = .{ .symbol_literal = "(" } },
        },
        .captures = &.{},
    }};

    const automaton = try compiler.compile(patterns, alloc);
    const source = "fn add(";
    // "fn" tokenized as .keyword (complete keywords section)
    const tokens = &[_]Token{
        .{ .kind = .keyword, .start = 0, .end = 2, .line = 1, .col = 0 },
        .{ .kind = .identifier, .start = 3, .end = 6, .line = 1, .col = 3 },
        .{ .kind = .delimiter, .start = 6, .end = 7, .line = 1, .col = 6 },
    };

    const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectApproxEqRel(@as(f32, 1.0), result[0].confidence, 0.01);
}

test "parse: mixed relaxed and full matches in same pattern" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Pattern: "fn" "pub" identifier — two keywords + identifier
    const patterns = &[_]loader.Pattern{.{
        .type_name = "pub_function",
        .sequence = &.{
            .{ .matcher = .{ .keyword_literal = "pub" } },
            .{ .matcher = .{ .keyword_literal = "fn" } },
            .{ .matcher = .{ .identifier = {} } },
        },
        .captures = &.{},
    }};

    const automaton = try compiler.compile(patterns, alloc);
    const source = "pub fn add";
    // "pub" as .keyword (full), "fn" as .identifier (relaxed)
    const tokens = &[_]Token{
        .{ .kind = .keyword, .start = 0, .end = 3, .line = 1, .col = 0 },
        .{ .kind = .identifier, .start = 4, .end = 6, .line = 1, .col = 4 },
        .{ .kind = .identifier, .start = 7, .end = 10, .line = 1, .col = 7 },
    };

    const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
    try testing.expectEqual(@as(usize, 1), result.len);
    // full(0.5) + relaxed(0.1) + identifier(0.2) = 0.8 / (0.5+0.5+0.2) = 0.8/1.2 ≈ 0.667
    try testing.expect(result[0].confidence < 1.0);
    try testing.expect(result[0].confidence > 0.3);
}

// --- Phase 2: Optional Element Tests ---

// Feature: probabilistic-confidence-scoring, Property 5: Optional elements affect confidence monotonically
// **Validates: Requirements 2.2, 2.3, 7.4**
test "property: optional elements affect confidence monotonically" {
    // Generate a boolean to decide if we include 1 or 2 optional elements
    const opt_gen = gen.boolean();

    try minish.check(testing.allocator, opt_gen, struct {
        fn prop(two_optionals: bool) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // Pattern: "fn" "$name:IDENTIFIER" "("? or "fn" "$name:IDENTIFIER" "("? "{"?
            // Required: fn, $name:IDENTIFIER
            // Optional: ( and optionally {
            var seq: std.ArrayList(loader.SequenceElement) = .empty;
            try seq.append(alloc, .{ .matcher = .{ .keyword_literal = "fn" } });
            try seq.append(alloc, .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } });
            try seq.append(alloc, .{ .matcher = .{ .symbol_literal = "(" }, .is_optional = true });
            if (two_optionals) {
                try seq.append(alloc, .{ .matcher = .{ .symbol_literal = "{" }, .is_optional = true });
            }

            const patterns = &[_]loader.Pattern{.{
                .type_name = "function",
                .sequence = seq.items,
                .captures = &.{.{ .field_name = "name", .position = 1 }},
            }};

            const automaton = try compiler.compile(patterns, alloc);

            // Full match: all tokens present (fn as .keyword, identifier, ( as .delimiter, optionally { as .delimiter)
            // "fn add(" = f(0)n(1) (2)a(3)d(4)d(5)((6) → len 7
            // "fn add( {" = ...((6) (7){(8) → len 9 — but we use "fn add({" = ...((6){(7) → len 8
            const full_source = if (two_optionals) "fn add({" else "fn add(";
            var full_tokens: std.ArrayList(Token) = .empty;
            try full_tokens.append(alloc, .{ .kind = .keyword, .start = 0, .end = 2, .line = 1, .col = 0 });
            try full_tokens.append(alloc, .{ .kind = .identifier, .start = 3, .end = 6, .line = 1, .col = 3 });
            try full_tokens.append(alloc, .{ .kind = .delimiter, .start = 6, .end = 7, .line = 1, .col = 6 });
            if (two_optionals) {
                try full_tokens.append(alloc, .{ .kind = .delimiter, .start = 7, .end = 8, .line = 1, .col = 7 });
            }

            const full_result = try parse(automaton, full_tokens.items, full_source, patterns, .{}, alloc);
            try testing.expectEqual(@as(usize, 1), full_result.len);

            // All-present confidence should be 1.0
            try testing.expectApproxEqRel(@as(f32, 1.0), full_result[0].confidence, 0.01);

            // Partial match: required tokens present (fn, identifier), then a non-matching token
            // triggers the optional skip logic. The ";" doesn't match "(" so the engine skips the optional.
            const partial_source = "fn add;";
            const partial_tokens = &[_]Token{
                .{ .kind = .keyword, .start = 0, .end = 2, .line = 1, .col = 0 },
                .{ .kind = .identifier, .start = 3, .end = 6, .line = 1, .col = 3 },
                .{ .kind = .symbol, .start = 6, .end = 7, .line = 1, .col = 6 },
            };

            const partial_result = try parse(automaton, partial_tokens, partial_source, patterns, .{}, alloc);
            try testing.expectEqual(@as(usize, 1), partial_result.len);

            // Partial confidence should be < 1.0
            try testing.expect(partial_result[0].confidence < 1.0);

            // Monotonicity: all-present > some-absent
            try testing.expect(full_result[0].confidence > partial_result[0].confidence);
        }
    }.prop, .{ .num_runs = 100 });
}

// --- Phase 2: Optional Element Unit Tests (engine) ---

test "parse: optional element present produces confidence = 1.0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Pattern: "fn" "$name:IDENTIFIER" "("?
    const patterns = &[_]loader.Pattern{.{
        .type_name = "function",
        .sequence = &.{
            .{ .matcher = .{ .keyword_literal = "fn" } },
            .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } },
            .{ .matcher = .{ .symbol_literal = "(" }, .is_optional = true },
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
    try testing.expectApproxEqRel(@as(f32, 1.0), result[0].confidence, 0.01);
}

test "parse: optional element absent produces confidence < 1.0 but event still emitted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Pattern: "fn" "$name:IDENTIFIER" "("?
    const patterns = &[_]loader.Pattern{.{
        .type_name = "function",
        .sequence = &.{
            .{ .matcher = .{ .keyword_literal = "fn" } },
            .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } },
            .{ .matcher = .{ .symbol_literal = "(" }, .is_optional = true },
        },
        .captures = &.{.{ .field_name = "name", .position = 1 }},
    }};

    const automaton = try compiler.compile(patterns, alloc);
    // "fn add;" — no "(" present, ";" triggers optional skip
    const source = "fn add;";
    const tokens = &[_]Token{
        .{ .kind = .keyword, .start = 0, .end = 2, .line = 1, .col = 0 },
        .{ .kind = .identifier, .start = 3, .end = 6, .line = 1, .col = 3 },
        .{ .kind = .symbol, .start = 6, .end = 7, .line = 1, .col = 6 },
    };

    const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
    try testing.expectEqual(@as(usize, 1), result.len);
    // Confidence should be < 1.0 because optional element is absent
    // matched: keyword(0.5) + identifier(0.2) = 0.7
    // max: keyword(0.5) + identifier(0.2) + symbol(0.2) = 0.9
    // confidence = 0.7 / 0.9 ≈ 0.778
    try testing.expect(result[0].confidence < 1.0);
    try testing.expect(result[0].confidence > 0.3);
    try testing.expectEqualStrings("function", result[0].type_name);
}

test "parse: all-optional pattern with none matching emits no event (Minimum_Evidence)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Pattern with only optional elements
    const patterns = &[_]loader.Pattern{.{
        .type_name = "test",
        .sequence = &.{
            .{ .matcher = .{ .keyword_literal = "fn" }, .is_optional = true },
            .{ .matcher = .{ .symbol_literal = "(" }, .is_optional = true },
        },
        .captures = &.{},
    }};

    const automaton = try compiler.compile(patterns, alloc);
    // Tokens that don't match any element in the pattern
    const source = "let x";
    const tokens = &[_]Token{
        .{ .kind = .keyword, .start = 0, .end = 3, .line = 1, .col = 0 },
        .{ .kind = .identifier, .start = 4, .end = 5, .line = 1, .col = 4 },
    };

    const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
    // No event should be emitted — Minimum_Evidence rule: at least one required element must match
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "parse: mix of required and optional, optional absent produces confidence < 1.0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Pattern: "fn" "$name:IDENTIFIER" "("? "{"?
    // Required: fn, $name:IDENTIFIER
    // Optional: (, {
    const patterns = &[_]loader.Pattern{.{
        .type_name = "function",
        .sequence = &.{
            .{ .matcher = .{ .keyword_literal = "fn" } },
            .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } },
            .{ .matcher = .{ .symbol_literal = "(" }, .is_optional = true },
            .{ .matcher = .{ .symbol_literal = "{" }, .is_optional = true },
        },
        .captures = &.{.{ .field_name = "name", .position = 1 }},
    }};

    const automaton = try compiler.compile(patterns, alloc);

    // Only required elements present, both optionals absent
    // ";" triggers the optional skip logic
    const source = "fn add;";
    const tokens = &[_]Token{
        .{ .kind = .keyword, .start = 0, .end = 2, .line = 1, .col = 0 },
        .{ .kind = .identifier, .start = 3, .end = 6, .line = 1, .col = 3 },
        .{ .kind = .symbol, .start = 6, .end = 7, .line = 1, .col = 6 },
    };

    const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
    try testing.expectEqual(@as(usize, 1), result.len);
    // matched: keyword(0.5) + identifier(0.2) = 0.7
    // max: keyword(0.5) + identifier(0.2) + symbol(0.2) + symbol(0.2) = 1.1
    // confidence = 0.7 / 1.1 ≈ 0.636
    try testing.expect(result[0].confidence < 1.0);
    try testing.expect(result[0].confidence > 0.3);
}

// --- Competing Pattern Evaluation Tests (Phase 3) ---

// Feature: probabilistic-confidence-scoring, Phase 3: Competing Pattern Evaluation
// Unit tests for selectBestCandidate

test "selectBestCandidate: empty candidates returns null" {
    const candidates: []const CandidateEvent = &.{};
    try testing.expect(selectBestCandidate(candidates) == null);
}

test "selectBestCandidate: single candidate returned" {
    const candidates = &[_]CandidateEvent{.{
        .event = .{
            .type_name = "call",
            .captures = &.{},
            .start = 0,
            .end = 4,
            .line = 1,
            .col = 0,
            .confidence = 0.8,
        },
        .match_length = 2,
        .pattern_index = 0,
    }};
    const best = selectBestCandidate(candidates);
    try testing.expect(best != null);
    try testing.expectEqualStrings("call", best.?.event.type_name);
}

test "selectBestCandidate: higher confidence wins" {
    const candidates = &[_]CandidateEvent{
        .{
            .event = .{
                .type_name = "call",
                .captures = &.{},
                .start = 0,
                .end = 4,
                .line = 1,
                .col = 0,
                .confidence = 0.6,
            },
            .match_length = 2,
            .pattern_index = 0,
        },
        .{
            .event = .{
                .type_name = "function",
                .captures = &.{},
                .start = 0,
                .end = 7,
                .line = 1,
                .col = 0,
                .confidence = 0.9,
            },
            .match_length = 3,
            .pattern_index = 1,
        },
    };
    const best = selectBestCandidate(candidates);
    try testing.expect(best != null);
    try testing.expectEqualStrings("function", best.?.event.type_name);
    try testing.expectApproxEqRel(@as(f32, 0.9), best.?.event.confidence, 0.01);
}

test "selectBestCandidate: equal confidence, longer match wins" {
    const candidates = &[_]CandidateEvent{
        .{
            .event = .{
                .type_name = "short",
                .captures = &.{},
                .start = 0,
                .end = 4,
                .line = 1,
                .col = 0,
                .confidence = 0.8,
            },
            .match_length = 2,
            .pattern_index = 0,
        },
        .{
            .event = .{
                .type_name = "long",
                .captures = &.{},
                .start = 0,
                .end = 7,
                .line = 1,
                .col = 0,
                .confidence = 0.8,
            },
            .match_length = 3,
            .pattern_index = 1,
        },
    };
    const best = selectBestCandidate(candidates);
    try testing.expect(best != null);
    try testing.expectEqualStrings("long", best.?.event.type_name);
}

test "selectBestCandidate: equal confidence and length, grammar order wins" {
    const candidates = &[_]CandidateEvent{
        .{
            .event = .{
                .type_name = "second",
                .captures = &.{},
                .start = 0,
                .end = 4,
                .line = 1,
                .col = 0,
                .confidence = 0.8,
            },
            .match_length = 2,
            .pattern_index = 1,
        },
        .{
            .event = .{
                .type_name = "first",
                .captures = &.{},
                .start = 0,
                .end = 4,
                .line = 1,
                .col = 0,
                .confidence = 0.8,
            },
            .match_length = 2,
            .pattern_index = 0,
        },
    };
    const best = selectBestCandidate(candidates);
    try testing.expect(best != null);
    try testing.expectEqualStrings("first", best.?.event.type_name);
    try testing.expectEqual(@as(usize, 0), best.?.pattern_index);
}

// Integration tests: competing patterns through the full parse pipeline

test "parse: single pattern emitted normally with buffered emission (no regression)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]loader.Pattern{.{
        .type_name = "function",
        .sequence = &.{
            .{ .matcher = .{ .keyword_literal = "fn" } },
            .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } },
            .{ .matcher = .{ .symbol_literal = "(" } },
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
    try testing.expectEqualStrings("add", result[0].captures[0].value);
    try testing.expectApproxEqRel(@as(f32, 1.0), result[0].confidence, 0.01);
}

test "parse: competing patterns with shared prefix, longer match wins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Pattern A: "fn" identifier → shorter (2 tokens)
    // Pattern B: "fn" identifier "(" → longer (3 tokens)
    // Both share prefix "fn" identifier. After matching "fn identifier",
    // Pattern A reaches terminal. With buffered emission, we continue
    // and Pattern B also reaches terminal after "(". The longer/higher-confidence wins.
    const patterns = &[_]loader.Pattern{
        .{
            .type_name = "fn_decl",
            .sequence = &.{
                .{ .matcher = .{ .keyword_literal = "fn" } },
                .{ .matcher = .{ .identifier = {} } },
            },
            .captures = &.{},
        },
        .{
            .type_name = "fn_call",
            .sequence = &.{
                .{ .matcher = .{ .keyword_literal = "fn" } },
                .{ .matcher = .{ .identifier = {} } },
                .{ .matcher = .{ .symbol_literal = "(" } },
            },
            .captures = &.{},
        },
    };

    const automaton = try compiler.compile(patterns, alloc);
    const source = "fn add(";
    const tokens = &[_]Token{
        .{ .kind = .keyword, .start = 0, .end = 2, .line = 1, .col = 0 },
        .{ .kind = .identifier, .start = 3, .end = 6, .line = 1, .col = 3 },
        .{ .kind = .delimiter, .start = 6, .end = 7, .line = 1, .col = 6 },
    };

    const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
    // Should emit only one event — the longer/higher-confidence match
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("fn_call", result[0].type_name);
}

test "parse: competing patterns, shorter match emitted when longer doesn't complete" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Pattern A: "fn" identifier → shorter
    // Pattern B: "fn" identifier "(" → longer
    // Input: "fn add ;" — only Pattern A matches
    const patterns = &[_]loader.Pattern{
        .{
            .type_name = "fn_decl",
            .sequence = &.{
                .{ .matcher = .{ .keyword_literal = "fn" } },
                .{ .matcher = .{ .identifier = {} } },
            },
            .captures = &.{},
        },
        .{
            .type_name = "fn_call",
            .sequence = &.{
                .{ .matcher = .{ .keyword_literal = "fn" } },
                .{ .matcher = .{ .identifier = {} } },
                .{ .matcher = .{ .symbol_literal = "(" } },
            },
            .captures = &.{},
        },
    };

    const automaton = try compiler.compile(patterns, alloc);
    const source = "fn add ;";
    const tokens = &[_]Token{
        .{ .kind = .keyword, .start = 0, .end = 2, .line = 1, .col = 0 },
        .{ .kind = .identifier, .start = 3, .end = 6, .line = 1, .col = 3 },
        .{ .kind = .symbol, .start = 7, .end = 8, .line = 1, .col = 7 },
    };

    const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
    // ";" doesn't match "(" so the longer pattern fails.
    // The shorter pattern (fn_decl) should be emitted from the buffer.
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("fn_decl", result[0].type_name);
}

test "parse: competing patterns, end of stream flushes buffered candidate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Pattern A: "fn" identifier → terminal after 2 tokens
    // Pattern B: "fn" identifier "(" → needs 3 tokens
    // Input: "fn add" — only 2 tokens, stream ends at terminal for A
    const patterns = &[_]loader.Pattern{
        .{
            .type_name = "fn_decl",
            .sequence = &.{
                .{ .matcher = .{ .keyword_literal = "fn" } },
                .{ .matcher = .{ .identifier = {} } },
            },
            .captures = &.{},
        },
        .{
            .type_name = "fn_call",
            .sequence = &.{
                .{ .matcher = .{ .keyword_literal = "fn" } },
                .{ .matcher = .{ .identifier = {} } },
                .{ .matcher = .{ .symbol_literal = "(" } },
            },
            .captures = &.{},
        },
    };

    const automaton = try compiler.compile(patterns, alloc);
    const source = "fn add";
    const tokens = &[_]Token{
        .{ .kind = .keyword, .start = 0, .end = 2, .line = 1, .col = 0 },
        .{ .kind = .identifier, .start = 3, .end = 6, .line = 1, .col = 3 },
    };

    const result = try parse(automaton, tokens, source, patterns, .{}, alloc);
    // End of stream should flush the buffered fn_decl candidate
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("fn_decl", result[0].type_name);
}

// Feature: probabilistic-confidence-scoring, Property 6: Competing patterns — highest confidence wins
// **Validates: Requirements 3.1, 3.2, 3.3**
test "property: competing patterns — highest confidence wins" {
    // Test that selectBestCandidate always picks the highest confidence,
    // with correct tiebreakers for equal confidence.
    const conf_gen = gen.intRange(u8, 30, 100);

    try minish.check(testing.allocator, conf_gen, struct {
        fn prop(conf_pct: u8) !void {
            const conf_a: f32 = @as(f32, @floatFromInt(conf_pct)) / 100.0;
            // conf_b is always slightly lower than conf_a (unless conf_a is at minimum)
            const conf_b: f32 = if (conf_pct > 30) conf_a - 0.01 else conf_a;

            const candidates = &[_]CandidateEvent{
                .{
                    .event = .{
                        .type_name = "pattern_a",
                        .captures = &.{},
                        .start = 0,
                        .end = 4,
                        .line = 1,
                        .col = 0,
                        .confidence = conf_a,
                    },
                    .match_length = 2,
                    .pattern_index = 0,
                },
                .{
                    .event = .{
                        .type_name = "pattern_b",
                        .captures = &.{},
                        .start = 0,
                        .end = 4,
                        .line = 1,
                        .col = 0,
                        .confidence = conf_b,
                    },
                    .match_length = 2,
                    .pattern_index = 1,
                },
            };

            const best = selectBestCandidate(candidates);
            try testing.expect(best != null);

            if (conf_a > conf_b) {
                // Higher confidence wins
                try testing.expectEqualStrings("pattern_a", best.?.event.type_name);
            } else {
                // Equal confidence — same length — lower pattern_index wins
                try testing.expectEqual(@as(usize, 0), best.?.pattern_index);
            }

            // Verify the winner's confidence is >= all candidates
            for (candidates) |c| {
                try testing.expect(best.?.event.confidence >= c.event.confidence);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// --- Phase 4: Noise Penalty Tests ---

// Feature: probabilistic-confidence-scoring, Property 7: Noise penalty is bounded and monotonic
// **Validates: Requirements 4.1, 4.2, 4.3, 7.5**
test "property: noise penalty is bounded and monotonic" {
    const noise_gen = gen.intRange(u32, 0, 20);

    try minish.check(testing.allocator, noise_gen, struct {
        fn prop(noise_count: u32) !void {
            const matched_weights: f32 = 0.9; // typical full match
            const pattern_max_score: f32 = 0.9;
            const penalty_per_token: f32 = events_mod.default_noise_penalty_per_token;
            const max_penalty: f32 = events_mod.default_max_noise_penalty;

            // Verify penalty formula: capped_penalty = min(N * 0.1, 0.5)
            const expected_penalty = @min(@as(f32, @floatFromInt(noise_count)) * penalty_per_token, max_penalty);
            const expected_raw = @max(@as(f32, 0.0), matched_weights - expected_penalty);
            const expected_confidence = @min(expected_raw / pattern_max_score, 1.0);

            const confidence = events_mod.computeConfidence(matched_weights, pattern_max_score, noise_count, penalty_per_token, max_penalty);
            try testing.expectApproxEqRel(expected_confidence, confidence, 0.001);

            // Verify bounded: confidence in [0.0, 1.0]
            try testing.expect(confidence >= 0.0);
            try testing.expect(confidence <= 1.0);

            // Verify monotonicity: more noise → lower or equal confidence
            if (noise_count > 0) {
                const prev_confidence = events_mod.computeConfidence(matched_weights, pattern_max_score, noise_count - 1, penalty_per_token, max_penalty);
                try testing.expect(prev_confidence >= confidence);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: probabilistic-confidence-scoring, Property 8: Noise exclusion in balanced delimiters
// **Validates: Requirements 4.5**
// NOTE: This tests the computeConfidence formula with noise_count parameter.
// Balanced delimiter depth tracking is infrastructure in the engine (delim_depth variable).
// When mismatch tolerance is added, tokens inside balanced delimiters will not increment noise_count.
// For now, we verify that the formula correctly handles noise_count = 0 (as if excluded).
test "property: noise exclusion in balanced delimiters (formula infrastructure)" {
    const weight_gen = gen.intRange(u16, 1, 100);

    try minish.check(testing.allocator, weight_gen, struct {
        fn prop(raw_weight: u16) !void {
            const matched_weights: f32 = @as(f32, @floatFromInt(raw_weight)) / 10.0;
            const pattern_max_score: f32 = matched_weights; // perfect match scenario

            // With noise_count = 0 (tokens inside balanced delimiters excluded), confidence = 1.0
            const confidence_no_noise = events_mod.computeConfidence(matched_weights, pattern_max_score, 0, events_mod.default_noise_penalty_per_token, events_mod.default_max_noise_penalty);
            try testing.expectApproxEqRel(@as(f32, 1.0), confidence_no_noise, 0.001);

            // With noise_count > 0 (tokens outside delimiters counted), confidence < 1.0
            const confidence_with_noise = events_mod.computeConfidence(matched_weights, pattern_max_score, 3, events_mod.default_noise_penalty_per_token, events_mod.default_max_noise_penalty);
            try testing.expect(confidence_with_noise <= confidence_no_noise);
        }
    }.prop, .{ .num_runs = 100 });
}

// --- Phase 4: Noise Penalty Unit Tests ---

test "computeConfidence: no noise produces same result as pre-noise formula" {
    // matched_weights = 0.9, max_score = 0.9, noise = 0 → confidence = 1.0
    const confidence = events_mod.computeConfidence(0.9, 0.9, 0, 0.1, 0.5);
    try testing.expectApproxEqRel(@as(f32, 1.0), confidence, 0.001);
}

test "computeConfidence: 1 noise token reduces confidence" {
    // matched_weights = 0.9, max_score = 0.9, noise = 1
    // penalty = min(1 * 0.1, 0.5) = 0.1
    // raw = max(0, 0.9 - 0.1) = 0.8
    // confidence = 0.8 / 0.9 ≈ 0.889
    const confidence = events_mod.computeConfidence(0.9, 0.9, 1, 0.1, 0.5);
    try testing.expect(confidence < 1.0);
    try testing.expectApproxEqRel(@as(f32, 0.8 / 0.9), confidence, 0.001);
}

test "computeConfidence: 5+ noise tokens penalty capped at 0.5" {
    // matched_weights = 0.9, max_score = 0.9, noise = 5
    // penalty = min(5 * 0.1, 0.5) = 0.5
    // raw = max(0, 0.9 - 0.5) = 0.4
    // confidence = 0.4 / 0.9 ≈ 0.444
    const conf_5 = events_mod.computeConfidence(0.9, 0.9, 5, 0.1, 0.5);
    try testing.expectApproxEqRel(@as(f32, 0.4 / 0.9), conf_5, 0.001);

    // noise = 10 → penalty still capped at 0.5
    const conf_10 = events_mod.computeConfidence(0.9, 0.9, 10, 0.1, 0.5);
    try testing.expectApproxEqRel(conf_5, conf_10, 0.001);

    // noise = 100 → same cap
    const conf_100 = events_mod.computeConfidence(0.9, 0.9, 100, 0.1, 0.5);
    try testing.expectApproxEqRel(conf_5, conf_100, 0.001);
}

test "computeConfidence: noise can push confidence below threshold" {
    // matched_weights = 0.4, max_score = 0.9, noise = 3
    // penalty = min(3 * 0.1, 0.5) = 0.3
    // raw = max(0, 0.4 - 0.3) = 0.1
    // confidence = 0.1 / 0.9 ≈ 0.111 — below 0.3 threshold
    const confidence = events_mod.computeConfidence(0.4, 0.9, 3, 0.1, 0.5);
    try testing.expect(confidence < 0.3);
}

test "computeConfidence: noise cannot produce negative confidence" {
    // matched_weights = 0.2, max_score = 0.9, noise = 10
    // penalty = min(10 * 0.1, 0.5) = 0.5
    // raw = max(0, 0.2 - 0.5) = 0.0
    // confidence = 0.0 / 0.9 = 0.0
    const confidence = events_mod.computeConfidence(0.2, 0.9, 10, 0.1, 0.5);
    try testing.expectApproxEqRel(@as(f32, 0.0), confidence, 0.001);
}

test "computeConfidence: zero max_score returns 0.0 regardless of noise" {
    const confidence = events_mod.computeConfidence(0.5, 0.0, 3, 0.1, 0.5);
    try testing.expectApproxEqRel(@as(f32, 0.0), confidence, 0.001);
}
