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

// --- LookbackBuffer: dynamically-sized circular buffer ---

const LookbackBuffer = struct {
    entries: [][]const u8,
    capacity: usize,
    count: usize = 0,
    write_pos: usize = 0,

    fn init(allocator: std.mem.Allocator, requested_capacity: usize) !LookbackBuffer {
        const cap = @max(requested_capacity, 4);
        const entries = try allocator.alloc([]const u8, cap);
        @memset(entries, &.{});
        return .{ .entries = entries, .capacity = cap };
    }

    fn push(self: *LookbackBuffer, text: []const u8) void {
        self.entries[self.write_pos] = text;
        self.write_pos = (self.write_pos + 1) % self.capacity;
        if (self.count < self.capacity) self.count += 1;
    }

    fn contains(self: LookbackBuffer, text: []const u8) bool {
        const valid = @min(self.count, self.capacity);
        for (0..valid) |i| {
            // Read from oldest to newest
            const idx = if (self.count >= self.capacity)
                (self.write_pos + i) % self.capacity
            else
                i;
            if (std.mem.eql(u8, self.entries[idx], text)) return true;
        }
        return false;
    }

    /// Check if any of the last `window` entries matches any value in `values`.
    fn containsAny(self: LookbackBuffer, values: []const []const u8, window: usize) bool {
        const valid = @min(self.count, @min(window, self.capacity));
        for (0..valid) |i| {
            // Read from newest to oldest
            const idx = if (self.count >= self.capacity)
                (self.write_pos + self.capacity - 1 - i) % self.capacity
            else if (self.count > i)
                self.count - 1 - i
            else
                break;
            for (values) |val| {
                if (std.mem.eql(u8, self.entries[idx], val)) return true;
            }
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
fn patternMaxScore(sequence: []const loader.SequenceElement, weights: loader.EvidenceWeights) f32 {
    var total: f32 = 0.0;
    for (sequence) |elem| {
        total += switch (elem.matcher) {
            .keyword_literal => weights.keyword,
            .symbol_literal => weights.symbol,
            .identifier, .capture, .identifier_literal => weights.identifier,
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

/// Scans all patterns' constraints and returns the maximum depth value.
/// Used to size the LookbackBuffer dynamically based on grammar needs.
fn computeMaxConstraintDepth(patterns: []const loader.Pattern) usize {
    var max_depth: usize = 0;
    for (patterns) |p| {
        for (p.constraints) |c| {
            if (c.depth > max_depth) max_depth = c.depth;
        }
    }
    return max_depth;
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
    weights: loader.EvidenceWeights,
    allocator: std.mem.Allocator,
) ![]StructuralEvent {
    var result: std.ArrayList(StructuralEvent) = .empty;
    var pending_captures: std.ArrayList(CaptureEntry) = .empty;
    var matched_kinds: std.ArrayList(TokenKind) = .empty;
    var matched_texts: std.ArrayList([]const u8) = .empty;
    var matched_qualities: std.ArrayList(MatchResult) = .empty;
    var candidates: std.ArrayList(CandidateEvent) = .empty;

    const max_depth = computeMaxConstraintDepth(patterns);
    var lookback = try LookbackBuffer.init(allocator, max_depth);
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

        // Snapshot prev_token_text before updating for constraint evaluation
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
                    weights,
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
                            weights,
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
                        weights,
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

/// Evaluates all constraints on a pattern. Returns true if all pass, false if any rejects.
fn evaluateConstraints(
    pattern: loader.Pattern,
    pending_captures: []const CaptureEntry,
    match_start_prev_token: ?[]const u8,
    lookback: LookbackBuffer,
) bool {
    for (pattern.constraints) |constraint| {
        switch (constraint.type) {
            .not => {
                if (constraint.depth == 0) {
                    // Depth 0: check captured field value
                    if (constraint.field) |field_name| {
                        for (pending_captures) |cap| {
                            if (std.mem.eql(u8, cap.field_name, field_name)) {
                                for (constraint.values) |val| {
                                    if (std.mem.eql(u8, cap.value, val)) return false;
                                }
                                break;
                            }
                        }
                    }
                    // Field not found in captures → skip constraint (don't reject)
                } else if (constraint.depth == 1) {
                    // Depth 1: check immediately preceding token
                    if (match_start_prev_token) |prev_text| {
                        for (constraint.values) |val| {
                            if (std.mem.eql(u8, prev_text, val)) return false;
                        }
                    }
                    // No preceding token (start of stream) → pass
                } else {
                    // Depth 2..N: check lookback window
                    if (lookback.containsAny(constraint.values, constraint.depth)) return false;
                }
            },
        }
    }
    return true;
}

/// Checks constraints (position) and confidence,
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
    weights: loader.EvidenceWeights,
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

    // Unified constraint evaluation (replaces exclude + not_preceded_by)
    if (pattern) |p| {
        if (!evaluateConstraints(p, pending_captures.items, match_start_prev_token, lookback)) {
            return false;
        }
    }

    // Compute confidence
    const max_score = if (pattern) |p| patternMaxScore(p.sequence, weights) else 1.0;
    var matched_weights: f32 = 0.0;
    for (matched_kinds.items, matched_qualities.items) |kind, quality| {
        if (quality == .relaxed_match) {
            matched_weights += weights.relaxed_keyword;
        } else {
            matched_weights += switch (kind) {
                .keyword => weights.keyword,
                .identifier => weights.identifier,
                .delimiter, .symbol => weights.symbol,
                else => 0.0,
            };
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
    weights: loader.EvidenceWeights,
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
        weights,
        allocator,
    );
}

fn findPattern(patterns: []const loader.Pattern, type_name: []const u8) ?loader.Pattern {
    for (patterns) |p| {
        if (std.mem.eql(u8, p.type_name, type_name)) return p;
    }
    return null;
}

fn findPatternMaxScore(patterns: []const loader.Pattern, type_name: []const u8, weights: loader.EvidenceWeights) f32 {
    if (findPattern(patterns, type_name)) |p| return patternMaxScore(p.sequence, weights);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("call", result[0].type_name);
    try testing.expectEqualStrings("call", result[1].type_name);
}

// --- LookbackBuffer Unit Tests ---

test "LookbackBuffer: push/contains with fewer than 4 entries" {
    var lb = try LookbackBuffer.init(testing.allocator, 4);
    defer testing.allocator.free(lb.entries);
    lb.push("hello");
    lb.push("world");
    try testing.expect(lb.contains("hello"));
    try testing.expect(lb.contains("world"));
    try testing.expect(!lb.contains("missing"));
}

test "LookbackBuffer: circular overwrite after 4+ pushes" {
    var lb = try LookbackBuffer.init(testing.allocator, 4);
    defer testing.allocator.free(lb.entries);
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

test "LookbackBuffer: init enforces minimum capacity of 4" {
    const lb = try LookbackBuffer.init(testing.allocator, 1);
    defer testing.allocator.free(lb.entries);
    try testing.expectEqual(@as(usize, 4), lb.capacity);

    const lb2 = try LookbackBuffer.init(testing.allocator, 0);
    defer testing.allocator.free(lb2.entries);
    try testing.expectEqual(@as(usize, 4), lb2.capacity);
}

test "LookbackBuffer: init with capacity > 4" {
    var lb = try LookbackBuffer.init(testing.allocator, 8);
    defer testing.allocator.free(lb.entries);
    try testing.expectEqual(@as(usize, 8), lb.capacity);

    // Push 8 entries — all should be retained
    lb.push("a");
    lb.push("b");
    lb.push("c");
    lb.push("d");
    lb.push("e");
    lb.push("f");
    lb.push("g");
    lb.push("h");
    try testing.expect(lb.contains("a"));
    try testing.expect(lb.contains("h"));

    // Push one more — "a" should be overwritten
    lb.push("i");
    try testing.expect(!lb.contains("a"));
    try testing.expect(lb.contains("b"));
    try testing.expect(lb.contains("i"));
}

test "LookbackBuffer: containsAny checks last window entries" {
    var lb = try LookbackBuffer.init(testing.allocator, 4);
    defer testing.allocator.free(lb.entries);
    lb.push("a");
    lb.push("b");
    lb.push("c");
    lb.push("d");

    // Window of 2 should check last 2 entries: "c", "d"
    const values = &[_][]const u8{"a"};
    try testing.expect(!lb.containsAny(values, 2));

    const values2 = &[_][]const u8{"d"};
    try testing.expect(lb.containsAny(values2, 2));

    const values3 = &[_][]const u8{"c"};
    try testing.expect(lb.containsAny(values3, 2));

    // Window of 4 should check all entries
    try testing.expect(lb.containsAny(values, 4));
}

test "LookbackBuffer: containsAny with multiple values" {
    var lb = try LookbackBuffer.init(testing.allocator, 4);
    defer testing.allocator.free(lb.entries);
    lb.push("x");
    lb.push("y");
    lb.push("z");

    const values = &[_][]const u8{ "a", "b", "y" };
    try testing.expect(lb.containsAny(values, 3));

    const values2 = &[_][]const u8{ "a", "b", "c" };
    try testing.expect(!lb.containsAny(values2, 3));
}

test "LookbackBuffer: containsAny with window larger than count" {
    var lb = try LookbackBuffer.init(testing.allocator, 4);
    defer testing.allocator.free(lb.entries);
    lb.push("a");
    lb.push("b");

    // Window of 10 but only 2 entries — should check both
    const values = &[_][]const u8{"a"};
    try testing.expect(lb.containsAny(values, 10));
}

test "LookbackBuffer: containsAny with window of 0 matches nothing" {
    var lb = try LookbackBuffer.init(testing.allocator, 4);
    defer testing.allocator.free(lb.entries);
    lb.push("a");

    const values = &[_][]const u8{"a"};
    try testing.expect(!lb.containsAny(values, 0));
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

    const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
    try testing.expectEqual(@as(usize, 0), result.len);
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

    const result = try parse(automaton, tokens, source, patterns, .{ .open = "{", .close = "}" }, .{}, alloc);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
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
    const result = try parse(automaton, tokens, source, patterns, .{ .open = "{", .close = "}" }, .{}, alloc);
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

            const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
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

            const result = try parse(automaton, tokens.items, source, patterns, .{}, .{}, alloc);
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

            const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
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

            const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
            if (col == 0) {
                try testing.expectEqual(@as(usize, 1), result.len);
            } else {
                try testing.expectEqual(@as(usize, 0), result.len);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase3-multi-language-patterns, Property 5: Lookback buffer stores last N non-skip tokens
test "property: lookback buffer stores last N non-skip tokens" {
    const count_gen = gen.intRange(u8, 0, 10);

    try minish.check(testing.allocator, count_gen, struct {
        fn prop(num_tokens: u8) !void {
            const capacity: usize = 4;
            var lb = try LookbackBuffer.init(testing.allocator, capacity);
            defer testing.allocator.free(lb.entries);

            // Push num_tokens entries
            var expected: std.ArrayList([]const u8) = .empty;
            defer expected.deinit(testing.allocator);

            const names = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" };
            for (0..num_tokens) |i| {
                lb.push(names[i]);
                try expected.append(testing.allocator, names[i]);
            }

            // The buffer should contain the last min(count, capacity) entries
            const window_start = if (num_tokens > capacity) num_tokens - capacity else 0;
            for (window_start..num_tokens) |i| {
                try testing.expect(lb.contains(names[i]));
            }

            // Entries before the window should not be present (if overwritten)
            if (num_tokens > capacity) {
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
                const result = try parse(automaton, tokens, source, patterns, .{ .open = "{", .close = "}" }, .{}, alloc);
                try testing.expectEqual(@as(usize, 1), result.len);
                try testing.expectEqual(@as(?usize, 0), result[0].block_start);
            } else {
                // "foo(" — no block
                const source = "foo(";
                const tokens = &[_]Token{
                    .{ .kind = .identifier, .start = 0, .end = 3, .line = 1, .col = 0 },
                    .{ .kind = .delimiter, .start = 3, .end = 4, .line = 1, .col = 3 },
                };
                const result = try parse(automaton, tokens, source, patterns, .{ .open = "{", .close = "}" }, .{}, alloc);
                try testing.expectEqual(@as(usize, 1), result.len);
                try testing.expectEqual(@as(?usize, null), result[0].block_start);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// --- End-to-end integration tests: Erlang grammar ---

test "e2e: Erlang grammar still detects real function definitions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Load the actual Erlang grammar
    const file = try std.Io.Dir.cwd().openFile(testing.io, "examples/grammars/erlang.toml", .{});
    defer file.close(testing.io);
    var fbuf: [4096]u8 = undefined;
    var file_reader = file.reader(testing.io, &fbuf);
    const grammar_source = try file_reader.interface.allocRemaining(alloc, .unlimited);
    const grammar = try loader.parseGrammar(grammar_source, alloc);
    const automaton = try compiler.compile(grammar.patterns, alloc);

    // Erlang source: a real function definition at column 0
    const source = "handle_call(Request, From, State) ->\n    {reply, ok, State}.";
    const tokens = try tokenizer.tokenize(source, grammar.keyword_table, alloc);
    const events = try parse(automaton, tokens, source, grammar.patterns, grammar.blocks, grammar.weights, alloc);

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

            const full_result = try parse(automaton, full_tokens.items, source, patterns, .{}, .{}, alloc);
            const relaxed_result = try parse(automaton, relaxed_tokens.items, source, patterns, .{}, .{}, alloc);

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

            const result = try parse(automaton, tokens_list.items, source, patterns, .{}, .{}, alloc);
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
            const result = try parse(automaton, tokens_list.items, source, patterns, .{}, .{}, alloc);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
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

            const full_result = try parse(automaton, full_tokens.items, full_source, patterns, .{}, .{}, alloc);
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

            const partial_result = try parse(automaton, partial_tokens, partial_source, patterns, .{}, .{}, alloc);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
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

    const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
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

// --- Phase 5: Configurable Weights Tests ---

// Feature: probabilistic-confidence-scoring, Property 14: Custom weights flow through to confidence
// **Validates: Requirements 5.4**
test "property: custom weights flow through to confidence" {
    // Generate a random percentage (1-100) for the keyword weight
    const pct_gen = gen.intRange(u8, 1, 100);

    try minish.check(testing.allocator, pct_gen, struct {
        fn prop(pct: u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const custom_keyword_weight: f32 = @as(f32, @floatFromInt(pct)) / 100.0;

            // Skip if custom weight equals default (0.5) — confidence would be the same
            const default_keyword: f32 = 0.5;
            if (@abs(custom_keyword_weight - default_keyword) < 0.01) return;

            // Pattern: keyword + identifier + symbol
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

            // Run with default weights
            const default_weights = loader.EvidenceWeights{};
            const default_result = try parse(automaton, tokens, source, patterns, .{}, default_weights, alloc);

            // Run with custom weights (only keyword changed)
            const custom_weights = loader.EvidenceWeights{
                .keyword = custom_keyword_weight,
                .identifier = 0.2,
                .symbol = 0.2,
                .block = 0.3,
                .relaxed_keyword = 0.1,
            };
            const custom_result = try parse(automaton, tokens, source, patterns, .{}, custom_weights, alloc);

            // Both should produce exactly 1 event (full match → confidence = 1.0 in both cases
            // since matched_weights == max_score for full matches)
            try testing.expectEqual(@as(usize, 1), default_result.len);
            try testing.expectEqual(@as(usize, 1), custom_result.len);

            // For a full match, confidence is always 1.0 regardless of weights.
            // To see the difference, we need a relaxed match.
            // Use identifier kind for "fn" to get a relaxed match.
            const relaxed_tokens = &[_]Token{
                .{ .kind = .identifier, .start = 0, .end = 2, .line = 1, .col = 0 },
                .{ .kind = .identifier, .start = 3, .end = 6, .line = 1, .col = 3 },
                .{ .kind = .delimiter, .start = 6, .end = 7, .line = 1, .col = 6 },
            };

            const default_relaxed = try parse(automaton, relaxed_tokens, source, patterns, .{}, default_weights, alloc);
            const custom_relaxed = try parse(automaton, relaxed_tokens, source, patterns, .{}, custom_weights, alloc);

            try testing.expectEqual(@as(usize, 1), default_relaxed.len);
            try testing.expectEqual(@as(usize, 1), custom_relaxed.len);

            // With relaxed match, the keyword contributes relaxed_keyword weight (0.1) instead of keyword weight.
            // Default: matched = 0.1 + 0.2 + 0.2 = 0.5, max = 0.5 + 0.2 + 0.2 = 0.9, conf = 0.5/0.9
            // Custom:  matched = 0.1 + 0.2 + 0.2 = 0.5, max = custom_kw + 0.2 + 0.2, conf = 0.5/(custom_kw + 0.4)
            // Since custom_kw != 0.5, the max_score differs, so confidence differs.
            try testing.expect(default_relaxed[0].confidence != custom_relaxed[0].confidence);
        }
    }.prop, .{ .num_runs = 100 });
}

// --- Phase 5: Configurable Weights Unit Test (engine) ---

test "parse: custom weights produce different confidence than defaults for same pattern" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Pattern: keyword + identifier + symbol
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

    // Use relaxed match (identifier kind for "fn") so weights affect confidence
    const tokens = &[_]Token{
        .{ .kind = .identifier, .start = 0, .end = 2, .line = 1, .col = 0 },
        .{ .kind = .identifier, .start = 3, .end = 6, .line = 1, .col = 3 },
        .{ .kind = .delimiter, .start = 6, .end = 7, .line = 1, .col = 6 },
    };

    // Default weights: keyword=0.5, identifier=0.2, symbol=0.2, relaxed_keyword=0.1
    // Relaxed match: matched = 0.1 + 0.2 + 0.2 = 0.5, max = 0.5 + 0.2 + 0.2 = 0.9
    // confidence = 0.5 / 0.9 ≈ 0.556
    const default_result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
    try testing.expectEqual(@as(usize, 1), default_result.len);

    // Custom weights: keyword=0.8 (higher), rest same
    // Relaxed match: matched = 0.1 + 0.2 + 0.2 = 0.5, max = 0.8 + 0.2 + 0.2 = 1.2
    // confidence = 0.5 / 1.2 ≈ 0.417
    const custom_weights = loader.EvidenceWeights{
        .keyword = 0.8,
        .identifier = 0.2,
        .symbol = 0.2,
        .block = 0.3,
        .relaxed_keyword = 0.1,
    };
    const custom_result = try parse(automaton, tokens, source, patterns, .{}, custom_weights, alloc);
    try testing.expectEqual(@as(usize, 1), custom_result.len);

    // Confidence should differ
    try testing.expect(default_result[0].confidence != custom_result[0].confidence);

    // With higher keyword weight, the max_score is higher but matched stays the same,
    // so confidence should be lower with custom weights
    try testing.expect(custom_result[0].confidence < default_result[0].confidence);
}

// Feature: unified-constraint-system, Property 3: Depth-0 capture value filtering
// **Validates: Requirements 3.1, 3.2, 3.3, 3.5, 10.5**
test "property: depth-0 capture value filtering" {
    // Generate a random captured value and a random constraint value, plus a boolean
    // to decide whether the captured value should be in the constraint values list.
    const tuple_gen = comptime gen.tuple3(
        []const u8,
        []const u8,
        bool,
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        gen.boolean(),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { []const u8, []const u8, bool }) !void {
            const captured_value = vals[0];
            const constraint_value = vals[1];
            const should_match = vals[2];

            // Build the constraint values list:
            // If should_match is true, include the captured_value in the constraint values.
            // If should_match is false, use only constraint_value (which may or may not equal captured_value).
            const lookback = try LookbackBuffer.init(testing.allocator, 4);
            defer testing.allocator.free(lookback.entries);

            // Case 1: Captured value IS in constraint values → should reject (return false)
            if (should_match) {
                const constraint_values = &[_][]const u8{captured_value};
                const pattern = loader.Pattern{
                    .type_name = "test",
                    .sequence = &.{
                        .{ .matcher = .{ .keyword_literal = "fn" } },
                        .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } },
                    },
                    .captures = &.{.{ .field_name = "name", .position = 1 }},
                    .constraints = &.{.{
                        .type = .not,
                        .depth = 0,
                        .field = "name",
                        .values = constraint_values,
                    }},
                };

                const captures = &[_]CaptureEntry{.{
                    .field_name = "name",
                    .value = captured_value,
                }};

                // Req 3.1, 3.2: captured value matches constraint → reject
                const result = evaluateConstraints(pattern, captures, null, lookback);
                try testing.expect(!result);
            } else {
                // Case 2: Use constraint_value which may differ from captured_value
                const constraint_values = &[_][]const u8{constraint_value};
                const pattern = loader.Pattern{
                    .type_name = "test",
                    .sequence = &.{
                        .{ .matcher = .{ .keyword_literal = "fn" } },
                        .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } },
                    },
                    .captures = &.{.{ .field_name = "name", .position = 1 }},
                    .constraints = &.{.{
                        .type = .not,
                        .depth = 0,
                        .field = "name",
                        .values = constraint_values,
                    }},
                };

                const captures = &[_]CaptureEntry{.{
                    .field_name = "name",
                    .value = captured_value,
                }};

                const result = evaluateConstraints(pattern, captures, null, lookback);

                // Req 3.2, 3.3, 3.5: exact byte equality check
                const values_contain_capture = std.mem.eql(u8, captured_value, constraint_value);
                if (values_contain_capture) {
                    try testing.expect(!result); // reject
                } else {
                    try testing.expect(result); // allow
                }
            }

            // Case 3: Field name doesn't match any capture → skip constraint (allow)
            // Req 3.4: field not found in captures → skip without rejecting
            {
                const constraint_values = &[_][]const u8{captured_value};
                const pattern_no_field = loader.Pattern{
                    .type_name = "test",
                    .sequence = &.{
                        .{ .matcher = .{ .keyword_literal = "fn" } },
                        .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } },
                    },
                    .captures = &.{.{ .field_name = "name", .position = 1 }},
                    .constraints = &.{.{
                        .type = .not,
                        .depth = 0,
                        .field = "other_field",
                        .values = constraint_values,
                    }},
                };

                const captures = &[_]CaptureEntry{.{
                    .field_name = "name",
                    .value = captured_value,
                }};

                const result = evaluateConstraints(pattern_no_field, captures, null, lookback);
                try testing.expect(result); // should always pass when field doesn't match
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: unified-constraint-system, Property 4: Depth-1 preceding token constraint
// **Validates: Requirements 4.1, 4.2, 4.3**
test "property: depth-1 preceding token constraint" {
    // Generate a random preceding token text and a random constraint value, plus a boolean
    // to decide whether the preceding token should be in the constraint values list.
    const tuple_gen = comptime gen.tuple3(
        []const u8,
        []const u8,
        bool,
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        gen.boolean(),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { []const u8, []const u8, bool }) !void {
            const prev_token_text = vals[0];
            const constraint_value = vals[1];
            const should_match = vals[2];

            const lookback = try LookbackBuffer.init(testing.allocator, 4);
            defer testing.allocator.free(lookback.entries);

            const empty_captures = &[_]CaptureEntry{};

            // Case 1: Preceding token IS in constraint values → should reject (return false)
            if (should_match) {
                const constraint_values = &[_][]const u8{prev_token_text};
                const pattern = loader.Pattern{
                    .type_name = "test",
                    .sequence = &.{
                        .{ .matcher = .{ .keyword_literal = "fn" } },
                        .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } },
                    },
                    .captures = &.{.{ .field_name = "name", .position = 1 }},
                    .constraints = &.{.{
                        .type = .not,
                        .depth = 1,
                        .field = null,
                        .values = constraint_values,
                    }},
                };

                // Req 4.1, 4.2: preceding token matches constraint → reject
                const result = evaluateConstraints(pattern, empty_captures, prev_token_text, lookback);
                try testing.expect(!result);
            } else {
                // Case 2: Use constraint_value which may differ from prev_token_text
                const constraint_values = &[_][]const u8{constraint_value};
                const pattern = loader.Pattern{
                    .type_name = "test",
                    .sequence = &.{
                        .{ .matcher = .{ .keyword_literal = "fn" } },
                        .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } },
                    },
                    .captures = &.{.{ .field_name = "name", .position = 1 }},
                    .constraints = &.{.{
                        .type = .not,
                        .depth = 1,
                        .field = null,
                        .values = constraint_values,
                    }},
                };

                const result = evaluateConstraints(pattern, empty_captures, prev_token_text, lookback);

                // Req 4.1, 4.2: exact byte equality check
                const values_contain_prev = std.mem.eql(u8, prev_token_text, constraint_value);
                if (values_contain_prev) {
                    try testing.expect(!result); // reject
                } else {
                    try testing.expect(result); // allow
                }
            }

            // Case 3: No preceding token (null) → match should proceed (start of stream)
            // Req 4.3: no preceding token → allow
            {
                const constraint_values = &[_][]const u8{prev_token_text};
                const pattern_null_prev = loader.Pattern{
                    .type_name = "test",
                    .sequence = &.{
                        .{ .matcher = .{ .keyword_literal = "fn" } },
                        .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } },
                    },
                    .captures = &.{.{ .field_name = "name", .position = 1 }},
                    .constraints = &.{.{
                        .type = .not,
                        .depth = 1,
                        .field = null,
                        .values = constraint_values,
                    }},
                };

                const result = evaluateConstraints(pattern_null_prev, empty_captures, null, lookback);
                try testing.expect(result); // should always pass when no preceding token
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: unified-constraint-system, Property 5: Depth-N lookback window constraint
// **Validates: Requirements 5.1, 5.2**
test "property: depth-N lookback window constraint" {
    // Generate a random depth (2-8), a random constraint value string, and a boolean
    // to control whether the constraint value appears within the lookback window.
    const tuple_gen = comptime gen.tuple3(
        u8,
        []const u8,
        bool,
        gen.intRange(u8, 2, 8),
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        gen.boolean(),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { u8, []const u8, bool }) !void {
            const depth: u8 = vals[0];
            const constraint_value: []const u8 = vals[1];
            const value_in_window: bool = vals[2];

            const empty_captures = &[_]CaptureEntry{};

            // Case 1: Constraint value IS within the last N tokens → should reject
            if (value_in_window) {
                var lookback = try LookbackBuffer.init(testing.allocator, depth);
                defer testing.allocator.free(lookback.entries);

                // Push some filler tokens, then push the constraint value within the window
                // Push (depth - 1) filler tokens first, then the constraint value
                for (0..@as(usize, depth) - 1) |_| {
                    lookback.push("filler");
                }
                lookback.push(constraint_value);

                const constraint_values = &[_][]const u8{constraint_value};
                const pattern = loader.Pattern{
                    .type_name = "test",
                    .sequence = &.{
                        .{ .matcher = .{ .keyword_literal = "fn" } },
                        .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } },
                    },
                    .captures = &.{.{ .field_name = "name", .position = 1 }},
                    .constraints = &.{.{
                        .type = .not,
                        .depth = depth,
                        .field = null,
                        .values = constraint_values,
                    }},
                };

                // Req 5.1, 5.2: value in last N tokens → reject
                const result = evaluateConstraints(pattern, empty_captures, null, lookback);
                try testing.expect(!result);
            } else {
                // Case 2: Constraint value is NOT within the last N tokens → should allow
                var lookback = try LookbackBuffer.init(testing.allocator, depth);
                defer testing.allocator.free(lookback.entries);

                // Push exactly depth tokens of filler (none matching constraint_value)
                // Use a filler that is guaranteed different from constraint_value
                const filler = "zzz_no_match";
                for (0..@as(usize, depth)) |_| {
                    lookback.push(filler);
                }

                const constraint_values = &[_][]const u8{constraint_value};
                const pattern = loader.Pattern{
                    .type_name = "test",
                    .sequence = &.{
                        .{ .matcher = .{ .keyword_literal = "fn" } },
                        .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } },
                    },
                    .captures = &.{.{ .field_name = "name", .position = 1 }},
                    .constraints = &.{.{
                        .type = .not,
                        .depth = depth,
                        .field = null,
                        .values = constraint_values,
                    }},
                };

                // Req 5.1, 5.2: value NOT in last N tokens → allow
                const result = evaluateConstraints(pattern, empty_captures, null, lookback);

                // The filler is "zzz_no_match" which is guaranteed different from
                // constraint_value (alpha charset, max 8 chars, min 1 char).
                // However, if constraint_value happens to equal "zzz_no_match",
                // the test would be wrong. Since constraint_value is alpha charset
                // with max 8 chars, and "zzz_no_match" is 12 chars, this can't happen.
                try testing.expect(result);
            }

            // Case 3: Value pushed OUTSIDE the window (more than N tokens ago) → should allow
            {
                // Use a larger buffer so we can push the value then push enough
                // filler to push it outside the window
                const buf_cap = @as(usize, depth) + 4;
                var lookback_outside = try LookbackBuffer.init(testing.allocator, buf_cap);
                defer testing.allocator.free(lookback_outside.entries);

                // Push the constraint value first
                lookback_outside.push(constraint_value);

                // Then push exactly `depth` filler tokens to push it outside the window
                for (0..@as(usize, depth)) |_| {
                    lookback_outside.push("other_token");
                }

                const constraint_values = &[_][]const u8{constraint_value};
                const pattern_outside = loader.Pattern{
                    .type_name = "test",
                    .sequence = &.{
                        .{ .matcher = .{ .keyword_literal = "fn" } },
                        .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } },
                    },
                    .captures = &.{.{ .field_name = "name", .position = 1 }},
                    .constraints = &.{.{
                        .type = .not,
                        .depth = depth,
                        .field = null,
                        .values = constraint_values,
                    }},
                };

                // Value was pushed depth+1 tokens ago, outside the window of depth tokens
                // "other_token" is 11 chars, constraint_value is alpha max 8 chars → no collision
                const result = evaluateConstraints(pattern_outside, empty_captures, null, lookback_outside);
                try testing.expect(result);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: unified-constraint-system, Property 6: Dynamic LookbackBuffer capacity
// **Validates: Requirements 5.3, 5.4, 5.5**
test "property: dynamic LookbackBuffer capacity" {
    // Generate three random depth values (0-20) representing constraint depths
    // on 1-3 patterns. We test that computeMaxConstraintDepth returns the max,
    // and LookbackBuffer.init allocates capacity = @max(max_depth, 4).
    const tuple_gen = comptime gen.tuple3(
        u8,
        u8,
        u8,
        gen.intRange(u8, 0, 20),
        gen.intRange(u8, 0, 20),
        gen.intRange(u8, 0, 20),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { u8, u8, u8 }) !void {
            const depth1: u8 = vals[0];
            const depth2: u8 = vals[1];
            const depth3: u8 = vals[2];

            const max_depth = @max(depth1, @max(depth2, depth3));
            const expected_capacity = @max(@as(usize, max_depth), 4);

            // Dummy values slice for constraints
            const dummy_values = &[_][]const u8{"x"};

            // Build three patterns, each with one constraint at the respective depth.
            // depth=0 constraints require a field, depth>0 constraints must not have a field.
            const constraint1 = loader.Constraint{
                .type = .not,
                .depth = depth1,
                .field = if (depth1 == 0) "name" else null,
                .values = dummy_values,
            };
            const constraint2 = loader.Constraint{
                .type = .not,
                .depth = depth2,
                .field = if (depth2 == 0) "name" else null,
                .values = dummy_values,
            };
            const constraint3 = loader.Constraint{
                .type = .not,
                .depth = depth3,
                .field = if (depth3 == 0) "name" else null,
                .values = dummy_values,
            };

            const constraints1 = &[_]loader.Constraint{constraint1};
            const constraints2 = &[_]loader.Constraint{constraint2};
            const constraints3 = &[_]loader.Constraint{constraint3};

            const dummy_seq = &[_]loader.SequenceElement{
                .{ .matcher = .{ .keyword_literal = "fn" } },
            };

            const patterns = &[_]loader.Pattern{
                .{
                    .type_name = "p1",
                    .sequence = dummy_seq,
                    .captures = &.{},
                    .constraints = constraints1,
                },
                .{
                    .type_name = "p2",
                    .sequence = dummy_seq,
                    .captures = &.{},
                    .constraints = constraints2,
                },
                .{
                    .type_name = "p3",
                    .sequence = dummy_seq,
                    .captures = &.{},
                    .constraints = constraints3,
                },
            };

            // Req 5.3: computeMaxConstraintDepth returns the maximum depth across all constraints
            const computed_max = computeMaxConstraintDepth(patterns);
            try testing.expectEqual(@as(usize, max_depth), computed_max);

            // Req 5.4, 5.5: LookbackBuffer capacity = @max(max_depth, 4)
            const lookback = try LookbackBuffer.init(testing.allocator, computed_max);
            defer testing.allocator.free(lookback.entries);
            try testing.expectEqual(expected_capacity, lookback.capacity);

            // Verify minimum capacity of 4 when all depths are small
            if (max_depth < 4) {
                try testing.expectEqual(@as(usize, 4), lookback.capacity);
            } else {
                try testing.expectEqual(@as(usize, max_depth), lookback.capacity);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// --- Unified Constraint System: Engine Unit Tests ---
// These unit tests complement the property tests (Properties 3-6) with specific
// examples that directly call evaluateConstraints and exercise the full parse pipeline.

// Requirement 10.2: Engine unit tests for unified constraint checks
// Requirement 10.5: Depth-0 capture filtering unit test

test "evaluateConstraints: depth-0 rejects when captured value matches" {
    const lookback = try LookbackBuffer.init(testing.allocator, 4);
    defer testing.allocator.free(lookback.entries);

    const pattern = loader.Pattern{
        .type_name = "method",
        .sequence = &.{
            .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 0 } } },
            .{ .matcher = .{ .symbol_literal = "(" } },
        },
        .captures = &.{.{ .field_name = "name", .position = 0 }},
        .constraints = &.{.{
            .type = .not,
            .depth = 0,
            .field = "name",
            .values = &.{ "print", "RegExp" },
        }},
    };

    const captures = &[_]CaptureEntry{.{ .field_name = "name", .value = "print" }};
    const result = evaluateConstraints(pattern, captures, null, lookback);
    try testing.expect(!result); // rejected because "print" is in values
}

test "evaluateConstraints: depth-0 allows when captured value does not match" {
    const lookback = try LookbackBuffer.init(testing.allocator, 4);
    defer testing.allocator.free(lookback.entries);

    const pattern = loader.Pattern{
        .type_name = "method",
        .sequence = &.{
            .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 0 } } },
            .{ .matcher = .{ .symbol_literal = "(" } },
        },
        .captures = &.{.{ .field_name = "name", .position = 0 }},
        .constraints = &.{.{
            .type = .not,
            .depth = 0,
            .field = "name",
            .values = &.{ "print", "RegExp" },
        }},
    };

    const captures = &[_]CaptureEntry{.{ .field_name = "name", .value = "myFunc" }};
    const result = evaluateConstraints(pattern, captures, null, lookback);
    try testing.expect(result); // allowed because "myFunc" is not in values
}

test "evaluateConstraints: depth-0 skips when field not found in captures" {
    const lookback = try LookbackBuffer.init(testing.allocator, 4);
    defer testing.allocator.free(lookback.entries);

    const pattern = loader.Pattern{
        .type_name = "method",
        .sequence = &.{
            .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 0 } } },
            .{ .matcher = .{ .symbol_literal = "(" } },
        },
        .captures = &.{.{ .field_name = "name", .position = 0 }},
        .constraints = &.{.{
            .type = .not,
            .depth = 0,
            .field = "callee", // field "callee" doesn't exist in captures
            .values = &.{"print"},
        }},
    };

    const captures = &[_]CaptureEntry{.{ .field_name = "name", .value = "print" }};
    const result = evaluateConstraints(pattern, captures, null, lookback);
    try testing.expect(result); // allowed because field "callee" not found — constraint skipped
}

