const std = @import("std");
const loader = @import("loader.zig");
const tokenizer = @import("../parser/tokenizer.zig");

const TokenMatcher = loader.TokenMatcher;
const Capture = loader.Capture;
const Pattern = loader.Pattern;
const Token = tokenizer.Token;

// --- Data Types ---

pub const Transition = struct {
    matcher: TokenMatcher,
    next_state: usize,
    capture: ?Capture = null,
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

pub const Automaton = struct {
    states: []const State,

    /// Check if a token matches a transition from the given state.
    /// Returns the next state index and optional capture, or null if no match.
    pub fn step(self: Automaton, state_idx: usize, token: Token, source: []const u8) ?struct { next: usize, capture: ?CaptureValue } {
        _ = self;
        _ = state_idx;
        _ = token;
        _ = source;
        @panic("TODO: implement Automaton.step");
    }
};

/// Compiles a list of patterns into a deterministic prefix trie automaton.
/// Reuses shared prefix states across patterns.
pub fn compile(patterns: []const Pattern, allocator: std.mem.Allocator) !Automaton {
    _ = patterns;
    _ = allocator;
    @panic("TODO: implement compile");
}
