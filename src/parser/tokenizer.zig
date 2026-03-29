const std = @import("std");

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
};

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
/// All allocations use the provided allocator (arena).
pub fn tokenize(
    source: []const u8,
    keyword_table: ?[]const []const u8,
    allocator: std.mem.Allocator,
) ![]Token {
    if (source.len == 0) return &[_]Token{};

    var tokens: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    var at_line_start = true;

    while (i < source.len) {
        const c = source[i];

        // Newline
        if (c == '\n') {
            try tokens.append(allocator, .{ .kind = .newline, .start = i, .end = i + 1 });
            i += 1;
            at_line_start = true;

            // Check for indent after newline
            const indent_start = i;
            while (i < source.len and isWhitespace(source[i])) : (i += 1) {}
            if (i > indent_start) {
                try tokens.append(allocator, .{ .kind = .indent, .start = indent_start, .end = i });
            }
            continue;
        }

        // Skip non-indentation whitespace
        if (isWhitespace(c)) {
            if (at_line_start) {
                const indent_start = i;
                while (i < source.len and isWhitespace(source[i])) : (i += 1) {}
                try tokens.append(allocator, .{ .kind = .indent, .start = indent_start, .end = i });
                at_line_start = false;
            } else {
                i += 1;
            }
            continue;
        }

        at_line_start = false;

        // Line comment: // or #
        if (c == '#' or (c == '/' and i + 1 < source.len and source[i + 1] == '/')) {
            const start = i;
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            try tokens.append(allocator, .{ .kind = .comment, .start = start, .end = i });
            continue;
        }

        // Block comment: /* ... */
        if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
            const start = i;
            i += 2;
            while (i + 1 < source.len) {
                if (source[i] == '*' and source[i + 1] == '/') {
                    i += 2;
                    break;
                }
                i += 1;
            } else {
                // Unclosed block comment — extend to end
                i = source.len;
            }
            try tokens.append(allocator, .{ .kind = .comment, .start = start, .end = i });
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
            try tokens.append(allocator, .{ .kind = .string, .start = start, .end = i });
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
            try tokens.append(allocator, .{ .kind = .number, .start = start, .end = i });
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
            try tokens.append(allocator, .{ .kind = kind, .start = start, .end = i });
            continue;
        }

        // Operators
        if (isOperator(c)) {
            try tokens.append(allocator, .{ .kind = .operator, .start = i, .end = i + 1 });
            i += 1;
            continue;
        }

        // Delimiters
        if (isDelimiter(c)) {
            try tokens.append(allocator, .{ .kind = .delimiter, .start = i, .end = i + 1 });
            i += 1;
            continue;
        }

        // Symbols
        if (isSymbol(c)) {
            try tokens.append(allocator, .{ .kind = .symbol, .start = i, .end = i + 1 });
            i += 1;
            continue;
        }

        // Unknown bytes — skip
        i += 1;
    }

    return tokens.toOwnedSlice(allocator);
}

// --- Unit Tests ---

const testing = std.testing;

fn expectTokens(source: []const u8, keyword_table: ?[]const []const u8, expected: []const struct { kind: TokenKind, text: []const u8 }) !void {
    const tokens = try tokenize(source, keyword_table, testing.allocator);
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
    const tokens = try tokenize("", null, testing.allocator);
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