test "evaluateConstraints: depth-1 rejects when preceding token matches" {
    const lookback = try LookbackBuffer.init(testing.allocator, 4);
    defer testing.allocator.free(lookback.entries);

    const pattern = loader.Pattern{
        .type_name = "function",
        .sequence = &.{
            .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 0 } } },
            .{ .matcher = .{ .symbol_literal = "(" } },
        },
        .captures = &.{.{ .field_name = "name", .position = 0 }},
        .constraints = &.{.{
            .type = .not,
            .depth = 1,
            .field = null,
            .values = &.{ "fun", "=" },
        }},
    };

    const captures = &[_]CaptureEntry{.{ .field_name = "name", .value = "add" }};
    const result = evaluateConstraints(pattern, captures, "fun", lookback);
    try testing.expect(!result); // rejected because preceding token "fun" is in values
}

test "evaluateConstraints: depth-1 passes at start of stream (null prev token)" {
    const lookback = try LookbackBuffer.init(testing.allocator, 4);
    defer testing.allocator.free(lookback.entries);

    const pattern = loader.Pattern{
        .type_name = "function",
        .sequence = &.{
            .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 0 } } },
            .{ .matcher = .{ .symbol_literal = "(" } },
        },
        .captures = &.{.{ .field_name = "name", .position = 0 }},
        .constraints = &.{.{
            .type = .not,
            .depth = 1,
            .field = null,
            .values = &.{ "fun", "=" },
        }},
    };

    const captures = &[_]CaptureEntry{.{ .field_name = "name", .value = "add" }};
    const result = evaluateConstraints(pattern, captures, null, lookback);
    try testing.expect(result); // allowed because no preceding token (start of stream)
}

