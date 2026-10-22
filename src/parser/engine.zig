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
            .number => weights.symbol,
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
// Uses buffered emission for competing pattern evaluation: when a terminal
// state is reached, the candidate is buffered and matching continues to find
// longer matches. The best candidate is emitted when the automaton resets.
// INVARIANT: buffering a terminal candidate SHALL NOT flush the region or
// reset the state while we advance a match from a fixed pattern_start (state
// never returns to 0); the region flushes only at a true reset, a new match
// start, a post-buffer constraint rejection, or end-of-stream.
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
    // End offset (exclusive) of the most recently matched sequence token.
    // A region spans the matched tokens only: a candidate buffered at a terminal
    // reached by skipping optionals ends here, not at the non-matching token
    // that triggered the skip (keeps optional-tail and union forms equivalent).
    var last_matched_end: usize = 0;

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
            last_matched_end = token.end;

            if (step_result.capture) |cap| {
                try pending_captures.append(allocator, .{
                    .field_name = cap.field_name,
                    .value = cap.value,
                });
            }

            // Check terminal state
            if (automaton.states[state].events.len > 0) {
                var any_buffered = false;
                for (automaton.states[state].events) |event_info| {
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
                        last_matched_end,
                        weights,
                        allocator,
                    );
                    if (buffered) any_buffered = true;
                }

                if (!any_buffered) {
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

                // INVARIANT (same-type-pattern-union): while the automaton
                // advances a match from a fixed pattern_start (state never
                // returns to 0), buffering a terminal candidate SHALL NOT flush
                // the region or reset the state. The region flushes only at a
                // true reset, a new independent match start, a post-buffer
                // constraint rejection, or end-of-stream. Keep advancing so a
                // longer same-start alternative (prefix case) can buffer too;
                // if this terminal has no outgoing transitions, the next token
                // fails to match and we flush then.
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
                    if (automaton.states[skip_state].events.len > 0) {
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
                        last_matched_end = token.end;

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
                    last_matched_end = token.end;

                    if (retry_result.capture) |cap| {
                        try pending_captures.append(allocator, .{
                            .field_name = cap.field_name,
                            .value = cap.value,
                        });
                    }

                    // Check if this immediately reaches a terminal state
                    if (automaton.states[state].events.len > 0) {
                        var any_buffered = false;
                        for (automaton.states[state].events) |event_info| {
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
                                last_matched_end,
                                weights,
                                allocator,
                            );
                            if (buffered) any_buffered = true;
                        }

                        if (!any_buffered) {
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
                if (automaton.states[state].events.len > 0) {
                    var any_buffered = false;
                    for (automaton.states[state].events) |event_info| {
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
                            last_matched_end,
                            weights,
                            allocator,
                        );
                        if (buffered) any_buffered = true;
                    }

                    if (!any_buffered) {
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

                    // INVARIANT: same as the main terminal path — a successfully
                    // buffered candidate (optionals skipped) does NOT reset or
                    // flush; keep matching for a longer alternative from this
                    // same pattern_start.
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
    last_matched_end: usize,
    weights: loader.EvidenceWeights,
    allocator: std.mem.Allocator,
) !bool {
    const pattern: ?loader.Pattern = if (event_info.pattern_index < patterns.len)
        patterns[event_info.pattern_index]
    else
        findPattern(patterns, event_info.type_name);

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

    // Build event captures from pattern definition using matched token texts
    var event_captures: std.ArrayList(CaptureEntry) = .empty;
    if (pattern) |p| {
        for (p.captures) |cap| {
            if (cap.position < matched_texts.items.len) {
                try event_captures.append(allocator, .{
                    .field_name = cap.field_name,
                    .value = matched_texts.items[cap.position],
                });
            }
        }
    } else {
        for (pending_captures.items) |cap| {
            try event_captures.append(allocator, cap);
        }
    }

    // Unified constraint evaluation (replaces exclude + not_preceded_by)
    if (pattern) |p| {
        if (!evaluateConstraints(p, event_captures.items, match_start_prev_token, lookback)) {
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
                .delimiter, .symbol, .operator => weights.symbol,
                .number => weights.symbol,
                else => 0.0,
            };
        }
    }
    const confidence = events_mod.computeConfidence(matched_weights, max_score, 0, events_mod.default_noise_penalty_per_token, events_mod.default_max_noise_penalty);

    if (confidence < 0.3) {
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

    const event = StructuralEvent{
        .type_name = event_info.type_name,
        .captures = try event_captures.toOwnedSlice(allocator),
        .start = pattern_start,
        .end = last_matched_end,
        .line = pattern_line,
        .col = pattern_col,
        .confidence = confidence,
        .block_start = block_stack.top(),
    };

    try candidates.append(allocator, .{
        .event = event,
        .match_length = matched_kinds.items.len,
        .pattern_index = event_info.pattern_index,
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
    last_matched_end: usize,
    weights: loader.EvidenceWeights,
    allocator: std.mem.Allocator,
) !bool {
    const pattern = if (event_info.pattern_index < patterns.len)
        patterns[event_info.pattern_index]
    else
        findPattern(patterns, event_info.type_name);

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
        last_matched_end,
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
    const tokens = try tokenizer.tokenize(source, grammar.keyword_table, grammar.comments, alloc);
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

// Feature: identical-sequence-pattern-shadowing, Property 1: Bug Condition - Identical-Sequence Patterns Shadowing
// **Validates: Requirements 1.1, 1.2, 1.3, 1.4, 2.1, 2.2, 2.3, 2.4, 2.5**
test "property: identical-sequence patterns coexist and route correctly" {
    const tuple_gen = comptime gen.tuple3(
        []const u8,
        []const u8,
        u16,
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        gen.intRange(u16, 1, 10),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { []const u8, []const u8, u16 }) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const fn_name = vals[0];
            const call_name = vals[1];
            const indent_val: usize = @intCast(vals[2]);

            // Two colliding patterns sharing identical sequence: IDENTIFIER "("
            // Pattern 0: function with position = "start"
            // Pattern 1: call without position
            const patterns = &[_]loader.Pattern{
                .{
                    .type_name = "function",
                    .sequence = &.{
                        .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 0 } } },
                        .{ .matcher = .{ .symbol_literal = "(" } },
                    },
                    .captures = &.{.{ .field_name = "name", .position = 0 }},
                    .position = .start,
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

            const automaton = try compiler.compile(patterns, alloc);

            // Construct source: "fn_name(\n" + indent spaces + "call_name("
            const indent_spaces = try alloc.alloc(u8, indent_val);
            @memset(indent_spaces, ' ');
            const source = try std.fmt.allocPrint(alloc, "{s}(\n{s}{s}(", .{ fn_name, indent_spaces, call_name });

            const line1_len = fn_name.len + 2; // "fn_name(\n"
            const call_start = line1_len + indent_val;
            const tokens = &[_]Token{
                .{ .kind = .identifier, .start = 0, .end = fn_name.len, .line = 1, .col = 0 },
                .{ .kind = .delimiter, .start = fn_name.len, .end = fn_name.len + 1, .line = 1, .col = fn_name.len },
                .{ .kind = .newline, .start = fn_name.len + 1, .end = line1_len, .line = 1, .col = fn_name.len + 1 },
                .{ .kind = .identifier, .start = call_start, .end = call_start + call_name.len, .line = 2, .col = indent_val },
                .{ .kind = .delimiter, .start = call_start + call_name.len, .end = call_start + call_name.len + 1, .line = 2, .col = indent_val + call_name.len },
            };

            const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);

            // Expected behavior (Property 1):
            // Both patterns coexist and route correctly:
            // 1. Column-0 foo( routes to "function"
            // 2. Indented bar( routes to "call"
            var fn_count: usize = 0;
            var call_count: usize = 0;
            for (result) |ev| {
                if (std.mem.eql(u8, ev.type_name, "function")) {
                    fn_count += 1;
                    try testing.expect(ev.captures.len > 0);
                    try testing.expectEqualStrings("name", ev.captures[0].field_name);
                    try testing.expectEqualStrings(fn_name, ev.captures[0].value);
                } else if (std.mem.eql(u8, ev.type_name, "call")) {
                    call_count += 1;
                    try testing.expect(ev.captures.len > 0);
                    try testing.expectEqualStrings("callee", ev.captures[0].field_name);
                    try testing.expectEqualStrings(call_name, ev.captures[0].value);
                }
            }

            try testing.expectEqual(@as(usize, 1), fn_count);
            try testing.expectEqual(@as(usize, 1), call_count);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: identical-sequence-pattern-shadowing, Property 2: Preservation - Non-colliding grammars event stream is preserved
// **Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5**
test "preservation: non-colliding grammars event stream is preserved" {
    const ident_gen = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha });

    try minish.check(testing.allocator, ident_gen, struct {
        fn prop(name: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // Two non-colliding patterns with distinct terminal sequences:
            // "fn" <name> "(" => function
            // "struct" <name> "{" => struct_def
            const patterns = &[_]loader.Pattern{
                .{
                    .type_name = "function",
                    .sequence = &.{
                        .{ .matcher = .{ .keyword_literal = "fn" } },
                        .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } },
                        .{ .matcher = .{ .symbol_literal = "(" } },
                    },
                    .captures = &.{.{ .field_name = "name", .position = 1 }},
                },
                .{
                    .type_name = "struct_def",
                    .sequence = &.{
                        .{ .matcher = .{ .keyword_literal = "struct" } },
                        .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } },
                        .{ .matcher = .{ .symbol_literal = "{" } },
                    },
                    .captures = &.{.{ .field_name = "name", .position = 1 }},
                },
            };

            const automaton = try compiler.compile(patterns, alloc);

            const source = try std.fmt.allocPrint(alloc, "fn {s}(\nstruct {s}{{", .{ name, name });
            const fn_len = 3 + name.len + 1; // "fn name("
            const tokens = &[_]Token{
                .{ .kind = .keyword, .start = 0, .end = 2, .line = 1, .col = 0 },
                .{ .kind = .identifier, .start = 3, .end = 3 + name.len, .line = 1, .col = 3 },
                .{ .kind = .delimiter, .start = 3 + name.len, .end = fn_len, .line = 1, .col = 3 + name.len },
                .{ .kind = .newline, .start = fn_len, .end = fn_len + 1, .line = 1, .col = fn_len },
                .{ .kind = .keyword, .start = fn_len + 1, .end = fn_len + 7, .line = 2, .col = 0 },
                .{ .kind = .identifier, .start = fn_len + 8, .end = fn_len + 8 + name.len, .line = 2, .col = 7 },
                .{ .kind = .delimiter, .start = fn_len + 8 + name.len, .end = fn_len + 9 + name.len, .line = 2, .col = 7 + name.len },
            };

            const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);

            try testing.expectEqual(@as(usize, 2), result.len);
            try testing.expectEqualStrings("function", result[0].type_name);
            try testing.expectEqual(@as(usize, 1), result[0].captures.len);
            try testing.expectEqualStrings("name", result[0].captures[0].field_name);
            try testing.expectEqualStrings(name, result[0].captures[0].value);
            try testing.expectEqual(@as(usize, 1), result[0].line);
            try testing.expectEqual(@as(usize, 0), result[0].col);
            try testing.expect(result[0].confidence >= 0.99);

            try testing.expectEqualStrings("struct_def", result[1].type_name);
            try testing.expectEqual(@as(usize, 1), result[1].captures.len);
            try testing.expectEqualStrings("name", result[1].captures[0].field_name);
            try testing.expectEqualStrings(name, result[1].captures[0].value);
            try testing.expectEqual(@as(usize, 2), result[1].line);
            try testing.expectEqual(@as(usize, 0), result[1].col);
            try testing.expect(result[1].confidence >= 0.99);
        }
    }.prop, .{ .num_runs = 100 });
}

