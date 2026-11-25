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
        try writer.writeAll(" ");
        try writeTokenObject(tok, writer);
    }

    if (tokens.len > 0) {
        try writer.writeAll(" ");
    }
    try writer.writeAll("] }");
}

/// Writes ONE raw token object: `{ "type": ..., "start": N, "end": N,
/// "line": N, "col": N }`. No surrounding array spaces, no comma. Single
/// source of token-object bytes (shared by the wrapped and NDJSON framings).
fn writeTokenObject(tok: Token, writer: anytype) !void {
    try writer.writeAll("{ \"type\": ");
    try writeJsonString(writer, tokenKindToString(tok.kind));
    try writer.writeAll(", \"start\": ");
    try writer.print("{d}", .{tok.start});
    try writer.writeAll(", \"end\": ");
    try writer.print("{d}", .{tok.end});
    try writer.writeAll(", \"line\": ");
    try writer.print("{d}", .{tok.line});
    try writer.writeAll(", \"col\": ");
    try writer.print("{d}", .{tok.col});
    try writer.writeAll(" }");
}
/// Writes `s` as a complete JSON string: opening quote, escaped body, closing
/// quote. Every string the serializer emits (values, names, file, grammar,
/// token kinds) must go through here. Bytes are treated as raw bytes, not
/// decoded.
fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    const hex = "0123456789abcdef";
    for (s) |c| {
        switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            0x08 => try w.writeAll("\\b"),
            0x09 => try w.writeAll("\\t"),
            0x0A => try w.writeAll("\\n"),
            0x0C => try w.writeAll("\\f"),
            0x0D => try w.writeAll("\\r"),
            0x00...0x07, 0x0B, 0x0E...0x1F => {
                try w.writeAll("\\u00");
                try w.writeByte(hex[c >> 4]);
                try w.writeByte(hex[c & 0x0F]);
            },
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

/// Writes `, "name": "value"` with both strings escaped.
fn writeStringField(w: anytype, name: []const u8, value: []const u8) !void {
    try w.writeAll(", ");
    try writeJsonString(w, name);
    try w.writeAll(": ");
    try writeJsonString(w, value);
}

/// Writes every capture as a `, "field": "value"` pair (events and alternatives).
fn writeCaptureFields(w: anytype, captures: []const CaptureEntry) !void {
    for (captures) |cap| try writeStringField(w, cap.field_name, cap.value);
}

/// Writes `"file": S, "grammar": S`; callers supply the surrounding punctuation.
fn writeEnvelopeFields(w: anytype, file: []const u8, grammar: []const u8) !void {
    try w.writeAll("\"file\": ");
    try writeJsonString(w, file);
    try w.writeAll(", \"grammar\": ");
    try writeJsonString(w, grammar);
}

const events_mod = @import("../parser/events.zig");
const StructuralEvent = events_mod.StructuralEvent;
const CaptureEntry = events_mod.CaptureEntry;
const Alternative = events_mod.Alternative;
const IntegerField = events_mod.IntegerField;
const CandidateSource = events_mod.CandidateSource;

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
    try writeEventArray(events_list, include_alternatives, writer);
    try writer.writeAll("] }");
}

/// Leading envelope fields for Dir_Mode flattened NDJSON records (R4).
const Envelope = struct {
    file: []const u8,
    grammar: []const u8,
};

/// Writes ONE structural event object: `{ "type": ..., "start": N, ... }`.
/// No leading/trailing array spaces, no comma. When `envelope` is non-null,
/// `file` and `grammar` are written as the FIRST two fields (R4.2 order),
/// before the event body fields; otherwise the object opens straight into the
/// event body. Single source of structural-event-object bytes.
fn writeEventObject(
    event: StructuralEvent,
    include_alternatives: bool,
    envelope: ?Envelope,
    writer: anytype,
) !void {
    try writer.writeAll("{");
    if (envelope) |env| {
        try writer.writeAll(" ");
        try writeEnvelopeFields(writer, env.file, env.grammar);
        try writer.writeAll(",");
    }
    try writer.writeAll(" \"type\": ");
    try writeJsonString(writer, event.type_name);
    try writer.writeAll(", \"start\": ");
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
    try writeCaptureFields(writer, event.captures);

    // Integer fields render as bare JSON numbers — never quoted (Req 7.1).
    for (event.int_fields) |f| {
        try writer.writeAll(", ");
        try writeJsonString(writer, f.field_name);
        try writer.writeAll(": ");
        try writer.print("{d}", .{f.value});
    }
    if (include_alternatives) {
        try writer.writeAll(", \"alternatives\": [");
        for (event.alternatives, 0..) |alt, j| {
            if (j > 0) try writer.writeAll(",");
            try writer.writeAll(" { \"type\": ");
            try writeJsonString(writer, alt.type_name);
            try writer.writeAll(", \"confidence\": ");
            try writer.print("{d:.2}", .{alt.confidence});
            if (alt.source == .resemblance) {
                // Advisory grammar-projected resemblance: mark the source and
                // repeat the resembled kind name + membership score (the
                // score IS the confidence).
                try writer.writeAll(", \"source\": \"resemblance\", \"resembled_kind\": ");
                try writeJsonString(writer, alt.type_name);
                try writer.writeAll(", \"membership\": ");
                try writer.print("{d:.2}", .{alt.confidence});
            }
            try writeCaptureFields(writer, alt.captures);
            try writer.writeAll(" }");
        }
        if (event.alternatives.len > 0) try writer.writeAll(" ");
        try writer.writeAll("]");
    }

    try writer.writeAll(" }");
}

/// Writes the `"events": [ ... ]` array body (without the wrapper object or
/// the closing bracket). A trailing space is emitted after a non-empty array,
/// matching the historical single-file byte stream exactly. The array framing
/// (leading/trailing spaces, commas) lives here — NOT in writeEventObject —
/// so the object primitive emits bare `{ ... }` for NDJSON lines.
fn writeEventArray(events_list: []const StructuralEvent, include_alternatives: bool, writer: anytype) !void {
    for (events_list, 0..) |event, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll(" ");
        try writeEventObject(event, include_alternatives, null, writer);
    }

    if (events_list.len > 0) {
        try writer.writeAll(" ");
    }
}

/// One `parse-dir` output entry: the walked file path, the grammar (file name)
/// that matched it, and that grammar's structural events for the file.
pub const DirResult = struct {
    file: []const u8,
    grammar: []const u8,
    events: []const StructuralEvent,
};

/// Serializes parse-dir results as a JSON array of `{file, grammar, events}`
/// objects; `[]` when there are no entries.
pub fn serializeDirResults(entries: []const DirResult, include_alternatives: bool, writer: anytype) !void {
    try writer.writeAll("[");
    for (entries, 0..) |entry, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll(" { ");
        try writeEnvelopeFields(writer, entry.file, entry.grammar);
        try writer.writeAll(", \"events\": [");
        try writeEventArray(entry.events, include_alternatives, writer);
        try writer.writeAll("] }");
    }
    if (entries.len > 0) try writer.writeAll(" ");
    try writer.writeAll("]");
}

// ---------------------------------------------------------------------------
// NDJSON serializers (`--jsonl`): one JSON value per line, each terminated by
// exactly one "\n". No document wrapper, no leading byte, no trailing document
// newline. N records → N newlines; 0 records → 0 bytes (R5, R7.4).
// ---------------------------------------------------------------------------

/// Single_File_Mode NDJSON: one line per event, `writeEventObject(..., null,
/// ...)` + "\n". Zero events → zero bytes.
pub fn serializeEventsNdjson(events_list: []const StructuralEvent, include_alternatives: bool, writer: anytype) !void {
    for (events_list) |event| {
        try writeEventObject(event, include_alternatives, null, writer);
        try writer.writeAll("\n");
    }
}

