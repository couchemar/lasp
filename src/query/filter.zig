const std = @import("std");

// --- Data Types ---

pub const ComparisonOp = enum {
    eq, // =
    neq, // !=
    gt, // >
};

pub const AttributeValue = union(enum) {
    string: []const u8, // for eq/neq comparisons
    number: f32, // for gt comparisons
};

pub const AttributeCondition = struct {
    field: []const u8,
    op: ComparisonOp,
    value: AttributeValue,
};

pub const TypeSelector = union(enum) {
    wildcard: void, // *
    named: []const u8, // e.g., "function"
};

pub const QueryFilter = struct {
    type_selector: TypeSelector,
    conditions: []const AttributeCondition,
};

// --- Format Function ---

/// Formats a QueryFilter back into a valid selector string.
/// Allocates the result string using the provided allocator.
pub fn format(filter: QueryFilter, allocator: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Write type selector
    switch (filter.type_selector) {
        .wildcard => try buf.appendSlice(allocator, "*"),
        .named => |name| try buf.appendSlice(allocator, name),
    }

    // Write attribute conditions
    for (filter.conditions) |cond| {
        try buf.append(allocator, '[');
        try buf.appendSlice(allocator, cond.field);

        // Write operator
        switch (cond.op) {
            .eq => try buf.append(allocator, '='),
            .neq => try buf.appendSlice(allocator, "!="),
            .gt => try buf.append(allocator, '>'),
        }

        // Write value
        switch (cond.value) {
            .string => |s| {
                try buf.append(allocator, '"');
                try buf.appendSlice(allocator, s);
                try buf.append(allocator, '"');
            },
            .number => |n| {
                var num_buf: [32]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d:.2}", .{n}) catch unreachable;
                try buf.appendSlice(allocator, num_str);
            },
        }

        try buf.append(allocator, ']');
    }

    return buf.toOwnedSlice(allocator);
}

// --- Unit Tests ---

const testing = std.testing;

