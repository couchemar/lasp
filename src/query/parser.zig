const std = @import("std");
const filter = @import("filter.zig");
const QueryFilter = filter.QueryFilter;
const TypeSelector = filter.TypeSelector;
const AttributeCondition = filter.AttributeCondition;
const ComparisonOp = filter.ComparisonOp;
const AttributeValue = filter.AttributeValue;

pub const ParseError = error{
    EmptySelector,
    UnclosedBracket,
    MissingFieldName,
    MissingOperator,
    MissingValue,
    UnclosedQuote,
    InvalidOperator,
    InvalidNumericValue,
    UnexpectedCharacter,
    ExpectedQuotedValue,
    OutOfMemory,
};

/// Reads the operator sigil at `pos` and advances past it. Returns the parsed
/// ComparisonOp. A `~`/`^`/`$`/`!` not followed by `=` is InvalidOperator, as
/// is any other lead byte (Req 9).
fn readOperator(trimmed: []const u8, pos: *usize) ParseError!ComparisonOp {
    const c = trimmed[pos.*];
    switch (c) {
        '=' => {
            pos.* += 1;
            return .eq;
        },
        '>' => {
            pos.* += 1;
            return .gt;
        },
        '!' => {
            if (pos.* + 1 >= trimmed.len or trimmed[pos.* + 1] != '=') return ParseError.InvalidOperator;
            pos.* += 2;
            return .neq;
        },
        '~' => {
            if (pos.* + 1 >= trimmed.len or trimmed[pos.* + 1] != '=') return ParseError.InvalidOperator;
            pos.* += 2;
            return .contains;
        },
        '^' => {
            if (pos.* + 1 >= trimmed.len or trimmed[pos.* + 1] != '=') return ParseError.InvalidOperator;
            pos.* += 2;
            return .prefix;
        },
        '$' => {
            if (pos.* + 1 >= trimmed.len or trimmed[pos.* + 1] != '=') return ParseError.InvalidOperator;
            pos.* += 2;
            return .suffix;
        },
        else => return ParseError.InvalidOperator,
    }
}

/// Reads a quoted string starting at the opening `"` at `pos`; advances past
/// the closing quote and returns the duped content. Unclosed → UnclosedQuote.
fn readQuotedString(trimmed: []const u8, pos: *usize, allocator: std.mem.Allocator) ParseError![]const u8 {
    std.debug.assert(trimmed[pos.*] == '"');
    pos.* += 1; // skip opening quote
    const val_start = pos.*;
    while (pos.* < trimmed.len and trimmed[pos.*] != '"') : (pos.* += 1) {}
    if (pos.* >= trimmed.len) return ParseError.UnclosedQuote;
    const val_str = trimmed[val_start..pos.*];
    pos.* += 1; // skip closing quote
    return allocator.dupe(u8, val_str) catch ParseError.OutOfMemory;
}