test "preservation: single function pattern grammar event stream" {
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
        .position = .start,
    }};

    const automaton = try compiler.compile(patterns, alloc);
    const source = "fn compute(";
    const tokens = &[_]Token{
        .{ .kind = .keyword, .start = 0, .end = 2, .line = 1, .col = 0 },
        .{ .kind = .identifier, .start = 3, .end = 10, .line = 1, .col = 3 },
        .{ .kind = .delimiter, .start = 10, .end = 11, .line = 1, .col = 10 },
    };

    const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("function", result[0].type_name);
    try testing.expectEqual(@as(usize, 1), result[0].captures.len);
    try testing.expectEqualStrings("name", result[0].captures[0].field_name);
    try testing.expectEqualStrings("compute", result[0].captures[0].value);
    try testing.expectEqual(@as(usize, 1), result[0].line);
    try testing.expectEqual(@as(usize, 0), result[0].col);
    try testing.expect(result[0].confidence >= 0.99);
}

test "parse: function vs call colliding grammar emits function for col 0 and call for indented" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]loader.Pattern{
        .{
            .type_name = "function",
            .sequence = &.{
                .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 0 } } },
                .{ .matcher = .{ .symbol_literal = "(" } },
            },
            .captures = &.{.{ .field_name = "name", .position = 0 }},
            .position = .start,
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

    const automaton = try compiler.compile(patterns, alloc);

    const source =
        \\foo()
        \\  bar()
        \\baz()
        \\    qux()
    ;
    const tokens = &[_]Token{
        .{ .kind = .identifier, .start = 0, .end = 3, .line = 1, .col = 0 },
        .{ .kind = .delimiter, .start = 3, .end = 4, .line = 1, .col = 3 },
        .{ .kind = .delimiter, .start = 4, .end = 5, .line = 1, .col = 4 },
        .{ .kind = .newline, .start = 5, .end = 6, .line = 1, .col = 5 },

        .{ .kind = .identifier, .start = 8, .end = 11, .line = 2, .col = 2 },
        .{ .kind = .delimiter, .start = 11, .end = 12, .line = 2, .col = 5 },
        .{ .kind = .delimiter, .start = 12, .end = 13, .line = 2, .col = 6 },
        .{ .kind = .newline, .start = 13, .end = 14, .line = 2, .col = 7 },

        .{ .kind = .identifier, .start = 14, .end = 17, .line = 3, .col = 0 },
        .{ .kind = .delimiter, .start = 17, .end = 18, .line = 3, .col = 3 },
        .{ .kind = .delimiter, .start = 18, .end = 19, .line = 3, .col = 4 },
        .{ .kind = .newline, .start = 19, .end = 20, .line = 3, .col = 5 },

        .{ .kind = .identifier, .start = 24, .end = 27, .line = 4, .col = 4 },
        .{ .kind = .delimiter, .start = 27, .end = 28, .line = 4, .col = 7 },
        .{ .kind = .delimiter, .start = 28, .end = 29, .line = 4, .col = 8 },
    };

    const result = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
    try testing.expectEqual(@as(usize, 4), result.len);

    try testing.expectEqualStrings("function", result[0].type_name);
    try testing.expectEqualStrings("foo", result[0].captures[0].value);
    try testing.expectEqual(@as(usize, 0), result[0].col);

    try testing.expectEqualStrings("call", result[1].type_name);
    try testing.expectEqualStrings("bar", result[1].captures[0].value);
    try testing.expectEqual(@as(usize, 2), result[1].col);

    try testing.expectEqualStrings("function", result[2].type_name);
    try testing.expectEqualStrings("baz", result[2].captures[0].value);
    try testing.expectEqual(@as(usize, 0), result[2].col);

    try testing.expectEqualStrings("call", result[3].type_name);
    try testing.expectEqualStrings("qux", result[3].captures[0].value);
    try testing.expectEqual(@as(usize, 4), result[3].col);
}

