const std = @import("std");

// --- Data Types ---

pub const Grammar = struct {
    language_name: ?[]const u8,
    keyword_categories: []const KeywordCategory,
    keyword_table: []const []const u8,
    patterns: []const Pattern,
    blocks: BlockConfig,
};

pub const KeywordCategory = struct {
    name: []const u8,
    keywords: []const []const u8,
};

pub const Pattern = struct {
    type_name: []const u8,
    sequence: []const TokenMatcher,
    captures: []const Capture,
};

pub const TokenMatcher = union(enum) {
    keyword_literal: []const u8,
    symbol_literal: []const u8,
    identifier: void,
    capture: Capture,
};

pub const Capture = struct {
    field_name: []const u8,
    position: usize,
};

pub const BlockConfig = struct {
    open: ?[]const u8 = null,
    close: ?[]const u8 = null,
    indentation: bool = false,
};

pub const GrammarError = error{
    FileNotFound,
    InvalidToml,
    MissingPatterns,
    EmptyPatternSequence,
    InvalidCaptureFormat,
    OutOfMemory,
};

/// Parses a TOML grammar file from bytes into a Grammar struct.
/// All allocations use the provided arena allocator.
pub fn parseGrammar(source: []const u8, allocator: std.mem.Allocator) GrammarError!Grammar {
    _ = source;
    _ = allocator;
    @panic("TODO: implement parseGrammar");
}

/// Formats a Grammar struct back into a TOML string.
/// Used for round-trip testing.
pub fn formatGrammar(grammar: Grammar, allocator: std.mem.Allocator) ![]const u8 {
    _ = grammar;
    _ = allocator;
    @panic("TODO: implement formatGrammar");
}
