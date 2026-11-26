const std = @import("std");
const cli = @import("args.zig");
const json = @import("../output/json.zig");
const events = @import("../parser/events.zig");
const tokenizer = @import("../parser/tokenizer.zig");

/// How output is written: one JSON document plus a final newline (`wrapped`),
/// one JSON value per line (`jsonl`), or plain text, one value per line
/// (`names_only`).
pub const Framing = enum { wrapped, jsonl, names_only };

/// `parseArgs` guarantees `names_only` and `jsonl` are never both set.
pub fn framingOf(parsed: cli.ParsedArgs) Framing {
    if (parsed.names_only) return .names_only;
    if (parsed.jsonl) return .jsonl;
    return .wrapped;
}

/// What a command produced.
pub const Payload = union(enum) {
    events: struct { list: []const events.StructuralEvent, include_alternatives: bool },
    tokens: []const tokenizer.Token,
    dir_results: struct { entries: []const json.DirResult, include_alternatives: bool },
};

/// One entry prints as bare events; several print as `DirResult` entries.
/// Asserts `entries.len >= 1`.
pub fn forGrammars(entries: []const json.DirResult, include_alternatives: bool) Payload {
    std.debug.assert(entries.len >= 1);
    if (entries.len == 1) return .{ .events = .{ .list = entries[0].events, .include_alternatives = include_alternatives } };
    return .{ .dir_results = .{ .entries = entries, .include_alternatives = include_alternatives } };
}

/// The single output step: serializes `payload` in `framing`. Wrapped JSON is
/// followed by one final newline (`finishWrapped`); jsonl and names-only add
/// none. `names_only` on `tokens` renders as wrapped JSON (the flag is ignored
/// without a grammar). `names_only` on `dir_results` cannot happen:
/// `parseArgs` rejects it for parse-dir and `rejectNamesOnlyMulti` for several grammars.
pub fn write(stdout: *std.Io.Writer, payload: Payload, framing: Framing) !void {
    switch (payload) {
        .events => |p| switch (framing) {
            .names_only => for (p.list) |event| try writeNamesOnlyLine(stdout, event),
            .jsonl => try json.serializeEventsNdjson(p.list, p.include_alternatives, stdout),
            .wrapped => {
                try json.serializeEventsWithAlternatives(p.list, p.include_alternatives, stdout);
                try finishWrapped(stdout);
            },
        },
        .tokens => |tokens| switch (framing) {
            .jsonl => try json.serializeTokensNdjson(tokens, stdout),
            .wrapped, .names_only => {
                try json.serializeTokens(tokens, stdout);
                try finishWrapped(stdout);
            },
        },
        .dir_results => |p| switch (framing) {
            .jsonl => try json.serializeDirResultsNdjson(p.entries, p.include_alternatives, stdout),
            .wrapped => {
                try json.serializeDirResults(p.entries, p.include_alternatives, stdout);
                try finishWrapped(stdout);
            },
            // `parseArgs` (parse-dir) and `rejectNamesOnlyMulti` (several grammars) own this rejection.
            .names_only => unreachable,
        },
    }
}
/// Called only after wrapped JSON was written: the final newline.
fn finishWrapped(stdout: *std.Io.Writer) !void {
    try stdout.writeAll("\n");
}
/// `--names-only` value selector: an event renders its first string capture;
/// an event with no string capture falls back to its leading integer field
/// (decimal digits); an event with neither renders nothing. No allocation,
/// no I/O — `writeNamesOnlyLine` delegates to this pure selector.
pub const NamesOnlyValue = union(enum) { text: []const u8, number: u32 };

pub fn namesOnlyValue(event: events.StructuralEvent) ?NamesOnlyValue {
    if (event.captures.len > 0) return .{ .text = event.captures[0].value };
    if (event.int_fields.len > 0) return .{ .number = event.int_fields[0].value };
    return null;
}

/// `--names-only` rendering: the first string capture renders; an event with
/// no string capture falls back to its leading integer field (decimal digits);
/// an event with neither prints nothing. Each value ends in a single '\n'.
pub fn writeNamesOnlyLine(stdout: *std.Io.Writer, event: events.StructuralEvent) !void {
    const value = namesOnlyValue(event) orelse return;
    switch (value) {
        .text => |t| {
            try stdout.writeAll(t);
            try stdout.writeAll("\n");
        },
        .number => |n| try stdout.print("{d}\n", .{n}),
    }
}

const test_caps_a = [_]events.CaptureEntry{.{ .field_name = "name", .value = "a" }};
const test_caps_b = [_]events.CaptureEntry{.{ .field_name = "name", .value = "b" }};