test "parse: --node function on colliding grammar filters to only function heads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const patterns = &[_]loader.Pattern{
        .{
            .type_name = "function",
            .sequence = &.{
                .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 0 } } },
                .{ .matcher = .{ .symbol_literal = "(" } },
            },
            .captures = &.{.{ .field_name = "name", .position = 0 }},
            .position = .start,
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

    const automaton = try compiler.compile(patterns, alloc);

    const source =
        \\ann()
        \\  call_site()
        \\compute()
    ;
    const tokens = &[_]Token{
        .{ .kind = .identifier, .start = 0, .end = 3, .line = 1, .col = 0 },
        .{ .kind = .delimiter, .start = 3, .end = 4, .line = 1, .col = 3 },
        .{ .kind = .delimiter, .start = 4, .end = 5, .line = 1, .col = 4 },
        .{ .kind = .newline, .start = 5, .end = 6, .line = 1, .col = 5 },

        .{ .kind = .identifier, .start = 8, .end = 17, .line = 2, .col = 2 },
        .{ .kind = .delimiter, .start = 17, .end = 18, .line = 2, .col = 11 },
        .{ .kind = .delimiter, .start = 18, .end = 19, .line = 2, .col = 12 },
        .{ .kind = .newline, .start = 19, .end = 20, .line = 2, .col = 13 },

        .{ .kind = .identifier, .start = 20, .end = 27, .line = 3, .col = 0 },
        .{ .kind = .delimiter, .start = 27, .end = 28, .line = 3, .col = 7 },
        .{ .kind = .delimiter, .start = 28, .end = 29, .line = 3, .col = 8 },
    };

    const all_events = try parse(automaton, tokens, source, patterns, .{}, .{}, alloc);
    try testing.expectEqual(@as(usize, 3), all_events.len);

    // Filter by node type "function"
    var fn_events: std.ArrayList(StructuralEvent) = .empty;
    for (all_events) |ev| {
        if (std.mem.eql(u8, ev.type_name, "function")) {
            try fn_events.append(alloc, ev);
        }
    }

    try testing.expectEqual(@as(usize, 2), fn_events.items.len);
    try testing.expectEqualStrings("ann", fn_events.items[0].captures[0].value);
    try testing.expectEqualStrings("compute", fn_events.items[1].captures[0].value);
}

// --- Same-Type Pattern Union: shared test helpers ---

const TestTokenItem = struct {
    kind: TokenKind,
    text: []const u8,
};

const StreamBuilt = struct {
    source: []const u8,
    tokens: []Token,
};

/// Builds a single-line source string and matching token list from items.
fn buildStream(alloc: std.mem.Allocator, items: []const TestTokenItem) !StreamBuilt {
    var total: usize = 0;
    for (items) |it| total += it.text.len;
    const source = try alloc.alloc(u8, total);
    var pos: usize = 0;
    for (items) |it| {
        @memcpy(source[pos..][0..it.text.len], it.text);
        pos += it.text.len;
    }
    const tokens = try alloc.alloc(Token, items.len);
    var offset: usize = 0;
    for (items, 0..) |it, i| {
        tokens[i] = .{
            .kind = it.kind,
            .start = offset,
            .end = offset + it.text.len,
            .line = 1,
            .col = offset,
        };
        offset += it.text.len;
    }
    return .{ .source = source, .tokens = tokens };
}

const SEP_ITEM = TestTokenItem{ .kind = .symbol, .text = ";" };
const LPAREN_ITEM = TestTokenItem{ .kind = .delimiter, .text = "(" };

fn kwItem(text: []const u8) TestTokenItem {
    return .{ .kind = .keyword, .text = text };
}

fn idItem(text: []const u8) TestTokenItem {
    return .{ .kind = .identifier, .text = text };
}

fn setKwCaptureSeq(seq: *[2]loader.SequenceElement, kw: []const u8, field: []const u8) void {
    seq[0] = .{ .matcher = .{ .keyword_literal = kw } };
    seq[1] = .{ .matcher = .{ .capture = .{ .field_name = field, .position = 1 } } };
}

fn setKwCaptureParenSeq(seq: *[3]loader.SequenceElement, kw: []const u8, field: []const u8) void {
    seq[0] = .{ .matcher = .{ .keyword_literal = kw } };
    seq[1] = .{ .matcher = .{ .capture = .{ .field_name = field, .position = 1 } } };
    seq[2] = .{ .matcher = .{ .symbol_literal = "(" } };
}

fn setKwCaptureOptParenSeq(seq: *[3]loader.SequenceElement, kw: []const u8, field: []const u8) void {
    seq[0] = .{ .matcher = .{ .keyword_literal = kw } };
    seq[1] = .{ .matcher = .{ .capture = .{ .field_name = field, .position = 1 } } };
    seq[2] = .{ .matcher = .{ .symbol_literal = "(" }, .is_optional = true };
}

fn setSingleCaptureSeq(seq: *[1]loader.SequenceElement, field: []const u8) void {
    seq[0] = .{ .matcher = .{ .capture = .{ .field_name = field, .position = 0 } } };
}

fn distinctStrings(a: []const u8, b: []const u8) bool {
    return !std.mem.eql(u8, a, b);
}