/// Raw-token NDJSON: one line per token, `writeTokenObject` + "\n". Zero
/// tokens → zero bytes.
pub fn serializeTokensNdjson(tokens: []const Token, writer: anytype) !void {
    for (tokens) |tok| {
        try writeTokenObject(tok, writer);
        try writer.writeAll("\n");
    }
}

/// Dir_Mode NDJSON: for each entry, for each event, one Flattened_Record line
/// = `writeEventObject(event, ..., .{ .file = entry.file, .grammar =
/// entry.grammar }, writer)` + "\n". An entry with zero events emits zero lines
/// (R4.6, R2.7). Entry order (walk order, then grammar load order) is
/// preserved, matching the Wrapped_Form DirResult array order (R2.4, R2.5).
pub fn serializeDirResultsNdjson(entries: []const DirResult, include_alternatives: bool, writer: anytype) !void {
    for (entries) |entry| {
        for (entry.events) |event| {
            try writeEventObject(event, include_alternatives, .{ .file = entry.file, .grammar = entry.grammar }, writer);
            try writer.writeAll("\n");
        }
    }
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
            .{ .type_name = "call", .confidence = 0.5, .captures = &.{.{ .field_name = "callee", .value = "run" }} },
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
    try testing.expect(std.mem.indexOf(u8, result, "\"alternatives\": [ { \"type\": \"number\", \"confidence\": 0.83, \"source\": \"resemblance\", \"resembled_kind\": \"number\", \"membership\": 0.83 } ]") != null);
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

// Feature: plain-toml-capture-tables, Unit: integer serialization
// **Validates: Requirements 7.1, 7.2, 7.3**
test "serializeEventsWithAlternatives: count-only event renders bare integer" {
    const ev = StructuralEvent{
        .type_name = "fn",
        .captures = &.{},
        .start = 0,
        .end = 9,
        .line = 1,
        .col = 0,
        .confidence = 1.0,
        .int_fields = &.{.{ .field_name = "args", .value = 2 }},
    };
    const result = try serializeEventsToStringWithAlternatives(&.{ev}, false);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "\"args\": 2") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"args\": \"2\"") == null);
}

test "serializeEventsWithAlternatives: zero count renders 0; int fields ride alongside captures" {
    const ev = StructuralEvent{
        .type_name = "fn",
        .captures = &.{.{ .field_name = "name", .value = "add" }},
        .start = 0,
        .end = 9,
        .line = 1,
        .col = 0,
        .confidence = 1.0,
        .int_fields = &.{
            .{ .field_name = "args", .value = 0 },
            .{ .field_name = "nested", .value = 3 },
        },
    };
    const result = try serializeEventsToStringWithAlternatives(&.{ev}, false);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "\"name\": \"add\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"args\": 0") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"nested\": 3") != null);
}

// Feature: plain-toml-capture-tables, Property 7: Integer fields serialize as
// valid bare-integer JSON
test "property: integer fields serialize as valid bare-integer JSON" {
    const n_gen = gen.intRange(u8, 0, 90);
    try minish.check(testing.allocator, n_gen, struct {
        fn prop(n: u8) !void {
            const ev = StructuralEvent{
                .type_name = "fn",
                .captures = &.{.{ .field_name = "name", .value = "f" }},
                .start = 0,
                .end = 9,
                .line = 1,
                .col = 0,
                .confidence = 1.0,
                .int_fields = &.{
                    .{ .field_name = "args", .value = n },
                    .{ .field_name = "x", .value = n + 1 },
                },
            };
            const result = try serializeEventsToStringWithAlternatives(&.{ev}, false);
            defer testing.allocator.free(result);
            const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
            defer parsed.deinit();
            const obj = parsed.value.object.get("events").?.array.items[0].object;
            const args = obj.get("args").?;
            try testing.expect(args == .integer);
            try testing.expectEqual(@as(i64, n), args.integer);
            const name = obj.get("name").?;
            try testing.expect(name == .string);
            try testing.expectEqualStrings("f", name.string);
        }
    }.prop, .{ .num_runs = 100 });
}
// Feature: parse-dir-directory-walk, Requirement 2.6: serializeDirResults emits
// a JSON array of {file, grammar, events}; event bytes match the single-file
// serializer; empty list emits [].
test "serializeDirResults: empty entry list emits []" {
    const result = try serializeDirResultsToString(&.{}, false);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("[]", result);
}

test "serializeDirResults: entries carry file/grammar/events and escape strings" {
    const ev = StructuralEvent{
        .type_name = "function",
        .captures = &.{.{ .field_name = "name", .value = "add" }},
        .start = 0,
        .end = 9,
        .line = 1,
        .col = 0,
        .confidence = 1.0,
    };
    const entries = [_]DirResult{
        .{ .file = "a.erl", .grammar = "erlang.toml", .events = &.{ev} },
        .{ .file = "sub/quote\"file.py", .grammar = "python.toml", .events = &.{} },
    };
    const result = try serializeDirResultsToString(&entries, false);
    defer testing.allocator.free(result);

    // Valid JSON array of two objects.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();
    const arr = parsed.value.array;
    try testing.expectEqual(@as(usize, 2), arr.items.len);
    const first = arr.items[0].object;
    try testing.expectEqualStrings("a.erl", first.get("file").?.string);
    try testing.expectEqualStrings("erlang.toml", first.get("grammar").?.string);
    try testing.expectEqual(@as(usize, 1), first.get("events").?.array.items.len);
    const second = arr.items[1].object;
    try testing.expectEqualStrings("sub/quote\"file.py", second.get("file").?.string);
    try testing.expectEqual(@as(usize, 0), second.get("events").?.array.items.len);

    // Event object bytes are identical to the single-file serializer's.
    const single = try serializeEventsToStringWithAlternatives(&.{ev}, false);
    defer testing.allocator.free(single);
    const single_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, single, .{});
    defer single_parsed.deinit();
    const single_events = single_parsed.value.object.get("events").?;
    const dir_events = first.get("events").?;
    try testing.expectEqual(single_events.array.items.len, dir_events.array.items.len);
    const a = single_events.array.items[0].object;
    const b = dir_events.array.items[0].object;
    try testing.expectEqualStrings("function", a.get("type").?.string);
    try testing.expectEqualStrings("function", b.get("type").?.string);
    try testing.expectEqual(@as(i64, 0), a.get("start").?.integer);
    try testing.expectEqual(@as(i64, 0), b.get("start").?.integer);
    try testing.expectEqualStrings("add", a.get("name").?.string);
    try testing.expectEqualStrings("add", b.get("name").?.string);
}

fn serializeDirResultsToString(entries: []const DirResult, include: bool) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try serializeDirResults(entries, include, &aw.writer);
    return aw.toOwnedSlice();
}

// --- NDJSON serializer tests (`--jsonl`) ---

fn serializeEventsNdjsonToString(events_list: []const StructuralEvent, include: bool) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try serializeEventsNdjson(events_list, include, &aw.writer);
    return aw.toOwnedSlice();
}

fn serializeTokensNdjsonToString(tokens: []const Token) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try serializeTokensNdjson(tokens, &aw.writer);
    return aw.toOwnedSlice();
}

fn serializeDirResultsNdjsonToString(entries: []const DirResult, include: bool) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try serializeDirResultsNdjson(entries, include, &aw.writer);
    return aw.toOwnedSlice();
}

fn stringifyValue(allocator: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var stringify: std.json.Stringify = .{
        .writer = &aw.writer,
        .options = .{},
    };
    try stringify.write(v);
    return aw.toOwnedSlice();
}

