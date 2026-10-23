const std = @import("std");
const CommentConfig = @import("../grammar/loader.zig").CommentConfig;

pub const TokenKind = enum {
    identifier,
    keyword,
    symbol,
    string,
    number,
    operator,
    newline,
    indent,
    comment,
    delimiter,
};

pub const Token = struct {
    kind: TokenKind,
    start: usize,
    end: usize,
    line: usize,
    col: usize,
    /// Index into the grammar's KindVocabulary for content tokens; 0 for structural
    /// tokens and for the default-profile path.
    kind_id: usize = 0,
};

/// A 256-entry membership bitset compiled from a char-set spec.
pub const CharClass = struct {
    bits: [256]bool = [_]bool{false} ** 256,

    pub fn set(self: *CharClass, c: u8) void {
        self.bits[c] = true;
    }

    pub fn contains(self: CharClass, c: u8) bool {
        return self.bits[c];
    }
};

/// Serializes a CharClass back into a canonical char-set spec string
/// (runs as `lo-hi`, singles literal, ambiguous bytes `\u`-escaped).
pub fn writeCharSetSpec(cc: CharClass, w: anytype) !void {
    var b: usize = 0;
    while (b < 256) {
        if (!cc.bits[b]) {
            b += 1;
            continue;
        }
        var run_end = b + 1;
        while (run_end < 256 and cc.bits[run_end]) run_end += 1;
        const len = run_end - b;
        if (len == 1) {
            try writeCharSpec(@intCast(b), w);
        } else {
            try writeCharSpec(@intCast(b), w);
            try w.writeByte('-');
            try writeCharSpec(@intCast(run_end - 1), w);
        }
        b = run_end;
    }
}

pub fn writeCharSpec(c: u8, w: anytype) !void {
    switch (c) {
        '"', '\\', '-' => try w.print("\\u{X:0>4}", .{c}),
        else => try w.writeByte(c),
    }
}

pub const CharClassRun = struct {
    start: CharClass,
    cont: CharClass,
};

pub const DelimitedSpan = struct {
    open: []const u8,
    close: []const u8,
    escape: ?u8,
};

pub const Recognizer = union(enum) {
    char_class_run: CharClassRun,
    delimited_span: DelimitedSpan,
    literal_set: []const []const u8,
};

pub const KindDefinition = struct {
    name: []const u8,
    recognizer: Recognizer,
};

pub const KindVocabulary = struct {
    kinds: []const KindDefinition,
};

/// Result of a comment match attempt
const CommentMatch = struct {
    /// End position (exclusive) of the comment
    end: usize,
    /// True if this was a block comment (spans multiple lines)
    is_block: bool,
    /// Number of newline characters within the comment
    newline_count: usize,
};

/// Try to match a comment starting at position `start` in `source`.
/// Returns `null` if no comment matches at this position, or a `CommentMatch`
/// with the end position (exclusive) and whether it's a block comment.
/// Implements longest-match semantics: returns the match with longest prefix.
/// For ties of equal length, prefers line prefixes over block delimiter.
fn tryMatchComment(source: []const u8, start: usize, config: CommentConfig) ?CommentMatch {
    // Short-circuit if we're at EOF
    if (start >= source.len) return null;

    var best_match: ?CommentMatch = null;
    var best_len: usize = 0;
    var best_priority: u32 = 0; // Lower number = higher priority (0=line[0], 1=line[1], ..., large=block)

    // Check all line comment prefixes first (in array order, lower priority number)
    for (config.line_prefixes, 0..) |prefix, idx| {
        if (std.mem.startsWith(u8, source[start..], prefix)) {
            // Found a line comment - scan to end of line or EOF
            var pos = start + prefix.len;
            while (pos < source.len and source[pos] != '\n') : (pos += 1) {}
            // Include the newline in the comment? No - line comment ends at newline exclusive
            const end = pos; // Don't include newline

            // Priority: idx (0 for first line prefix, 1 for second, etc.)
            const priority = @as(u32, @intCast(idx));

            // Check if this is better than current best
            // Longer prefix wins, or same length and lower priority number wins
            const is_better = if (prefix.len > best_len) true else if (prefix.len == best_len and priority < best_priority) true else false;

            if (is_better) {
                best_len = prefix.len;
                best_priority = priority;
                best_match = CommentMatch{
                    .end = end,
                    .is_block = false,
                    .newline_count = 0,
                };
            }
        }
    }

    // Check block comment (has lower priority than all line prefixes)
    if (config.block_open) |open| {
        if (std.mem.startsWith(u8, source[start..], open)) {
            const open_len = open.len;
            const open_end = start + open_len;
            var pos = open_end;
            var newline_count: usize = 0;
            var found_close = false;

            if (config.block_close) |close| {
                // Find matching close delimiter
                while (pos <= source.len - close.len) {
                    if (source[pos] == '\n') {
                        newline_count += 1;
                    }
                    if (std.mem.startsWith(u8, source[pos..], close)) {
                        // Found closing delimiter
                        const end = pos + close.len;
                        found_close = true;
                        // Block priority is after all line prefixes
                        const priority = @as(u32, @intCast(config.line_prefixes.len)) + 1;

                        // Check if this is better than current best
                        // Longer prefix wins, or same length and this has lower priority number
                        // (but block always has higher priority number than line prefixes)
                        const is_better = if (open_len > best_len) true else if (open_len == best_len and priority < best_priority) true else false;

                        if (is_better) {
                            best_len = open_len;
                            best_priority = priority;
                            best_match = CommentMatch{
                                .end = end,
                                .is_block = true,
                                .newline_count = newline_count,
                            };
                        }
                        break;
                    }
                    pos += 1;
                }
            }

            if (!found_close) {
                // No closing delimiter found - extend to EOF
                // Count any newlines that we scanned before giving up
                while (pos < source.len) {
                    if (source[pos] == '\n') newline_count += 1;
                    pos += 1;
                }
                const end = source.len;
                const priority = @as(u32, @intCast(config.line_prefixes.len)) + 1;

                if (open_len > best_len or (open_len == best_len and priority < best_priority)) {
                    best_len = open_len;
                    best_priority = priority;
                    best_match = CommentMatch{
                        .end = end,
                        .is_block = true,
                        .newline_count = newline_count,
                    };
                }
            }
        }
    }

    return best_match;
}

// --- Character classification helpers ---

pub fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

pub fn isAlphaNum(c: u8) bool {
    return isAlpha(c) or isDigit(c) or c == '_';
}

pub fn isOperator(c: u8) bool {
    return switch (c) {
        '+', '-', '*', '/', '=', '<', '>', '!', '&', '|', '^', '%', '~' => true,
        else => false,
    };
}

pub fn isDelimiter(c: u8) bool {
    return switch (c) {
        '(', ')', '{', '}', '[', ']' => true,
        else => false,
    };
}

pub fn isSymbol(c: u8) bool {
    return switch (c) {
        ',', ';', ':', '.', '@', '?' => true,
        else => false,
    };
}

pub fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn isKeyword(text: []const u8, keyword_table: []const []const u8) bool {
    for (keyword_table) |kw| {
        if (std.mem.eql(u8, text, kw)) return true;
    }
    return false;
}

