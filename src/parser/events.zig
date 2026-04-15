const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
const TokenKind = tokenizer.TokenKind;

// --- Data Types ---

pub const StructuralEvent = struct {
    type_name: []const u8,
    captures: []const CaptureEntry,
    start: usize,
    end: usize,
    line: usize,
    col: usize,
    confidence: f32,
    block_start: ?usize = null,
    block_end: ?usize = null,
};

pub const CaptureEntry = struct {
    field_name: []const u8,
    value: []const u8,
};

/// Evidence weights for confidence scoring.
pub const evidence_weights = struct {
    pub const keyword: f32 = 0.5;
    pub const identifier: f32 = 0.2;
    pub const symbol: f32 = 0.2;
    pub const block: f32 = 0.3;
    pub const relaxed_keyword: f32 = 0.1;
};

/// Returns the evidence weight for a given token kind.
pub fn weightForKind(kind: TokenKind) f32 {
    return switch (kind) {
        .keyword => evidence_weights.keyword,
        .identifier => evidence_weights.identifier,
        .delimiter, .symbol => evidence_weights.symbol,
        else => 0.0,
    };
}

/// Computes confidence score for a pattern match.
/// Takes pre-computed matched_weights and normalizes to 0.0–1.0.
pub fn computeConfidence(matched_weights: f32, pattern_max_score: f32) f32 {
    if (pattern_max_score <= 0.0) return 0.0;
    return @min(matched_weights / pattern_max_score, 1.0);
}