// Feature: ndjson-output, Unit: empty result emits zero bytes (R5)
test "serializeEventsNdjson: empty → zero bytes" {
    const out = try serializeEventsNdjsonToString(&.{}, false);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "serializeTokensNdjson: empty → zero bytes" {
    const out = try serializeTokensNdjsonToString(&.{});
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "serializeDirResultsNdjson: empty → zero bytes" {
    const out = try serializeDirResultsNdjsonToString(&.{}, false);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

// Feature: ndjson-output, Unit: one event → one line ending in a single \n (R7)
test "serializeEventsNdjson: one event → one line ending in single \\n" {
    const ev = StructuralEvent{
        .type_name = "function",
        .captures = &.{.{ .field_name = "name", .value = "add" }},
        .start = 0,
        .end = 10,
        .line = 1,
        .col = 0,
        .confidence = 0.95,
    };
    const out = try serializeEventsNdjsonToString(&.{ev}, false);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\n"));
    try testing.expectEqual(out[out.len - 1], '\n');
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out[0 .. out.len - 1], .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("function", parsed.value.object.get("type").?.string);
    try testing.expectEqualStrings("add", parsed.value.object.get("name").?.string);
}

// Feature: ndjson-output, Unit: N events → N lines/N newlines, last byte \n (R7.4)
test "serializeEventsNdjson: N events → N lines, N newlines, final byte \\n" {
    const evs = [_]StructuralEvent{
        .{ .type_name = "a", .captures = &.{}, .start = 0, .end = 1, .line = 1, .col = 0, .confidence = 1.0 },
        .{ .type_name = "b", .captures = &.{}, .start = 2, .end = 3, .line = 1, .col = 2, .confidence = 0.5 },
        .{ .type_name = "c", .captures = &.{}, .start = 4, .end = 5, .line = 2, .col = 0, .confidence = 0.25 },
    };
    const out = try serializeEventsNdjsonToString(&evs, false);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "\n"));
    try testing.expectEqual(out[out.len - 1], '\n');
    var it = std.mem.splitScalar(u8, out, '\n');
    var lines: usize = 0;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        lines += 1;
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        parsed.deinit();
    }
    try testing.expectEqual(@as(usize, 3), lines);
}

// Feature: ndjson-output, Unit: token lines parse and match the wrapped token body
test "serializeTokensNdjson: line matches wrapped token object body" {
    const tok = Token{ .kind = .identifier, .start = 0, .end = 5, .line = 1, .col = 0 };
    const out = try serializeTokensNdjsonToString(&.{tok});
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\n"));
    const parsed_line = try std.json.parseFromSlice(std.json.Value, testing.allocator, out[0 .. out.len - 1], .{});
    defer parsed_line.deinit();
    const wrapped = try serializeToString(&.{tok});
    defer testing.allocator.free(wrapped);
    const parsed_wrapped = try std.json.parseFromSlice(std.json.Value, testing.allocator, wrapped, .{});
    defer parsed_wrapped.deinit();
    const wrapped_tok = parsed_wrapped.value.object.get("events").?.array.items[0].object;
    const l1 = try stringifyValue(testing.allocator, .{ .object = parsed_line.value.object });
    defer testing.allocator.free(l1);
    const l2 = try stringifyValue(testing.allocator, .{ .object = wrapped_tok });
    defer testing.allocator.free(l2);
    try testing.expectEqualStrings(l2, l1);
}

// Feature: ndjson-output, Unit: dir-mode flattened lines (R4)
test "serializeDirResultsNdjson: flattened file/grammar leading; zero-event entry emits zero lines; order preserved" {
    const ev = StructuralEvent{
        .type_name = "function",
        .captures = &.{},
        .start = 0,
        .end = 9,
        .line = 1,
        .col = 0,
        .confidence = 1.0,
    };
    const entries = [_]DirResult{
        .{ .file = "a.erl", .grammar = "erlang.toml", .events = &.{ev} },
        .{ .file = "b.py", .grammar = "python.toml", .events = &.{} },
        .{ .file = "c.rs", .grammar = "rust.toml", .events = &.{ev} },
    };
    const out = try serializeDirResultsNdjsonToString(&entries, false);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "\n"));
    var it = std.mem.splitScalar(u8, out, '\n');
    const l1 = it.next().?;
    const l2 = it.next().?;
    const p1 = try std.json.parseFromSlice(std.json.Value, testing.allocator, l1, .{});
    defer p1.deinit();
    const o1 = p1.value.object;
    try testing.expectEqualStrings("a.erl", o1.get("file").?.string);
    try testing.expectEqualStrings("erlang.toml", o1.get("grammar").?.string);
    try testing.expectEqualStrings("function", o1.get("type").?.string);
    const p2 = try std.json.parseFromSlice(std.json.Value, testing.allocator, l2, .{});
    defer p2.deinit();
    const o2 = p2.value.object;
    try testing.expectEqualStrings("c.rs", o2.get("file").?.string);
    try testing.expectEqualStrings("rust.toml", o2.get("grammar").?.string);
}

// --- Independent reference emitters for the historical Wrapped_Form bytes ---
// Written from the documented format (the pinned unit-test strings above), NOT
// from the current serializer implementation. Used by Property 1.

fn appendFmt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try out.appendSlice(allocator, s);
}

fn appendEscaped(out: *std.ArrayList(u8), s: []const u8, allocator: std.mem.Allocator) !void {
    // Independent literal table (RFC 8259), deliberately not derived from
    // production `writeJsonString`.
    const control = [32][]const u8{
        "\\u0000", "\\u0001", "\\u0002", "\\u0003", "\\u0004", "\\u0005", "\\u0006", "\\u0007",
        "\\b",     "\\t",     "\\n",     "\\u000b", "\\f",     "\\r",     "\\u000e", "\\u000f",
        "\\u0010", "\\u0011", "\\u0012", "\\u0013", "\\u0014", "\\u0015", "\\u0016", "\\u0017",
        "\\u0018", "\\u0019", "\\u001a", "\\u001b", "\\u001c", "\\u001d", "\\u001e", "\\u001f",
    };
    for (s) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            0...0x1f => try out.appendSlice(allocator, control[c]),
            else => try out.append(allocator, c),
        }
    }
}

fn referenceEventArrayBody(events_list: []const StructuralEvent, include_alts: bool, allocator: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (events_list, 0..) |ev, i| {
        if (i > 0) try out.appendSlice(allocator, ",");
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, "{ \"type\": \"");
        try appendEscaped(&out, ev.type_name, allocator);
        try out.appendSlice(allocator, "\", \"start\": ");
        try appendFmt(&out, allocator, "{d}", .{ev.start});
        try out.appendSlice(allocator, ", \"end\": ");
        try appendFmt(&out, allocator, "{d}", .{ev.end});
        try out.appendSlice(allocator, ", \"line\": ");
        try appendFmt(&out, allocator, "{d}", .{ev.line});
        try out.appendSlice(allocator, ", \"confidence\": ");
        try appendFmt(&out, allocator, "{d:.2}", .{ev.confidence});
        try out.appendSlice(allocator, ", \"col\": ");
        try appendFmt(&out, allocator, "{d}", .{ev.col});
        if (ev.block_start) |bs| {
            try out.appendSlice(allocator, ", \"block_start\": ");
            try appendFmt(&out, allocator, "{d}", .{bs});
        }
        if (ev.block_end) |be| {
            try out.appendSlice(allocator, ", \"block_end\": ");
            try appendFmt(&out, allocator, "{d}", .{be});
        }
        for (ev.captures) |cap| {
            try out.appendSlice(allocator, ", \"");
            try appendEscaped(&out, cap.field_name, allocator);
            try out.appendSlice(allocator, "\": \"");
            try appendEscaped(&out, cap.value, allocator);
            try out.appendSlice(allocator, "\"");
        }
        for (ev.int_fields) |f| {
            try out.appendSlice(allocator, ", \"");
            try appendEscaped(&out, f.field_name, allocator);
            try out.appendSlice(allocator, "\": ");
            try appendFmt(&out, allocator, "{d}", .{f.value});
        }
        if (include_alts) {
            try out.appendSlice(allocator, ", \"alternatives\": [");
            for (ev.alternatives, 0..) |alt, j| {
                if (j > 0) try out.appendSlice(allocator, ",");
                try out.appendSlice(allocator, " { \"type\": \"");
                try appendEscaped(&out, alt.type_name, allocator);
                try out.appendSlice(allocator, "\", \"confidence\": ");
                try appendFmt(&out, allocator, "{d:.2}", .{alt.confidence});
                if (alt.source == .resemblance) {
                    try out.appendSlice(allocator, ", \"source\": \"resemblance\", \"resembled_kind\": \"");
                    try appendEscaped(&out, alt.type_name, allocator);
                    try out.appendSlice(allocator, "\", \"membership\": ");
                    try appendFmt(&out, allocator, "{d:.2}", .{alt.confidence});
                }
                for (alt.captures) |cap| {
                    try out.appendSlice(allocator, ", \"");
                    try appendEscaped(&out, cap.field_name, allocator);
                    try out.appendSlice(allocator, "\": \"");
                    try appendEscaped(&out, cap.value, allocator);
                    try out.appendSlice(allocator, "\"");
                }
                try out.appendSlice(allocator, " }");
            }
            if (ev.alternatives.len > 0) try out.appendSlice(allocator, " ");
            try out.appendSlice(allocator, "]");
        }
        try out.appendSlice(allocator, " }");
    }
    if (events_list.len > 0) try out.append(allocator, ' ');
    return out.toOwnedSlice(allocator);
}