/// Tokenizes source bytes into an array of Tokens.
/// Keywords are recognized via the optional keyword_table.
/// Comment recognition uses the provided CommentConfig.
/// All allocations use the provided allocator (arena).
pub fn tokenize(
    source: []const u8,
    keyword_table: ?[]const []const u8,
    comments: CommentConfig,
    allocator: std.mem.Allocator,
) ![]Token {
    if (source.len == 0) return &[_]Token{};

    var tokens: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    var at_line_start = true;
    var current_line: usize = 1;
    var line_start: usize = 0;

    while (i < source.len) {
        const c = source[i];

        // Newline
        if (c == '\n') {
            try tokens.append(allocator, .{ .kind = .newline, .start = i, .end = i + 1, .line = current_line, .col = i - line_start });
            i += 1;
            at_line_start = true;
            current_line += 1;
            line_start = i;

            // Check for indent after newline
            const indent_start = i;
            while (i < source.len and isWhitespace(source[i])) : (i += 1) {}
            if (i > indent_start) {
                try tokens.append(allocator, .{ .kind = .indent, .start = indent_start, .end = i, .line = current_line, .col = indent_start - line_start });
            }
            continue;
        }

        // Skip non-indentation whitespace
        if (isWhitespace(c)) {
            if (at_line_start) {
                const indent_start = i;
                while (i < source.len and isWhitespace(source[i])) : (i += 1) {}
                try tokens.append(allocator, .{ .kind = .indent, .start = indent_start, .end = i, .line = current_line, .col = indent_start - line_start });
                at_line_start = false;
            } else {
                i += 1;
            }
            continue;
        }

        at_line_start = false;

        // Try to match a comment (configurable)
        if (tryMatchComment(source, i, comments)) |match| {
            const start = i;
            i = match.end;

            // Save the original line start and current line BEFORE updating them
            const token_line_start = line_start;
            const token_line = current_line;

            // Update line tracking for block comments spanning multiple lines
            if (match.is_block) {
                current_line += match.newline_count;
                // Need to find the start of the current line after the comment
                // Start scanning from end of comment
                var scan_pos = i;
                line_start = i;
                // Scan backwards to find the last newline before end of comment
                while (scan_pos > 0) {
                    scan_pos -= 1;
                    if (source[scan_pos] == '\n') {
                        line_start = scan_pos + 1;
                        break;
                    }
                }
                // If we didn't find a newline, line_start stays at i (start of line after comment)
            }

            try tokens.append(allocator, .{ .kind = .comment, .start = start, .end = i, .line = token_line, .col = start - token_line_start });
            continue;
        }

        // String literals: "..." or '...'
        if (c == '"' or c == '\'') {
            const start = i;
            const quote = c;
            i += 1;
            while (i < source.len) {
                if (source[i] == '\\') {
                    i += 2; // skip escaped char
                    continue;
                }
                if (source[i] == quote) {
                    i += 1;
                    break;
                }
                i += 1;
            }
            // If we exited without finding closing quote, i == source.len (unclosed string)
            try tokens.append(allocator, .{ .kind = .string, .start = start, .end = i, .line = current_line, .col = start - line_start });
            continue;
        }

        // Numbers: [0-9]+ with optional single '.'
        if (isDigit(c)) {
            const start = i;
            while (i < source.len and isDigit(source[i])) : (i += 1) {}
            if (i < source.len and source[i] == '.') {
                i += 1;
                while (i < source.len and isDigit(source[i])) : (i += 1) {}
            }
            try tokens.append(allocator, .{ .kind = .number, .start = start, .end = i, .line = current_line, .col = start - line_start });
            continue;
        }

        // Identifiers and keywords: [a-zA-Z_][a-zA-Z0-9_]*
        if (isAlpha(c) or c == '_') {
            const start = i;
            while (i < source.len and isAlphaNum(source[i])) : (i += 1) {}
            const text = source[start..i];
            const kind: TokenKind = if (keyword_table) |kt|
                (if (isKeyword(text, kt)) TokenKind.keyword else TokenKind.identifier)
            else
                .identifier;
            try tokens.append(allocator, .{ .kind = kind, .start = start, .end = i, .line = current_line, .col = start - line_start });
            continue;
        }

        // Operators
        if (isOperator(c)) {
            try tokens.append(allocator, .{ .kind = .operator, .start = i, .end = i + 1, .line = current_line, .col = i - line_start });
            i += 1;
            continue;
        }

        // Delimiters
        if (isDelimiter(c)) {
            try tokens.append(allocator, .{ .kind = .delimiter, .start = i, .end = i + 1, .line = current_line, .col = i - line_start });
            i += 1;
            continue;
        }

        // Symbols
        if (isSymbol(c)) {
            try tokens.append(allocator, .{ .kind = .symbol, .start = i, .end = i + 1, .line = current_line, .col = i - line_start });
            i += 1;
            continue;
        }

        // Unknown bytes — skip
        i += 1;
    }

    return tokens.toOwnedSlice(allocator);
}

// --- Vocabulary-driven scan ([tokens] grammars) ---

fn tryRecognizer(rec: Recognizer, source: []const u8, at: usize) ?usize {
    return switch (rec) {
        .char_class_run => |r| {
            if (at >= source.len or !r.start.contains(source[at])) return null;
            var end = at + 1;
            while (end < source.len and r.cont.contains(source[end])) : (end += 1) {}
            return end;
        },
        .delimited_span => |d| {
            if (!std.mem.startsWith(u8, source[at..], d.open)) return null;
            var pos = at + d.open.len;
            while (pos < source.len) {
                if (d.escape) |esc| {
                    if (source[pos] == esc) {
                        pos += 2;
                        continue;
                    }
                }
                if (std.mem.startsWith(u8, source[pos..], d.close)) {
                    return pos + d.close.len;
                }
                pos += 1;
            }
            return source.len; // unclosed span extends to EOF
        },
        .literal_set => |set| {
            var best: usize = 0;
            for (set) |lit| {
                if (lit.len > best and std.mem.startsWith(u8, source[at..], lit)) {
                    best = lit.len;
                }
            }
            if (best > 0) return at + best;
            return null;
        },
    };
}

fn kindTokenKind(name: []const u8, rec: Recognizer) TokenKind {
    if (std.mem.eql(u8, name, "identifier")) return .identifier;
    if (std.mem.eql(u8, name, "keyword")) return .keyword;
    if (std.mem.eql(u8, name, "symbol")) return .symbol;
    if (std.mem.eql(u8, name, "string")) return .string;
    if (std.mem.eql(u8, name, "number")) return .number;
    if (std.mem.eql(u8, name, "operator")) return .operator;
    if (std.mem.eql(u8, name, "delimiter")) return .delimiter;
    // Custom (non-built-in) kind names fall back to a content kind derived from
    // their recognizer shape so default matching paths (e.g. .punctuation
    // matchers against literal-set tokens) keep working.
    return switch (rec) {
        .char_class_run, .delimited_span => .identifier,
        .literal_set => .symbol,
    };
}

/// Tokenizes source using a grammar-declared KindVocabulary. Structural kinds
/// (newline/indent/comment) and whitespace handling mirror the default path.
pub fn tokenizeWithVocab(
    source: []const u8,
    vocab: KindVocabulary,
    keyword_table: ?[]const []const u8,
    comments: CommentConfig,
    allocator: std.mem.Allocator,
) ![]Token {
    if (source.len == 0) return &[_]Token{};

    var tokens: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    var at_line_start = true;
    var current_line: usize = 1;
    var line_start: usize = 0;

    while (i < source.len) {
        const c = source[i];

        if (c == '\n') {
            try tokens.append(allocator, .{ .kind = .newline, .start = i, .end = i + 1, .line = current_line, .col = i - line_start });
            i += 1;
            at_line_start = true;
            current_line += 1;
            line_start = i;
            const indent_start = i;
            while (i < source.len and isWhitespace(source[i])) : (i += 1) {}
            if (i > indent_start) {
                try tokens.append(allocator, .{ .kind = .indent, .start = indent_start, .end = i, .line = current_line, .col = indent_start - line_start });
            }
            continue;
        }

        if (isWhitespace(c)) {
            if (at_line_start) {
                const indent_start = i;
                while (i < source.len and isWhitespace(source[i])) : (i += 1) {}
                try tokens.append(allocator, .{ .kind = .indent, .start = indent_start, .end = i, .line = current_line, .col = indent_start - line_start });
                at_line_start = false;
            } else {
                i += 1;
            }
            continue;
        }

        at_line_start = false;

        if (tryMatchComment(source, i, comments)) |match| {
            const start = i;
            i = match.end;
            const token_line_start = line_start;
            const token_line = current_line;
            if (match.is_block) {
                current_line += match.newline_count;
                var scan_pos = i;
                line_start = i;
                while (scan_pos > 0) {
                    scan_pos -= 1;
                    if (source[scan_pos] == '\n') {
                        line_start = scan_pos + 1;
                        break;
                    }
                }
            }
            try tokens.append(allocator, .{ .kind = .comment, .start = start, .end = i, .line = token_line, .col = start - token_line_start });
            continue;
        }

        var matched = false;
        for (vocab.kinds, 0..) |def, id| {
            if (tryRecognizer(def.recognizer, source, i)) |end| {
                var kind = kindTokenKind(def.name, def.recognizer);
                // [keywords] overlay: identifier runs whose text is in the keyword
                // table emit as keyword-kind tokens.
                if (kind == .identifier) {
                    if (keyword_table) |kt| {
                        if (isKeyword(source[i..end], kt)) kind = .keyword;
                    }
                }
                try tokens.append(allocator, .{
                    .kind = kind,
                    .start = i,
                    .end = end,
                    .line = current_line,
                    .col = i - line_start,
                    .kind_id = id,
                });
                i = end;
                matched = true;
                break;
            }
        }
        if (matched) continue;

        i += 1; // unknown byte advances by one
    }

    return tokens.toOwnedSlice(allocator);
}

// --- Unit Tests ---

const testing = std.testing;

fn expectTokens(source: []const u8, keyword_table: ?[]const []const u8, expected: []const struct { kind: TokenKind, text: []const u8 }) !void {
    const tokens = try tokenize(source, keyword_table, CommentConfig.default, testing.allocator);
    defer testing.allocator.free(tokens);
    try testing.expectEqual(expected.len, tokens.len);
    for (expected, 0..) |exp, idx| {
        try testing.expectEqual(exp.kind, tokens[idx].kind);
        try testing.expectEqualStrings(exp.text, source[tokens[idx].start..tokens[idx].end]);
    }
}