/// Parses a selector string into a QueryFilter.
/// All strings in the returned QueryFilter are allocated with the provided allocator.
pub fn parse(selector: []const u8, allocator: std.mem.Allocator) ParseError!QueryFilter {
    // Trim leading/trailing whitespace
    const trimmed = std.mem.trim(u8, selector, " \t\r\n");
    if (trimmed.len == 0) return ParseError.EmptySelector;

    var pos: usize = 0;

    // --- Step 1: Parse type selector ---
    // Read until '[' or end-of-string
    const type_start = pos;
    while (pos < trimmed.len and trimmed[pos] != '[') : (pos += 1) {}
    const type_raw = std.mem.trim(u8, trimmed[type_start..pos], " \t\r\n");

    if (type_raw.len == 0) return ParseError.EmptySelector;

    const type_selector: TypeSelector = if (std.mem.eql(u8, type_raw, "*"))
        .wildcard
    else blk: {
        const name = allocator.dupe(u8, type_raw) catch return ParseError.OutOfMemory;
        break :blk .{ .named = name };
    };

    // --- Step 2: Parse attribute conditions ---
    var conditions: std.ArrayList(AttributeCondition) = .empty;
    errdefer {
        // Free any already-allocated condition strings on error
        for (conditions.items) |cond| {
            allocator.free(cond.field);
            switch (cond.value) {
                .string => |s| allocator.free(s),
                .number => {},
            }
        }
        conditions.deinit(allocator);
        // Also free type selector name if allocated
        switch (type_selector) {
            .named => |n| allocator.free(n),
            .wildcard => {},
        }
    }

    while (pos < trimmed.len) {
        if (trimmed[pos] != '[') return ParseError.UnexpectedCharacter;
        pos += 1; // skip '['

        // 2a. Read field name — alphanumeric and underscore only
        const field_start = pos;
        while (pos < trimmed.len and (std.ascii.isAlphanumeric(trimmed[pos]) or trimmed[pos] == '_')) : (pos += 1) {}

        const field_name = trimmed[field_start..pos];
        if (field_name.len == 0) return ParseError.MissingFieldName;

        if (pos >= trimmed.len) return ParseError.UnclosedBracket;

        // 2b. Read operator
        if (trimmed[pos] == ']') return ParseError.MissingOperator;
        const op = try readOperator(trimmed, &pos);

        if (pos >= trimmed.len) return ParseError.UnclosedBracket;

        // 2c. Read value
        const value: AttributeValue = switch (op) {
            .eq, .neq => blk: {
                // Quoted string value, or unquoted numeric value (count fields).
                if (trimmed[pos] != '"') {
                    const val_start = pos;
                    while (pos < trimmed.len and trimmed[pos] != ']') : (pos += 1) {}
                    const val_raw = std.mem.trim(u8, trimmed[val_start..pos], " \t");
                    if (val_raw.len == 0) return ParseError.MissingValue;
                    const num = std.fmt.parseFloat(f32, val_raw) catch return ParseError.InvalidNumericValue;
                    break :blk .{ .number = num };
                }
                break :blk .{ .string = try readQuotedString(trimmed, &pos, allocator) };
            },
            .gt => blk: {
                // Read unquoted numeric value until ']'
                const val_start = pos;
                while (pos < trimmed.len and trimmed[pos] != ']') : (pos += 1) {}
                const val_raw = std.mem.trim(u8, trimmed[val_start..pos], " \t");
                if (val_raw.len == 0) return ParseError.MissingValue;
                const num = std.fmt.parseFloat(f32, val_raw) catch return ParseError.InvalidNumericValue;
                break :blk .{ .number = num };
            },
            .contains, .prefix, .suffix => blk: {
                // Substring operators accept a quoted string value ONLY (Req 7).
                if (trimmed[pos] != '"') return ParseError.ExpectedQuotedValue;
                break :blk .{ .string = try readQuotedString(trimmed, &pos, allocator) };
            },
        };

        // Allocate field and append condition before checking ']'
        // so errdefer on conditions handles cleanup on failure.
        const field_duped = allocator.dupe(u8, field_name) catch return ParseError.OutOfMemory;
        conditions.append(allocator, .{
            .field = field_duped,
            .op = op,
            .value = value,
        }) catch {
            allocator.free(field_duped);
            switch (value) {
                .string => |s| allocator.free(s),
                .number => {},
            }
            return ParseError.OutOfMemory;
        };

        // 2d. Expect ']'
        if (pos >= trimmed.len) return ParseError.UnclosedBracket;
        if (trimmed[pos] != ']') return ParseError.UnclosedBracket;
        pos += 1; // skip ']'
    }

    return QueryFilter{
        .type_selector = type_selector,
        .conditions = conditions.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
    };
}

// --- Unit Tests ---

const testing = std.testing;

fn freeFilter(f: QueryFilter, allocator: std.mem.Allocator) void {
    switch (f.type_selector) {
        .named => |n| allocator.free(n),
        .wildcard => {},
    }
    for (f.conditions) |cond| {
        allocator.free(cond.field);
        switch (cond.value) {
            .string => |s| allocator.free(s),
            .number => {},
        }
    }
    allocator.free(f.conditions);
}

test "parse: type-only selector 'function'" {
    const f = try parse("function", testing.allocator);
    defer freeFilter(f, testing.allocator);

    try testing.expectEqualStrings("function", f.type_selector.named);
    try testing.expectEqual(@as(usize, 0), f.conditions.len);
}

test "parse: wildcard selector '*'" {
    const f = try parse("*", testing.allocator);
    defer freeFilter(f, testing.allocator);

    try testing.expect(f.type_selector == .wildcard);
    try testing.expectEqual(@as(usize, 0), f.conditions.len);
}

test "parse: type + equality condition" {
    const f = try parse("function[name=\"foo\"]", testing.allocator);
    defer freeFilter(f, testing.allocator);

    try testing.expectEqualStrings("function", f.type_selector.named);
    try testing.expectEqual(@as(usize, 1), f.conditions.len);
    try testing.expectEqualStrings("name", f.conditions[0].field);
    try testing.expectEqual(ComparisonOp.eq, f.conditions[0].op);
    try testing.expectEqualStrings("foo", f.conditions[0].value.string);
}