fn testEvent(comptime name: []const u8) events.StructuralEvent {
    const caps: []const events.CaptureEntry = if (comptime std.mem.eql(u8, name, "a")) &test_caps_a else &test_caps_b;
    return .{
        .type_name = "function",
        .captures = caps,
        .start = 0,
        .end = 10,
        .line = 1,
        .col = 0,
        .confidence = 1.0,
        .int_fields = &.{},
    };
}

/// Renders `payload` in `framing`, then the expected bytes via `expect_fn`
/// (the underlying serializer) plus `suffix`, and compares.
fn expectCell(payload: Payload, framing: Framing, comptime which: enum { events, tokens, dir }, suffix: []const u8) !void {
    const a = std.testing.allocator;
    var got: std.Io.Writer.Allocating = .init(a);
    defer got.deinit();
    try write(&got.writer, payload, framing);
    var want: std.Io.Writer.Allocating = .init(a);
    defer want.deinit();
    switch (which) {
        .events => {
            const p = payload.events;
            if (framing == .jsonl)
                try json.serializeEventsNdjson(p.list, p.include_alternatives, &want.writer)
            else
                try json.serializeEventsWithAlternatives(p.list, p.include_alternatives, &want.writer);
        },
        .tokens => {
            if (framing == .jsonl)
                try json.serializeTokensNdjson(payload.tokens, &want.writer)
            else
                try json.serializeTokens(payload.tokens, &want.writer);
        },
        .dir => {
            const p = payload.dir_results;
            if (framing == .jsonl)
                try json.serializeDirResultsNdjson(p.entries, p.include_alternatives, &want.writer)
            else
                try json.serializeDirResults(p.entries, p.include_alternatives, &want.writer);
        },
    }
    try want.writer.writeAll(suffix);
    try std.testing.expectEqualStrings(want.written(), got.written());
}

test "output.write events: wrapped adds one newline, jsonl adds none" {
    const list = [_]events.StructuralEvent{ testEvent("a"), testEvent("b") };
    const p: Payload = .{ .events = .{ .list = &list, .include_alternatives = false } };
    try expectCell(p, .wrapped, .events, "\n");
    try expectCell(p, .jsonl, .events, "");
}

test "output.write events names_only: one line per value, no newline added" {
    const list = [_]events.StructuralEvent{ testEvent("a"), testEvent("b") };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try write(&aw.writer, .{ .events = .{ .list = &list, .include_alternatives = false } }, .names_only);
    try std.testing.expectEqualStrings("a\nb\n", aw.written());
}

test "output.write tokens: wrapped adds one newline, jsonl none" {
    const toks = [_]tokenizer.Token{.{ .kind = .identifier, .start = 0, .end = 1, .line = 1, .col = 0, .kind_id = 0 }};
    const p: Payload = .{ .tokens = &toks };
    try expectCell(p, .wrapped, .tokens, "\n");
    try expectCell(p, .jsonl, .tokens, "");
}

test "output.write dir_results: wrapped adds one newline, jsonl none" {
    const list = [_]events.StructuralEvent{testEvent("a")};
    const entries = [_]json.DirResult{.{ .file = "f.zig", .grammar = "g.toml", .events = &list }};
    const p: Payload = .{ .dir_results = .{ .entries = &entries, .include_alternatives = false } };
    try expectCell(p, .wrapped, .dir, "\n");
    try expectCell(p, .jsonl, .dir, "");
}

test "output.write names_only on tokens renders wrapped JSON with one final newline" {
    const toks = [_]tokenizer.Token{.{ .kind = .identifier, .start = 0, .end = 1, .line = 1, .col = 0, .kind_id = 0 }};
    try expectCell(.{ .tokens = &toks }, .names_only, .tokens, "\n");
}

test "forGrammars: one entry is bare events, several are dir_results" {
    const list = [_]events.StructuralEvent{testEvent("a")};
    const one = [_]json.DirResult{.{ .file = "f", .grammar = "g", .events = &list }};
    const two = [_]json.DirResult{ one[0], one[0] };
    try std.testing.expect(forGrammars(&one, true) == .events);
    try std.testing.expect(forGrammars(&one, true).events.include_alternatives);
    try std.testing.expect(forGrammars(&two, false) == .dir_results);
    try std.testing.expectEqual(@as(usize, 2), forGrammars(&two, false).dir_results.entries.len);
}

test "framingOf: names_only, jsonl, neither" {
    const base = try cli.parseArgs(&.{ "parse", "f.zig" });
    try std.testing.expectEqual(Framing.wrapped, framingOf(base));
    const jl = try cli.parseArgs(&.{ "parse", "f.zig", "--jsonl" });
    try std.testing.expectEqual(Framing.jsonl, framingOf(jl));
    const no = try cli.parseArgs(&.{ "parse", "f.zig", "--names-only" });
    try std.testing.expectEqual(Framing.names_only, framingOf(no));
}