fn expectTokensWithConfig(source: []const u8, keyword_table: ?[]const []const u8, comments: CommentConfig, expected: []const struct { kind: TokenKind, text: []const u8 }) !void {
    const tokens = try tokenize(source, keyword_table, comments, testing.allocator);
    defer testing.allocator.free(tokens);
    try testing.expectEqual(expected.len, tokens.len);
    for (expected, 0..) |exp, idx| {
        try testing.expectEqual(exp.kind, tokens[idx].kind);
        try testing.expectEqualStrings(exp.text, source[tokens[idx].start..tokens[idx].end]);
    }
}

test "tokenize identifier" {
    try expectTokens("hello world", null, &.{
        .{ .kind = .identifier, .text = "hello" },
        .{ .kind = .identifier, .text = "world" },
    });
}

test "tokenize keyword with table" {
    const kw = &[_][]const u8{ "fn", "pub" };
    try expectTokens("fn hello pub", kw, &.{
        .{ .kind = .keyword, .text = "fn" },
        .{ .kind = .identifier, .text = "hello" },
        .{ .kind = .keyword, .text = "pub" },
    });
}

test "tokenize no keywords without table" {
    try expectTokens("fn pub", null, &.{
        .{ .kind = .identifier, .text = "fn" },
        .{ .kind = .identifier, .text = "pub" },
    });
}

test "tokenize number integer" {
    try expectTokens("42", null, &.{
        .{ .kind = .number, .text = "42" },
    });
}

test "tokenize number decimal" {
    try expectTokens("3.14", null, &.{
        .{ .kind = .number, .text = "3.14" },
    });
}

test "tokenize string double quotes" {
    try expectTokens("\"hello\"", null, &.{
        .{ .kind = .string, .text = "\"hello\"" },
    });
}

test "tokenize string single quotes" {
    try expectTokens("'world'", null, &.{
        .{ .kind = .string, .text = "'world'" },
    });
}

test "tokenize string with escape" {
    try expectTokens("\"he\\\"llo\"", null, &.{
        .{ .kind = .string, .text = "\"he\\\"llo\"" },
    });
}

test "tokenize operators" {
    try expectTokens("+ - * /", null, &.{
        .{ .kind = .operator, .text = "+" },
        .{ .kind = .operator, .text = "-" },
        .{ .kind = .operator, .text = "*" },
        .{ .kind = .operator, .text = "/" },
    });
}

test "tokenize delimiters" {
    try expectTokens("(){}", null, &.{
        .{ .kind = .delimiter, .text = "(" },
        .{ .kind = .delimiter, .text = ")" },
        .{ .kind = .delimiter, .text = "{" },
        .{ .kind = .delimiter, .text = "}" },
    });
}

test "tokenize symbols" {
    try expectTokens(",;:.", null, &.{
        .{ .kind = .symbol, .text = "," },
        .{ .kind = .symbol, .text = ";" },
        .{ .kind = .symbol, .text = ":" },
        .{ .kind = .symbol, .text = "." },
    });
}

test "tokenize line comment //" {
    try expectTokens("// a comment\nx", null, &.{
        .{ .kind = .comment, .text = "// a comment" },
        .{ .kind = .newline, .text = "\n" },
        .{ .kind = .identifier, .text = "x" },
    });
}

test "tokenize line comment #" {
    try expectTokens("# a comment\nx", null, &.{
        .{ .kind = .comment, .text = "# a comment" },
        .{ .kind = .newline, .text = "\n" },
        .{ .kind = .identifier, .text = "x" },
    });
}

test "tokenize block comment" {
    try expectTokens("/* block */x", null, &.{
        .{ .kind = .comment, .text = "/* block */" },
        .{ .kind = .identifier, .text = "x" },
    });
}

test "tokenize newline and indent" {
    try expectTokens("a\n  b", null, &.{
        .{ .kind = .identifier, .text = "a" },
        .{ .kind = .newline, .text = "\n" },
        .{ .kind = .indent, .text = "  " },
        .{ .kind = .identifier, .text = "b" },
    });
}

test "tokenize indent at start of input" {
    try expectTokens("  x", null, &.{
        .{ .kind = .indent, .text = "  " },
        .{ .kind = .identifier, .text = "x" },
    });
}

test "tokenize empty input" {
    const tokens = try tokenize("", null, CommentConfig.default, testing.allocator);
    try testing.expectEqual(@as(usize, 0), tokens.len);
}

test "tokenize unclosed string" {
    try expectTokens("\"hello", null, &.{
        .{ .kind = .string, .text = "\"hello" },
    });
}

test "tokenize unclosed block comment" {
    try expectTokens("/* stuff", null, &.{
        .{ .kind = .comment, .text = "/* stuff" },
    });
}

test "tokenize skips non-indentation whitespace" {
    try expectTokens("a   b", null, &.{
        .{ .kind = .identifier, .text = "a" },
        .{ .kind = .identifier, .text = "b" },
    });
}

test "tokenize mixed expression" {
    try expectTokens("x = 42 + y", null, &.{
        .{ .kind = .identifier, .text = "x" },
        .{ .kind = .operator, .text = "=" },
        .{ .kind = .number, .text = "42" },
        .{ .kind = .operator, .text = "+" },
        .{ .kind = .identifier, .text = "y" },
    });
}

// --- Configurable Comment Unit Tests ---

test "tokenize Erlang % line comment" {
    const config = CommentConfig{ .line_prefixes = &.{"%"} };
    try expectTokensWithConfig("% comment\nx", null, config, &.{
        .{ .kind = .comment, .text = "% comment" },
        .{ .kind = .newline, .text = "\n" },
        .{ .kind = .identifier, .text = "x" },
    });
}

test "tokenize Lua -- line comment" {
    const config = CommentConfig{ .line_prefixes = &.{"--"} };
    try expectTokensWithConfig("-- comment\nx", null, config, &.{
        .{ .kind = .comment, .text = "-- comment" },
        .{ .kind = .newline, .text = "\n" },
        .{ .kind = .identifier, .text = "x" },
    });
}

test "tokenize Haskell {- -} block comment" {
    const config = CommentConfig{ .block_open = "{-", .block_close = "-}" };
    try expectTokensWithConfig("{- block -}x", null, config, &.{
        .{ .kind = .comment, .text = "{- block -}" },
        .{ .kind = .identifier, .text = "x" },
    });
}

test "tokenize mixed line + block config" {
    const config = CommentConfig{ .line_prefixes = &.{ "%", "--" }, .block_open = "/*", .block_close = "*/" };
    try expectTokensWithConfig("% line\n/* block */x", null, config, &.{
        .{ .kind = .comment, .text = "% line" },
        .{ .kind = .newline, .text = "\n" },
        .{ .kind = .comment, .text = "/* block */" },
        .{ .kind = .identifier, .text = "x" },
    });
}

test "tokenize with CommentConfig.none produces zero comment tokens" {
    const source = "// not a comment\n# also not";
    const tokens = try tokenize(source, null, CommentConfig.none, testing.allocator);
    defer testing.allocator.free(tokens);
    for (tokens) |tok| {
        try testing.expect(tok.kind != .comment);
    }
}

test "tokenize comment with quote characters does not open string" {
    const config = CommentConfig{ .line_prefixes = &.{"%"} };
    try expectTokensWithConfig("% it's a comment with 'quotes'", null, config, &.{
        .{ .kind = .comment, .text = "% it's a comment with 'quotes'" },
    });
}

test "tokenize comment prefix inside string stays string content" {
    const config = CommentConfig{ .line_prefixes = &.{"%"} };
    try expectTokensWithConfig("\"foo % bar\"", null, config, &.{
        .{ .kind = .string, .text = "\"foo % bar\"" },
    });
}

test "tokenize unbalanced apostrophe in comment does not swallow subsequent code" {
    const config = CommentConfig{ .line_prefixes = &.{"%"} };
    try expectTokensWithConfig("% it's\nx = 1", null, config, &.{
        .{ .kind = .comment, .text = "% it's" },
        .{ .kind = .newline, .text = "\n" },
        .{ .kind = .identifier, .text = "x" },
        .{ .kind = .operator, .text = "=" },
        .{ .kind = .number, .text = "1" },
    });
}

test "tokenize real string literal unaffected by comment recognition" {
    const config = CommentConfig{ .line_prefixes = &.{"%"} };
    try expectTokensWithConfig("'atom'", null, config, &.{
        .{ .kind = .string, .text = "'atom'" },
    });
}

test "tokenize trailing line comment after code" {
    const config = CommentConfig{ .line_prefixes = &.{"%"} };
    try expectTokensWithConfig("foo() %% note", null, config, &.{
        .{ .kind = .identifier, .text = "foo" },
        .{ .kind = .delimiter, .text = "(" },
        .{ .kind = .delimiter, .text = ")" },
        .{ .kind = .comment, .text = "%% note" },
    });
}

test "tokenize block comment at EOF without close delimiter" {
    const config = CommentConfig{ .block_open = "/*", .block_close = "*/" };
    try expectTokensWithConfig("/* stuff", null, config, &.{
        .{ .kind = .comment, .text = "/* stuff" },
    });
}

