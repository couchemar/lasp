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
/// Format: { "events": [ { "type": "...", "start": N, "end": N, "line": N }, ... ] }
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
        try writer.writeAll(", \"line\": ");
        try writer.print("{d}", .{tok.line});
        try writer.writeAll(", \"col\": ");
        try writer.print("{d}", .{tok.col});
        try writer.writeAll(" }");
    }

    if (tokens.len > 0) {
        try writer.writeAll(" ");
    }
    try writer.writeAll("] }");
}

// Writes a string with JSON escaping (backslash and double quote).
fn writeJsonEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            else => try w.writeByte(c),
        }
    }
}

const events_mod = @import("../parser/events.zig");
const StructuralEvent = events_mod.StructuralEvent;

/// Serializes structural events to JSON format.
/// Format: { "events": [ { "type": "...", "start": N, "end": N, "line": N, "confidence": F, ... } ] }
/// When include_alternatives is true, every event also carries an "alternatives"
/// array listing the non-winning candidates of its region (type, confidence,
/// captures only).
pub fn serializeEvents(events_list: []const StructuralEvent, writer: anytype) !void {
    try serializeEventsWithAlternatives(events_list, false, writer);
}

pub fn serializeEventsWithAlternatives(events_list: []const StructuralEvent, include_alternatives: bool, writer: anytype) !void {
    try writer.writeAll("{ \"events\": [");

    for (events_list, 0..) |event, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll(" { \"type\": \"");
        try writer.writeAll(event.type_name);
        try writer.writeAll("\", \"start\": ");
        try writer.print("{d}", .{event.start});
        try writer.writeAll(", \"end\": ");
        try writer.print("{d}", .{event.end});
        try writer.writeAll(", \"line\": ");
        try writer.print("{d}", .{event.line});
        try writer.writeAll(", \"confidence\": ");
        try writer.print("{d:.2}", .{event.confidence});

        // Include col field
        try writer.writeAll(", \"col\": ");
        try writer.print("{d}", .{event.col});

        // Include block_start when present
        if (event.block_start) |bs| {
            try writer.writeAll(", \"block_start\": ");
            try writer.print("{d}", .{bs});
        }

        // Include block_end when present
        if (event.block_end) |be| {
            try writer.writeAll(", \"block_end\": ");
            try writer.print("{d}", .{be});
        }

        // Include capture fields
        for (event.captures) |cap| {
            try writer.writeAll(", \"");
            try writer.writeAll(cap.field_name);
            try writer.writeAll("\": \"");
            try writeJsonEscaped(writer, cap.value);
            try writer.writeAll("\"");
        }

        if (include_alternatives) {
            try writer.writeAll(", \"alternatives\": [");
            for (event.alternatives, 0..) |alt, j| {
                if (j > 0) try writer.writeAll(",");
                try writer.writeAll(" { \"type\": \"");
                try writer.writeAll(alt.type_name);
                try writer.writeAll("\", \"confidence\": ");
                try writer.print("{d:.2}", .{alt.confidence});
                if (alt.source == .resemblance) {
                    // Advisory grammar-projected resemblance: mark the source and
                    // repeat the resembled kind name + membership score (the
                    // score IS the confidence).
                    try writer.writeAll(", \"source\": \"resemblance\", \"resembled_kind\": \"");
                    try writer.writeAll(alt.type_name);
                    try writer.writeAll("\", \"membership\": ");
                    try writer.print("{d:.2}", .{alt.confidence});
                }
                for (alt.captures) |cap| {
                    try writer.writeAll(", \"");
                    try writer.writeAll(cap.field_name);
                    try writer.writeAll("\": \"");
                    try writeJsonEscaped(writer, cap.value);
                    try writer.writeAll("\"");
                }
                try writer.writeAll(" }");
            }
            if (event.alternatives.len > 0) try writer.writeAll(" ");
            try writer.writeAll("]");
        }

        try writer.writeAll(" }");
    }

    if (events_list.len > 0) {
        try writer.writeAll(" ");
    }
    try writer.writeAll("] }");
}

// --- Unit Tests ---

const testing = std.testing;

fn serializeToString(tokens: []const Token) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try serializeTokens(tokens, &aw.writer);
    return aw.toOwnedSlice();
}