// Feature: same-type-pattern-union, Property 1: Union membership emits the shared type
// **Validates: Requirements 1.1, 1.2**
test "property: union membership emits the shared type" {
    const P1Input = struct {
        shared_type: []const u8,
        kw_a: []const u8,
        kw_b: []const u8,
        kw_c: []const u8,
    };
    const p1_gen = gen.structure(P1Input, .{
        .shared_type = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        .kw_a = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        .kw_b = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        .kw_c = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
    });

    try minish.check(testing.allocator, p1_gen, struct {
        fn prop(inp: P1Input) !void {
            const shared_type = inp.shared_type;
            const kw_a = inp.kw_a;
            const kw_b = inp.kw_b;
            const kw_c = inp.kw_c;
            if (!distinctStrings(kw_a, kw_b) or
                !distinctStrings(kw_a, kw_c) or
                !distinctStrings(kw_b, kw_c)) return;

            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            var seq_a: [2]loader.SequenceElement = undefined;
            var seq_b: [2]loader.SequenceElement = undefined;
            var seq_c: [2]loader.SequenceElement = undefined;
            setKwCaptureSeq(&seq_a, kw_a, "a");
            setKwCaptureSeq(&seq_b, kw_b, "b");
            setKwCaptureSeq(&seq_c, kw_c, "c");

            const patterns = &[_]loader.Pattern{
                .{ .type_name = shared_type, .sequence = &seq_a, .captures = &.{.{ .field_name = "a", .position = 1 } } },
                .{ .type_name = shared_type, .sequence = &seq_b, .captures = &.{.{ .field_name = "b", .position = 1 } } },
                .{ .type_name = shared_type, .sequence = &seq_c, .captures = &.{.{ .field_name = "c", .position = 1 } } },
            };
            const automaton = try compiler.compile(patterns, alloc);

            var items: std.ArrayList(TestTokenItem) = .empty;
            try items.append(alloc, kwItem(kw_a));
            try items.append(alloc, idItem("va"));
            try items.append(alloc, SEP_ITEM);
            try items.append(alloc, kwItem(kw_b));
            try items.append(alloc, idItem("vb"));
            try items.append(alloc, SEP_ITEM);
            try items.append(alloc, kwItem(kw_c));
            try items.append(alloc, idItem("vc"));
            const stream = try buildStream(alloc, items.items);

            const result = try parse(automaton, stream.tokens, stream.source, patterns, .{}, .{}, alloc);
            try testing.expectEqual(@as(usize, 3), result.len);

            const Expected = struct { field: []const u8, value: []const u8 };
            const expected = [_]Expected{
                .{ .field = "a", .value = "va" },
                .{ .field = "b", .value = "vb" },
                .{ .field = "c", .value = "vc" },
            };
            for (result, expected) |ev, exp| {
                try testing.expectEqualStrings(shared_type, ev.type_name);
                try testing.expectEqual(@as(usize, 1), ev.captures.len);
                try testing.expectEqualStrings(exp.field, ev.captures[0].field_name);
                try testing.expectEqualStrings(exp.value, ev.captures[0].value);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: same-type-pattern-union, Property 2: Disjoint same-type alternatives each emit,
// carrying the matched alternative's captures
// **Validates: Requirements 2.1, 2.2**
test "property: disjoint same-type alternatives emit, carrying the matched alternative's captures" {
    const P2Input = struct {
        shared_type: []const u8,
        kw_a: []const u8,
        kw_b: []const u8,
        cap_a: []const u8,
        cap_b: []const u8,
    };
    const p2_gen = gen.structure(P2Input, .{
        .shared_type = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        .kw_a = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        .kw_b = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        .cap_a = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        .cap_b = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
    });

    try minish.check(testing.allocator, p2_gen, struct {
        fn prop(inp: P2Input) !void {
            if (!distinctStrings(inp.kw_a, inp.kw_b)) return;

            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            var seq_a: [2]loader.SequenceElement = undefined;
            var seq_b: [2]loader.SequenceElement = undefined;
            setKwCaptureSeq(&seq_a, inp.kw_a, "a");
            setKwCaptureSeq(&seq_b, inp.kw_b, "b");

            const patterns = &[_]loader.Pattern{
                .{ .type_name = inp.shared_type, .sequence = &seq_a, .captures = &.{.{ .field_name = "a", .position = 1 } } },
                .{ .type_name = inp.shared_type, .sequence = &seq_b, .captures = &.{.{ .field_name = "b", .position = 1 } } },
            };
            const automaton = try compiler.compile(patterns, alloc);

            var items: std.ArrayList(TestTokenItem) = .empty;
            try items.append(alloc, kwItem(inp.kw_a));
            try items.append(alloc, idItem(inp.cap_a));
            try items.append(alloc, SEP_ITEM);
            try items.append(alloc, kwItem(inp.kw_b));
            try items.append(alloc, idItem(inp.cap_b));
            const stream = try buildStream(alloc, items.items);

            const result = try parse(automaton, stream.tokens, stream.source, patterns, .{}, .{}, alloc);
            try testing.expectEqual(@as(usize, 2), result.len);

            try testing.expectEqualStrings(inp.shared_type, result[0].type_name);
            try testing.expectEqual(@as(usize, 1), result[0].captures.len);
            try testing.expectEqualStrings("a", result[0].captures[0].field_name);
            try testing.expectEqualStrings(inp.cap_a, result[0].captures[0].value);

            try testing.expectEqualStrings(inp.shared_type, result[1].type_name);
            try testing.expectEqual(@as(usize, 1), result[1].captures.len);
            try testing.expectEqualStrings("b", result[1].captures[0].field_name);
            try testing.expectEqualStrings(inp.cap_b, result[1].captures[0].value);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: same-type-pattern-union, Property 3: Prefix longest-wins
// **Validates: Requirements 3.4, 4.1, 4.2, 4.3**
test "property: prefix longest-wins" {
    const P3Input = struct {
        kw: []const u8,
        value: []const u8,
        same_type: bool,
    };
    const p3_gen = gen.structure(P3Input, .{
        .kw = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        .value = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        .same_type = gen.boolean(),
    });

    try minish.check(testing.allocator, p3_gen, struct {
        fn prop(inp: P3Input) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const type_short = if (inp.same_type) "union" else "short";
            const type_long = if (inp.same_type) "union" else "long";

            var seq_a: [2]loader.SequenceElement = undefined;
            var seq_b: [3]loader.SequenceElement = undefined;
            setKwCaptureSeq(&seq_a, inp.kw, "name");
            setKwCaptureParenSeq(&seq_b, inp.kw, "name");

            const patterns = &[_]loader.Pattern{
                .{ .type_name = type_short, .sequence = &seq_a, .captures = &.{.{ .field_name = "name", .position = 1 } } },
                .{ .type_name = type_long, .sequence = &seq_b, .captures = &.{.{ .field_name = "name", .position = 1 } } },
            };
            const automaton = try compiler.compile(patterns, alloc);

            var items: std.ArrayList(TestTokenItem) = .empty;
            try items.append(alloc, kwItem(inp.kw));
            try items.append(alloc, idItem(inp.value));
            try items.append(alloc, LPAREN_ITEM);
            const stream = try buildStream(alloc, items.items);

            const result = try parse(automaton, stream.tokens, stream.source, patterns, .{}, .{}, alloc);
            // Longer form B matches: exactly one primary spanning B (through "("), never a
            // separate shorter primary ending at A's span.
            try testing.expectEqual(@as(usize, 1), result.len);
            try testing.expectEqualStrings(type_long, result[0].type_name);
            try testing.expectEqual(@as(usize, 0), result[0].start);
            try testing.expectEqual(stream.tokens[2].end, result[0].end);
            try testing.expectEqual(@as(usize, 1), result[0].captures.len);
            try testing.expectEqualStrings("name", result[0].captures[0].field_name);
            try testing.expectEqualStrings(inp.value, result[0].captures[0].value);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: same-type-pattern-union, Property 4: Prefix short-only emits the shorter
// **Validates: Requirements 4.4**
test "property: prefix short-only emits the shorter" {
    const P4Input = struct {
        kw: []const u8,
        value: []const u8,
        same_type: bool,
    };
    const p4_gen = gen.structure(P4Input, .{
        .kw = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        .value = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        .same_type = gen.boolean(),
    });

    try minish.check(testing.allocator, p4_gen, struct {
        fn prop(inp: P4Input) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const type_short = if (inp.same_type) "union" else "short";
            const type_long = if (inp.same_type) "union" else "long";

            var seq_a: [2]loader.SequenceElement = undefined;
            var seq_b: [3]loader.SequenceElement = undefined;
            setKwCaptureSeq(&seq_a, inp.kw, "name");
            setKwCaptureParenSeq(&seq_b, inp.kw, "name");

            const patterns = &[_]loader.Pattern{
                .{ .type_name = type_short, .sequence = &seq_a, .captures = &.{.{ .field_name = "name", .position = 1 } } },
                .{ .type_name = type_long, .sequence = &seq_b, .captures = &.{.{ .field_name = "name", .position = 1 } } },
            };
            const automaton = try compiler.compile(patterns, alloc);

            var items: std.ArrayList(TestTokenItem) = .empty;
            try items.append(alloc, kwItem(inp.kw));
            try items.append(alloc, idItem(inp.value));
            try items.append(alloc, SEP_ITEM);
            const stream = try buildStream(alloc, items.items);

            const result = try parse(automaton, stream.tokens, stream.source, patterns, .{}, .{}, alloc);
            // Only the shorter form matches: exactly one primary covering A's span.
            try testing.expectEqual(@as(usize, 1), result.len);
            try testing.expectEqualStrings(type_short, result[0].type_name);
            try testing.expectEqual(@as(usize, 0), result[0].start);
            try testing.expectEqual(stream.tokens[1].end, result[0].end);
            try testing.expectEqualStrings(inp.value, result[0].captures[0].value);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: same-type-pattern-union, Property 5: Non-overlapping matches are independent
// **Validates: Requirements 5.1, 5.2**
test "property: non-overlapping matches are independent" {
    const P5Input = struct {
        count: u8,
        kw: []const u8,
    };
    const p5_gen = gen.structure(P5Input, .{
        .count = gen.intRange(u8, 1, 5),
        .kw = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
    });

    try minish.check(testing.allocator, p5_gen, struct {
        fn prop(inp: P5Input) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            var seq: [2]loader.SequenceElement = undefined;
            setKwCaptureSeq(&seq, inp.kw, "name");
            const patterns = &[_]loader.Pattern{.{
                .type_name = "unit",
                .sequence = &seq,
                .captures = &.{.{ .field_name = "name", .position = 1 }},
            }};
            const automaton = try compiler.compile(patterns, alloc);

            var items: std.ArrayList(TestTokenItem) = .empty;
            for (0..inp.count) |_| {
                try items.append(alloc, kwItem(inp.kw));
                try items.append(alloc, idItem("x"));
                try items.append(alloc, SEP_ITEM);
            }
            const stream = try buildStream(alloc, items.items);

            const result = try parse(automaton, stream.tokens, stream.source, patterns, .{}, .{}, alloc);
            try testing.expectEqual(@as(usize, inp.count), result.len);
            for (result, 0..) |ev, i| {
                try testing.expectEqual(stream.tokens[3 * i].start, ev.start);
                try testing.expectEqualStrings("unit", ev.type_name);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: same-type-pattern-union, Property 6: Optional-tail and union forms yield equivalent primaries
// **Validates: Requirements 6.1, 6.2, 6.3**
test "property: optional-tail and union forms yield equivalent primaries" {
    const P6Input = struct {
        kw: []const u8,
        value: []const u8,
    };
    const p6_gen = gen.structure(P6Input, .{
        .kw = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        .value = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
    });

    try minish.check(testing.allocator, p6_gen, struct {
        fn prop(inp: P6Input) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // Optional-tail grammar: [kw, capture, "("?]
            var seq_opt: [3]loader.SequenceElement = undefined;
            setKwCaptureOptParenSeq(&seq_opt, inp.kw, "name");
            const opt_patterns = &[_]loader.Pattern{.{
                .type_name = "decl",
                .sequence = &seq_opt,
                .captures = &.{.{ .field_name = "name", .position = 1 }},
            }};
            const opt_automaton = try compiler.compile(opt_patterns, alloc);

            // Union grammar: [kw, capture] and [kw, capture, "("] sharing one type
            var seq_a: [2]loader.SequenceElement = undefined;
            var seq_b: [3]loader.SequenceElement = undefined;
            setKwCaptureSeq(&seq_a, inp.kw, "name");
            setKwCaptureParenSeq(&seq_b, inp.kw, "name");
            const union_patterns = &[_]loader.Pattern{
                .{ .type_name = "decl", .sequence = &seq_a, .captures = &.{.{ .field_name = "name", .position = 1 } } },
                .{ .type_name = "decl", .sequence = &seq_b, .captures = &.{.{ .field_name = "name", .position = 1 } } },
            };
            const union_automaton = try compiler.compile(union_patterns, alloc);

            // Short shape: [kw, value, SEP]; long shape: [kw, value, "("]
            const shapes = [_]struct { items: [3]TestTokenItem, label: []const u8 }{
                .{ .items = .{ kwItem(inp.kw), idItem(inp.value), SEP_ITEM }, .label = "short" },
                .{ .items = .{ kwItem(inp.kw), idItem(inp.value), LPAREN_ITEM }, .label = "long" },
            };

            for (shapes) |shape| {
                const stream = try buildStream(alloc, shape.items[0..]);
                const union_result = try parse(union_automaton, stream.tokens, stream.source, union_patterns, .{}, .{}, alloc);
                const opt_result = try parse(opt_automaton, stream.tokens, stream.source, opt_patterns, .{}, .{}, alloc);

                try testing.expectEqual(@as(usize, 1), union_result.len);
                try testing.expectEqual(@as(usize, 1), opt_result.len);
                try testing.expectEqualStrings("decl", union_result[0].type_name);
                try testing.expectEqualStrings("decl", opt_result[0].type_name);
                try testing.expectEqual(union_result[0].start, opt_result[0].start);
                try testing.expectEqual(union_result[0].end, opt_result[0].end);
                try testing.expectEqual(union_result[0].captures.len, opt_result[0].captures.len);
                try testing.expectEqualStrings(union_result[0].captures[0].field_name, opt_result[0].captures[0].field_name);
                try testing.expectEqualStrings(union_result[0].captures[0].value, opt_result[0].captures[0].value);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: same-type-pattern-union, Property 7: Different-type overlap collapses to one tiebreak-selected primary
// **Validates: Requirements 3.1, 3.2, 3.3, 3.5, 4.5**
test "property: different-type overlap collapses to one tiebreak-selected primary" {
    const P7Input = struct {
        kw: []const u8,
        value: []const u8,
        same_type: bool,
        relax: u8, // 0 = none, 1 = relax the shared first keyword, 2 = relax B's trailing keyword
    };
    const p7_gen = gen.structure(P7Input, .{
        .kw = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        .value = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        .same_type = gen.boolean(),
        .relax = gen.intRange(u8, 0, 2),
    });

    try minish.check(testing.allocator, p7_gen, struct {
        fn prop(inp: P7Input) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const type_short = if (inp.same_type) "overlap" else "short";
            const type_long = if (inp.same_type) "overlap" else "long";

            // A = [kw, capture]; B = [kw, capture, keyword_literal "?"] (A is a strict prefix).
            // B's trailing keyword can be relaxed by tokenizing it as an identifier.
            var seq_a: [2]loader.SequenceElement = undefined;
            var seq_b: [3]loader.SequenceElement = undefined;
            setKwCaptureSeq(&seq_a, inp.kw, "name");
            seq_b[0] = .{ .matcher = .{ .keyword_literal = inp.kw } };
            seq_b[1] = .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } };
            seq_b[2] = .{ .matcher = .{ .keyword_literal = "?" } };

            const patterns = &[_]loader.Pattern{
                .{ .type_name = type_short, .sequence = &seq_a, .captures = &.{.{ .field_name = "name", .position = 1 } } },
                .{ .type_name = type_long, .sequence = &seq_b, .captures = &.{.{ .field_name = "name", .position = 1 } } },
            };
            const automaton = try compiler.compile(patterns, alloc);

            var items: std.ArrayList(TestTokenItem) = .empty;
            if (inp.relax == 1) {
                try items.append(alloc, idItem(inp.kw));
            } else {
                try items.append(alloc, kwItem(inp.kw));
            }
            try items.append(alloc, idItem(inp.value));
            if (inp.relax == 2) {
                try items.append(alloc, idItem("?"));
            } else {
                try items.append(alloc, kwItem("?"));
            }
            const stream = try buildStream(alloc, items.items);

            const result = try parse(automaton, stream.tokens, stream.source, patterns, .{}, .{}, alloc);
            try testing.expectEqual(@as(usize, 1), result.len);

            // Expected winner by Tiebreak_Order (confidence → length → grammar order):
            // - no relaxation: both full, equal confidence → longest (B)
            // - shared first keyword relaxed: A below 1.0 → B (higher confidence)
            // - B's trailing keyword relaxed: B below 1.0 → A (higher confidence, despite shorter)
            const expected_type = switch (inp.relax) {
                2 => type_short,
                else => type_long,
            };
            try testing.expectEqualStrings(expected_type, result[0].type_name);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: same-type-pattern-union, Property 8: Backward compatibility for non-overlapping,
// non-prefix grammars (Requirement 9.1, 9.2, 1.4). The single-pass O(N) step count is not
// observable through the public parse() API; the loop structurally visits each token once
// (no backtracking) as reviewed in the implementation.
test "property: backward compatibility for non-overlapping, non-prefix grammars" {
    const P8Input = struct {
        kw_a: []const u8,
        kw_b: []const u8,
        cap_a: []const u8,
        cap_b: []const u8,
    };
    const p8_gen = gen.structure(P8Input, .{
        .kw_a = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        .kw_b = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        .cap_a = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        .cap_b = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
    });

    try minish.check(testing.allocator, p8_gen, struct {
        fn prop(inp: P8Input) !void {
            if (!distinctStrings(inp.kw_a, inp.kw_b)) return;
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // Distinct types per pattern: identical to pre-feature behavior.
            var seq_a: [2]loader.SequenceElement = undefined;
            var seq_b: [2]loader.SequenceElement = undefined;
            setKwCaptureSeq(&seq_a, inp.kw_a, "name");
            setKwCaptureSeq(&seq_b, inp.kw_b, "other");
            const patterns = &[_]loader.Pattern{
                .{ .type_name = "type_a", .sequence = &seq_a, .captures = &.{.{ .field_name = "name", .position = 1 } } },
                .{ .type_name = "type_b", .sequence = &seq_b, .captures = &.{.{ .field_name = "other", .position = 1 } } },
            };
            const automaton = try compiler.compile(patterns, alloc);

            var items: std.ArrayList(TestTokenItem) = .empty;
            try items.append(alloc, kwItem(inp.kw_a));
            try items.append(alloc, idItem(inp.cap_a));
            try items.append(alloc, SEP_ITEM);
            try items.append(alloc, kwItem(inp.kw_b));
            try items.append(alloc, idItem(inp.cap_b));
            const stream = try buildStream(alloc, items.items);

            const result = try parse(automaton, stream.tokens, stream.source, patterns, .{}, .{}, alloc);
            try testing.expectEqual(@as(usize, 2), result.len);
            try testing.expectEqualStrings("type_a", result[0].type_name);
            try testing.expectEqualStrings("name", result[0].captures[0].field_name);
            try testing.expectEqualStrings(inp.cap_a, result[0].captures[0].value);
            try testing.expectEqual(stream.tokens[0].start, result[0].start);
            try testing.expectEqual(stream.tokens[1].end, result[0].end);
            try testing.expectEqualStrings("type_b", result[1].type_name);
            try testing.expectEqualStrings("other", result[1].captures[0].field_name);
            try testing.expectEqualStrings(inp.cap_b, result[1].captures[0].value);
            try testing.expectEqual(stream.tokens[3].start, result[1].start);
            try testing.expectEqual(stream.tokens[4].end, result[1].end);
        }
    }.prop, .{ .num_runs = 100 });
}

// Requirement 1.4: a one-pattern type behaves identically to the pre-feature engine.
test "property: single-pattern grammar emits identically to pre-feature" {
    const P8BInput = struct {
        kw: []const u8,
        value: []const u8,
    };
    const p8b_gen = gen.structure(P8BInput, .{
        .kw = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        .value = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
    });
    try minish.check(testing.allocator, p8b_gen, struct {
        fn prop(inp: P8BInput) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            var seq: [2]loader.SequenceElement = undefined;
            setKwCaptureSeq(&seq, inp.kw, "name");
            const patterns = &[_]loader.Pattern{.{
                .type_name = "single",
                .sequence = &seq,
                .captures = &.{.{ .field_name = "name", .position = 1 }},
            }};
            const automaton = try compiler.compile(patterns, alloc);

            var items: std.ArrayList(TestTokenItem) = .empty;
            try items.append(alloc, kwItem(inp.kw));
            try items.append(alloc, idItem(inp.value));
            try items.append(alloc, SEP_ITEM);
            try items.append(alloc, kwItem(inp.kw));
            try items.append(alloc, idItem(inp.value));
            const stream = try buildStream(alloc, items.items);

            const result = try parse(automaton, stream.tokens, stream.source, patterns, .{}, .{}, alloc);
            try testing.expectEqual(@as(usize, 2), result.len);
            for (result) |ev| {
                try testing.expectEqualStrings("single", ev.type_name);
                try testing.expectEqualStrings("name", ev.captures[0].field_name);
                try testing.expectEqualStrings(inp.value, ev.captures[0].value);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: same-type-pattern-union, Property 9: Identical-sequence union coexists via the shadowing fix
// **Validates: Requirements 8.1, 8.2, 8.3**
test "property: identical-sequence union coexists via the shadowing fix" {
    const v_gen = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha });
    try minish.check(testing.allocator, v_gen, struct {
        fn prop(value: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            var seq_a: [1]loader.SequenceElement = undefined;
            var seq_b: [1]loader.SequenceElement = undefined;
            setSingleCaptureSeq(&seq_a, "a");
            setSingleCaptureSeq(&seq_b, "b");

            const patterns = &[_]loader.Pattern{
                .{ .type_name = "same", .sequence = &seq_a, .captures = &.{.{ .field_name = "a", .position = 0 } } },
                .{ .type_name = "same", .sequence = &seq_b, .captures = &.{.{ .field_name = "b", .position = 0 } } },
            };
            const automaton = try compiler.compile(patterns, alloc);
            const term = automaton.states[1];
            try testing.expectEqual(@as(usize, 2), term.events.len);
            try testing.expectEqual(@as(usize, 0), term.events[0].pattern_index);
            try testing.expectEqual(@as(usize, 1), term.events[1].pattern_index);
            try testing.expectEqualStrings("same", term.events[0].type_name);
            try testing.expectEqualStrings("same", term.events[1].type_name);

            const items = [_]TestTokenItem{idItem(value)};
            const stream = try buildStream(alloc, &items);
            const result = try parse(automaton, stream.tokens, stream.source, patterns, .{}, .{}, alloc);
            // One event of the shared type; tiebreak picks grammar order (index 0 → field "a").
            try testing.expectEqual(@as(usize, 1), result.len);
            try testing.expectEqualStrings("same", result[0].type_name);
            try testing.expectEqual(@as(usize, 1), result[0].captures.len);
            try testing.expectEqualStrings("a", result[0].captures[0].field_name);
            try testing.expectEqualStrings(value, result[0].captures[0].value);
        }
    }.prop, .{ .num_runs = 100 });
}

// --- Same-Type Pattern Union: unit tests (concrete examples and edge cases) ---

test "parse: prefix pair emits the long form once on long input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var seq_a: [2]loader.SequenceElement = undefined;
    var seq_b: [3]loader.SequenceElement = undefined;
    setKwCaptureSeq(&seq_a, "fn", "name");
    setKwCaptureParenSeq(&seq_b, "fn", "name");
    const patterns = &[_]loader.Pattern{
        .{ .type_name = "decl", .sequence = &seq_a, .captures = &.{.{ .field_name = "name", .position = 1 } } },
        .{ .type_name = "decl", .sequence = &seq_b, .captures = &.{.{ .field_name = "name", .position = 1 } } },
    };
    const automaton = try compiler.compile(patterns, alloc);

    const items = [_]TestTokenItem{ kwItem("fn"), idItem("add"), LPAREN_ITEM };
    const stream = try buildStream(alloc, &items);
    const result = try parse(automaton, stream.tokens, stream.source, patterns, .{}, .{}, alloc);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("decl", result[0].type_name);
    try testing.expectEqual(@as(usize, 0), result[0].start);
    try testing.expectEqual(stream.tokens[2].end, result[0].end);
    try testing.expectEqualStrings("add", result[0].captures[0].value);
}

test "parse: prefix pair emits the short form on short input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var seq_a: [2]loader.SequenceElement = undefined;
    var seq_b: [3]loader.SequenceElement = undefined;
    setKwCaptureSeq(&seq_a, "fn", "name");
    setKwCaptureParenSeq(&seq_b, "fn", "name");
    const patterns = &[_]loader.Pattern{
        .{ .type_name = "decl", .sequence = &seq_a, .captures = &.{.{ .field_name = "name", .position = 1 } } },
        .{ .type_name = "decl", .sequence = &seq_b, .captures = &.{.{ .field_name = "name", .position = 1 } } },
    };
    const automaton = try compiler.compile(patterns, alloc);

    const items = [_]TestTokenItem{ kwItem("fn"), idItem("add"), SEP_ITEM };
    const stream = try buildStream(alloc, &items);
    const result = try parse(automaton, stream.tokens, stream.source, patterns, .{}, .{}, alloc);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("decl", result[0].type_name);
    try testing.expectEqual(@as(usize, 0), result[0].start);
    try testing.expectEqual(stream.tokens[1].end, result[0].end);
    try testing.expectEqualStrings("add", result[0].captures[0].value);
}

test "parse: same-type union with disjoint first tokens emits the shared type for each form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var seq_a: [2]loader.SequenceElement = undefined;
    var seq_b: [2]loader.SequenceElement = undefined;
    setKwCaptureSeq(&seq_a, "def", "name");
    setKwCaptureSeq(&seq_b, "class", "name");
    const patterns = &[_]loader.Pattern{
        .{ .type_name = "thing", .sequence = &seq_a, .captures = &.{.{ .field_name = "name", .position = 1 } } },
        .{ .type_name = "thing", .sequence = &seq_b, .captures = &.{.{ .field_name = "name", .position = 1 } } },
    };
    const automaton = try compiler.compile(patterns, alloc);

    const items = [_]TestTokenItem{ kwItem("def"), idItem("x"), SEP_ITEM, kwItem("class"), idItem("y") };
    const stream = try buildStream(alloc, &items);
    const result = try parse(automaton, stream.tokens, stream.source, patterns, .{}, .{}, alloc);
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("thing", result[0].type_name);
    try testing.expectEqualStrings("x", result[0].captures[0].value);
    try testing.expectEqualStrings("thing", result[1].type_name);
    try testing.expectEqualStrings("y", result[1].captures[0].value);
}

test "parse: constraint-rejected terminal candidate does not produce a premature shorter primary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A = [kw, capture] with a depth-0 constraint rejecting the captured value "bad".
    // B = [kw, capture, "("] — the longer same-start alternative.
    var seq_a: [2]loader.SequenceElement = undefined;
    var seq_b: [3]loader.SequenceElement = undefined;
    setKwCaptureSeq(&seq_a, "fn", "name");
    setKwCaptureParenSeq(&seq_b, "fn", "name");
    const patterns = &[_]loader.Pattern{
        .{
            .type_name = "decl",
            .sequence = &seq_a,
            .captures = &.{.{ .field_name = "name", .position = 1 }},
            .constraints = &.{.{
                .type = .not,
                .depth = 0,
                .field = "name",
                .values = &.{"bad"},
            }},
        },
        .{ .type_name = "decl", .sequence = &seq_b, .captures = &.{.{ .field_name = "name", .position = 1 } } },
    };
    const automaton = try compiler.compile(patterns, alloc);

    // Input "fn bad (" — A's constraint rejects the captured "bad" at A's terminal, so the
    // region aborts: neither a shorter primary nor B is emitted for this start.
    const items = [_]TestTokenItem{ kwItem("fn"), idItem("bad"), LPAREN_ITEM };
    const stream = try buildStream(alloc, &items);
    const result = try parse(automaton, stream.tokens, stream.source, patterns, .{}, .{}, alloc);
    try testing.expectEqual(@as(usize, 0), result.len);

    // Input "fn good (" — B matches fully and wins as the longer alternative.
    const items2 = [_]TestTokenItem{ kwItem("fn"), idItem("good"), LPAREN_ITEM };
    const stream2 = try buildStream(alloc, &items2);
    const result2 = try parse(automaton, stream2.tokens, stream2.source, patterns, .{}, .{}, alloc);
    try testing.expectEqual(@as(usize, 1), result2.len);
    try testing.expectEqualStrings("decl", result2[0].type_name);
    try testing.expectEqualStrings("good", result2[0].captures[0].value);
}

test "parse: arbitrary non-language type strings are treated opaquely" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var seq_a: [2]loader.SequenceElement = undefined;
    var seq_b: [2]loader.SequenceElement = undefined;
    setKwCaptureSeq(&seq_a, "alpha", "name");
    setKwCaptureSeq(&seq_b, "beta", "name");
    const patterns = &[_]loader.Pattern{
        .{ .type_name = "xyzzy", .sequence = &seq_a, .captures = &.{.{ .field_name = "name", .position = 1 } } },
        .{ .type_name = "42type", .sequence = &seq_b, .captures = &.{.{ .field_name = "name", .position = 1 } } },
    };
    const automaton = try compiler.compile(patterns, alloc);

    const items = [_]TestTokenItem{ kwItem("alpha"), idItem("a"), SEP_ITEM, kwItem("beta"), idItem("b") };
    const stream = try buildStream(alloc, &items);
    const result = try parse(automaton, stream.tokens, stream.source, patterns, .{}, .{}, alloc);
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("xyzzy", result[0].type_name);
    try testing.expectEqualStrings("42type", result[1].type_name);
}

// --- Operator Token Matching (spec: operator-token-matching) ---

fn opItem(text: []const u8) TestTokenItem {
    return .{ .kind = .operator, .text = text };
}

// Feature: operator-token-matching, Unit: operator-anchored pattern scores identically to
// the equivalent symbol-anchored pattern
// **Validates: Requirements 4.1, 4.2, 4.3**
test "parse: operator-anchored pattern scores identically to symbol-anchored pattern" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A: [kw "fn", id, sym "("]; B: [kw "fn", id, sym "-"]. The first keyword is
    // relaxed (identifier token) so confidence < 1 and the symbol weight is observable.
    var seq_a: [3]loader.SequenceElement = undefined;
    var seq_b: [3]loader.SequenceElement = undefined;
    seq_a[0] = .{ .matcher = .{ .keyword_literal = "fn" } };
    seq_a[1] = .{ .matcher = .{ .identifier = {} } };
    seq_a[2] = .{ .matcher = .{ .symbol_literal = "(" } };
    seq_b[0] = .{ .matcher = .{ .keyword_literal = "fn" } };
    seq_b[1] = .{ .matcher = .{ .identifier = {} } };
    seq_b[2] = .{ .matcher = .{ .symbol_literal = "-" } };

    const patterns_a = &[_]loader.Pattern{.{
        .type_name = "a",
        .sequence = &seq_a,
        .captures = &.{},
    }};
    const patterns_b = &[_]loader.Pattern{.{
        .type_name = "b",
        .sequence = &seq_b,
        .captures = &.{},
    }};
    const auto_a = try compiler.compile(patterns_a, alloc);
    const auto_b = try compiler.compile(patterns_b, alloc);

    const items_a = [_]TestTokenItem{ idItem("fn"), idItem("x"), LPAREN_ITEM };
    const items_b = [_]TestTokenItem{ idItem("fn"), idItem("x"), opItem("-") };
    const stream_a = try buildStream(alloc, &items_a);
    const stream_b = try buildStream(alloc, &items_b);

    const res_a = try parse(auto_a, stream_a.tokens, stream_a.source, patterns_a, .{}, .{}, alloc);
    const res_b = try parse(auto_b, stream_b.tokens, stream_b.source, patterns_b, .{}, .{}, alloc);
    try testing.expectEqual(@as(usize, 1), res_a.len);
    try testing.expectEqual(@as(usize, 1), res_b.len);
    try testing.expectApproxEqRel(res_a[0].confidence, res_b[0].confidence, 0.001);

    // Same equivalence under a [weights] override of the symbol weight.
    const custom_weights = loader.EvidenceWeights{ .symbol = 0.8 };
    const res_a_c = try parse(auto_a, stream_a.tokens, stream_a.source, patterns_a, .{}, custom_weights, alloc);
    const res_b_c = try parse(auto_b, stream_b.tokens, stream_b.source, patterns_b, .{}, custom_weights, alloc);
    try testing.expectApproxEqRel(res_a_c[0].confidence, res_b_c[0].confidence, 0.001);

    // The opacity weight change actually moved the operator-anchored confidence.
    try testing.expect(res_b_c[0].confidence > res_b[0].confidence);
}

// Feature: operator-token-matching, Property 5: Operator matches contribute the symbol weight
// **Validates: Requirements 4.1, 4.2, 4.3**
test "property: operator matches contribute the symbol weight" {
    const override_gen = gen.boolean();

    try minish.check(testing.allocator, override_gen, struct {
        fn prop(override: bool) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            var seq_a: [3]loader.SequenceElement = undefined;
            var seq_b: [3]loader.SequenceElement = undefined;
            seq_a[0] = .{ .matcher = .{ .keyword_literal = "fn" } };
            seq_a[1] = .{ .matcher = .{ .identifier = {} } };
            seq_a[2] = .{ .matcher = .{ .symbol_literal = "(" } };
            seq_b[0] = .{ .matcher = .{ .keyword_literal = "fn" } };
            seq_b[1] = .{ .matcher = .{ .identifier = {} } };
            seq_b[2] = .{ .matcher = .{ .symbol_literal = "-" } };

            const patterns_a = &[_]loader.Pattern{.{
                .type_name = "a",
                .sequence = &seq_a,
                .captures = &.{},
            }};
            const patterns_b = &[_]loader.Pattern{.{
                .type_name = "b",
                .sequence = &seq_b,
                .captures = &.{},
            }};
            const auto_a = try compiler.compile(patterns_a, alloc);
            const auto_b = try compiler.compile(patterns_b, alloc);

            const weights = if (override) loader.EvidenceWeights{ .symbol = 0.8 } else loader.EvidenceWeights{};
            const items_a = [_]TestTokenItem{ idItem("fn"), idItem("x"), LPAREN_ITEM };
            const items_b = [_]TestTokenItem{ idItem("fn"), idItem("x"), opItem("-") };
            const stream_a = try buildStream(alloc, &items_a);
            const stream_b = try buildStream(alloc, &items_b);

            const res_a = try parse(auto_a, stream_a.tokens, stream_a.source, patterns_a, .{}, weights, alloc);
            const res_b = try parse(auto_b, stream_b.tokens, stream_b.source, patterns_b, .{}, weights, alloc);
            try testing.expectEqual(@as(usize, 1), res_a.len);
            try testing.expectEqual(@as(usize, 1), res_b.len);
            try testing.expectApproxEqRel(res_a[0].confidence, res_b[0].confidence, 0.001);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: operator-token-matching, Unit: Erlang -module attribute anchoring
// **Validates: Requirements 6.1, 6.2, 6.3**
test "parse: -module attribute anchors on the leading '-' operator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var seq: [4]loader.SequenceElement = undefined;
    seq[0] = .{ .matcher = .{ .symbol_literal = "-" } };
    seq[1] = .{ .matcher = .{ .keyword_literal = "module" } };
    seq[2] = .{ .matcher = .{ .symbol_literal = "(" } };
    seq[3] = .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 3 } } };
    const patterns = &[_]loader.Pattern{.{
        .type_name = "module_attr",
        .sequence = &seq,
        .captures = &.{.{ .field_name = "name", .position = 3 }},
    }};
    const automaton = try compiler.compile(patterns, alloc);

    // -module(foo): leading "-" is an operator token → event emitted, captures foo.
    const items = [_]TestTokenItem{ opItem("-"), kwItem("module"), LPAREN_ITEM, idItem("foo") };
    const stream = try buildStream(alloc, &items);
    const result = try parse(automaton, stream.tokens, stream.source, patterns, .{}, .{}, alloc);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("module_attr", result[0].type_name);
    try testing.expectEqual(@as(usize, 0), result[0].start);
    try testing.expectEqual(@as(usize, 1), result[0].captures.len);
    try testing.expectEqualStrings("foo", result[0].captures[0].value);

    // module(foo): no leading "-" → the attribute pattern must not fire.
    const items2 = [_]TestTokenItem{ kwItem("module"), LPAREN_ITEM, idItem("foo") };
    const stream2 = try buildStream(alloc, &items2);
    const result2 = try parse(automaton, stream2.tokens, stream2.source, patterns, .{}, .{}, alloc);
    try testing.expectEqual(@as(usize, 0), result2.len);
}

test "parse: multi-character operator literal compiles but never matches single-token operators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var seq: [2]loader.SequenceElement = undefined;
    seq[0] = .{ .matcher = .{ .symbol_literal = "->" } };
    seq[1] = .{ .matcher = .{ .keyword_literal = "module" } };
    const patterns = &[_]loader.Pattern{.{
        .type_name = "arrow_attr",
        .sequence = &seq,
        .captures = &.{},
    }};
    const automaton = try compiler.compile(patterns, alloc);

    // "->" tokenizes as two single-character operator tokens; the literal cannot match
    // a single token, so no event is emitted (documented single-token limitation).
    const items = [_]TestTokenItem{ opItem("-"), opItem(">"), kwItem("module") };
    const stream = try buildStream(alloc, &items);
    const result = try parse(automaton, stream.tokens, stream.source, patterns, .{}, .{}, alloc);
    try testing.expectEqual(@as(usize, 0), result.len);
}

// Feature: operator-token-matching, Property 7: Erlang attribute anchoring end-to-end
// **Validates: Requirements 6.1, 6.2, 6.3**
test "property: erlang attribute anchoring end-to-end" {
    const name_gen = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha });

    try minish.check(testing.allocator, name_gen, struct {
        fn prop(name: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            var seq: [4]loader.SequenceElement = undefined;
            seq[0] = .{ .matcher = .{ .symbol_literal = "-" } };
            seq[1] = .{ .matcher = .{ .keyword_literal = "module" } };
            seq[2] = .{ .matcher = .{ .symbol_literal = "(" } };
            seq[3] = .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 3 } } };
            const patterns = &[_]loader.Pattern{.{
                .type_name = "module_attr",
                .sequence = &seq,
                .captures = &.{.{ .field_name = "name", .position = 3 }},
            }};
            const automaton = try compiler.compile(patterns, alloc);

            const items = [_]TestTokenItem{ opItem("-"), kwItem("module"), LPAREN_ITEM, idItem(name) };
            const stream = try buildStream(alloc, &items);
            const result = try parse(automaton, stream.tokens, stream.source, patterns, .{}, .{}, alloc);
            try testing.expectEqual(@as(usize, 1), result.len);
            try testing.expectEqualStrings("module_attr", result[0].type_name);
            try testing.expectEqualStrings(name, result[0].captures[0].value);

            const items2 = [_]TestTokenItem{ kwItem("module"), LPAREN_ITEM, idItem(name) };
            const stream2 = try buildStream(alloc, &items2);
            const result2 = try parse(automaton, stream2.tokens, stream2.source, patterns, .{}, .{}, alloc);
            try testing.expectEqual(@as(usize, 0), result2.len);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: operator-token-matching, Property 8: Backward compatibility of existing grammar output
// **Validates: Requirements 7.1, 7.3, 7.4**
test "property: backward compatibility of existing grammar output" {
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

            // A symbol/delimiter-only grammar (pre-feature surface) must emit the same
            // events as before: one full-match event per occurrence with confidence 1.0.
            var seq: [3]loader.SequenceElement = undefined;
            seq[0] = .{ .matcher = .{ .keyword_literal = vals[0] } };
            seq[1] = .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 1 } } };
            seq[2] = .{ .matcher = .{ .symbol_literal = "(" } };
            const patterns = &[_]loader.Pattern{.{
                .type_name = "call",
                .sequence = &seq,
                .captures = &.{.{ .field_name = "name", .position = 1 }},
            }};
            const automaton = try compiler.compile(patterns, alloc);

            const items = [_]TestTokenItem{
                kwItem(vals[0]), idItem(vals[1]), LPAREN_ITEM, SEP_ITEM,
                kwItem(vals[0]), idItem("second"), LPAREN_ITEM,
            };
            const stream = try buildStream(alloc, &items);
            const result = try parse(automaton, stream.tokens, stream.source, patterns, .{}, .{}, alloc);
            try testing.expectEqual(@as(usize, 2), result.len);
            try testing.expectEqualStrings("call", result[0].type_name);
            try testing.expectEqualStrings(vals[1], result[0].captures[0].value);
            try testing.expectApproxEqRel(@as(f32, 1.0), result[0].confidence, 0.001);
            try testing.expectEqualStrings("call", result[1].type_name);
            try testing.expectEqualStrings("second", result[1].captures[0].value);
            try testing.expectApproxEqRel(@as(f32, 1.0), result[1].confidence, 0.001);
        }
    }.prop, .{ .num_runs = 100 });
}

// --- Number Token Primitive (spec: number-token-primitive) ---

fn numItem(text: []const u8) TestTokenItem {
    return .{ .kind = .number, .text = text };
}

// Feature: number-token-primitive, Unit: confidence examples
// **Validates: Requirements 6.3**
test "parse: lone number pattern scores exactly 1.0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var seq: [1]loader.SequenceElement = undefined;
    seq[0] = .{ .matcher = .{ .number = {} } };
    const patterns = &[_]loader.Pattern{.{
        .type_name = "num",
        .sequence = &seq,
        .captures = &.{},
    }};
    const automaton = try compiler.compile(patterns, alloc);

    const items = [_]TestTokenItem{numItem("42")};
    const stream = try buildStream(alloc, &items);
    const result = try parse(automaton, stream.tokens, stream.source, patterns, .{}, .{}, alloc);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("num", result[0].type_name);
    try testing.expectApproxEqRel(@as(f32, 1.0), result[0].confidence, 0.001);
    try testing.expectEqual(@as(usize, 0), result[0].captures.len);
}

test "parse: composed capture + optional number pattern scores sensibly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var seq: [2]loader.SequenceElement = undefined;
    seq[0] = .{ .matcher = .{ .capture = .{ .field_name = "name", .position = 0 } } };
    seq[1] = .{ .matcher = .{ .number = {} }, .is_optional = true };
    const patterns = &[_]loader.Pattern{.{
        .type_name = "decl",
        .sequence = &seq,
        .captures = &.{.{ .field_name = "name", .position = 0 }},
    }};
    const automaton = try compiler.compile(patterns, alloc);

    // Short shape (number absent): confidence = identifier/(identifier+symbol) = 0.5.
    const items_short = [_]TestTokenItem{ idItem("x"), SEP_ITEM };
    const stream_short = try buildStream(alloc, &items_short);
    const res_short = try parse(automaton, stream_short.tokens, stream_short.source, patterns, .{}, .{}, alloc);
    try testing.expectEqual(@as(usize, 1), res_short.len);
    try testing.expectApproxEqRel(@as(f32, 0.2 / 0.4), res_short[0].confidence, 0.001);

    // Long shape (number present): full match → 1.0.
    const items_long = [_]TestTokenItem{ idItem("x"), numItem("7") };
    const stream_long = try buildStream(alloc, &items_long);
    const res_long = try parse(automaton, stream_long.tokens, stream_long.source, patterns, .{}, .{}, alloc);
    try testing.expectEqual(@as(usize, 1), res_long.len);
    try testing.expectApproxEqRel(@as(f32, 1.0), res_long[0].confidence, 0.001);
    try testing.expectEqualStrings("x", res_long[0].captures[0].value);
}

// Feature: number-token-primitive, Property 5: a lone required number match scores 1.0
// with the symbol weight
// **Validates: Requirements 6.1, 6.2, 6.3**
test "property: a lone required number match scores 1.0 with the symbol weight" {
    const weight_gen = gen.intRange(u16, 1, 100);

    try minish.check(testing.allocator, weight_gen, struct {
        fn prop(pct: u16) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const sym_weight: f32 = @as(f32, @floatFromInt(pct)) / 100.0;
            const weights = loader.EvidenceWeights{ .symbol = sym_weight };

            var seq: [1]loader.SequenceElement = undefined;
            seq[0] = .{ .matcher = .{ .number = {} } };
            const patterns = &[_]loader.Pattern{.{
                .type_name = "num",
                .sequence = &seq,
                .captures = &.{},
            }};
            const automaton = try compiler.compile(patterns, alloc);

            const items = [_]TestTokenItem{numItem("42")};
            const stream = try buildStream(alloc, &items);
            const result = try parse(automaton, stream.tokens, stream.source, patterns, .{}, weights, alloc);
            try testing.expectEqual(@as(usize, 1), result.len);
            try testing.expectApproxEqRel(@as(f32, 1.0), result[0].confidence, 0.001);
        }
    }.prop, .{ .num_runs = 100 });
}