test "tokenize multi-line block comment increments line counter" {
    const config = CommentConfig{ .block_open = "/*", .block_close = "*/" };
    const source = "/* line1\n  line2\n  */x";
    const tokens = try tokenize(source, null, config, testing.allocator);
    defer testing.allocator.free(tokens);
    try testing.expectEqual(@as(usize, 2), tokens.len);
    try testing.expectEqual(TokenKind.comment, tokens[0].kind);
    try testing.expectEqual(@as(usize, 0), tokens[0].start);
    try testing.expectEqual(@as(usize, 21), tokens[0].end); // "/* line1\n  line2\n  */"
    try testing.expectEqual(TokenKind.identifier, tokens[1].kind);
    try testing.expectEqual(@as(usize, 21), tokens[1].start); // "x" starts after comment
}

test "tokenize multi-line block comment col is relative to starting line" {
    const config = CommentConfig{ .block_open = "/*", .block_close = "*/" };
    // Comment starts at column 2 on line 1 and ends on line 3.
    // The col/line must reflect where the token STARTED, not where it ended.
    const source = "x /* a\nb\nc */ y";
    const tokens = try tokenize(source, null, config, testing.allocator);
    defer testing.allocator.free(tokens);
    // tokens: identifier("x"), comment, identifier("y")
    try testing.expectEqual(@as(usize, 3), tokens.len);
    try testing.expectEqual(TokenKind.comment, tokens[1].kind);
    try testing.expectEqual(@as(usize, 2), tokens[1].start);
    try testing.expectEqual(@as(usize, 1), tokens[1].line); // starting line, not ending line
    try testing.expectEqual(@as(usize, 2), tokens[1].col); // column on the starting line
    // "y" sits on line 3 after "c */ "
    try testing.expectEqual(TokenKind.identifier, tokens[2].kind);
    try testing.expectEqual(@as(usize, 3), tokens[2].line);
}

test "tokenize partial prefix match does not trigger comment" {
    const config = CommentConfig{ .line_prefixes = &.{"--"} };
    try expectTokensWithConfig("- x", null, config, &.{
        .{ .kind = .operator, .text = "-" },
        .{ .kind = .identifier, .text = "x" },
    });
}

test "tokenize longest match when overlapping prefixes" {
    const config = CommentConfig{ .line_prefixes = &.{ "-", "--", "---" } };
    try expectTokensWithConfig("--- comment\nx", null, config, &.{
        .{ .kind = .comment, .text = "--- comment" },
        .{ .kind = .newline, .text = "\n" },
        .{ .kind = .identifier, .text = "x" },
    });
}

// --- Column Tracking Unit Tests ---

test "column tracking: first line tokens have col equal to start offset" {
    const source = "hello world";
    const tokens = try tokenize(source, null, CommentConfig.default, testing.allocator);
    defer testing.allocator.free(tokens);
    try testing.expectEqual(@as(usize, 2), tokens.len);
    // "hello" starts at byte 0
    try testing.expectEqual(@as(usize, 0), tokens[0].col);
    // "world" starts at byte 6
    try testing.expectEqual(@as(usize, 6), tokens[1].col);
}

test "column tracking: tokens after newline have col relative to newline" {
    const source = "a\n  bc";
    const tokens = try tokenize(source, null, CommentConfig.default, testing.allocator);
    defer testing.allocator.free(tokens);
    // tokens: identifier("a"), newline, indent("  "), identifier("bc")
    try testing.expectEqual(@as(usize, 4), tokens.len);
    try testing.expectEqual(@as(usize, 0), tokens[0].col); // "a" at byte 0, line_start=0
    try testing.expectEqual(@as(usize, 1), tokens[1].col); // newline at byte 1, line_start=0
    try testing.expectEqual(@as(usize, 0), tokens[2].col); // indent at byte 2, line_start=2
    try testing.expectEqual(@as(usize, 2), tokens[3].col); // "bc" at byte 4, line_start=2
}

test "column tracking: tab counts as 1 column (byte-level)" {
    const source = "\tx";
    const tokens = try tokenize(source, null, CommentConfig.default, testing.allocator);
    defer testing.allocator.free(tokens);
    // tokens: indent("\t"), identifier("x")
    try testing.expectEqual(@as(usize, 2), tokens.len);
    try testing.expectEqual(@as(usize, 0), tokens[0].col); // indent at byte 0
    try testing.expectEqual(@as(usize, 1), tokens[1].col); // "x" at byte 1
}

test "column tracking: multiple lines with varying indentation" {
    const source = "fn add\n    x\n  y";
    const tokens = try tokenize(source, null, CommentConfig.default, testing.allocator);
    defer testing.allocator.free(tokens);
    // Line 1: "fn"(col=0) "add"(col=3)
    // newline(col=6)
    // Line 2: indent "    "(col=0) "x"(col=4)
    // newline(col=5)
    // Line 3: indent "  "(col=0) "y"(col=2)
    try testing.expectEqual(@as(usize, 0), tokens[0].col); // "fn"
    try testing.expectEqual(@as(usize, 3), tokens[1].col); // "add"
    // tokens[2] = newline
    try testing.expectEqual(@as(usize, 0), tokens[3].col); // indent "    "
    try testing.expectEqual(@as(usize, 4), tokens[4].col); // "x"
    // tokens[5] = newline
    try testing.expectEqual(@as(usize, 0), tokens[6].col); // indent "  "
    try testing.expectEqual(@as(usize, 2), tokens[7].col); // "y"
}

// --- Property Tests ---

const minish = @import("minish");
const gen = minish.gen;