test "serializeTokens empty tokens" {
    const result = try serializeToString(&[_]Token{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("{ \"events\": [] }", result);
}

test "serializeTokens single token" {
    const tokens = [_]Token{
        .{ .kind = .identifier, .start = 0, .end = 5, .line = 1, .col = 0 },
    };
    const result = try serializeToString(&tokens);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(
        "{ \"events\": [ { \"type\": \"identifier\", \"start\": 0, \"end\": 5, \"line\": 1, \"col\": 0 } ] }",
        result,
    );
}

test "serializeTokens multiple tokens" {
    const tokens = [_]Token{
        .{ .kind = .keyword, .start = 0, .end = 2, .line = 1, .col = 0 },
        .{ .kind = .identifier, .start = 3, .end = 6, .line = 1, .col = 3 },
        .{ .kind = .delimiter, .start = 6, .end = 7, .line = 1, .col = 6 },
    };
    const result = try serializeToString(&tokens);
    defer testing.allocator.free(result);

    const expected =
        "{ \"events\": [ { \"type\": \"keyword\", \"start\": 0, \"end\": 2, \"line\": 1, \"col\": 0 }," ++
        " { \"type\": \"identifier\", \"start\": 3, \"end\": 6, \"line\": 1, \"col\": 3 }," ++
        " { \"type\": \"delimiter\", \"start\": 6, \"end\": 7, \"line\": 1, \"col\": 6 } ] }";
    try testing.expectEqualStrings(expected, result);
}

test "serializeTokens output is valid JSON" {
    const tokens = [_]Token{
        .{ .kind = .string, .start = 0, .end = 7, .line = 1, .col = 0 },
        .{ .kind = .operator, .start = 8, .end = 9, .line = 1, .col = 8 },
        .{ .kind = .number, .start = 10, .end = 12, .line = 1, .col = 10 },
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
        const tokens = [_]Token{.{ .kind = kind, .start = 0, .end = 1, .line = 1, .col = 0 }};
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

            const tokens = [_]Token{.{ .kind = kind, .start = start, .end = end, .line = 1, .col = start }};

            var aw: std.Io.Writer.Allocating = .init(testing.allocator);
            defer aw.deinit();
            try serializeTokens(&tokens, &aw.writer);

            // (a) Parses as valid JSON
            const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
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

// --- Structural Event Tests ---

fn serializeEventsToString(events_list: []const StructuralEvent) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try serializeEvents(events_list, &aw.writer);
    return aw.toOwnedSlice();
}

test "serializeEvents: empty events" {
    const result = try serializeEventsToString(&.{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("{ \"events\": [] }", result);
}

test "serializeEvents: event with name capture" {
    const result = try serializeEventsToString(&.{.{
        .type_name = "function",
        .captures = &.{.{ .field_name = "name", .value = "add" }},
        .start = 0,
        .end = 10,
        .line = 1,
        .col = 0,
        .confidence = 0.95,
    }});
    defer testing.allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();
    const event = parsed.value.object.get("events").?.array.items[0].object;
    try testing.expectEqualStrings("function", event.get("type").?.string);
    try testing.expectEqualStrings("add", event.get("name").?.string);
    try testing.expectEqual(@as(i64, 0), event.get("start").?.integer);
    try testing.expectEqual(@as(i64, 10), event.get("end").?.integer);
}

test "serializeEvents: event with callee capture" {
    const result = try serializeEventsToString(&.{.{
        .type_name = "call",
        .captures = &.{.{ .field_name = "callee", .value = "validate" }},
        .start = 20,
        .end = 32,
        .line = 2,
        .col = 0,
        .confidence = 0.88,
    }});
    defer testing.allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();
    const event = parsed.value.object.get("events").?.array.items[0].object;
    try testing.expectEqualStrings("call", event.get("type").?.string);
    try testing.expectEqualStrings("validate", event.get("callee").?.string);
}

test "serializeEvents: event without captures" {
    const result = try serializeEventsToString(&.{.{
        .type_name = "import",
        .captures = &.{},
        .start = 5,
        .end = 15,
        .line = 1,
        .col = 0,
        .confidence = 0.70,
    }});
    defer testing.allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();
    const event = parsed.value.object.get("events").?.array.items[0].object;
    try testing.expectEqualStrings("import", event.get("type").?.string);
    try testing.expect(event.get("name") == null);
    try testing.expect(event.get("callee") == null);
}

test "serializeEvents: output is valid JSON" {
    const result = try serializeEventsToString(&.{
        .{ .type_name = "function", .captures = &.{.{ .field_name = "name", .value = "foo" }}, .start = 0, .end = 10, .line = 1, .col = 0, .confidence = 0.95 },
        .{ .type_name = "call", .captures = &.{.{ .field_name = "callee", .value = "bar" }}, .start = 15, .end = 25, .line = 2, .col = 0, .confidence = 0.80 },
    });
    defer testing.allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.object.get("events").?.array.items.len);
}

test "serializeTokens: col field in token JSON" {
    const tokens = [_]Token{
        .{ .kind = .identifier, .start = 5, .end = 8, .line = 2, .col = 3 },
    };
    const result = try serializeToString(&tokens);
    defer testing.allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();
    const event = parsed.value.object.get("events").?.array.items[0].object;
    try testing.expectEqual(@as(i64, 3), event.get("col").?.integer);
}

test "serializeEvents: col field in structural event JSON" {
    const result = try serializeEventsToString(&.{.{
        .type_name = "function",
        .captures = &.{},
        .start = 0,
        .end = 10,
        .line = 1,
        .col = 4,
        .confidence = 0.90,
    }});
    defer testing.allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();
    const event = parsed.value.object.get("events").?.array.items[0].object;
    try testing.expectEqual(@as(i64, 4), event.get("col").?.integer);
}

test "serializeEvents: block_start present when non-null" {
    const result = try serializeEventsToString(&.{.{
        .type_name = "call",
        .captures = &.{},
        .start = 5,
        .end = 10,
        .line = 1,
        .col = 2,
        .confidence = 0.85,
        .block_start = 0,
    }});
    defer testing.allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();
    const event = parsed.value.object.get("events").?.array.items[0].object;
    try testing.expectEqual(@as(i64, 0), event.get("block_start").?.integer);
}

test "serializeEvents: block_start omitted when null" {
    const result = try serializeEventsToString(&.{.{
        .type_name = "call",
        .captures = &.{},
        .start = 5,
        .end = 10,
        .line = 1,
        .col = 0,
        .confidence = 0.85,
    }});
    defer testing.allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();
    const event = parsed.value.object.get("events").?.array.items[0].object;
    try testing.expect(event.get("block_start") == null);
}

test "serializeEvents: block_end present when non-null" {
    const result = try serializeEventsToString(&.{.{
        .type_name = "call",
        .captures = &.{},
        .start = 5,
        .end = 10,
        .line = 1,
        .col = 0,
        .confidence = 0.85,
        .block_end = 42,
    }});
    defer testing.allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();
    const event = parsed.value.object.get("events").?.array.items[0].object;
    try testing.expectEqual(@as(i64, 42), event.get("block_end").?.integer);
}

// Feature: phase2-grammar-automaton, Property 11: Event JSON serialization correctness
test "property: event JSON serialization correctness" {
    const event_gen = comptime gen.tuple3(
        []const u8,
        u16,
        u16,
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        gen.intRange(u16, 0, 1000),
        gen.intRange(u16, 0, 1000),
    );

    try minish.check(testing.allocator, event_gen, struct {
        fn prop(vals: struct { []const u8, u16, u16 }) !void {
            const type_name = vals[0];
            const start: usize = @intCast(vals[1]);
            const end: usize = start + @as(usize, @intCast(vals[2]));

            const events_list = &[_]StructuralEvent{.{
                .type_name = type_name,
                .captures = &.{.{ .field_name = "name", .value = "test" }},
                .start = start,
                .end = end,
                .line = 1,
                .col = 0,
                .confidence = 0.85,
            }};

            var aw: std.Io.Writer.Allocating = .init(testing.allocator);
            defer aw.deinit();
            try serializeEvents(events_list, &aw.writer);

            // (a) Valid JSON
            const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
            defer parsed.deinit();

            // (b) Has "events" array
            const json_events = parsed.value.object.get("events").?;
            try testing.expectEqual(@as(usize, 1), json_events.array.items.len);

            // (c) Has required fields
            const event = json_events.array.items[0].object;
            try testing.expect(event.get("type") != null);
            try testing.expect(event.get("start") != null);
            try testing.expect(event.get("end") != null);
            try testing.expect(event.get("confidence") != null);

            // (d) name capture present
            try testing.expect(event.get("name") != null);

            // (e) Values correct
            try testing.expectEqualStrings(type_name, event.get("type").?.string);
            try testing.expectEqual(@as(i64, @intCast(start)), event.get("start").?.integer);
            try testing.expectEqual(@as(i64, @intCast(end)), event.get("end").?.integer);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase3-multi-language-patterns, Property 7: JSON serialization of extended fields
test "property: JSON serialization of extended fields" {
    const field_gen = comptime gen.tuple3(
        u16,
        u16,
        bool,
        gen.intRange(u16, 0, 1000),
        gen.intRange(u16, 0, 1000),
        gen.boolean(),
    );

    try minish.check(testing.allocator, field_gen, struct {
        fn prop(vals: struct { u16, u16, bool }) !void {
            const col: usize = @intCast(vals[0]);
            const block_offset: usize = @intCast(vals[1]);
            const has_block = vals[2];

            const events_list = &[_]StructuralEvent{.{
                .type_name = "test",
                .captures = &.{},
                .start = 0,
                .end = 10,
                .line = 1,
                .col = col,
                .confidence = 0.90,
                .block_start = if (has_block) block_offset else null,
                .block_end = null,
            }};

            var aw: std.Io.Writer.Allocating = .init(testing.allocator);
            defer aw.deinit();
            try serializeEvents(events_list, &aw.writer);

            // (a) Valid JSON
            const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
            defer parsed.deinit();

            const json_events = parsed.value.object.get("events").?;
            try testing.expectEqual(@as(usize, 1), json_events.array.items.len);

            const event = json_events.array.items[0].object;

            // (b) col field present with correct value
            try testing.expectEqual(@as(i64, @intCast(col)), event.get("col").?.integer);

            // (c) block_start conditional
            if (has_block) {
                try testing.expectEqual(@as(i64, @intCast(block_offset)), event.get("block_start").?.integer);
            } else {
                try testing.expect(event.get("block_start") == null);
            }

            // (d) block_end omitted when null
            try testing.expect(event.get("block_end") == null);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: competing-candidate-emission, Unit: alternatives serialization bytes
// **Validates: Requirements 2.2, 2.4, 2.5**
test "serializeEventsWithAlternatives: winner with two alternatives" {
    const ev = StructuralEvent{
        .type_name = "decl",
        .captures = &.{.{ .field_name = "name", .value = "run" }},
        .start = 0,
        .end = 8,
        .line = 1,
        .col = 0,
        .confidence = 0.9,
        .alternatives = &.{
            .{ .type_name = "call", .confidence = 0.5, .captures = &.{.{ .field_name = "callee", .value = "run" } } },
            .{ .type_name = "ref", .confidence = 0.3, .captures = &.{} },
        },
    };
    const result = try serializeEventsToStringWithAlternatives(&.{ev}, true);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "\"alternatives\": [ { \"type\": \"call\", \"confidence\": 0.50, \"callee\": \"run\" }, { \"type\": \"ref\", \"confidence\": 0.30 } ]") != null);
    // Winner keeps its own fields.
    try testing.expect(std.mem.indexOf(u8, result, "\"type\": \"decl\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"start\": 0") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"name\": \"run\"") != null);
    // Alternatives carry no position fields.
    try testing.expect(std.mem.indexOf(u8, result, "\"start\"") != null);
}

fn serializeEventsToStringWithAlternatives(events_list: []const StructuralEvent, include: bool) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try serializeEventsWithAlternatives(events_list, include, &aw.writer);
    return aw.toOwnedSlice();
}

// Feature: competing-candidate-emission, Property 1: Flag-off byte-identical output
// **Validates: Requirements 9.1, 9.2, 9.3**
test "property: flag-off byte-identical output" {
    const conf_gen = gen.intRange(u16, 0, 100);

    try minish.check(testing.allocator, conf_gen, struct {
        fn prop(c: u16) !void {
            const ev = StructuralEvent{
                .type_name = "t",
                .captures = &.{},
                .start = 0,
                .end = 1,
                .line = 1,
                .col = 0,
                .confidence = @as(f32, @floatFromInt(c)) / 100.0,
                .alternatives = &.{.{
                    .type_name = "x",
                    .confidence = 0.2,
                    .captures = &.{},
                }},
            };
            const with_flag = try serializeEventsToStringWithAlternatives(&.{ev}, false);
            defer testing.allocator.free(with_flag);
            const old = try serializeEventsToString(&.{ev});
            defer testing.allocator.free(old);
            try testing.expectEqualStrings(old, with_flag);
            try testing.expect(std.mem.indexOf(u8, with_flag, "alternatives") == null);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: competing-candidate-emission, Property 5: Empty-array invariant
// **Validates: Requirements 5.1, 5.2, 10.3**
test "property: empty-array invariant" {
    const ev = StructuralEvent{
        .type_name = "t",
        .captures = &.{},
        .start = 0,
        .end = 1,
        .line = 1,
        .col = 0,
        .confidence = 1.0,
    };
    const result = try serializeEventsToStringWithAlternatives(&.{ev}, true);
    defer testing.allocator.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();
    const event = parsed.value.object.get("events").?.array.items[0].object;
    const alts = event.get("alternatives").?;
    try testing.expectEqual(@as(usize, 0), alts.array.items.len);
}

// Feature: competing-candidate-emission, Property 6: Alternative field set
// **Validates: Requirements 2.3, 2.5**
test "property: alternative field set" {
    const name_gen = gen.string(.{ .min_len = 1, .max_len = 6, .charset = .alpha });

    try minish.check(testing.allocator, name_gen, struct {
        fn prop(name: []const u8) !void {
            const ev = StructuralEvent{
                .type_name = "t",
                .captures = &.{},
                .start = 0,
                .end = 1,
                .line = 1,
                .col = 0,
                .confidence = 1.0,
                .alternatives = &.{.{
                    .type_name = "other",
                    .confidence = 0.4,
                    .captures = &.{.{ .field_name = "callee", .value = name }},
                }},
            };
            const result = try serializeEventsToStringWithAlternatives(&.{ev}, true);
            defer testing.allocator.free(result);
            const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
            defer parsed.deinit();
            const alt = parsed.value.object.get("events").?.array.items[0].object.get("alternatives").?.array.items[0].object;
            try testing.expect(alt.get("type") != null);
            try testing.expect(alt.get("confidence") != null);
            try testing.expect(alt.get("callee") != null);
            try testing.expect(alt.get("start") == null);
            try testing.expect(alt.get("end") == null);
            try testing.expect(alt.get("line") == null);
            try testing.expect(alt.get("col") == null);
            try testing.expect(alt.get("block_start") == null);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: grammar-projected-resemblance, Unit: alternatives serialization
// **Validates: Requirements 6.2, 6.3, 6.4**
test "serializeEventsWithAlternatives: resemblance alternative carries source marker" {
    const ev = StructuralEvent{
        .type_name = "literal",
        .captures = &.{},
        .start = 0,
        .end = 4,
        .line = 1,
        .col = 0,
        .confidence = 1.0,
        .alternatives = &.{
            .{ .type_name = "number", .confidence = 0.83, .captures = &.{}, .source = .resemblance },
        },
    };
    const result = try serializeEventsToStringWithAlternatives(&.{ev}, true);
    defer testing.allocator.free(result);

    // Exact bytes: resemblance alternative carries type, confidence, source,
    // resembled kind name, and membership score.
    try testing.expect(std.mem.indexOf(u8, result,
        "\"alternatives\": [ { \"type\": \"number\", \"confidence\": 0.83, \"source\": \"resemblance\", \"resembled_kind\": \"number\", \"membership\": 0.83 } ]") != null);
}

test "serializeEventsWithAlternatives: resemblance marker absent when flag off or grammar-sourced" {
    const ev = StructuralEvent{
        .type_name = "decl",
        .captures = &.{},
        .start = 0,
        .end = 1,
        .line = 1,
        .col = 0,
        .confidence = 1.0,
        .alternatives = &.{
            .{ .type_name = "call", .confidence = 0.5, .captures = &.{} },
        },
    };
    const off = try serializeEventsToStringWithAlternatives(&.{ev}, false);
    defer testing.allocator.free(off);
    try testing.expect(std.mem.indexOf(u8, off, "source") == null);
    try testing.expect(std.mem.indexOf(u8, off, "resemblance") == null);

    const on = try serializeEventsToStringWithAlternatives(&.{ev}, true);
    defer testing.allocator.free(on);
    try testing.expect(std.mem.indexOf(u8, on, "source") == null);
}

test "serializeEventsWithAlternatives: resemblance output is valid JSON" {
    const ev = StructuralEvent{
        .type_name = "literal",
        .captures = &.{},
        .start = 0,
        .end = 4,
        .line = 1,
        .col = 0,
        .confidence = 1.0,
        .alternatives = &.{
            .{ .type_name = "number", .confidence = 0.83, .captures = &.{}, .source = .resemblance },
            .{ .type_name = "other", .confidence = 0.4, .captures = &.{} },
        },
    };
    const result = try serializeEventsToStringWithAlternatives(&.{ev}, true);
    defer testing.allocator.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();
    const alts = parsed.value.object.get("events").?.array.items[0].object.get("alternatives").?.array.items;
    try testing.expectEqual(@as(usize, 2), alts.len);
    const resemblance_alt = alts[0].object;
    try testing.expectEqualStrings("resemblance", resemblance_alt.get("source").?.string);
    try testing.expectEqualStrings("number", resemblance_alt.get("resembled_kind").?.string);
    try testing.expectApproxEqRel(@as(f64, 0.83), resemblance_alt.get("membership").?.float, 0.001);
    const grammar_alt = alts[1].object;
    try testing.expect(grammar_alt.get("source") == null);
}
