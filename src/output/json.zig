const std = @import("std");
const tokenizer = @import("../parser/tokenizer.zig");
const Token = tokenizer.Token;
const TokenKind = tokenizer.TokenKind;

/// Maps a TokenKind to its lowercase JSON string name.
fn tokenKindToString(kind: TokenKind) []const u8 {
    return switch (kind) {
        .identifier => "identifier",
        .keyword => "keyword",
        .symbol => "symbol",
        .string => "string",
        .number => "number",
        .operator => "operator",
        .newline => "newline",
        .indent => "indent",
        .comment => "comment",
        .delimiter => "delimiter",
    };
}

/// Serializes a token array to JSON format and writes to the provided writer.
/// Format: { "events": [ { "type": "...", "start": N, "end": N }, ... ] }
/// Writes directly to the writer with no intermediate string allocation.
pub fn serializeTokens(tokens: []const Token, writer: anytype) !void {
    try writer.writeAll("{ \"events\": [");

    for (tokens, 0..) |tok, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll(" { \"type\": \"");
        try writer.writeAll(tokenKindToString(tok.kind));
        try writer.writeAll("\", \"start\": ");
        try writer.print("{d}", .{tok.start});
        try writer.writeAll(", \"end\": ");
        try writer.print("{d}", .{tok.end});
        try writer.writeAll(" }");
    }

    if (tokens.len > 0) {
        try writer.writeAll(" ");
    }
    try writer.writeAll("] }");
}


// --- Unit Tests ---

const testing = std.testing;

fn serializeToString(tokens: []const Token) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(testing.allocator);
    try serializeTokens(tokens, buf.writer(testing.allocator));
    return buf.toOwnedSlice(testing.allocator);
}

test "serializeTokens empty tokens" {
    const result = try serializeToString(&[_]Token{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("{ \"events\": [] }", result);
}

test "serializeTokens single token" {
    const tokens = [_]Token{
        .{ .kind = .identifier, .start = 0, .end = 5 },
    };
    const result = try serializeToString(&tokens);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(
        "{ \"events\": [ { \"type\": \"identifier\", \"start\": 0, \"end\": 5 } ] }",
        result,
    );
}

test "serializeTokens multiple tokens" {
    const tokens = [_]Token{
        .{ .kind = .keyword, .start = 0, .end = 2 },
        .{ .kind = .identifier, .start = 3, .end = 6 },
        .{ .kind = .delimiter, .start = 6, .end = 7 },
    };
    const result = try serializeToString(&tokens);
    defer testing.allocator.free(result);

    const expected =
        "{ \"events\": [ { \"type\": \"keyword\", \"start\": 0, \"end\": 2 }," ++
        " { \"type\": \"identifier\", \"start\": 3, \"end\": 6 }," ++
        " { \"type\": \"delimiter\", \"start\": 6, \"end\": 7 } ] }";
    try testing.expectEqualStrings(expected, result);
}

test "serializeTokens output is valid JSON" {
    const tokens = [_]Token{
        .{ .kind = .string, .start = 0, .end = 7 },
        .{ .kind = .operator, .start = 8, .end = 9 },
        .{ .kind = .number, .start = 10, .end = 12 },
    };
    const result = try serializeToString(&tokens);
    defer testing.allocator.free(result);

    // Verify it parses as valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();

    // Check top-level "events" key exists and is an array
    const events = parsed.value.object.get("events").?;
    try testing.expectEqual(@as(usize, 3), events.array.items.len);

    // Check first event fields
    const first = events.array.items[0].object;
    try testing.expectEqualStrings("string", first.get("type").?.string);
    try testing.expectEqual(@as(i64, 0), first.get("start").?.integer);
    try testing.expectEqual(@as(i64, 7), first.get("end").?.integer);
}

test "serializeTokens all token kinds" {
    const kinds = [_]TokenKind{ .identifier, .keyword, .symbol, .string, .number, .operator, .newline, .indent, .comment, .delimiter };
    const names = [_][]const u8{ "identifier", "keyword", "symbol", "string", "number", "operator", "newline", "indent", "comment", "delimiter" };

    for (kinds, names) |kind, expected_name| {
        const tokens = [_]Token{.{ .kind = kind, .start = 0, .end = 1 }};
        const result = try serializeToString(&tokens);
        defer testing.allocator.free(result);

        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
        defer parsed.deinit();

        const event = parsed.value.object.get("events").?.array.items[0].object;
        try testing.expectEqualStrings(expected_name, event.get("type").?.string);
    }
}

// --- Property Tests ---

const minish = @import("minish");
const gen = minish.gen;

// Feature: phase1-tokenizer-cli, Property 14: JSON serialization correctness
test "property: JSON serialization correctness" {
    // Generate random token kind index (0..9) and position values
    const token_gen = comptime gen.tuple3(
        u4,
        u16,
        u16,
        gen.intRange(u4, 0, 9),
        gen.intRange(u16, 0, 10000),
        gen.intRange(u16, 0, 10000),
    );

    try minish.check(testing.allocator, token_gen, struct {
        fn prop(vals: struct { u4, u16, u16 }) !void {
            const kind_idx = vals[0];
            const start: usize = @intCast(vals[1]);
            // Ensure end >= start
            const end: usize = start + @as(usize, @intCast(vals[2]));

            const kinds = [_]TokenKind{ .identifier, .keyword, .symbol, .string, .number, .operator, .newline, .indent, .comment, .delimiter };
            const names = [_][]const u8{ "identifier", "keyword", "symbol", "string", "number", "operator", "newline", "indent", "comment", "delimiter" };

            const kind = kinds[kind_idx];
            const expected_name = names[kind_idx];

            const tokens = [_]Token{.{ .kind = kind, .start = start, .end = end }};

            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(testing.allocator);
            try serializeTokens(&tokens, buf.writer(testing.allocator));

            // (a) Parses as valid JSON
            const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf.items, .{});
            defer parsed.deinit();

            // (b) Has top-level "events" array
            const events = parsed.value.object.get("events").?;
            try testing.expectEqual(@as(usize, 1), events.array.items.len);

            // (c) Each element has "type", "start", "end"
            const event = events.array.items[0].object;
            const type_val = event.get("type").?;
            const start_val = event.get("start").?;
            const end_val = event.get("end").?;

            // (d) Values are correct
            try testing.expectEqualStrings(expected_name, type_val.string);
            try testing.expectEqual(@as(i64, @intCast(start)), start_val.integer);
            try testing.expectEqual(@as(i64, @intCast(end)), end_val.integer);
        }
    }.prop, .{ .num_runs = 100 });
}