test "format: wildcard type selector, no conditions" {
    const filter = QueryFilter{
        .type_selector = .wildcard,
        .conditions = &.{},
    };
    const result = try format(filter, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("*", result);
}

test "format: named type selector, no conditions" {
    const filter = QueryFilter{
        .type_selector = .{ .named = "function" },
        .conditions = &.{},
    };
    const result = try format(filter, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("function", result);
}

test "format: empty conditions list" {
    const filter = QueryFilter{
        .type_selector = .{ .named = "call" },
        .conditions = &.{},
    };
    const result = try format(filter, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("call", result);
}

test "format: equality operator with string value" {
    const conditions = [_]AttributeCondition{
        .{ .field = "name", .op = .eq, .value = .{ .string = "foo" } },
    };
    const filter = QueryFilter{
        .type_selector = .{ .named = "function" },
        .conditions = &conditions,
    };
    const result = try format(filter, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("function[name=\"foo\"]", result);
}

test "format: negation operator with string value" {
    const conditions = [_]AttributeCondition{
        .{ .field = "name", .op = .neq, .value = .{ .string = "print" } },
    };
    const filter = QueryFilter{
        .type_selector = .{ .named = "function" },
        .conditions = &conditions,
    };
    const result = try format(filter, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("function[name!=\"print\"]", result);
}

test "format: greater-than operator with numeric value" {
    const conditions = [_]AttributeCondition{
        .{ .field = "confidence", .op = .gt, .value = .{ .number = 0.7 } },
    };
    const filter = QueryFilter{
        .type_selector = .{ .named = "call" },
        .conditions = &conditions,
    };
    const result = try format(filter, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("call[confidence>0.70]", result);
}

test "format: wildcard with condition" {
    const conditions = [_]AttributeCondition{
        .{ .field = "confidence", .op = .gt, .value = .{ .number = 0.9 } },
    };
    const filter = QueryFilter{
        .type_selector = .wildcard,
        .conditions = &conditions,
    };
    const result = try format(filter, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("*[confidence>0.90]", result);
}

test "format: multiple conditions" {
    const conditions = [_]AttributeCondition{
        .{ .field = "name", .op = .eq, .value = .{ .string = "foo" } },
        .{ .field = "confidence", .op = .gt, .value = .{ .number = 0.8 } },
    };
    const filter = QueryFilter{
        .type_selector = .{ .named = "function" },
        .conditions = &conditions,
    };
    const result = try format(filter, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("function[name=\"foo\"][confidence>0.80]", result);
}

// --- Property Tests ---

const minish = @import("minish");
const gen = minish.gen;
const query_parser = @import("parser.zig");

// Feature: structural-query, Property 1: QueryFilter round-trip
// **Validates: Requirements 2.1, 2.2, 2.4, 2.5, 2.6, 2.9, 2.10**
test "property: QueryFilter round-trip (parse -> format -> parse)" {
    // Generate: (is_wildcard, num_conditions 0-3, seed for ops/values)
    const tuple_gen = comptime gen.tuple3(
        bool,
        u8,
        u8,
        gen.boolean(),
        gen.intRange(u8, 0, 3),
        gen.intRange(u8, 0, 255),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { bool, u8, u8 }) !void {
            const is_wildcard = vals[0];
            const num_conditions = vals[1];
            const seed = vals[2];

            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // Fixed pools for deterministic selection
            const type_names = [_][]const u8{ "function", "call", "import", "struct", "method" };
            const field_names = [_][]const u8{ "name", "kind", "level" };
            const string_values = [_][]const u8{ "foo", "bar", "baz" };

            // Build type selector
            const type_selector: TypeSelector = if (is_wildcard)
                .wildcard
            else
                .{ .named = type_names[seed % type_names.len] };

            // Build conditions
            var cond_buf: [3]AttributeCondition = undefined;
            for (0..num_conditions) |i| {
                // Derive op from seed bits: each condition uses 2 bits
                const op_bits: u2 = @truncate(seed >> @intCast(i * 2));
                const op: ComparisonOp = switch (op_bits % 3) {
                    0 => .eq,
                    1 => .neq,
                    2 => .gt,
                    else => unreachable,
                };

                const field = field_names[i];
                const value: AttributeValue = switch (op) {
                    .eq, .neq => .{ .string = string_values[i] },
                    .gt => blk: {
                        // Use seed to pick a percentage (0-99) for a clean 2-decimal float
                        const pct: u8 = @intCast((@as(u16, seed) * @as(u16, @intCast(i + 1))) % 100);
                        break :blk .{ .number = @as(f32, @floatFromInt(pct)) / 100.0 };
                    },
                };

                cond_buf[i] = .{
                    .field = field,
                    .op = op,
                    .value = value,
                };
            }

            const original = QueryFilter{
                .type_selector = type_selector,
                .conditions = cond_buf[0..num_conditions],
            };

            // Step 1: Format the QueryFilter to a selector string
            const formatted = try format(original, alloc);

            // Step 2: Parse the formatted string back
            const parsed = query_parser.parse(formatted, alloc) catch |err| {
                std.debug.print("Parse failed on formatted string: \"{s}\", error: {}\n", .{ formatted, err });
                return err;
            };

            // Step 3: Verify structural equivalence

            // Type selector equivalence
            switch (original.type_selector) {
                .wildcard => try testing.expect(parsed.type_selector == .wildcard),
                .named => |name| {
                    try testing.expect(parsed.type_selector == .named);
                    try testing.expectEqualStrings(name, parsed.type_selector.named);
                },
            }

            // Conditions count
            try testing.expectEqual(original.conditions.len, parsed.conditions.len);

            // Each condition
            for (original.conditions, parsed.conditions) |orig_cond, parsed_cond| {
                try testing.expectEqualStrings(orig_cond.field, parsed_cond.field);
                try testing.expectEqual(orig_cond.op, parsed_cond.op);

                switch (orig_cond.value) {
                    .string => |s| {
                        try testing.expect(parsed_cond.value == .string);
                        try testing.expectEqualStrings(s, parsed_cond.value.string);
                    },
                    .number => |n| {
                        try testing.expect(parsed_cond.value == .number);
                        // Compare with tolerance for float formatting round-trip
                        const diff = @abs(n - parsed_cond.value.number);
                        try testing.expect(diff < 0.01);
                    },
                }
            }
        }
    }.prop, .{ .num_runs = 100 });
}
