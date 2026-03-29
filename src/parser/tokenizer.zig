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

// --- Property Tests ---

const minish = @import("minish");
const gen = minish.gen;

// Feature: phase1-tokenizer-cli, Property 5: Token bounds invariant
test "property: token bounds invariant" {
    // For any source bytes, every token satisfies start <= end <= source.len
    const source_gen = gen.string(.{ .min_len = 0, .max_len = 256, .charset = .ascii });

    try minish.check(testing.allocator, source_gen, struct {
        fn prop(source: []const u8) !void {
            const tokens = try tokenize(source, null, testing.allocator);
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

            const tokens = try tokenize(input, null, testing.allocator);
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
            const tokens = try tokenize(input, kw_table, testing.allocator);
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

            const tokens = try tokenize(input, null, testing.allocator);
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

            const tokens = try tokenize(input, null, testing.allocator);
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

            const tokens = try tokenize(input, null, testing.allocator);
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

            const tokens = try tokenize(input, null, testing.allocator);
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

            const tokens = try tokenize(input, null, testing.allocator);
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

            const tokens = try tokenize(input, null, testing.allocator);
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

            const tokens = try tokenize(input, null, testing.allocator);
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

            const tokens = try tokenize(input, null, testing.allocator);
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

            const tokens = try tokenize(input, null, testing.allocator);
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

            const tokens = try tokenize(input, null, testing.allocator);
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

            const tokens = try tokenize(input, null, testing.allocator);
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

            const tokens = try tokenize(input, null, testing.allocator);
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

            const tokens = try tokenize(input, null, testing.allocator);
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

            const tokens = try tokenize(input, null, testing.allocator);
            defer testing.allocator.free(tokens);

            try testing.expect(tokens.len >= 1);
            const last = tokens[tokens.len - 1];
            try testing.expectEqual(TokenKind.comment, last.kind);
            try testing.expectEqual(input.len, last.end);
        }
    }.prop, .{ .num_runs = 100 });
}