test "evaluateConstraints: depth-N rejects when lookback contains matching token" {
    var lookback = try LookbackBuffer.init(testing.allocator, 4);
    defer testing.allocator.free(lookback.entries);

    // Simulate a token history: ["-spec", "foo", "bar"]
    lookback.push("-spec");
    lookback.push("foo");
    lookback.push("bar");

    const pattern = loader.Pattern{
        .type_name = "function",
        .sequence = &.{
            .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 0 } } },
            .{ .matcher = .{ .symbol_literal = "(" } },
        },
        .captures = &.{.{ .field_name = "name", .position = 0 }},
        .constraints = &.{.{
            .type = .not,
            .depth = 4,
            .field = null,
            .values = &.{ "-spec", "-type" },
        }},
    };

    const captures = &[_]CaptureEntry{.{ .field_name = "name", .value = "add" }};
    const result = evaluateConstraints(pattern, captures, null, lookback);
    try testing.expect(!result); // rejected because "-spec" is in the lookback window
}

test "evaluateConstraints: multiple constraints short-circuit on first rejection" {
    const lookback = try LookbackBuffer.init(testing.allocator, 4);
    defer testing.allocator.free(lookback.entries);

    // Pattern with two constraints:
    // 1. depth=0: reject if captured name is "print"
    // 2. depth=1: reject if preceding token is "fun"
    // If the first constraint rejects, the second is never evaluated (short-circuit).
    const pattern = loader.Pattern{
        .type_name = "method",
        .sequence = &.{
            .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 0 } } },
            .{ .matcher = .{ .symbol_literal = "(" } },
        },
        .captures = &.{.{ .field_name = "name", .position = 0 }},
        .constraints = &.{
            .{
                .type = .not,
                .depth = 0,
                .field = "name",
                .values = &.{"print"},
            },
            .{
                .type = .not,
                .depth = 1,
                .field = null,
                .values = &.{"fun"},
            },
        },
    };

    // Captured value "print" matches first constraint → rejected immediately
    const captures = &[_]CaptureEntry{.{ .field_name = "name", .value = "print" }};
    const result = evaluateConstraints(pattern, captures, "something_else", lookback);
    try testing.expect(!result); // rejected by first constraint (depth-0)

    // Now test that both constraints must pass for the match to proceed
    const captures2 = &[_]CaptureEntry{.{ .field_name = "name", .value = "myFunc" }};
    const result2 = evaluateConstraints(pattern, captures2, "fun", lookback);
    try testing.expect(!result2); // first constraint passes, second rejects (preceding "fun")

    // Both constraints pass
    const captures3 = &[_]CaptureEntry{.{ .field_name = "name", .value = "myFunc" }};
    const result3 = evaluateConstraints(pattern, captures3, "something_else", lookback);
    try testing.expect(result3); // both constraints pass → allowed
}