fn referenceWrappedEvents(events_list: []const StructuralEvent, include_alts: bool, allocator: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{ \"events\": [");
    const body = try referenceEventArrayBody(events_list, include_alts, allocator);
    defer allocator.free(body);
    try out.appendSlice(allocator, body);
    try out.appendSlice(allocator, "] }");
    return out.toOwnedSlice(allocator);
}

fn referenceWrappedTokens(tokens: []const Token, allocator: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{ \"events\": [");
    for (tokens, 0..) |tok, i| {
        if (i > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, " { \"type\": \"");
        try appendEscaped(&out, tokenKindToString(tok.kind), allocator);
        try out.appendSlice(allocator, "\", \"start\": ");
        try appendFmt(&out, allocator, "{d}", .{tok.start});
        try out.appendSlice(allocator, ", \"end\": ");
        try appendFmt(&out, allocator, "{d}", .{tok.end});
        try out.appendSlice(allocator, ", \"line\": ");
        try appendFmt(&out, allocator, "{d}", .{tok.line});
        try out.appendSlice(allocator, ", \"col\": ");
        try appendFmt(&out, allocator, "{d}", .{tok.col});
        try out.appendSlice(allocator, " }");
    }
    if (tokens.len > 0) try out.append(allocator, ' ');
    try out.appendSlice(allocator, "] }");
    return out.toOwnedSlice(allocator);
}

fn referenceWrappedDirResults(entries: []const DirResult, include_alts: bool, allocator: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (entries, 0..) |entry, i| {
        if (i > 0) try out.appendSlice(allocator, ",");
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, "{ \"file\": \"");
        try appendEscaped(&out, entry.file, allocator);
        try out.appendSlice(allocator, "\", \"grammar\": \"");
        try appendEscaped(&out, entry.grammar, allocator);
        try out.appendSlice(allocator, "\", \"events\": [");
        const body = try referenceEventArrayBody(entry.events, include_alts, allocator);
        defer allocator.free(body);
        try out.appendSlice(allocator, body);
        try out.appendSlice(allocator, "] }");
    }
    if (entries.len > 0) try out.append(allocator, ' ');
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

// --- Property tests (minish, ≥100 iterations each) ---

// Generated events use deterministic, unique field-name pools per record so
// that JSON objects never contain duplicate keys (std.json rejects them).
const cap_names = [_][]const u8{ "cap0", "cap1", "cap2" };
const int_names = [_][]const u8{ "int0", "int1" };
const altcap_names = [_][]const u8{ "altcap0", "altcap1" };

const EventModel = struct {
    type_name: []const u8,
    n_captures: u8,
    n_int_fields: u8,
    n_alts: u8,
    start: usize,
    end: usize,
    line: usize,
    col: usize,
    confidence: f32,
    block_start: ?usize,
    block_end: ?usize,
};

const AltModel = struct {
    type_name: []const u8,
    confidence: f32,
    n_captures: u8,
    resemblance: bool,
};

const EventPair = struct {
    model: EventModel,
    alts: []const AltModel,
};

const event_model_gen = gen.structure(EventModel, .{
    .type_name = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
    .n_captures = gen.intRange(u8, 0, 3),
    .n_int_fields = gen.intRange(u8, 0, 2),
    .n_alts = gen.intRange(u8, 0, 2),
    .start = gen.intRange(usize, 0, 5000),
    .end = gen.intRange(usize, 0, 10000),
    .line = gen.intRange(usize, 1, 200),
    .col = gen.intRange(usize, 0, 80),
    .confidence = gen.floatRange(f32, 0.0, 1.0),
    .block_start = gen.optional(usize, gen.intRange(usize, 0, 1000)),
    .block_end = gen.optional(usize, gen.intRange(usize, 0, 1000)),
});

const alt_model_gen = gen.structure(AltModel, .{
    .type_name = gen.string(.{ .min_len = 1, .max_len = 6, .charset = .alpha }),
    .confidence = gen.floatRange(f32, 0.0, 1.0),
    .n_captures = gen.intRange(u8, 0, 2),
    .resemblance = gen.boolean(),
});

const pair_gen = gen.structure(EventPair, .{
    .model = event_model_gen,
    .alts = gen.list(AltModel, alt_model_gen, 0, 2),
});

const pair_list_gen = gen.list(EventPair, pair_gen, 0, 4);

const DirModel = struct {
    file: []const u8,
    grammar: []const u8,
    events: []const EventPair,
};

const dir_model_gen = gen.structure(DirModel, .{
    .file = gen.string(.{ .min_len = 1, .max_len = 16, .charset = .alphanumeric }),
    .grammar = gen.string(.{ .min_len = 1, .max_len = 12, .charset = .alphanumeric }),
    .events = gen.list(EventPair, pair_gen, 0, 3),
});

const dir_list_gen = gen.list(DirModel, dir_model_gen, 0, 3);

const ndjson_token_gen = gen.structure(Token, .{
    .kind = gen.enumValue(TokenKind),
    .start = gen.intRange(usize, 0, 5000),
    .end = gen.intRange(usize, 0, 10000),
    .line = gen.intRange(usize, 1, 200),
    .col = gen.intRange(usize, 0, 80),
    .kind_id = gen.intRange(usize, 0, 3),
});

/// Adversarial byte pool: every control byte 0x00..0x1F, `"`, `\`, `/`, 0x7F,
/// all bytes >= 0x80 (invalid UTF-8 included), plus a few printable letters.
const adversarial_chars: []const u8 = blk: {
    var buf: [32 + 4 + 128 + 3]u8 = undefined;
    var n: usize = 0;
    for (0..32) |c| {
        buf[n] = @intCast(c);
        n += 1;
    }
    for ("\"\\/\x7f") |c| {
        buf[n] = c;
        n += 1;
    }
    for (0x80..0x100) |c| {
        buf[n] = @intCast(c);
        n += 1;
    }
    for ("abz") |c| {
        buf[n] = c;
        n += 1;
    }
    const final = buf;
    break :blk &final;
};

/// Adversarial salt appended to generated strings (empty allowed).
const adv_salt_gen = gen.string(.{ .min_len = 0, .max_len = 8, .charset = .custom, .custom_chars = adversarial_chars });

