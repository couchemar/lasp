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

/// Default noise penalty constants.
pub const default_noise_penalty_per_token: f32 = 0.1;
pub const default_max_noise_penalty: f32 = 0.5;

/// Computes confidence score for a pattern match.
/// Takes pre-computed matched_weights and normalizes to 0.0–1.0.
/// Applies a capped noise penalty before normalization.
/// When noise_count = 0, behavior is identical to the pre-noise formula.
pub fn computeConfidence(
    matched_weights: f32,
    pattern_max_score: f32,
    noise_count: u32,
    noise_penalty_per_token: f32,
    max_noise_penalty: f32,
) f32 {
    if (pattern_max_score <= 0.0) return 0.0;
    const capped_penalty = @min(@as(f32, @floatFromInt(noise_count)) * noise_penalty_per_token, max_noise_penalty);
    const raw = @max(@as(f32, 0.0), matched_weights - capped_penalty);
    return @min(raw / pattern_max_score, 1.0);
}