test "parse: combined position + constraints evaluation order" {
    // Position is checked BEFORE constraints. A pattern with position = "start"
    // at col > 0 should be rejected by position check, never reaching constraint evaluation.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]loader.Pattern{.{
        .type_name = "function",
        .sequence = &.{
            .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 0 } } },
            .{ .matcher = .{ .symbol_literal = "(" } },
        },
        .captures = &.{.{ .field_name = "name", .position = 0 }},
        .position = .start,
        .constraints = &.{.{
            .type = .not,
            .depth = 0,
            .field = "name",
            .values = &.{"print"},
        }},
    }};

    const automaton = try compiler.compile(patterns, alloc);

    // Case 1: col > 0, captured value NOT in constraint values
    // Position check rejects → no event emitted (constraint never evaluated)
    {
        const source = "  myFunc(";
        const tokens = &[_]Token{
            .{ .kind = .identifier, .start = 2, .end = 8, .line = 1, .col = 2 },
            .{ .kind = .delimiter, .start = 8, .end = 9, .line = 1, .col = 8 },
        };
        const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
        try testing.expectEqual(@as(usize, 0), result.len); // rejected by position
    }

    // Case 2: col = 0, captured value IS in constraint values
    // Position check passes, constraint rejects → no event emitted
    {
        const source = "print(";
        const tokens = &[_]Token{
            .{ .kind = .identifier, .start = 0, .end = 5, .line = 1, .col = 0 },
            .{ .kind = .delimiter, .start = 5, .end = 6, .line = 1, .col = 5 },
        };
        const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
        try testing.expectEqual(@as(usize, 0), result.len); // rejected by constraint
    }

    // Case 3: col = 0, captured value NOT in constraint values
    // Both position and constraint pass → event emitted
    {
        const source = "myFunc(";
        const tokens = &[_]Token{
            .{ .kind = .identifier, .start = 0, .end = 6, .line = 1, .col = 0 },
            .{ .kind = .delimiter, .start = 6, .end = 7, .line = 1, .col = 6 },
        };
        const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
        try testing.expectEqual(@as(usize, 1), result.len); // both checks pass
        try testing.expectEqualStrings("function", result[0].type_name);
    }
}