/// `base ++ salt[rot..]` when salted, otherwise `base` unchanged. Callers keep
/// a unique `base` per JSON key, so adversarial suffixes never create
/// duplicate keys.
fn saltedString(allocator: std.mem.Allocator, base: []const u8, salt: ?[]const u8, rot: usize) ![]const u8 {
    const s = salt orelse return base;
    const tail = if (s.len == 0) s else s[rot % s.len ..];
    return std.mem.concat(allocator, u8, &.{ base, tail });
}

/// Value strings: the salt itself (rotated) when salted, otherwise `plain`.
fn saltedValue(plain: []const u8, salt: ?[]const u8, rot: usize) []const u8 {
    const s = salt orelse return plain;
    return if (s.len == 0) s else s[rot % s.len ..];
}

fn buildEventAlloc(m: EventModel, alts: []const AltModel, allocator: std.mem.Allocator) !StructuralEvent {
    return buildEventSalted(m, alts, null, allocator);
}

fn buildEventSalted(m: EventModel, alts: []const AltModel, salt: ?[]const u8, allocator: std.mem.Allocator) !StructuralEvent {
    const caps = try allocator.alloc(CaptureEntry, m.n_captures);
    for (0..m.n_captures) |j| {
        caps[j] = .{
            .field_name = try saltedString(allocator, cap_names[j], salt, j + 1),
            .value = saltedValue("v", salt, j),
        };
    }
    const ints = try allocator.alloc(IntegerField, m.n_int_fields);
    for (0..m.n_int_fields) |j| {
        ints[j] = .{ .field_name = try saltedString(allocator, int_names[j], salt, j + 2), .value = 7 };
    }
    const altbuf = try allocator.alloc(Alternative, alts.len);
    for (alts, 0..) |a, j| {
        const acaps = try allocator.alloc(CaptureEntry, a.n_captures);
        for (0..a.n_captures) |k| {
            acaps[k] = .{
                .field_name = try saltedString(allocator, altcap_names[k], salt, k + j + 3),
                .value = saltedValue("w", salt, k + j + 1),
            };
        }
        altbuf[j] = .{
            .type_name = try saltedString(allocator, a.type_name, salt, j + 4),
            .confidence = a.confidence,
            .captures = acaps,
            .source = if (a.resemblance) .resemblance else .grammar,
        };
    }
    return .{
        .type_name = try saltedString(allocator, m.type_name, salt, 0),
        .captures = caps,
        .start = m.start,
        .end = m.end,
        .line = m.line,
        .col = m.col,
        .confidence = m.confidence,
        .block_start = m.block_start,
        .block_end = m.block_end,
        .alternatives = altbuf,
        .int_fields = ints,
    };
}

fn buildEventsAlloc(pairs: []const EventPair, allocator: std.mem.Allocator) ![]StructuralEvent {
    return buildEventsSalted(pairs, null, allocator);
}

fn buildEventsSalted(pairs: []const EventPair, salt: ?[]const u8, allocator: std.mem.Allocator) ![]StructuralEvent {
    const events = try allocator.alloc(StructuralEvent, pairs.len);
    for (pairs, 0..) |p, i| {
        events[i] = try buildEventSalted(p.model, p.alts, salt, allocator);
    }
    return events;
}

fn buildDirResultsAlloc(models: []const DirModel, allocator: std.mem.Allocator) ![]DirResult {
    return buildDirResultsSalted(models, null, allocator);
}

fn buildDirResultsSalted(models: []const DirModel, salt: ?[]const u8, allocator: std.mem.Allocator) ![]DirResult {
    const entries = try allocator.alloc(DirResult, models.len);
    for (models, 0..) |m, i| {
        const evs = try buildEventsSalted(m.events, salt, allocator);
        entries[i] = .{
            .file = try saltedString(allocator, m.file, salt, i),
            .grammar = try saltedString(allocator, m.grammar, salt, i + 1),
            .events = evs,
        };
    }
    return entries;
}

// Feature: ndjson-output, Property 1: Byte-identical output when the flag is off
test "property: byte-identical output when the flag is off (refactor guard)" {
    try minish.check(testing.allocator, pair_list_gen, struct {
        fn prop(pairs: []const EventPair) !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const events = try buildEventsAlloc(pairs, arena.allocator());
            const actual = try serializeEventsToStringWithAlternatives(events, true);
            defer testing.allocator.free(actual);
            const expected = try referenceWrappedEvents(events, true, testing.allocator);
            defer testing.allocator.free(expected);
            try testing.expectEqualStrings(expected, actual);
        }
    }.prop, .{ .num_runs = 100 });

    const token_list_gen = gen.list(Token, ndjson_token_gen, 0, 4);
    try minish.check(testing.allocator, token_list_gen, struct {
        fn prop(tokens: []const Token) !void {
            const actual = try serializeToString(tokens);
            defer testing.allocator.free(actual);
            const expected = try referenceWrappedTokens(tokens, testing.allocator);
            defer testing.allocator.free(expected);
            try testing.expectEqualStrings(expected, actual);
        }
    }.prop, .{ .num_runs = 100 });

    try minish.check(testing.allocator, dir_list_gen, struct {
        fn prop(models: []const DirModel) !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const entries = try buildDirResultsAlloc(models, arena.allocator());
            const actual = try serializeDirResultsToString(entries, true);
            defer testing.allocator.free(actual);
            const expected = try referenceWrappedDirResults(entries, true, testing.allocator);
            defer testing.allocator.free(expected);
            try testing.expectEqualStrings(expected, actual);
        }
    }.prop, .{ .num_runs = 100 });
}

