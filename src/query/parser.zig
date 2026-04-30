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
    OutOfMemory,
};

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
        if (trimmed[pos] != '=' and trimmed[pos] != '!' and trimmed[pos] != '>') return ParseError.InvalidOperator;

        const op: ComparisonOp = if (trimmed[pos] == '=')
            .eq
        else if (trimmed[pos] == '!' and pos + 1 < trimmed.len and trimmed[pos + 1] == '=') blk: {
            pos += 1; // skip the extra '=' of '!='
            break :blk .neq;
        } else if (trimmed[pos] == '>')
            .gt
        else
            return ParseError.InvalidOperator;

        pos += 1; // skip the operator char ('=' or '>')

        if (pos >= trimmed.len) return ParseError.UnclosedBracket;

        // 2c. Read value
        const value: AttributeValue = switch (op) {
            .eq, .neq => blk: {
                // Expect quoted string value
                if (trimmed[pos] != '"') return ParseError.MissingValue;
                pos += 1; // skip opening quote
                const val_start = pos;
                while (pos < trimmed.len and trimmed[pos] != '"') : (pos += 1) {}
                if (pos >= trimmed.len) return ParseError.UnclosedQuote;
                const val_str = trimmed[val_start..pos];
                pos += 1; // skip closing quote
                const duped = allocator.dupe(u8, val_str) catch return ParseError.OutOfMemory;
                break :blk .{ .string = duped };
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