test "parse: type + negation condition" {
    const f = try parse("function[name!=\"print\"]", testing.allocator);
    defer freeFilter(f, testing.allocator);

    try testing.expectEqualStrings("function", f.type_selector.named);
    try testing.expectEqual(@as(usize, 1), f.conditions.len);
    try testing.expectEqualStrings("name", f.conditions[0].field);
    try testing.expectEqual(ComparisonOp.neq, f.conditions[0].op);
    try testing.expectEqualStrings("print", f.conditions[0].value.string);
}

test "parse: type + greater-than condition" {
    const f = try parse("call[confidence>0.7]", testing.allocator);
    defer freeFilter(f, testing.allocator);

    try testing.expectEqualStrings("call", f.type_selector.named);
    try testing.expectEqual(@as(usize, 1), f.conditions.len);
    try testing.expectEqualStrings("confidence", f.conditions[0].field);
    try testing.expectEqual(ComparisonOp.gt, f.conditions[0].op);
    try testing.expect(f.conditions[0].value.number == 0.7);
}

test "parse: wildcard + condition" {
    const f = try parse("*[confidence>0.9]", testing.allocator);
    defer freeFilter(f, testing.allocator);

    try testing.expect(f.type_selector == .wildcard);
    try testing.expectEqual(@as(usize, 1), f.conditions.len);
    try testing.expectEqualStrings("confidence", f.conditions[0].field);
    try testing.expectEqual(ComparisonOp.gt, f.conditions[0].op);
    try testing.expect(f.conditions[0].value.number == 0.9);
}

test "parse: multiple conditions" {
    const f = try parse("function[name=\"foo\"][confidence>0.8]", testing.allocator);
    defer freeFilter(f, testing.allocator);

    try testing.expectEqualStrings("function", f.type_selector.named);
    try testing.expectEqual(@as(usize, 2), f.conditions.len);

    try testing.expectEqualStrings("name", f.conditions[0].field);
    try testing.expectEqual(ComparisonOp.eq, f.conditions[0].op);
    try testing.expectEqualStrings("foo", f.conditions[0].value.string);

    try testing.expectEqualStrings("confidence", f.conditions[1].field);
    try testing.expectEqual(ComparisonOp.gt, f.conditions[1].op);
    try testing.expect(f.conditions[1].value.number == 0.8);
}

test "parse error: empty string" {
    const result = parse("", testing.allocator);
    try testing.expectError(ParseError.EmptySelector, result);
}

test "parse error: whitespace-only string" {
    const result = parse("   ", testing.allocator);
    try testing.expectError(ParseError.EmptySelector, result);
}

test "parse error: unclosed bracket" {
    const result = parse("function[name=\"foo\"", testing.allocator);
    try testing.expectError(ParseError.UnclosedBracket, result);
}

test "parse error: missing field name" {
    const result = parse("function[=\"foo\"]", testing.allocator);
    try testing.expectError(ParseError.MissingFieldName, result);
}

test "parse error: missing operator (field then close bracket)" {
    const result = parse("function[name]", testing.allocator);
    try testing.expectError(ParseError.MissingOperator, result);
}

test "parse error: unclosed quote" {
    const result = parse("function[name=\"foo]", testing.allocator);
    try testing.expectError(ParseError.UnclosedQuote, result);
}

test "parse error: invalid operator" {
    const result = parse("function[name~\"foo\"]", testing.allocator);
    try testing.expectError(ParseError.InvalidOperator, result);
}

test "parse error: invalid numeric value" {
    const result = parse("call[confidence>abc]", testing.allocator);
    try testing.expectError(ParseError.InvalidNumericValue, result);
}

// Feature: plain-toml-capture-tables, Unit: unquoted numeric values for =/!=
// **Validates: Requirement 8.1**
test "parse: unquoted numeric values for eq/neq" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        const f = try parse("fn[args=2]", alloc);
        try testing.expectEqual(.eq, f.conditions[0].op);
        try testing.expect(f.conditions[0].value == .number);
        try testing.expectApproxEqRel(@as(f32, 2.0), f.conditions[0].value.number, 0.001);
    }
    {
        const f = try parse("fn[args!=0]", alloc);
        try testing.expectEqual(.neq, f.conditions[0].op);
        try testing.expect(f.conditions[0].value == .number);
    }
    {
        const f = try parse("fn[args=\"2\"]", alloc);
        try testing.expect(f.conditions[0].value == .string);
        try testing.expectEqualStrings("2", f.conditions[0].value.string);
    }
    {
        try testing.expectError(ParseError.InvalidNumericValue, parse("fn[args=abc]", alloc));
    }
}

// --- Substring operator parsing (Spec: query-comparison-operators) ---