// Feature: phase3-multi-language-patterns, Property 1: Column tracking correctness
test "property: column tracking correctness" {
    // For any source byte string, every token has col == token.start - (position after most recent newline before token.start)
    const source_gen = gen.string(.{ .min_len = 0, .max_len = 256, .charset = .ascii });

    try minish.check(testing.allocator, source_gen, struct {
        fn prop(source: []const u8) !void {
            const tokens = try tokenize(source, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(tokens);

            for (tokens) |tok| {
                // Find the position after the most recent newline before token.start
                var line_start: usize = 0;
                for (source[0..tok.start]) |ch| {
                    if (ch == '\n') {
                        line_start = 0; // will be set properly below
                    }
                }
                // Recompute: scan for last newline before tok.start
                line_start = 0;
                var j: usize = 0;
                while (j < tok.start) : (j += 1) {
                    if (source[j] == '\n') {
                        line_start = j + 1;
                    }
                }
                const expected_col = tok.start - line_start;
                try testing.expectEqual(expected_col, tok.col);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase1-tokenizer-cli, Property 5: Token bounds invariant
test "property: token bounds invariant" { // For any source bytes, every token satisfies start <= end <= source.len
    const source_gen = gen.string(.{ .min_len = 0, .max_len = 256, .charset = .ascii });

    try minish.check(testing.allocator, source_gen, struct {
        fn prop(source: []const u8) !void {
            const tokens = try tokenize(source, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(tokens);

            for (tokens) |tok| {
                try testing.expect(tok.start <= tok.end);
                try testing.expect(tok.end <= source.len);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase1-tokenizer-cli, Property 6: Identifier classification
test "property: identifier classification" {
    // For any string matching [a-zA-Z_][a-zA-Z0-9_]* surrounded by whitespace,
    // tokenizer produces .identifier (no keyword table)
    const ident_gen = gen.string(.{ .min_len = 1, .max_len = 32, .charset = .alpha });

    try minish.check(testing.allocator, ident_gen, struct {
        fn prop(ident: []const u8) !void {
            // Use "x <ident> x" to avoid leading whitespace triggering indent
            var buf: [256]u8 = undefined;
            const input = std.fmt.bufPrint(&buf, "x {s} x", .{ident}) catch return;

            const tokens = try tokenize(input, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(tokens);

            // Expect: identifier("x"), identifier(ident), identifier("x")
            try testing.expectEqual(@as(usize, 3), tokens.len);
            try testing.expectEqual(TokenKind.identifier, tokens[1].kind);
            try testing.expectEqualStrings(ident, input[tokens[1].start..tokens[1].end]);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase1-tokenizer-cli, Property 7: Keyword classification correctness
test "property: keyword classification correctness" {
    const ident_gen = gen.string(.{ .min_len = 1, .max_len = 16, .charset = .alpha });

    // Part A: with keyword table, matching identifier → .keyword
    try minish.check(testing.allocator, ident_gen, struct {
        fn prop(word: []const u8) !void {
            var buf: [256]u8 = undefined;
            const input = std.fmt.bufPrint(&buf, "x {s} x", .{word}) catch return;

            const kw_table = &[_][]const u8{word};
            const tokens = try tokenize(input, kw_table, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(tokens);

            // Expect: identifier("x"), keyword(word), identifier("x")
            try testing.expectEqual(@as(usize, 3), tokens.len);
            try testing.expectEqual(TokenKind.keyword, tokens[1].kind);
        }
    }.prop, .{ .num_runs = 100 });

    // Part B: without keyword table, no .keyword tokens ever
    try minish.check(testing.allocator, ident_gen, struct {
        fn prop(word: []const u8) !void {
            var buf: [256]u8 = undefined;
            const input = std.fmt.bufPrint(&buf, "x {s} x", .{word}) catch return;

            const tokens = try tokenize(input, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(tokens);

            for (tokens) |tok| {
                try testing.expect(tok.kind != .keyword);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase1-tokenizer-cli, Property 8: Comment recognition
test "property: comment recognition" {
    // Content for comments: alphanumeric to avoid accidental comment terminators
    const content_gen = gen.string(.{ .min_len = 0, .max_len = 64, .charset = .alphanumeric });

    // Line comment with //
    try minish.check(testing.allocator, content_gen, struct {
        fn prop(content: []const u8) !void {
            var buf: [256]u8 = undefined;
            const input = std.fmt.bufPrint(&buf, "//{s}\n", .{content}) catch return;

            const tokens = try tokenize(input, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(tokens);

            // First token should be .comment spanning from // to before \n
            try testing.expect(tokens.len >= 1);
            try testing.expectEqual(TokenKind.comment, tokens[0].kind);
            try testing.expectEqual(@as(usize, 0), tokens[0].start);
            try testing.expectEqual(2 + content.len, tokens[0].end);
        }
    }.prop, .{ .num_runs = 100 });

    // Line comment with #
    try minish.check(testing.allocator, content_gen, struct {
        fn prop(content: []const u8) !void {
            var buf: [256]u8 = undefined;
            const input = std.fmt.bufPrint(&buf, "#{s}\n", .{content}) catch return;

            const tokens = try tokenize(input, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(tokens);

            try testing.expect(tokens.len >= 1);
            try testing.expectEqual(TokenKind.comment, tokens[0].kind);
            try testing.expectEqual(@as(usize, 0), tokens[0].start);
            try testing.expectEqual(1 + content.len, tokens[0].end);
        }
    }.prop, .{ .num_runs = 100 });

    // Block comment with /* ... */
    try minish.check(testing.allocator, content_gen, struct {
        fn prop(content: []const u8) !void {
            var buf: [256]u8 = undefined;
            const input = std.fmt.bufPrint(&buf, "/*{s}*/", .{content}) catch return;

            const tokens = try tokenize(input, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(tokens);

            try testing.expectEqual(@as(usize, 1), tokens.len);
            try testing.expectEqual(TokenKind.comment, tokens[0].kind);
            try testing.expectEqual(@as(usize, 0), tokens[0].start);
            try testing.expectEqual(input.len, tokens[0].end);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase1-tokenizer-cli, Property 9: String literal recognition
test "property: string literal recognition" {
    // Use alphanumeric content to avoid unescaped quotes or backslashes
    const content_gen = gen.string(.{ .min_len = 0, .max_len = 64, .charset = .alphanumeric });

    // Double-quoted strings
    try minish.check(testing.allocator, content_gen, struct {
        fn prop(content: []const u8) !void {
            var buf: [256]u8 = undefined;
            const input = std.fmt.bufPrint(&buf, "\"{s}\"", .{content}) catch return;

            const tokens = try tokenize(input, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(tokens);

            try testing.expectEqual(@as(usize, 1), tokens.len);
            try testing.expectEqual(TokenKind.string, tokens[0].kind);
            try testing.expectEqual(@as(usize, 0), tokens[0].start);
            try testing.expectEqual(input.len, tokens[0].end);
        }
    }.prop, .{ .num_runs = 100 });

    // Single-quoted strings
    try minish.check(testing.allocator, content_gen, struct {
        fn prop(content: []const u8) !void {
            var buf: [256]u8 = undefined;
            const input = std.fmt.bufPrint(&buf, "'{s}'", .{content}) catch return;

            const tokens = try tokenize(input, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(tokens);

            try testing.expectEqual(@as(usize, 1), tokens.len);
            try testing.expectEqual(TokenKind.string, tokens[0].kind);
            try testing.expectEqual(@as(usize, 0), tokens[0].start);
            try testing.expectEqual(input.len, tokens[0].end);
        }
    }.prop, .{ .num_runs = 100 });

    // Escaped quotes don't terminate early
    try minish.check(testing.allocator, content_gen, struct {
        fn prop(content: []const u8) !void {
            var buf: [256]u8 = undefined;
            // Build: "content\"content"
            const input = std.fmt.bufPrint(&buf, "\"{s}\\\"{s}\"", .{ content, content }) catch return;

            const tokens = try tokenize(input, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(tokens);

            try testing.expectEqual(@as(usize, 1), tokens.len);
            try testing.expectEqual(TokenKind.string, tokens[0].kind);
            try testing.expectEqual(@as(usize, 0), tokens[0].start);
            try testing.expectEqual(input.len, tokens[0].end);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase1-tokenizer-cli, Property 10: Number literal recognition
test "property: number literal recognition" {
    // Integer digits
    const digits_gen = gen.string(.{ .min_len = 1, .max_len = 16, .charset = .numeric });

    // Integer numbers
    try minish.check(testing.allocator, digits_gen, struct {
        fn prop(digits: []const u8) !void {
            var buf: [256]u8 = undefined;
            const input = std.fmt.bufPrint(&buf, "x {s} x", .{digits}) catch return;

            const tokens = try tokenize(input, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(tokens);

            // Expect: identifier("x"), number(digits), identifier("x")
            try testing.expectEqual(@as(usize, 3), tokens.len);
            try testing.expectEqual(TokenKind.number, tokens[1].kind);
            try testing.expectEqualStrings(digits, input[tokens[1].start..tokens[1].end]);
        }
    }.prop, .{ .num_runs = 100 });

    // Decimal numbers: integer_part.fractional_part
    const pair_gen = gen.tuple2(
        []const u8,
        []const u8,
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .numeric }),
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .numeric }),
    );

    try minish.check(testing.allocator, pair_gen, struct {
        fn prop(parts: struct { []const u8, []const u8 }) !void {
            var buf: [256]u8 = undefined;
            const input = std.fmt.bufPrint(&buf, "x {s}.{s} x", .{ parts[0], parts[1] }) catch return;

            const tokens = try tokenize(input, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(tokens);

            // Expect: identifier("x"), number(N.N), identifier("x")
            try testing.expectEqual(@as(usize, 3), tokens.len);
            try testing.expectEqual(TokenKind.number, tokens[1].kind);

            // Token text should be "integer.fractional"
            var expected_buf: [64]u8 = undefined;
            const expected = std.fmt.bufPrint(&expected_buf, "{s}.{s}", .{ parts[0], parts[1] }) catch return;
            try testing.expectEqualStrings(expected, input[tokens[1].start..tokens[1].end]);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase1-tokenizer-cli, Property 11: Indent recognition
test "property: indent recognition" {
    // Generate whitespace strings of spaces and tabs
    const ws_gen = gen.string(.{ .min_len = 1, .max_len = 16, .charset = .custom, .custom_chars = " \t" });

    try minish.check(testing.allocator, ws_gen, struct {
        fn prop(ws: []const u8) !void {
            var buf: [256]u8 = undefined;
            // "\n<whitespace>x" — indent after newline
            const input = std.fmt.bufPrint(&buf, "\n{s}x", .{ws}) catch return;

            const tokens = try tokenize(input, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(tokens);

            // Expect: newline, indent, identifier
            try testing.expect(tokens.len >= 2);
            try testing.expectEqual(TokenKind.newline, tokens[0].kind);
            try testing.expectEqual(TokenKind.indent, tokens[1].kind);

            // Indent token should cover exactly the whitespace
            const indent_text = input[tokens[1].start..tokens[1].end];
            try testing.expectEqualStrings(ws, indent_text);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase1-tokenizer-cli, Property 12: Non-indentation whitespace skipping
test "property: non-indentation whitespace skipping" {
    // Generate whitespace of varying length between two identifiers
    const ws_gen = gen.string(.{ .min_len = 1, .max_len = 32, .charset = .custom, .custom_chars = " \t" });

    try minish.check(testing.allocator, ws_gen, struct {
        fn prop(ws: []const u8) !void {
            var buf: [256]u8 = undefined;
            // "a<whitespace>b" — whitespace between tokens, not at line start
            const input = std.fmt.bufPrint(&buf, "a{s}b", .{ws}) catch return;

            const tokens = try tokenize(input, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(tokens);

            // Should produce exactly two identifier tokens, no whitespace tokens
            try testing.expectEqual(@as(usize, 2), tokens.len);
            try testing.expectEqual(TokenKind.identifier, tokens[0].kind);
            try testing.expectEqual(TokenKind.identifier, tokens[1].kind);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase1-tokenizer-cli, Property 13: Unclosed construct resilience
test "property: unclosed construct resilience" {
    const content_gen = gen.string(.{ .min_len = 0, .max_len = 64, .charset = .alphanumeric });

    // Unclosed double-quoted string
    try minish.check(testing.allocator, content_gen, struct {
        fn prop(content: []const u8) !void {
            var buf: [256]u8 = undefined;
            const input = std.fmt.bufPrint(&buf, "\"{s}", .{content}) catch return;

            const tokens = try tokenize(input, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(tokens);

            // Should produce a string token extending to end of input
            try testing.expect(tokens.len >= 1);
            const last = tokens[tokens.len - 1];
            try testing.expectEqual(TokenKind.string, last.kind);
            try testing.expectEqual(input.len, last.end);
        }
    }.prop, .{ .num_runs = 100 });

    // Unclosed single-quoted string
    try minish.check(testing.allocator, content_gen, struct {
        fn prop(content: []const u8) !void {
            var buf: [256]u8 = undefined;
            const input = std.fmt.bufPrint(&buf, "'{s}", .{content}) catch return;

            const tokens = try tokenize(input, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(tokens);

            try testing.expect(tokens.len >= 1);
            const last = tokens[tokens.len - 1];
            try testing.expectEqual(TokenKind.string, last.kind);
            try testing.expectEqual(input.len, last.end);
        }
    }.prop, .{ .num_runs = 100 });

    // Unclosed block comment
    try minish.check(testing.allocator, content_gen, struct {
        fn prop(content: []const u8) !void {
            var buf: [256]u8 = undefined;
            const input = std.fmt.bufPrint(&buf, "/*{s}", .{content}) catch return;

            const tokens = try tokenize(input, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(tokens);

            try testing.expect(tokens.len >= 1);
            const last = tokens[tokens.len - 1];
            try testing.expectEqual(TokenKind.comment, last.kind);
            try testing.expectEqual(input.len, last.end);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: configurable-comment-prefixes, Property 2: Line Comment Single Token Emission
// **Validates: Requirements 3.1, 3.5**
test "property: line comment single token emission" {
    // Alphanumeric body keeps the comment on one line and avoids accidental
    // secondary prefixes, so the "exactly one .comment token" assertion is deterministic.
    const body_gen = gen.string(.{ .min_len = 0, .max_len = 64, .charset = .alphanumeric });

    try minish.check(testing.allocator, body_gen, struct {
        fn prop(body: []const u8) !void {
            var buf: [256]u8 = undefined;
            const input = std.fmt.bufPrint(&buf, "%{s}\n", .{body}) catch return;

            const config = CommentConfig{ .line_prefixes = &.{"%"} };
            const tokens = try tokenize(input, null, config, testing.allocator);
            defer testing.allocator.free(tokens);

            // First token is the single comment, spanning prefix to EOL (exclusive of \n).
            try testing.expect(tokens.len >= 1);
            try testing.expectEqual(TokenKind.comment, tokens[0].kind);
            try testing.expectEqual(@as(usize, 0), tokens[0].start);
            try testing.expectEqual(1 + body.len, tokens[0].end); // "%" (len 1) + body
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: configurable-comment-prefixes, Property 3: Default Config Behavioral Equivalence
// **Validates: Requirements 2.1, 2.2**
test "property: default config behavioral equivalence" {
    // Invariant check against the DOCUMENTED default behavior (// and # line comments to EOL,
    // /* */ block comments). There is no removed hardcoded path to diff against — the
    // assertions describe default comment semantics structurally. If a generated source makes
    // the tokenizer disagree with this invariant, that is a possible production bug — report,
    // do NOT patch.
    const source_gen = gen.string(.{ .min_len = 0, .max_len = 256, .charset = .ascii });

    try minish.check(testing.allocator, source_gen, struct {
        fn prop(source: []const u8) !void {
            const tokens = try tokenize(source, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(tokens);

            for (tokens) |tok| {
                if (tok.kind != .comment) continue;
                const text = source[tok.start..tok.end];
                const is_line = std.mem.startsWith(u8, text, "//") or std.mem.startsWith(u8, text, "#");
                const is_block = std.mem.startsWith(u8, text, "/*");
                // Every comment token must begin with a default prefix.
                try testing.expect(is_line or is_block);

                if (is_line) {
                    // Line comment is EOL-exclusive: it must not contain a newline.
                    try testing.expect(std.mem.indexOfScalar(u8, text, '\n') == null);
                } else {
                    // Block comment either ends just past a */ close or extends to EOF (unclosed).
                    const closed = std.mem.endsWith(u8, text, "*/") and text.len >= 4;
                    const unclosed = tok.end == source.len;
                    try testing.expect(closed or unclosed);
                }
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: configurable-comment-prefixes, Property 4: Block Comment Line Tracking
// **Validates: Requirements 4.5**
test "property: block comment line tracking" {
    // N internal newlines inside a block comment; the token after the comment must sit N lines
    // below the comment's starting line.
    const n_gen = gen.intRange(u8, 0, 8);

    try minish.check(testing.allocator, n_gen, struct {
        fn prop(n: u8) !void {
            var aw: std.Io.Writer.Allocating = .init(testing.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            try w.writeAll("/*");
            var i: usize = 0;
            while (i < n) : (i += 1) {
                try w.writeByte('\n');
            }
            try w.writeAll("*/x");
            const input = aw.written();

            const config = CommentConfig{ .block_open = "/*", .block_close = "*/" };
            const tokens = try tokenize(input, null, config, testing.allocator);
            defer testing.allocator.free(tokens);

            // Locate the comment token and the following identifier ("x").
            try testing.expectEqual(@as(usize, 2), tokens.len);
            try testing.expectEqual(TokenKind.comment, tokens[0].kind);
            try testing.expectEqual(TokenKind.identifier, tokens[1].kind);
            try testing.expectEqual(tokens[0].line + n, tokens[1].line);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: configurable-comment-prefixes, Property 5: Longest Match Priority
// **Validates: Requirements 7.2, 7.3**
test "property: longest match priority" {
    // Config lists both a short prefix and a longer superset; a source starting with the longer
    // prefix must select the longer one and emit a single comment token.
    const body_gen = gen.string(.{ .min_len = 0, .max_len = 64, .charset = .alphanumeric });

    try minish.check(testing.allocator, body_gen, struct {
        fn prop(body: []const u8) !void {
            var buf: [256]u8 = undefined;
            const input = std.fmt.bufPrint(&buf, "--{s}\n", .{body}) catch return;

            const config = CommentConfig{ .line_prefixes = &.{ "-", "--" } };
            const tokens = try tokenize(input, null, config, testing.allocator);
            defer testing.allocator.free(tokens);

            // Single leading comment token spanning the "--" prefix plus body (EOL-exclusive).
            try testing.expect(tokens.len >= 1);
            try testing.expectEqual(TokenKind.comment, tokens[0].kind);
            try testing.expectEqual(@as(usize, 0), tokens[0].start);
            try testing.expectEqual(2 + body.len, tokens[0].end); // "--" (len 2) + body
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: configurable-comment-prefixes, Property 6: Empty Config Produces No Comment Tokens
// **Validates: Requirements 3.4, 4.3**
test "property: empty config produces no comment tokens" {
    const source_gen = gen.string(.{ .min_len = 0, .max_len = 256, .charset = .ascii });

    try minish.check(testing.allocator, source_gen, struct {
        fn prop(source: []const u8) !void {
            const tokens = try tokenize(source, null, CommentConfig.none, testing.allocator);
            defer testing.allocator.free(tokens);

            for (tokens) |tok| {
                try testing.expect(tok.kind != .comment);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: configurable-comment-prefixes, Property 8: Token Count Reduction for Configured Languages
// **Validates: Requirements 3.1**
test "property: token count reduction" {
    // A comment line with >=2 content tokens collapses to a single comment token when the
    // prefix is configured, so the configured run yields strictly fewer tokens than CommentConfig.none.
    const body_gen = gen.string(.{ .min_len = 1, .max_len = 16, .charset = .alpha });

    try minish.check(testing.allocator, body_gen, struct {
        fn prop(body: []const u8) !void {
            var buf: [256]u8 = undefined;
            const input = std.fmt.bufPrint(&buf, "% {s} {s} {s}\n", .{ body, body, body }) catch return;

            const config = CommentConfig{ .line_prefixes = &.{"%"} };
            const configured = try tokenize(input, null, config, testing.allocator);
            defer testing.allocator.free(configured);

            const none = try tokenize(input, null, CommentConfig.none, testing.allocator);
            defer testing.allocator.free(none);

            try testing.expect(configured.len < none.len);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: configurable-comment-prefixes, Property 9: Quote-in-Comment Does Not Open a String
// **Validates: Requirements 8.1, 8.2, 7.2**
test "property: quote in comment does not open string" {
    // Body is alphanumeric-ish plus quote characters (', ", backtick) but no newline, so the
    // comment stays one line. Quotes inside a comment must not open a string token.
    const body_gen = gen.string(.{ .min_len = 0, .max_len = 48, .charset = .custom, .custom_chars = "abc '\"`" });

    try minish.check(testing.allocator, body_gen, struct {
        fn prop(body: []const u8) !void {
            var buf: [256]u8 = undefined;
            // Single leading space exercises the optional-leading-whitespace case.
            const input = std.fmt.bufPrint(&buf, "% {s}\n", .{body}) catch return;

            const config = CommentConfig{ .line_prefixes = &.{"%"} };
            const tokens = try tokenize(input, null, config, testing.allocator);
            defer testing.allocator.free(tokens);

            // Exactly one comment token for the line, and zero string tokens from the quotes.
            var comment_count: usize = 0;
            for (tokens) |tok| {
                if (tok.kind == .comment) comment_count += 1;
                try testing.expect(tok.kind != .string);
            }
            try testing.expectEqual(@as(usize, 1), comment_count);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: configurable-comment-prefixes, Property 10: Comment Does Not Swallow Subsequent Code
// **Validates: Requirements 8.3, 8.4**
// NOTE: asserted at the TOKEN level. tokenizer.zig cannot import engine.zig without creating an
// import cycle (engine imports tokenizer), so the parse-level assertion is intentionally omitted;
// token-level resumption still validates Requirements 8.3/8.4.
test "property: comment does not swallow subsequent code" {
    // An odd number of apostrophes in a comment line must not open a string that swallows the
    // following code line.
    const n_gen = gen.intRange(u8, 1, 9);

    try minish.check(testing.allocator, n_gen, struct {
        fn prop(n_raw: u8) !void {
            const odd: usize = @as(usize, n_raw) | 1; // force odd count of apostrophes
            var aw: std.Io.Writer.Allocating = .init(testing.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            try w.writeAll("% ");
            var i: usize = 0;
            while (i < odd) : (i += 1) {
                try w.writeByte('\'');
            }
            try w.writeAll("\nx = 1");
            const input = aw.written();

            const config = CommentConfig{ .line_prefixes = &.{"%"} };
            const tokens = try tokenize(input, null, config, testing.allocator);
            defer testing.allocator.free(tokens);

            // Expect: comment, newline, identifier("x"), operator("="), number("1").
            try testing.expectEqual(@as(usize, 5), tokens.len);
            try testing.expectEqual(TokenKind.comment, tokens[0].kind);
            try testing.expectEqual(TokenKind.newline, tokens[1].kind);
            try testing.expectEqual(TokenKind.identifier, tokens[2].kind);
            try testing.expectEqualStrings("x", input[tokens[2].start..tokens[2].end]);
            try testing.expectEqual(TokenKind.operator, tokens[3].kind);
            try testing.expectEqualStrings("=", input[tokens[3].start..tokens[3].end]);
            try testing.expectEqual(TokenKind.number, tokens[4].kind);
            try testing.expectEqualStrings("1", input[tokens[4].start..tokens[4].end]);
        }
    }.prop, .{ .num_runs = 100 });
}


// --- Grammar vocabulary scan tests (configurable-token-kinds) ---

fn ccAlpha() CharClass {
    var cc = CharClass{};
    cc.set('a');
    cc.set('b');
    cc.set('c');
    cc.set('d');
    cc.set('e');
    cc.set('f');
    cc.set('g');
    cc.set('h');
    cc.set('i');
    cc.set('j');
    cc.set('k');
    cc.set('l');
    cc.set('m');
    cc.set('n');
    cc.set('o');
    cc.set('p');
    cc.set('q');
    cc.set('r');
    cc.set('s');
    cc.set('t');
    cc.set('u');
    cc.set('v');
    cc.set('w');
    cc.set('x');
    cc.set('y');
    cc.set('z');
    cc.set('A');
    cc.set('B');
    cc.set('C');
    cc.set('D');
    cc.set('E');
    cc.set('F');
    cc.set('G');
    cc.set('H');
    cc.set('I');
    cc.set('J');
    cc.set('K');
    cc.set('L');
    cc.set('M');
    cc.set('N');
    cc.set('O');
    cc.set('P');
    cc.set('Q');
    cc.set('R');
    cc.set('S');
    cc.set('T');
    cc.set('U');
    cc.set('V');
    cc.set('W');
    cc.set('X');
    cc.set('Y');
    cc.set('Z');
    cc.set('_');
    return cc;
}

fn ccAlphaNum() CharClass {
    var cc = ccAlpha();
    var d: u8 = '0';
    while (d <= '9') : (d += 1) cc.set(d);
    return cc;
}

fn ccDigits() CharClass {
    var cc = CharClass{};
    var d: u8 = '0';
    while (d <= '9') : (d += 1) cc.set(d);
    return cc;
}

test "tokenizeWithVocab: char_class_run greedy + start/continue split" {
    const ident = KindDefinition{
        .name = "identifier",
        .recognizer = .{ .char_class_run = .{ .start = ccAlpha(), .cont = ccAlphaNum() } },
    };
    const num = KindDefinition{
        .name = "number",
        .recognizer = .{ .char_class_run = .{ .start = ccDigits(), .cont = ccDigits() } },
    };
    const vocab = KindVocabulary{ .kinds = &.{ ident, num } };

    const tokens = try tokenizeWithVocab("foo123 abc 42", vocab, null, CommentConfig.default, testing.allocator);
    defer testing.allocator.free(tokens);

    try testing.expectEqual(@as(usize, 3), tokens.len);
    try testing.expectEqual(TokenKind.identifier, tokens[0].kind);
    try testing.expectEqual(@as(usize, 0), tokens[0].kind_id);
    try testing.expectEqualStrings("foo123", "foo123 abc 42"[tokens[0].start..tokens[0].end]);
    try testing.expectEqual(TokenKind.identifier, tokens[1].kind);
    try testing.expectEqualStrings("abc", "foo123 abc 42"[tokens[1].start..tokens[1].end]);
    try testing.expectEqual(TokenKind.number, tokens[2].kind);
    try testing.expectEqual(@as(usize, 1), tokens[2].kind_id);
    try testing.expectEqualStrings("42", "foo123 abc 42"[tokens[2].start..tokens[2].end]);
}

test "tokenizeWithVocab: first-declared kind wins on ambiguity" {
    // Both kinds match at the same position; priority order decides.
    const letters = KindDefinition{
        .name = "letters",
        .recognizer = .{ .char_class_run = .{ .start = ccAlpha(), .cont = ccAlpha() } },
    };
    const alnum = KindDefinition{
        .name = "alnum",
        .recognizer = .{ .char_class_run = .{ .start = ccAlpha(), .cont = ccAlphaNum() } },
    };
    const vocab = KindVocabulary{ .kinds = &.{ letters, alnum } };

    const tokens = try tokenizeWithVocab("a1", vocab, null, CommentConfig.default, testing.allocator);
    defer testing.allocator.free(tokens);

    try testing.expectEqual(@as(usize, 1), tokens.len);
    try testing.expectEqual(@as(usize, 0), tokens[0].kind_id);
    try testing.expectEqualStrings("a", "a1"[tokens[0].start..tokens[0].end]);
    try testing.expectEqual(@as(usize, 1), tokens[0].end);
}

test "tokenizeWithVocab: delimited_span with escape and EOF fallback" {
    const str = KindDefinition{
        .name = "string",
        .recognizer = .{ .delimited_span = .{ .open = "\"", .close = "\"", .escape = '\\' } },
    };
    const vocab = KindVocabulary{ .kinds = &.{str} };

    // Escaped quote does not close; token spans to the closing quote.
    const src1 = "\"a\\\"b\"";
    const t1 = try tokenizeWithVocab(src1, vocab, null, CommentConfig.default, testing.allocator);
    defer testing.allocator.free(t1);
    try testing.expectEqual(@as(usize, 1), t1.len);
    try testing.expectEqual(@as(usize, 0), t1[0].start);
    try testing.expectEqual(src1.len, t1[0].end);

    // Unclosed span extends to EOF.
    const src2 = "\"abc";
    const t2 = try tokenizeWithVocab(src2, vocab, null, CommentConfig.default, testing.allocator);
    defer testing.allocator.free(t2);
    try testing.expectEqual(@as(usize, 1), t2.len);
    try testing.expectEqual(src2.len, t2[0].end);
}

test "tokenizeWithVocab: literal_set longest match wins" {
    const arrow = KindDefinition{
        .name = "arrow",
        .recognizer = .{ .literal_set = &.{ "->", "-" } },
    };
    const vocab = KindVocabulary{ .kinds = &.{arrow} };

    const tokens = try tokenizeWithVocab("-> -", vocab, null, CommentConfig.default, testing.allocator);
    defer testing.allocator.free(tokens);
    try testing.expectEqual(@as(usize, 2), tokens.len);
    try testing.expectEqualStrings("->", "-> -"[tokens[0].start..tokens[0].end]);
    try testing.expectEqualStrings("-", "-> -"[tokens[1].start..tokens[1].end]);
}

test "tokenizeWithVocab: structural kinds still emitted" {
    const ident = KindDefinition{
        .name = "identifier",
        .recognizer = .{ .char_class_run = .{ .start = ccAlpha(), .cont = ccAlphaNum() } },
    };
    const vocab = KindVocabulary{ .kinds = &.{ident} };

    const tokens = try tokenizeWithVocab("a\n  b", vocab, null, CommentConfig.default, testing.allocator);
    defer testing.allocator.free(tokens);
    try testing.expectEqual(@as(usize, 4), tokens.len);
    try testing.expectEqual(TokenKind.identifier, tokens[0].kind);
    try testing.expectEqual(TokenKind.newline, tokens[1].kind);
    try testing.expectEqual(TokenKind.indent, tokens[2].kind);
    try testing.expectEqualStrings("  ", "a\n  b"[tokens[2].start..tokens[2].end]);
    try testing.expectEqual(TokenKind.identifier, tokens[3].kind);
}

test "tokenizeWithVocab: comments via Config and unknown byte advance" {
    const ident = KindDefinition{
        .name = "identifier",
        .recognizer = .{ .char_class_run = .{ .start = ccAlpha(), .cont = ccAlphaNum() } },
    };
    const vocab = KindVocabulary{ .kinds = &.{ident} };
    const cfg = CommentConfig{ .line_prefixes = &.{"%"} };

    const tokens = try tokenizeWithVocab("% hi\nx@y", vocab, null, cfg, testing.allocator);
    defer testing.allocator.free(tokens);
    // comment, newline, identifier("x"), identifier("y") — '@' skipped.
    try testing.expectEqual(@as(usize, 4), tokens.len);
    try testing.expectEqual(TokenKind.comment, tokens[0].kind);
    try testing.expectEqual(TokenKind.newline, tokens[1].kind);
    try testing.expectEqual(TokenKind.identifier, tokens[2].kind);
    try testing.expectEqualStrings("x", "% hi\nx@y"[tokens[2].start..tokens[2].end]);
    try testing.expectEqual(TokenKind.identifier, tokens[3].kind);
    try testing.expectEqualStrings("y", "% hi\nx@y"[tokens[3].start..tokens[3].end]);
}

test "tokenizeWithVocab: keyword overlay promotes identifier-run kind" {
    const ident = KindDefinition{
        .name = "identifier",
        .recognizer = .{ .char_class_run = .{ .start = ccAlpha(), .cont = ccAlphaNum() } },
    };
    const vocab = KindVocabulary{ .kinds = &.{ident} };
    const keywords = [_][]const u8{"fn"};

    const tokens = try tokenizeWithVocab("fn foo", vocab, &keywords, CommentConfig.default, testing.allocator);
    defer testing.allocator.free(tokens);
    try testing.expectEqual(@as(usize, 2), tokens.len);
    try testing.expectEqual(TokenKind.keyword, tokens[0].kind);
    try testing.expectEqual(TokenKind.identifier, tokens[1].kind);
}

test "tokenizeWithVocab: empty source yields no tokens" {
    const vocab = KindVocabulary{ .kinds = &.{} };
    const tokens = try tokenizeWithVocab("", vocab, null, CommentConfig.default, testing.allocator);
    defer testing.allocator.free(tokens);
    try testing.expectEqual(@as(usize, 0), tokens.len);
}

// Feature: configurable-token-kinds, Property 2: Char-class-run greedy maximal match
test "property: char_class_run greedy maximal match" {
    const word_gen = gen.string(.{ .min_len = 1, .max_len = 32, .charset = .alphanumeric });

    try minish.check(testing.allocator, word_gen, struct {
        fn prop(word: []const u8) !void {
            const ident = KindDefinition{
                .name = "identifier",
                .recognizer = .{ .char_class_run = .{ .start = ccAlpha(), .cont = ccAlphaNum() } },
            };
            const vocab = KindVocabulary{ .kinds = &.{ident} };
            var buf: [256]u8 = undefined;
            const input = std.fmt.bufPrint(&buf, "x{s}", .{word}) catch return;
            const tokens = try tokenizeWithVocab(input, vocab, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(tokens);
            try testing.expectEqual(@as(usize, 1), tokens.len);
            try testing.expectEqual(input.len, tokens[0].end);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: configurable-token-kinds, Property 3: Recognizer priority determinism
test "property: recognizer priority determinism" {
    const word_gen = gen.string(.{ .min_len = 1, .max_len = 24, .charset = .alphanumeric });

    try minish.check(testing.allocator, word_gen, struct {
        fn prop(word: []const u8) !void {
            const letters = KindDefinition{
                .name = "letters",
                .recognizer = .{ .char_class_run = .{ .start = ccAlpha(), .cont = ccAlpha() } },
            };
            const alnum = KindDefinition{
                .name = "alnum",
                .recognizer = .{ .char_class_run = .{ .start = ccAlpha(), .cont = ccAlphaNum() } },
            };
            const vocab = KindVocabulary{ .kinds = &.{ letters, alnum } };
            var buf: [256]u8 = undefined;
            const input = std.fmt.bufPrint(&buf, "a{s}", .{word}) catch return;
            const t1 = try tokenizeWithVocab(input, vocab, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(t1);
            const t2 = try tokenizeWithVocab(input, vocab, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(t2);
            try testing.expectEqual(t1.len, t2.len);
            for (t1, t2) |a, b| {
                try testing.expectEqual(a.kind_id, b.kind_id);
                try testing.expectEqual(a.start, b.start);
                try testing.expectEqual(a.end, b.end);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: configurable-token-kinds, Property 4: Delimited-span boundaries and escapes
test "property: delimited_span boundaries and escapes" {
    const body_gen = gen.string(.{ .min_len = 0, .max_len = 32, .charset = .custom, .custom_chars = "abc XYZ123 " });

    try minish.check(testing.allocator, body_gen, struct {
        fn prop(body: []const u8) !void {
            const str = KindDefinition{
                .name = "string",
                .recognizer = .{ .delimited_span = .{ .open = "\"", .close = "\"", .escape = '\\' } },
            };
            const ident = KindDefinition{
                .name = "identifier",
                .recognizer = .{ .char_class_run = .{ .start = ccAlpha(), .cont = ccAlphaNum() } },
            };
            const vocab = KindVocabulary{ .kinds = &.{ str, ident } };
            var aw: std.Io.Writer.Allocating = .init(testing.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            try w.writeByte('"');
            try w.writeAll(body);
            try w.writeByte('"');
            try w.writeByte('x');
            const input = aw.written();

            const tokens = try tokenizeWithVocab(input, vocab, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(tokens);
            try testing.expectEqual(@as(usize, 2), tokens.len);
            // First token spans open quote through close quote.
            try testing.expectEqual(@as(usize, 0), tokens[0].start);
            try testing.expectEqual(input.len - 1, tokens[0].end);
            try testing.expectEqual(TokenKind.identifier, tokens[1].kind);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: configurable-token-kinds, Property 5: Literal-set exact membership
test "property: literal_set exact membership" {
    const idx_gen = gen.intRange(u8, 0, 2);

    try minish.check(testing.allocator, idx_gen, struct {
        fn prop(idx: u8) !void {
            const op = KindDefinition{
                .name = "op",
                .recognizer = .{ .literal_set = &.{ "->", "=>", "::" } },
            };
            const vocab = KindVocabulary{ .kinds = &.{op} };
            const lits = [_][]const u8{ "->", "=>", "::" };
            const input = lits[idx];
            const tokens = try tokenizeWithVocab(input, vocab, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(tokens);
            try testing.expectEqual(@as(usize, 1), tokens.len);
            try testing.expectEqualStrings(input, input[tokens[0].start..tokens[0].end]);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: configurable-token-kinds, Property 8: Single-pass linearity (coverage + no overlap)
test "property: vocab scan is single-pass and total" {
    const source_gen = gen.string(.{ .min_len = 0, .max_len = 128, .charset = .custom, .custom_chars = "abc123 \n\t" });

    try minish.check(testing.allocator, source_gen, struct {
        fn prop(source: []const u8) !void {
            const ident = KindDefinition{
                .name = "identifier",
                .recognizer = .{ .char_class_run = .{ .start = ccAlpha(), .cont = ccAlphaNum() } },
            };
            const num = KindDefinition{
                .name = "number",
                .recognizer = .{ .char_class_run = .{ .start = ccDigits(), .cont = ccDigits() } },
            };
            const vocab = KindVocabulary{ .kinds = &.{ ident, num } };
            const tokens = try tokenizeWithVocab(source, vocab, null, CommentConfig.default, testing.allocator);
            defer testing.allocator.free(tokens);

            // Tokens are ordered and non-overlapping.
            var prev_end: usize = 0;
            for (tokens) |tok| {
                try testing.expect(tok.start >= prev_end);
                try testing.expect(tok.end > tok.start);
                prev_end = tok.end;
            }
            // Unknown bytes are skipped, so coverage may be partial — but never beyond source.
            try testing.expect(tokens.len == 0 or tokens[tokens.len - 1].end <= source.len);
        }
    }.prop, .{ .num_runs = 100 });
}