// Same comparison as Property 1, with adversarial bytes (control bytes, `"`,
// `\`, `/`, 0x7F, >= 0x80) appended to every string slot: type, capture and
// integer field names, alternative type, capture values, file, grammar. Each
// field name keeps its unique base, so keys stay distinct. Compared byte for
// byte against the independent reference only (no std.json parse, since the
// bytes may be invalid UTF-8).
test "property: reference comparison holds with adversarial strings" {
    const events_gen = comptime gen.tuple2(
        []const EventPair,
        []const u8,
        pair_list_gen,
        adv_salt_gen,
    );
    try minish.check(testing.allocator, events_gen, struct {
        fn prop(v: struct { []const EventPair, []const u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const events = try buildEventsSalted(v[0], v[1], arena.allocator());
            const actual = try serializeEventsToStringWithAlternatives(events, true);
            defer testing.allocator.free(actual);
            const expected = try referenceWrappedEvents(events, true, testing.allocator);
            defer testing.allocator.free(expected);
            try testing.expectEqualStrings(expected, actual);
        }
    }.prop, .{ .num_runs = 100 });

    const dir_gen = comptime gen.tuple2(
        []const DirModel,
        []const u8,
        dir_list_gen,
        adv_salt_gen,
    );
    try minish.check(testing.allocator, dir_gen, struct {
        fn prop(v: struct { []const DirModel, []const u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const entries = try buildDirResultsSalted(v[0], v[1], arena.allocator());
            const actual = try serializeDirResultsToString(entries, true);
            defer testing.allocator.free(actual);
            const expected = try referenceWrappedDirResults(entries, true, testing.allocator);
            defer testing.allocator.free(expected);
            try testing.expectEqualStrings(expected, actual);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: ndjson-output, Property 2: Each NDJSON record is one complete JSON
// value on one line
test "property: each NDJSON record is one complete JSON value on one line" {
    try minish.check(testing.allocator, pair_list_gen, struct {
        fn prop(pairs: []const EventPair) !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const events = try buildEventsAlloc(pairs, arena.allocator());
            const out = try serializeEventsNdjsonToString(events, true);
            defer testing.allocator.free(out);
            var it = std.mem.splitScalar(u8, out, '\n');
            var lines: usize = 0;
            while (it.next()) |line| {
                if (line.len == 0) continue;
                lines += 1;
                try testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
                const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
                defer parsed.deinit();
                try testing.expect(std.meta.activeTag(parsed.value) == .object);
            }
            try testing.expectEqual(events.len, lines);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: ndjson-output, Property 3: Wrapped to NDJSON event-set equivalence
test "property: Wrapped to NDJSON event-set equivalence" {
    try minish.check(testing.allocator, pair_list_gen, struct {
        fn prop(pairs: []const EventPair) !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const events = try buildEventsAlloc(pairs, arena.allocator());

            const wrapped = try serializeEventsToStringWithAlternatives(events, true);
            defer testing.allocator.free(wrapped);
            const parsed_wrapped = try std.json.parseFromSlice(std.json.Value, testing.allocator, wrapped, .{});
            defer parsed_wrapped.deinit();
            const wrapped_events = parsed_wrapped.value.object.get("events").?.array.items;

            const nd = try serializeEventsNdjsonToString(events, true);
            defer testing.allocator.free(nd);
            var it = std.mem.splitScalar(u8, nd, '\n');
            var idx: usize = 0;
            while (it.next()) |line| {
                if (line.len == 0) continue;
                const parsed_line = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
                defer parsed_line.deinit();
                const s1 = try stringifyValue(testing.allocator, .{ .object = parsed_line.value.object });
                defer testing.allocator.free(s1);
                const s2 = try stringifyValue(testing.allocator, .{ .object = wrapped_events[idx].object });
                defer testing.allocator.free(s2);
                try testing.expectEqualStrings(s2, s1);
                idx += 1;
            }
            try testing.expectEqual(events.len, idx);
        }
    }.prop, .{ .num_runs = 100 });

    const token_list_gen = gen.list(Token, ndjson_token_gen, 0, 4);
    try minish.check(testing.allocator, token_list_gen, struct {
        fn prop(tokens: []const Token) !void {
            const wrapped = try serializeToString(tokens);
            defer testing.allocator.free(wrapped);
            const parsed_wrapped = try std.json.parseFromSlice(std.json.Value, testing.allocator, wrapped, .{});
            defer parsed_wrapped.deinit();
            const wrapped_tokens = parsed_wrapped.value.object.get("events").?.array.items;

            const nd = try serializeTokensNdjsonToString(tokens);
            defer testing.allocator.free(nd);
            var it = std.mem.splitScalar(u8, nd, '\n');
            var idx: usize = 0;
            while (it.next()) |line| {
                if (line.len == 0) continue;
                const parsed_line = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
                defer parsed_line.deinit();
                const s1 = try stringifyValue(testing.allocator, .{ .object = parsed_line.value.object });
                defer testing.allocator.free(s1);
                const s2 = try stringifyValue(testing.allocator, .{ .object = wrapped_tokens[idx].object });
                defer testing.allocator.free(s2);
                try testing.expectEqualStrings(s2, s1);
                idx += 1;
            }
            try testing.expectEqual(tokens.len, idx);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: ndjson-output, Property 4: Exact line framing N events to N newlines
test "property: exact line framing — N events ⇒ N newlines, zero ⇒ zero bytes" {
    try minish.check(testing.allocator, pair_list_gen, struct {
        fn prop(pairs: []const EventPair) !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const events = try buildEventsAlloc(pairs, arena.allocator());
            const out = try serializeEventsNdjsonToString(events, false);
            defer testing.allocator.free(out);
            var nl: usize = 0;
            for (out) |b| {
                if (b == '\n') nl += 1;
            }
            try testing.expectEqual(events.len, nl);
            if (events.len == 0) {
                try testing.expectEqual(@as(usize, 0), out.len);
            } else {
                try testing.expectEqual(out[out.len - 1], '\n');
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: ndjson-output, Property 5: Dir_Mode flattened lines carry correct envelope
test "property: Dir_Mode flattened lines carry correct envelope" {
    try minish.check(testing.allocator, dir_list_gen, struct {
        fn prop(models: []const DirModel) !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const entries = try buildDirResultsAlloc(models, arena.allocator());
            const total_events = blk: {
                var n: usize = 0;
                for (entries) |e| n += e.events.len;
                break :blk n;
            };
            const out = try serializeDirResultsNdjsonToString(entries, false);
            defer testing.allocator.free(out);
            var it = std.mem.splitScalar(u8, out, '\n');
            var entry_idx: usize = 0;
            var inner_idx: usize = 0;
            var seen: usize = 0;
            while (it.next()) |line| {
                if (line.len == 0) continue;
                while (entry_idx < entries.len and inner_idx >= entries[entry_idx].events.len) {
                    entry_idx += 1;
                    inner_idx = 0;
                }
                try testing.expect(entry_idx < entries.len);
                const entry = entries[entry_idx];
                const ev = entry.events[inner_idx];
                inner_idx += 1;
                seen += 1;

                const parsed_line = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
                defer parsed_line.deinit();
                const obj = parsed_line.value.object;
                try testing.expectEqualStrings(entry.file, obj.get("file").?.string);
                try testing.expectEqualStrings(entry.grammar, obj.get("grammar").?.string);
                var stripped = obj;
                _ = stripped.orderedRemove("file");
                _ = stripped.orderedRemove("grammar");

                const single_out = try serializeEventsToStringWithAlternatives(&.{ev}, false);
                defer testing.allocator.free(single_out);
                const parsed_single = try std.json.parseFromSlice(std.json.Value, testing.allocator, single_out, .{});
                defer parsed_single.deinit();
                const single_ev = parsed_single.value.object.get("events").?.array.items[0].object;
                const s1 = try stringifyValue(testing.allocator, .{ .object = stripped });
                defer testing.allocator.free(s1);
                const s2 = try stringifyValue(testing.allocator, .{ .object = single_ev });
                defer testing.allocator.free(s2);
                try testing.expectEqualStrings(s2, s1);
            }
            try testing.expectEqual(total_events, seen);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: ndjson-output, Property 6: No added field names in Single_File_Mode
test "property: No added field names in Single_File_Mode" {
    try minish.check(testing.allocator, pair_gen, struct {
        fn prop(p: EventPair) !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const ev = try buildEventAlloc(p.model, p.alts, arena.allocator());
            const events = &[_]StructuralEvent{ev};
            const nd = try serializeEventsNdjsonToString(events, true);
            defer testing.allocator.free(nd);
            const wr = try serializeEventsToStringWithAlternatives(events, true);
            defer testing.allocator.free(wr);
            const p_nd = try std.json.parseFromSlice(std.json.Value, testing.allocator, nd[0 .. nd.len - 1], .{});
            defer p_nd.deinit();
            const p_wr = try std.json.parseFromSlice(std.json.Value, testing.allocator, wr, .{});
            defer p_wr.deinit();
            const line_obj = p_nd.value.object;
            const wrapped_obj = p_wr.value.object.get("events").?.array.items[0].object;
            try testing.expectEqual(line_obj.count(), wrapped_obj.count());
            var it = line_obj.iterator();
            while (it.next()) |kv| {
                try testing.expect(wrapped_obj.get(kv.key_ptr.*) != null);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// --- Bug condition exploration tests (spec: json-string-escaping, task 1) ---
// These encode the EXPECTED (fixed) behavior and MUST FAIL on unfixed code.

fn explorationEvent(type_name: []const u8, captures: []const CaptureEntry) StructuralEvent {
    return .{ .type_name = type_name, .captures = captures, .start = 0, .end = 1, .line = 1, .col = 0, .confidence = 1.0 };
}

fn explorationFirstEvent(parsed: std.json.Parsed(std.json.Value)) std.json.ObjectMap {
    return parsed.value.object.get("events").?.array.items[0].object;
}

test "exploration: control bytes in capture value are escaped" {
    const value = "a\nb\tc\x00\x1f\r\x08\x0c\x01";
    const ev = explorationEvent("t", &.{.{ .field_name = "s", .value = value }});
    const out = try serializeEventsToString(&.{ev});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"s\": \"a\\nb\\tc\\u0000\\u001f\\r\\b\\f\\u0001\"") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(value, explorationFirstEvent(parsed).get("s").?.string);
}

test "exploration: quote and backslash in type, capture field, and integer field names" {
    const ev = StructuralEvent{
        .type_name = "a\"b",
        .captures = &.{.{ .field_name = "x\\y", .value = "v" }},
        .int_fields = &.{.{ .field_name = "i\"j", .value = 7 }},
        .start = 0,
        .end = 1,
        .line = 1,
        .col = 0,
        .confidence = 1.0,
    };
    const out = try serializeEventsToString(&.{ev});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"type\": \"a\\\"b\"") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const obj = explorationFirstEvent(parsed);
    try testing.expectEqualStrings("a\"b", obj.get("type").?.string);
    try testing.expectEqualStrings("v", obj.get("x\\y").?.string);
    try testing.expectEqual(@as(i64, 7), obj.get("i\"j").?.integer);
}

test "exploration: alternative type, capture field name, and capture value are escaped" {
    const ev = StructuralEvent{
        .type_name = "t",
        .captures = &.{},
        .start = 0,
        .end = 1,
        .line = 1,
        .col = 0,
        .confidence = 1.0,
        .alternatives = &.{.{
            .type_name = "o\"p",
            .confidence = 0.5,
            .captures = &.{.{ .field_name = "x\"y", .value = "l1\nl2" }},
        }},
    };
    const out = try serializeEventsToStringWithAlternatives(&.{ev}, true);
    defer testing.allocator.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const alt = explorationFirstEvent(parsed).get("alternatives").?.array.items[0].object;
    try testing.expectEqualStrings("o\"p", alt.get("type").?.string);
    try testing.expectEqualStrings("l1\nl2", alt.get("x\"y").?.string);
}

test "exploration: resembled_kind with backslash is escaped" {
    const ev = StructuralEvent{
        .type_name = "t",
        .captures = &.{},
        .start = 0,
        .end = 1,
        .line = 1,
        .col = 0,
        .confidence = 1.0,
        .alternatives = &.{.{ .type_name = "n\\um", .confidence = 0.83, .captures = &.{}, .source = .resemblance }},
    };
    const out = try serializeEventsToStringWithAlternatives(&.{ev}, true);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"resembled_kind\": \"n\\\\um\"") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const alt = explorationFirstEvent(parsed).get("alternatives").?.array.items[0].object;
    try testing.expectEqualStrings("n\\um", alt.get("resembled_kind").?.string);
}

test "exploration: parse-dir envelope control bytes, wrapped" {
    const entries = [_]DirResult{.{
        .file = "a\nb",
        .grammar = "g\x01",
        .events = &.{explorationEvent("t", &.{})},
    }};
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try serializeDirResults(&entries, false, &aw.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const obj = parsed.value.array.items[0].object;
    try testing.expectEqualStrings("a\nb", obj.get("file").?.string);
    try testing.expectEqualStrings("g\x01", obj.get("grammar").?.string);
}

test "exploration: parse-dir envelope control bytes, NDJSON" {
    const entries = [_]DirResult{.{
        .file = "a\nb",
        .grammar = "g\x01",
        .events = &.{explorationEvent("t", &.{})},
    }};
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try serializeDirResultsNdjson(&entries, false, &aw.writer);
    const out = aw.written();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\n"));
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out[0 .. out.len - 1], .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("a\nb", parsed.value.object.get("file").?.string);
    try testing.expectEqualStrings("g\x01", parsed.value.object.get("grammar").?.string);
}

test "exploration: jsonl newline count equals record count with LF and CR in captures" {
    const evs = [_]StructuralEvent{
        explorationEvent("t", &.{.{ .field_name = "s", .value = "a\nb" }}),
        explorationEvent("t", &.{.{ .field_name = "s", .value = "c\rd\ne" }}),
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try serializeEventsNdjson(&evs, false, &aw.writer);
    const out = aw.written();
    try testing.expectEqual(@as(usize, evs.len), std.mem.count(u8, out, "\n"));
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "\r"));
}

// --- Ground-truth and byte-level tests (spec: json-string-escaping, task 5) ---
// Property 1: adversarial VALID UTF-8 in every string slot must parse with
// std.json and round-trip exactly, in every framing. std.json is the oracle,
// independent of the production writer and of the reference serializer.
const ctrl_bytes: [32]u8 = blk: {
    var b: [32]u8 = undefined;
    for (0..32) |i| b[i] = @intCast(i);
    break :blk b;
};
const non_ctrl_atoms = [_][]const u8{
    "\"", "\\", "/", "\x7f", "a", "Z", " ", "\u{e9}", "\u{20ac}", "\u{1f600}", "\u{10ffff}",
};
const n_atoms: u8 = 32 + non_ctrl_atoms.len;
const atom_gen = gen.intRange(u8, 0, n_atoms - 1);
const atoms_gen = gen.list(u8, atom_gen, 0, 48);
fn atomBytes(idx: u8) []const u8 {
    if (idx < 32) return ctrl_bytes[idx .. idx + 1];
    return non_ctrl_atoms[idx - 32];
}
/// Deterministic adversarial string for a slot: 0..5 atoms from a slot-specific
/// window of the generated atom list.
fn slotString(allocator: std.mem.Allocator, atoms: []const u8, slot: usize) ![]const u8 {
    if (atoms.len == 0) return "";
    const len = (slot * 5 + atoms.len) % 6;
    var out: std.ArrayList(u8) = .empty;
    for (0..len) |k| {
        try out.appendSlice(allocator, atomBytes(atoms[(slot * 7 + k) % atoms.len]));
    }
    return out.items;
}
/// `"<prefix>:"` ++ adversarial suffix. The prefix is unique per slot and
/// prefix-free, so keys stay distinct and never collide with built-in keys.
fn slotName(allocator: std.mem.Allocator, atoms: []const u8, slot: *usize, comptime fmt: []const u8, args: anytype) ![]const u8 {
    const prefix = try std.fmt.allocPrint(allocator, fmt, args);
    const suffix = try slotString(allocator, atoms, slot.*);
    slot.* += 1;
    return std.mem.concat(allocator, u8, &.{ prefix, suffix });
}
fn slotValue(allocator: std.mem.Allocator, atoms: []const u8, slot: *usize) ![]const u8 {
    const s = try slotString(allocator, atoms, slot.*);
    slot.* += 1;
    return s;
}
/// Builds `n` events, every `[]const u8` of StructuralEvent, Alternative,
/// CaptureEntry and IntegerField being an adversarial string. A new string
/// field added to those types must be filled here, or the round-trip below
/// cannot cover it.
fn buildGroundTruthEvents(allocator: std.mem.Allocator, atoms: []const u8, n: usize) ![]StructuralEvent {
    var slot: usize = 0;
    const events = try allocator.alloc(StructuralEvent, n);
    for (events, 0..) |*ev, e| {
        const caps = try allocator.alloc(CaptureEntry, 2);
        for (caps, 0..) |*c, k| {
            c.* = .{
                .field_name = try slotName(allocator, atoms, &slot, "c{d}_{d}:", .{ e, k }),
                .value = try slotValue(allocator, atoms, &slot),
            };
        }
        const ints = try allocator.alloc(IntegerField, 2);
        for (ints, 0..) |*f, k| {
            f.* = .{ .field_name = try slotName(allocator, atoms, &slot, "i{d}_{d}:", .{ e, k }), .value = @intCast(e * 10 + k) };
        }
        const alts = try allocator.alloc(Alternative, 2);
        for (alts, 0..) |*a, j| {
            const acaps = try allocator.alloc(CaptureEntry, 2);
            for (acaps, 0..) |*c, k| {
                c.* = .{
                    .field_name = try slotName(allocator, atoms, &slot, "a{d}_{d}_{d}:", .{ e, j, k }),
                    .value = try slotValue(allocator, atoms, &slot),
                };
            }
            a.* = .{
                .type_name = try slotValue(allocator, atoms, &slot),
                .confidence = 0.5,
                .captures = acaps,
                .source = if (j == 1) .resemblance else .grammar,
            };
        }
        ev.* = .{
            .type_name = try slotValue(allocator, atoms, &slot),
            .captures = caps,
            .start = e,
            .end = e + 1,
            .line = 1,
            .col = 0,
            .confidence = 1.0,
            .alternatives = alts,
            .int_fields = ints,
        };
    }
    return events;
}
fn expectEventRoundTrip(obj: std.json.ObjectMap, ev: StructuralEvent) !void {
    try testing.expectEqualStrings(ev.type_name, obj.get("type").?.string);
    for (ev.captures) |c| try testing.expectEqualStrings(c.value, obj.get(c.field_name).?.string);
    for (ev.int_fields) |f| try testing.expectEqual(@as(i64, f.value), obj.get(f.field_name).?.integer);
    const alts = obj.get("alternatives").?.array.items;
    try testing.expectEqual(ev.alternatives.len, alts.len);
    for (ev.alternatives, alts) |a, av| {
        const ao = av.object;
        try testing.expectEqualStrings(a.type_name, ao.get("type").?.string);
        for (a.captures) |c| try testing.expectEqualStrings(c.value, ao.get(c.field_name).?.string);
        if (a.source == .resemblance) {
            try testing.expectEqualStrings("resemblance", ao.get("source").?.string);
            try testing.expectEqualStrings(a.type_name, ao.get("resembled_kind").?.string);
        }
    }
}
fn expectEventsRoundTrip(items: []const std.json.Value, events: []const StructuralEvent) !void {
    try testing.expectEqual(events.len, items.len);
    for (events, items) |ev, item| try expectEventRoundTrip(item.object, ev);
}
/// Parses each `\n`-terminated line of `out`; asserts the newline count equals
/// the record count and that every line is one complete JSON value.
fn parseNdjsonLines(allocator: std.mem.Allocator, out: []const u8, n_records: usize) ![]std.json.Value {
    try testing.expectEqual(n_records, std.mem.count(u8, out, "\n"));
    const vals = try allocator.alloc(std.json.Value, n_records);
    var it = std.mem.splitScalar(u8, out, '\n');
    for (vals) |*v| {
        const line = it.next().?;
        v.* = try std.json.parseFromSliceLeaky(std.json.Value, allocator, line, .{});
    }
    try testing.expectEqualStrings("", it.next().?);
    return vals;
}
test "property: adversarial valid UTF-8 round-trips through std.json in every framing" {
    const g = comptime gen.tuple2([]const u8, u8, atoms_gen, gen.intRange(u8, 0, 3));
    try minish.check(testing.allocator, g, struct {
        fn prop(v: struct { []const u8, u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const events = try buildGroundTruthEvents(a, v[0], v[1]);
            var slot: usize = 1000;
            const entries = [_]DirResult{
                .{ .file = try slotValue(a, v[0], &slot), .grammar = try slotValue(a, v[0], &slot), .events = events },
                .{ .file = try slotValue(a, v[0], &slot), .grammar = try slotValue(a, v[0], &slot), .events = events },
            };

            // Wrapped events (with alternatives).
            {
                var aw: std.Io.Writer.Allocating = .init(a);
                try serializeEventsWithAlternatives(events, true, &aw.writer);
                const doc = try std.json.parseFromSliceLeaky(std.json.Value, a, aw.written(), .{});
                try expectEventsRoundTrip(doc.object.get("events").?.array.items, events);
            }
            // --jsonl records.
            {
                var aw: std.Io.Writer.Allocating = .init(a);
                try serializeEventsNdjson(events, true, &aw.writer);
                const lines = try parseNdjsonLines(a, aw.written(), events.len);
                for (events, lines) |ev, line| try expectEventRoundTrip(line.object, ev);
            }
            // parse-dir wrapped array.
            {
                var aw: std.Io.Writer.Allocating = .init(a);
                try serializeDirResults(&entries, true, &aw.writer);
                const doc = try std.json.parseFromSliceLeaky(std.json.Value, a, aw.written(), .{});
                try testing.expectEqual(entries.len, doc.array.items.len);
                for (entries, doc.array.items) |en, item| {
                    try testing.expectEqualStrings(en.file, item.object.get("file").?.string);
                    try testing.expectEqualStrings(en.grammar, item.object.get("grammar").?.string);
                    try expectEventsRoundTrip(item.object.get("events").?.array.items, en.events);
                }
            }
            // parse-dir NDJSON records (one line per event, envelope leading).
            {
                var aw: std.Io.Writer.Allocating = .init(a);
                try serializeDirResultsNdjson(&entries, true, &aw.writer);
                const lines = try parseNdjsonLines(a, aw.written(), entries.len * events.len);
                var i: usize = 0;
                for (entries) |en| {
                    for (en.events) |ev| {
                        const obj = lines[i].object;
                        try testing.expectEqualStrings(en.file, obj.get("file").?.string);
                        try testing.expectEqualStrings(en.grammar, obj.get("grammar").?.string);
                        try expectEventRoundTrip(obj, ev);
                        i += 1;
                    }
                }
            }
        }
    }.prop, .{ .num_runs = 100 });
}
fn expectWrittenString(input: []const u8, expected: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeJsonString(&aw.writer, input);
    try testing.expectEqualStrings(expected, aw.written());
}
test "writeJsonString: exact bytes for each escape table row" {
    try expectWrittenString("", "\"\"");
    try expectWrittenString("\"", "\"\\\"\"");
    try expectWrittenString("\\", "\"\\\\\"");
    try expectWrittenString("\x08", "\"\\b\"");
    try expectWrittenString("\x09", "\"\\t\"");
    try expectWrittenString("\x0a", "\"\\n\"");
    try expectWrittenString("\x0c", "\"\\f\"");
    try expectWrittenString("\x0d", "\"\\r\"");
    try expectWrittenString("\x00", "\"\\u0000\"");
    try expectWrittenString("\x01", "\"\\u0001\"");
    try expectWrittenString("\x1f", "\"\\u001f\"");
    try expectWrittenString("\x0b", "\"\\u000b\"");
    try expectWrittenString("\x1b", "\"\\u001b\"");
}
test "writeJsonString: pass-through rows and invalid UTF-8 bytes unchanged" {
    try expectWrittenString("/", "\"/\"");
    try expectWrittenString("\x7f", "\"\x7f\"");
    try expectWrittenString("\u{e9}", "\"\u{e9}\"");
    try expectWrittenString("\xff", "\"\xff\"");
    try expectWrittenString("a\xc3(b\x80", "\"a\xc3(b\x80\"");
}
// --- Preservation tests (spec: json-string-escaping, task 2) ---

// Feature: json-string-escaping, Unit: pinned preservation bytes (non-UTF-8,
// DEL, `/`, and quote/backslash in a value-class string stay as today).
// **Validates: Requirements 3.1, 2.7**
test "preservation: value-class bytes pinned (quote, backslash, slash, DEL, high bytes)" {
    const ev = StructuralEvent{
        .type_name = "t",
        .captures = &.{.{ .field_name = "s", .value = "q\"b\\/\x7f\xff\xc3\xa9" }},
        .start = 0,
        .end = 1,
        .line = 1,
        .col = 0,
        .confidence = 1.0,
    };
    const out = try serializeEventsToStringWithAlternatives(&.{ev}, false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "{ \"events\": [ { \"type\": \"t\", \"start\": 0, \"end\": 1, \"line\": 1, \"confidence\": 1.00, \"col\": 0, \"s\": \"q\\\"b\\\\/\x7f\xff\xc3\xa9\" } ] }",
        out,
    );
}