test "parse: contains/prefix/suffix sigils with quoted values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        const f = try parse("function[name~=\"dead\"]", alloc);
        try testing.expectEqual(ComparisonOp.contains, f.conditions[0].op);
        try testing.expect(f.conditions[0].value == .string);
        try testing.expectEqualStrings("dead", f.conditions[0].value.string);
    }
    {
        const f = try parse("function[name^=\"test_\"]", alloc);
        try testing.expectEqual(ComparisonOp.prefix, f.conditions[0].op);
        try testing.expectEqualStrings("test_", f.conditions[0].value.string);
    }
    {
        const f = try parse("call[callee$=\"export_quotes\"]", alloc);
        try testing.expectEqual(ComparisonOp.suffix, f.conditions[0].op);
        try testing.expectEqualStrings("export_quotes", f.conditions[0].value.string);
    }
}

test "parse error: lone ~/^/$ sigil is InvalidOperator" {
    try testing.expectError(ParseError.InvalidOperator, parse("function[name~\"x\"]", testing.allocator));
    try testing.expectError(ParseError.InvalidOperator, parse("function[name^\"x\"]", testing.allocator));
    try testing.expectError(ParseError.InvalidOperator, parse("function[name$\"x\"]", testing.allocator));
    try testing.expectError(ParseError.InvalidOperator, parse("function[name!\"x\"]", testing.allocator));
}

test "parse error: substring operator with unquoted value is ExpectedQuotedValue" {
    try testing.expectError(ParseError.ExpectedQuotedValue, parse("function[name~=dead]", testing.allocator));
    try testing.expectError(ParseError.ExpectedQuotedValue, parse("function[name^=test_]", testing.allocator));
    try testing.expectError(ParseError.ExpectedQuotedValue, parse("call[callee$=export_quotes]", testing.allocator));
}

test "parse: substring ops inherit unclosed-quote handling" {
    try testing.expectError(ParseError.UnclosedQuote, parse("function[name~=\"dead]", testing.allocator));
}

// --- Spec: query-comparison-operators property tests ---

const minish = @import("minish");
const gen = minish.gen;

// Feature: query-comparison-operators, Property 4: Substring operators parse
// only quoted values
test "property: substring operators parse only quoted values (P4)" {
    const tuple_gen = comptime gen.tuple3(
        u8,
        []const u8,
        []const u8,
        gen.intRange(u8, 0, 2),
        gen.string(.{ .min_len = 0, .max_len = 10, .charset = .alphanumeric }),
        gen.string(.{ .min_len = 1, .max_len = 6, .charset = .alpha }),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { u8, []const u8, []const u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const sigil = switch (vals[0]) {
                0 => "~=",
                1 => "^=",
                else => "$=",
            };
            const quoted = try std.fmt.allocPrint(alloc, "function[name{s}\"{s}\"]", .{ sigil, vals[1] });
            const f = try parse(quoted, alloc);
            const op: ComparisonOp = switch (vals[0]) {
                0 => .contains,
                1 => .prefix,
                else => .suffix,
            };
            try testing.expectEqual(op, f.conditions[0].op);
            try testing.expect(f.conditions[0].value == .string);
            try testing.expectEqualStrings(vals[1], f.conditions[0].value.string);

            const unquoted = try std.fmt.allocPrint(alloc, "function[name{s}{s}]", .{ sigil, vals[2] });
            try testing.expectError(ParseError.ExpectedQuotedValue, parse(unquoted, alloc));
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: query-comparison-operators, Property 6: Invalid operator sigils are
// rejected without crashing
test "property: invalid operator sigils are rejected without crashing (P6)" {
    const tuple_gen = comptime gen.tuple2(
        []const u8,
        []const u8,
        gen.string(.{ .min_len = 1, .max_len = 2, .charset = .alpha }),
        gen.string(.{ .min_len = 1, .max_len = 6, .charset = .alphanumeric }),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { []const u8, []const u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const s = try std.fmt.allocPrint(alloc, "function[name{s}\"{s}\"]", .{ vals[0], vals[1] });
            // Any sigil that is not exactly one of the six valid forms is a
            // parse error; never a crash.
            // Quoted-value-valid sigils: = != ~= ^= $= (gt takes an unquoted
            // number, so with a quoted value it must error — never crash).
            const valid = std.mem.eql(u8, vals[0], "=") or
                std.mem.eql(u8, vals[0], "!=") or
                std.mem.eql(u8, vals[0], "~=") or
                std.mem.eql(u8, vals[0], "^=") or
                std.mem.eql(u8, vals[0], "$=");
            const result = parse(s, alloc);
            if (valid) {
                _ = try result;
            } else {
                const r = result catch return; // parse error → property holds
                _ = r;
                return error.ShouldHaveFailed;
            }
        }
    }.prop, .{ .num_runs = 100 });
}
