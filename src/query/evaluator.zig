const std = @import("std");
const events_mod = @import("../parser/events.zig");
const StructuralEvent = events_mod.StructuralEvent;
const CaptureEntry = events_mod.CaptureEntry;
const IntegerField = events_mod.IntegerField;
const filter_mod = @import("filter.zig");
const QueryFilter = filter_mod.QueryFilter;
const TypeSelector = filter_mod.TypeSelector;
const AttributeCondition = filter_mod.AttributeCondition;
const ComparisonOp = filter_mod.ComparisonOp;
const AttributeValue = filter_mod.AttributeValue;

/// Filters events against a query filter.
/// Returns a new slice containing only matching events.
/// The returned slice is allocated with the provided allocator.
/// Input events are not modified. Output preserves input order.
pub fn evaluate(
    events_list: []const StructuralEvent,
    query_filter: QueryFilter,
    allocator: std.mem.Allocator,
) ![]const StructuralEvent {
    var result: std.ArrayList(StructuralEvent) = .empty;
    errdefer result.deinit(allocator);

    for (events_list) |event| {
        if (matchesFilter(event, query_filter)) {
            try result.append(allocator, event);
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Tests whether a single event matches the query filter.
fn matchesFilter(event: StructuralEvent, query_filter: QueryFilter) bool {
    // 1. Type match
    switch (query_filter.type_selector) {
        .wildcard => {}, // passes all
        .named => |name| {
            if (!std.ascii.eqlIgnoreCase(event.type_name, name)) {
                return false;
            }
        },
    }

    // 2. Attribute conditions (AND semantics — all must pass)
    for (query_filter.conditions) |cond| {
        if (!matchesCondition(event, cond)) {
            return false;
        }
    }

    return true;
}

/// Tests whether a single event matches a single attribute condition.
/// Resolved_Value: what Field_Resolution yields for a field on an event — a
/// string (capture), an integer (count/extent field), a float (the `confidence`
/// built-in), or absent.
const ResolvedValue = union(enum) {
    string: []const u8,
    integer: u32,
    floating: f32,
    absent,
};

/// The single place that maps a condition field name to its value on an event.
/// Resolution order preserves today's precedence: integer fields, the
/// `confidence` built-in, then string captures (a name present nowhere is
/// absent). No per-language or grammar-specific branching (Req 1).
fn resolveField(event: StructuralEvent, name: []const u8) ResolvedValue {
    if (lookupInt(event.int_fields, name)) |v| return .{ .integer = v };
    if (std.mem.eql(u8, name, "confidence")) return .{ .floating = event.confidence };
    if (lookupCapture(event.captures, name)) |s| return .{ .string = s };
    return .absent;
}

/// Tests whether a single event matches a single attribute condition.
/// Dispatch is by operator family over the resolved value: string operators
/// (eq/neq/contains/prefix/suffix) apply a text predicate; numeric operators
/// (gt, plus numeric eq/neq) apply a numeric predicate.
fn matchesCondition(event: StructuralEvent, cond: AttributeCondition) bool {
    const resolved = resolveField(event, cond.field);
    return switch (cond.op) {
        // String operators: compare the resolved STRING value.
        .eq, .neq, .contains, .prefix, .suffix => blk: {
            // Numeric eq/neq against an unquoted number keep the integer path
            // (Req 3.3).
            if ((cond.op == .eq or cond.op == .neq) and cond.value == .number) {
                break :blk matchNumericEq(resolved, cond.op, cond.value.number);
            }
            const needle = cond.value.string; // substring ops are always .string (parser-enforced)
            break :blk switch (resolved) {
                .string => |s| stringPredicate(cond.op, s, needle),
                // absent / non-string: eq→false, neq→true, substring ops→false
                else => cond.op == .neq,
            };
        },
        // Numeric operators: compare the resolved NUMERIC value.
        .gt => numericGt(resolved, cond.value.number),
    };
}

fn stringPredicate(op: ComparisonOp, haystack: []const u8, needle: []const u8) bool {
    return switch (op) {
        .eq => std.mem.eql(u8, haystack, needle),
        .neq => !std.mem.eql(u8, haystack, needle),
        .contains => std.mem.indexOf(u8, haystack, needle) != null,
        .prefix => std.mem.startsWith(u8, haystack, needle),
        .suffix => std.mem.endsWith(u8, haystack, needle),
        else => unreachable,
    };
}

/// gt preserves today's resolution: integer field, then confidence, then a
/// capture parsed as float. resolveField already encodes int→confidence→string.
fn numericGt(resolved: ResolvedValue, threshold: f32) bool {
    return switch (resolved) {
        .integer => |v| @as(f32, @floatFromInt(v)) > threshold,
        .floating => |f| f > threshold,
        .string => |s| (std.fmt.parseFloat(f32, s) catch return false) > threshold,
        .absent => false,
    };
}

/// Numeric eq/neq against an unquoted number: compare the integer field;
/// absent → eq false / neq true (Req 3.3, unchanged).
fn matchNumericEq(resolved: ResolvedValue, op: ComparisonOp, n: f32) bool {
    const v: ?f32 = switch (resolved) {
        .integer => |i| @as(f32, @floatFromInt(i)),
        .floating => |f| f,
        else => null,
    };
    if (v) |fv| return if (op == .eq) fv == n else fv != n;
    return op == .neq; // absent: eq excludes, neq includes
}

/// Looks up a field name in the integer-field slice.
fn lookupInt(int_fields: []const IntegerField, field: []const u8) ?u32 {
    for (int_fields) |f| {
        if (std.mem.eql(u8, f.field_name, field)) {
            return f.value;
        }
    }
    return null;
}

/// Looks up a field name in the captures slice.
fn lookupCapture(captures: []const CaptureEntry, field: []const u8) ?[]const u8 {
    for (captures) |cap| {
        if (std.mem.eql(u8, cap.field_name, field)) {
            return cap.value;
        }
    }
    return null;
}

// --- Unit Tests ---

const testing = std.testing;

fn makeEvent(type_name: []const u8, captures: []const CaptureEntry, confidence: f32) StructuralEvent {
    return .{
        .type_name = type_name,
        .captures = captures,
        .start = 0,
        .end = 10,
        .line = 1,
        .col = 0,
        .confidence = confidence,
    };
}

test "type filter includes matching events" {
    const ev = [_]StructuralEvent{
        makeEvent("function", &.{}, 1.0),
        makeEvent("call", &.{}, 1.0),
        makeEvent("function", &.{}, 0.8),
    };
    const f = QueryFilter{
        .type_selector = .{ .named = "function" },
        .conditions = &.{},
    };
    const result = try evaluate(&ev, f, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("function", result[0].type_name);
    try testing.expectEqualStrings("function", result[1].type_name);
}

test "type filter excludes non-matching events" {
    const ev = [_]StructuralEvent{
        makeEvent("call", &.{}, 1.0),
        makeEvent("import", &.{}, 1.0),
    };
    const f = QueryFilter{
        .type_selector = .{ .named = "function" },
        .conditions = &.{},
    };
    const result = try evaluate(&ev, f, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "type filter is case-insensitive" {
    const ev = [_]StructuralEvent{
        makeEvent("Function", &.{}, 1.0),
        makeEvent("FUNCTION", &.{}, 1.0),
        makeEvent("function", &.{}, 1.0),
    };
    const f = QueryFilter{
        .type_selector = .{ .named = "function" },
        .conditions = &.{},
    };
    const result = try evaluate(&ev, f, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 3), result.len);
}

test "wildcard includes all events" {
    const ev = [_]StructuralEvent{
        makeEvent("function", &.{}, 1.0),
        makeEvent("call", &.{}, 0.5),
        makeEvent("import", &.{}, 0.9),
    };
    const f = QueryFilter{
        .type_selector = .wildcard,
        .conditions = &.{},
    };
    const result = try evaluate(&ev, f, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 3), result.len);
}

test "equality condition includes matching captures" {
    const caps = [_]CaptureEntry{.{ .field_name = "name", .value = "foo" }};
    const ev = [_]StructuralEvent{
        makeEvent("function", &caps, 1.0),
    };
    const conds = [_]AttributeCondition{
        .{ .field = "name", .op = .eq, .value = .{ .string = "foo" } },
    };
    const f = QueryFilter{
        .type_selector = .wildcard,
        .conditions = &conds,
    };
    const result = try evaluate(&ev, f, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 1), result.len);
}

test "equality condition excludes missing captures" {
    const ev = [_]StructuralEvent{
        makeEvent("function", &.{}, 1.0),
    };
    const conds = [_]AttributeCondition{
        .{ .field = "name", .op = .eq, .value = .{ .string = "foo" } },
    };
    const f = QueryFilter{
        .type_selector = .wildcard,
        .conditions = &conds,
    };
    const result = try evaluate(&ev, f, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "negation condition includes events without field" {
    const ev = [_]StructuralEvent{
        makeEvent("function", &.{}, 1.0),
    };
    const conds = [_]AttributeCondition{
        .{ .field = "name", .op = .neq, .value = .{ .string = "print" } },
    };
    const f = QueryFilter{
        .type_selector = .wildcard,
        .conditions = &conds,
    };
    const result = try evaluate(&ev, f, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 1), result.len);
}

test "negation condition includes events with different value" {
    const caps = [_]CaptureEntry{.{ .field_name = "name", .value = "foo" }};
    const ev = [_]StructuralEvent{
        makeEvent("function", &caps, 1.0),
    };
    const conds = [_]AttributeCondition{
        .{ .field = "name", .op = .neq, .value = .{ .string = "print" } },
    };
    const f = QueryFilter{
        .type_selector = .wildcard,
        .conditions = &conds,
    };
    const result = try evaluate(&ev, f, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 1), result.len);
}

test "negation condition excludes events with matching value" {
    const caps = [_]CaptureEntry{.{ .field_name = "name", .value = "print" }};
    const ev = [_]StructuralEvent{
        makeEvent("function", &caps, 1.0),
    };
    const conds = [_]AttributeCondition{
        .{ .field = "name", .op = .neq, .value = .{ .string = "print" } },
    };
    const f = QueryFilter{
        .type_selector = .wildcard,
        .conditions = &conds,
    };
    const result = try evaluate(&ev, f, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "confidence gt condition includes events above threshold" {
    const ev = [_]StructuralEvent{
        makeEvent("function", &.{}, 0.9),
        makeEvent("function", &.{}, 0.5),
    };
    const conds = [_]AttributeCondition{
        .{ .field = "confidence", .op = .gt, .value = .{ .number = 0.7 } },
    };
    const f = QueryFilter{
        .type_selector = .wildcard,
        .conditions = &conds,
    };
    const result = try evaluate(&ev, f, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expect(result[0].confidence == 0.9);
}

test "confidence gt condition excludes events at or below threshold" {
    const ev = [_]StructuralEvent{
        makeEvent("function", &.{}, 0.7),
        makeEvent("function", &.{}, 0.3),
    };
    const conds = [_]AttributeCondition{
        .{ .field = "confidence", .op = .gt, .value = .{ .number = 0.7 } },
    };
    const f = QueryFilter{
        .type_selector = .wildcard,
        .conditions = &conds,
    };
    const result = try evaluate(&ev, f, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "multiple conditions use AND semantics" {
    const caps_match = [_]CaptureEntry{.{ .field_name = "name", .value = "foo" }};
    const caps_no_match = [_]CaptureEntry{.{ .field_name = "name", .value = "bar" }};
    const ev = [_]StructuralEvent{
        makeEvent("function", &caps_match, 0.9), // matches both
        makeEvent("function", &caps_match, 0.5), // fails confidence
        makeEvent("function", &caps_no_match, 0.9), // fails name
    };
    const conds = [_]AttributeCondition{
        .{ .field = "name", .op = .eq, .value = .{ .string = "foo" } },
        .{ .field = "confidence", .op = .gt, .value = .{ .number = 0.7 } },
    };
    const f = QueryFilter{
        .type_selector = .{ .named = "function" },
        .conditions = &conds,
    };
    const result = try evaluate(&ev, f, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expect(result[0].confidence == 0.9);
}

test "empty events input returns empty output" {
    const f = QueryFilter{
        .type_selector = .wildcard,
        .conditions = &.{},
    };
    const result = try evaluate(&.{}, f, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "evaluator preserves event order" {
    const ev = [_]StructuralEvent{
        makeEvent("function", &.{}, 1.0),
        makeEvent("call", &.{}, 1.0),
        makeEvent("function", &.{}, 0.8),
        makeEvent("import", &.{}, 1.0),
        makeEvent("function", &.{}, 0.6),
    };
    const f = QueryFilter{
        .type_selector = .{ .named = "function" },
        .conditions = &.{},
    };
    const result = try evaluate(&ev, f, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 3), result.len);
    // Verify order matches input order
    try testing.expect(result[0].confidence == 1.0);
    try testing.expect(result[1].confidence == 0.8);
    try testing.expect(result[2].confidence == 0.6);
}

// --- Property Tests ---

const minish = @import("minish");
const gen = minish.gen;

// Feature: structural-query, Property 2: Type filter correctness (case-insensitive)
// **Validates: Requirements 2.7, 3.1, 3.3**
test "property: type filter correctness (case-insensitive)" {
    // Generate a random type name and a seed to build events with mixed types
    const tuple_gen = comptime gen.tuple2(
        []const u8,
        u8,
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        gen.intRange(u8, 0, 255),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { []const u8, u8 }) !void {
            const type_name = vals[0];
            const seed = vals[1];

            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const other_types = [_][]const u8{ "call", "import", "struct", "method", "class" };

            // Build a list of events: some matching, some not
            var event_list: std.ArrayList(StructuralEvent) = .empty;
            const num_events: usize = 6;
            var expected_count: usize = 0;

            for (0..num_events) |i| {
                // Use seed bits to decide if this event matches
                const matches = ((seed >> @intCast(i % 8)) & 1) == 1;
                const tn = if (matches) type_name else other_types[i % other_types.len];
                // Skip if the "other" type happens to match case-insensitively
                if (!matches and std.ascii.eqlIgnoreCase(tn, type_name)) continue;
                try event_list.append(alloc, makeEvent(tn, &.{}, 1.0));
                if (matches) expected_count += 1;
            }

            const f = QueryFilter{
                .type_selector = .{ .named = type_name },
                .conditions = &.{},
            };

            const result = try evaluate(event_list.items, f, alloc);

            // Verify count
            try testing.expectEqual(expected_count, result.len);

            // Verify all results match case-insensitively
            for (result) |ev| {
                try testing.expect(std.ascii.eqlIgnoreCase(ev.type_name, type_name));
            }

            // Verify no matching events were missed
            for (event_list.items) |ev| {
                if (std.ascii.eqlIgnoreCase(ev.type_name, type_name)) {
                    // Should be in result
                    var found = false;
                    for (result) |r| {
                        if (r.start == ev.start and r.confidence == ev.confidence and
                            std.mem.eql(u8, r.type_name, ev.type_name))
                        {
                            found = true;
                            break;
                        }
                    }
                    try testing.expect(found);
                }
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: structural-query, Property 3: Wildcard passes all
// **Validates: Requirements 3.2**
test "property: wildcard selector passes all events" {
    const len_gen = gen.intRange(u8, 0, 10);

    try minish.check(testing.allocator, len_gen, struct {
        fn prop(num_events: u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const type_names = [_][]const u8{ "function", "call", "import", "struct", "method" };

            var event_list: std.ArrayList(StructuralEvent) = .empty;
            for (0..num_events) |i| {
                try event_list.append(alloc, makeEvent(
                    type_names[i % type_names.len],
                    &.{},
                    @as(f32, @floatFromInt(i % 10)) / 10.0,
                ));
            }

            const f = QueryFilter{
                .type_selector = .wildcard,
                .conditions = &.{},
            };

            const result = try evaluate(event_list.items, f, alloc);

            try testing.expectEqual(@as(usize, num_events), result.len);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: structural-query, Property 4: Equality condition correctness
// **Validates: Requirements 4.1, 4.5**
test "property: equality condition correctness" {
    // Generate a field value and a seed for building events
    const tuple_gen = comptime gen.tuple2(
        []const u8,
        u8,
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        gen.intRange(u8, 0, 255),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { []const u8, u8 }) !void {
            const target_value = vals[0];
            const seed = vals[1];

            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const other_values = [_][]const u8{ "bar", "baz", "qux", "quux" };

            var event_list: std.ArrayList(StructuralEvent) = .empty;
            var expected_count: usize = 0;

            for (0..6) |i| {
                const bit = ((seed >> @intCast(i % 8)) & 1);
                const scenario = (bit + @as(u8, @intCast(i))) % 3;

                switch (scenario) {
                    0 => {
                        // Event with matching capture
                        const caps = try alloc.alloc(CaptureEntry, 1);
                        caps[0] = .{ .field_name = "name", .value = target_value };
                        try event_list.append(alloc, makeEvent("function", caps, 1.0));
                        expected_count += 1;
                    },
                    1 => {
                        // Event with non-matching capture
                        const other = other_values[i % other_values.len];
                        // Skip if other happens to equal target
                        if (std.mem.eql(u8, other, target_value)) {
                            const caps = try alloc.alloc(CaptureEntry, 1);
                            caps[0] = .{ .field_name = "name", .value = "zzz_nomatch" };
                            try event_list.append(alloc, makeEvent("function", caps, 1.0));
                        } else {
                            const caps = try alloc.alloc(CaptureEntry, 1);
                            caps[0] = .{ .field_name = "name", .value = other };
                            try event_list.append(alloc, makeEvent("function", caps, 1.0));
                        }
                    },
                    2 => {
                        // Event with no captures (missing field)
                        try event_list.append(alloc, makeEvent("function", &.{}, 1.0));
                    },
                    else => unreachable,
                }
            }

            const conds = try alloc.alloc(AttributeCondition, 1);
            conds[0] = .{ .field = "name", .op = .eq, .value = .{ .string = target_value } };

            const f = QueryFilter{
                .type_selector = .wildcard,
                .conditions = conds,
            };

            const result = try evaluate(event_list.items, f, alloc);

            // Verify count
            try testing.expectEqual(expected_count, result.len);

            // Verify all results have the matching capture
            for (result) |ev| {
                const val = lookupCapture(ev.captures, "name");
                try testing.expect(val != null);
                try testing.expectEqualStrings(target_value, val.?);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: structural-query, Property 5: Negation condition correctness
// **Validates: Requirements 4.2**
test "property: negation condition correctness" {
    const tuple_gen = comptime gen.tuple2(
        []const u8,
        u8,
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        gen.intRange(u8, 0, 255),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { []const u8, u8 }) !void {
            const target_value = vals[0];
            const seed = vals[1];

            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            var event_list: std.ArrayList(StructuralEvent) = .empty;
            var expected_count: usize = 0;

            for (0..6) |i| {
                const bit = ((seed >> @intCast(i % 8)) & 1);
                const scenario = (bit + @as(u8, @intCast(i))) % 3;

                switch (scenario) {
                    0 => {
                        // Event with matching capture → should be EXCLUDED
                        const caps = try alloc.alloc(CaptureEntry, 1);
                        caps[0] = .{ .field_name = "name", .value = target_value };
                        try event_list.append(alloc, makeEvent("function", caps, 1.0));
                        // NOT counted
                    },
                    1 => {
                        // Event with different capture → should be INCLUDED
                        const caps = try alloc.alloc(CaptureEntry, 1);
                        caps[0] = .{ .field_name = "name", .value = "zzz_different" };
                        try event_list.append(alloc, makeEvent("function", caps, 1.0));
                        expected_count += 1;
                    },
                    2 => {
                        // Event with no captures (missing field) → should be INCLUDED
                        try event_list.append(alloc, makeEvent("function", &.{}, 1.0));
                        expected_count += 1;
                    },
                    else => unreachable,
                }
            }

            const conds = try alloc.alloc(AttributeCondition, 1);
            conds[0] = .{ .field = "name", .op = .neq, .value = .{ .string = target_value } };

            const f = QueryFilter{
                .type_selector = .wildcard,
                .conditions = conds,
            };

            const result = try evaluate(event_list.items, f, alloc);

            // Verify count
            try testing.expectEqual(expected_count, result.len);

            // Verify no result has the excluded value
            for (result) |ev| {
                const val = lookupCapture(ev.captures, "name");
                if (val) |v| {
                    // If field exists, value must differ
                    try testing.expect(!std.mem.eql(u8, v, target_value));
                }
                // If field doesn't exist, that's fine (included)
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: structural-query, Property 6: Confidence threshold correctness
// **Validates: Requirements 4.3, 4.6**
test "property: confidence threshold correctness" {
    // Generate a threshold percentage (0-99) to create a clean float
    const pct_gen = gen.intRange(u8, 0, 99);

    try minish.check(testing.allocator, pct_gen, struct {
        fn prop(pct: u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const threshold: f32 = @as(f32, @floatFromInt(pct)) / 100.0;

            // Build events with confidence values from 0.0 to 1.0 in steps of 0.1
            var event_list: std.ArrayList(StructuralEvent) = .empty;
            var expected_count: usize = 0;

            for (0..11) |i| {
                const conf: f32 = @as(f32, @floatFromInt(i)) / 10.0;
                try event_list.append(alloc, makeEvent("function", &.{}, conf));
                if (conf > threshold) expected_count += 1;
            }

            const conds = try alloc.alloc(AttributeCondition, 1);
            conds[0] = .{ .field = "confidence", .op = .gt, .value = .{ .number = threshold } };

            const f = QueryFilter{
                .type_selector = .wildcard,
                .conditions = conds,
            };

            const result = try evaluate(event_list.items, f, alloc);

            // Verify count
            try testing.expectEqual(expected_count, result.len);

            // Verify all results have confidence > threshold
            for (result) |ev| {
                try testing.expect(ev.confidence > threshold);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: structural-query, Property 7: AND semantics
// **Validates: Requirements 4.4**
test "property: AND semantics — adding conditions never increases results" {
    // Generate a seed to build events and conditions
    const tuple_gen = comptime gen.tuple2(
        u8,
        u8,
        gen.intRange(u8, 0, 255),
        gen.intRange(u8, 0, 99),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { u8, u8 }) !void {
            const seed = vals[0];
            const conf_pct = vals[1];

            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const threshold: f32 = @as(f32, @floatFromInt(conf_pct)) / 100.0;
            const names = [_][]const u8{ "foo", "bar", "baz", "qux" };

            // Build events with varying captures and confidence
            var event_list: std.ArrayList(StructuralEvent) = .empty;
            for (0..8) |i| {
                const name_idx = (seed +% @as(u8, @intCast(i))) % 4;
                const caps = try alloc.alloc(CaptureEntry, 1);
                caps[0] = .{ .field_name = "name", .value = names[name_idx] };
                const conf: f32 = @as(f32, @floatFromInt((seed +% @as(u8, @intCast(i * 13))) % 100)) / 100.0;
                try event_list.append(alloc, makeEvent("function", caps, conf));
            }

            // Filter with N conditions (just type filter)
            const conds_n = try alloc.alloc(AttributeCondition, 1);
            conds_n[0] = .{ .field = "name", .op = .eq, .value = .{ .string = "foo" } };

            const filter_n = QueryFilter{
                .type_selector = .wildcard,
                .conditions = conds_n,
            };

            const result_n = try evaluate(event_list.items, filter_n, alloc);

            // Filter with N+1 conditions (add confidence threshold)
            const conds_n1 = try alloc.alloc(AttributeCondition, 2);
            conds_n1[0] = .{ .field = "name", .op = .eq, .value = .{ .string = "foo" } };
            conds_n1[1] = .{ .field = "confidence", .op = .gt, .value = .{ .number = threshold } };

            const filter_n1 = QueryFilter{
                .type_selector = .wildcard,
                .conditions = conds_n1,
            };

            const result_n1 = try evaluate(event_list.items, filter_n1, alloc);

            // Adding a condition should never increase results
            try testing.expect(result_n1.len <= result_n.len);

            // Every event in result_n1 should also be in result_n
            for (result_n1) |ev1| {
                var found = false;
                for (result_n) |evn| {
                    if (ev1.confidence == evn.confidence and ev1.start == evn.start and
                        std.mem.eql(u8, ev1.type_name, evn.type_name))
                    {
                        found = true;
                        break;
                    }
                }
                try testing.expect(found);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: structural-query, Property 8: Evaluator preserves input and order
// **Validates: Requirements 7.2, 7.3**
test "property: evaluator preserves input and order" {
    const seed_gen = gen.intRange(u8, 0, 255);

    try minish.check(testing.allocator, seed_gen, struct {
        fn prop(seed: u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const type_names = [_][]const u8{ "function", "call", "import", "struct" };
            const num_events: usize = @as(usize, seed % 10) + 1;

            // Build events with unique start positions for identification
            var event_list = try alloc.alloc(StructuralEvent, num_events);
            for (0..num_events) |i| {
                const tn = type_names[(seed +% @as(u8, @intCast(i))) % type_names.len];
                event_list[i] = .{
                    .type_name = tn,
                    .captures = &.{},
                    .start = i * 100,
                    .end = i * 100 + 50,
                    .line = i + 1,
                    .col = 0,
                    .confidence = @as(f32, @floatFromInt((seed +% @as(u8, @intCast(i * 7))) % 100)) / 100.0,
                };
            }

            // Snapshot input for comparison
            const snapshot = try alloc.alloc(StructuralEvent, num_events);
            @memcpy(snapshot, event_list);

            // Apply a filter (type filter on "function")
            const f = QueryFilter{
                .type_selector = .{ .named = "function" },
                .conditions = &.{},
            };

            const result = try evaluate(event_list, f, alloc);

            // 1. Input is unchanged
            for (0..num_events) |i| {
                try testing.expectEqualStrings(snapshot[i].type_name, event_list[i].type_name);
                try testing.expectEqual(snapshot[i].start, event_list[i].start);
                try testing.expectEqual(snapshot[i].confidence, event_list[i].confidence);
            }

            // 2. Output is a subsequence of input (same relative order)
            var input_idx: usize = 0;
            for (result) |r| {
                // Find this result in the input starting from input_idx
                var found = false;
                while (input_idx < num_events) : (input_idx += 1) {
                    if (event_list[input_idx].start == r.start and
                        std.mem.eql(u8, event_list[input_idx].type_name, r.type_name) and
                        event_list[input_idx].confidence == r.confidence)
                    {
                        input_idx += 1;
                        found = true;
                        break;
                    }
                }
                try testing.expect(found);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: plain-toml-capture-tables, Unit: numeric query conditions
// **Validates: Requirements 8.1, 8.2, 8.3, 8.4**
test "numeric conditions on count fields" {
    const ev = [_]StructuralEvent{
        .{
            .type_name = "fn",
            .captures = &.{.{ .field_name = "name", .value = "f" }},
            .start = 0,
            .end = 10,
            .line = 1,
            .col = 0,
            .confidence = 1.0,
            .int_fields = &.{.{ .field_name = "args", .value = 2 }},
        },
        .{
            .type_name = "fn",
            .captures = &.{.{ .field_name = "name", .value = "f" }},
            .start = 0,
            .end = 10,
            .line = 1,
            .col = 0,
            .confidence = 1.0,
            .int_fields = &.{.{ .field_name = "args", .value = 0 }},
        },
        .{
            .type_name = "fn",
            .captures = &.{.{ .field_name = "name", .value = "f" }},
            .start = 0,
            .end = 10,
            .line = 1,
            .col = 0,
            .confidence = 1.0,
            .int_fields = &.{.{ .field_name = "args", .value = 5 }},
        },
    };

    {
        const f = QueryFilter{
            .type_selector = .{ .named = "fn" },
            .conditions = &.{.{ .field = "args", .op = .eq, .value = .{ .number = 2 } }},
        };
        const result = try evaluate(&ev, f, testing.allocator);
        defer testing.allocator.free(result);
        try testing.expectEqual(@as(usize, 1), result.len);
        try testing.expectEqual(@as(u32, 2), result[0].int_fields[0].value);
    }

    {
        const f = QueryFilter{
            .type_selector = .{ .named = "fn" },
            .conditions = &.{.{ .field = "args", .op = .gt, .value = .{ .number = 1 } }},
        };
        const result = try evaluate(&ev, f, testing.allocator);
        defer testing.allocator.free(result);
        try testing.expectEqual(@as(usize, 2), result.len);
    }

    {
        const f = QueryFilter{
            .type_selector = .{ .named = "fn" },
            .conditions = &.{.{ .field = "args", .op = .neq, .value = .{ .number = 0 } }},
        };
        const result = try evaluate(&ev, f, testing.allocator);
        defer testing.allocator.free(result);
        try testing.expectEqual(@as(usize, 2), result.len);
    }
}

test "numeric conditions: absent field excludes for eq, includes for neq, excludes for gt" {
    const ev = [_]StructuralEvent{
        makeEvent("fn", &.{}, 1.0),
    };
    {
        const f = QueryFilter{
            .type_selector = .{ .named = "fn" },
            .conditions = &.{.{ .field = "args", .op = .eq, .value = .{ .number = 2 } }},
        };
        const result = try evaluate(&ev, f, testing.allocator);
        defer testing.allocator.free(result);
        try testing.expectEqual(@as(usize, 0), result.len);
    }
    {
        const f = QueryFilter{
            .type_selector = .{ .named = "fn" },
            .conditions = &.{.{ .field = "args", .op = .neq, .value = .{ .number = 2 } }},
        };
        const result = try evaluate(&ev, f, testing.allocator);
        defer testing.allocator.free(result);
        try testing.expectEqual(@as(usize, 1), result.len);
    }
    {
        const f = QueryFilter{
            .type_selector = .{ .named = "fn" },
            .conditions = &.{.{ .field = "args", .op = .gt, .value = .{ .number = 1 } }},
        };
        const result = try evaluate(&ev, f, testing.allocator);
        defer testing.allocator.free(result);
        try testing.expectEqual(@as(usize, 0), result.len);
    }
}

// Feature: plain-toml-capture-tables, Property 8: Numeric query comparison on
// count fields
test "property: numeric query comparison on count fields" {
    const tuple_gen = comptime gen.tuple2(
        u8,
        u8,
        gen.intRange(u8, 0, 20),
        gen.intRange(u8, 0, 3),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { u8, u8 }) !void {
            const args: u32 = vals[0];
            const cond_idx = vals[1];
            const events = [_]StructuralEvent{.{
                .type_name = "fn",
                .captures = &.{.{ .field_name = "name", .value = "f" }},
                .start = 0,
                .end = 10,
                .line = 1,
                .col = 0,
                .confidence = 1.0,
                .int_fields = &.{.{ .field_name = "args", .value = args }},
            }};

            const threshold: f32 = @floatFromInt(args +% 2);
            const cond = switch (cond_idx) {
                0 => AttributeCondition{ .field = "args", .op = .eq, .value = .{ .number = threshold } },
                1 => AttributeCondition{ .field = "args", .op = .gt, .value = .{ .number = @as(f32, @floatFromInt(args -% 1)) } },
                else => AttributeCondition{ .field = "args", .op = .neq, .value = .{ .number = threshold } },
            };
            const f = QueryFilter{ .type_selector = .{ .named = "fn" }, .conditions = &.{cond} };
            const result = try evaluate(&events, f, testing.allocator);
            defer testing.allocator.free(result);

            const match = switch (cond_idx) {
                0 => @as(f32, @floatFromInt(args)) == threshold,
                1 => @as(f32, @floatFromInt(args)) > @as(f32, @floatFromInt(args -% 1)),
                else => @as(f32, @floatFromInt(args)) != threshold,
            };
            try testing.expectEqual(match, result.len == 1);
        }
    }.prop, .{ .num_runs = 100 });
}

// ---------------------------------------------------------------------------
// Spec: query-comparison-operators property tests
// ---------------------------------------------------------------------------

const cap_names_pool = [_][]const u8{ "name", "kind", "callee" };
const int_names_pool = [_][]const u8{ "args", "level" };
const string_pool = [_][]const u8{ "deadline", "test_deadline", "foo", "client.export_quotes", "other", "" };
const type_pool = [_][]const u8{ "function", "call", "import" };

fn makeEventFull(type_name: []const u8, caps: []const CaptureEntry, ints: []const IntegerField, confidence: f32) StructuralEvent {
    return .{
        .type_name = type_name,
        .captures = caps,
        .int_fields = ints,
        .start = 0,
        .end = 1,
        .line = 1,
        .col = 0,
        .confidence = confidence,
    };
}

/// Independent reference for the PRE-refactor evaluator (the original
/// `matchesCondition`), used only by Property 1.
fn refMatchesCondition(event: StructuralEvent, cond: AttributeCondition) bool {
    return switch (cond.op) {
        .eq => blk: {
            if (cond.value == .number) {
                const iv = lookupInt(event.int_fields, cond.field);
                break :blk if (iv) |v| @as(f32, @floatFromInt(v)) == cond.value.number else false;
            }
            const cv = lookupCapture(event.captures, cond.field);
            if (cv) |val| break :blk std.mem.eql(u8, val, cond.value.string);
            break :blk false;
        },
        .neq => blk: {
            if (cond.value == .number) {
                const iv = lookupInt(event.int_fields, cond.field);
                break :blk if (iv) |v| @as(f32, @floatFromInt(v)) != cond.value.number else true;
            }
            const cv = lookupCapture(event.captures, cond.field);
            if (cv) |val| break :blk !std.mem.eql(u8, val, cond.value.string);
            break :blk true;
        },
        .gt => blk: {
            const threshold = cond.value.number;
            if (lookupInt(event.int_fields, cond.field)) |v| break :blk @as(f32, @floatFromInt(v)) > threshold;
            if (std.mem.eql(u8, cond.field, "confidence")) break :blk event.confidence > threshold;
            const cv = lookupCapture(event.captures, cond.field);
            if (cv) |val| {
                const parsed = std.fmt.parseFloat(f32, val) catch break :blk false;
                break :blk parsed > threshold;
            }
            break :blk false;
        },
        .contains, .prefix, .suffix => unreachable,
    };
}

fn eventFromSeed(alloc: std.mem.Allocator, seed: u8, idx: usize) !StructuralEvent {
    const tn = type_pool[(seed +% @as(u8, @intCast(idx * 3))) % type_pool.len];
    const confidence: f32 = @as(f32, @floatFromInt(seed % 11)) / 10.0;
    // Deterministic capture/int presence from seed bits.
    const have_cap = (@as(u16, seed) >> @intCast(@as(u4, @intCast((idx % 8) + 1)))) & 1 == 1;
    const have_int = (@as(u16, seed) >> @intCast(@as(u4, @intCast(idx % 8)))) & 1 == 1;
    const caps_slice = if (have_cap) blk: {
        const caps = try alloc.alloc(CaptureEntry, 1);
        caps[0] = .{ .field_name = cap_names_pool[idx % cap_names_pool.len], .value = string_pool[(seed +% @as(u8, @intCast(idx))) % string_pool.len] };
        break :blk caps;
    } else &[_]CaptureEntry{};
    const ints_slice = if (have_int) blk: {
        const ints = try alloc.alloc(IntegerField, 1);
        ints[0] = .{ .field_name = int_names_pool[idx % int_names_pool.len], .value = seed };
        break :blk ints;
    } else &[_]IntegerField{};
    return makeEventFull(tn, caps_slice, ints_slice, confidence);
}

fn condFromSeed(seed: u8, idx: usize) !AttributeCondition {
    // 0..2: legacy ops; 3..5: substring ops (only used by later properties).
    const op: ComparisonOp = switch (seed % 6) {
        0 => .eq,
        1 => .neq,
        2 => .gt,
        3 => .contains,
        4 => .prefix,
        else => .suffix,
    };
    const field = switch (op) {
        .gt => if (idx % 2 == 0) "confidence" else int_names_pool[idx % int_names_pool.len],
        .contains, .prefix, .suffix => cap_names_pool[idx % cap_names_pool.len],
        else => if (idx % 3 == 0) int_names_pool[idx % int_names_pool.len] else cap_names_pool[idx % cap_names_pool.len],
    };
    const value: AttributeValue = switch (op) {
        .gt => .{ .number = @as(f32, @floatFromInt(seed % 10)) },
        .contains, .prefix, .suffix => .{ .string = string_pool[(seed +% @as(u8, @intCast(idx * 2))) % string_pool.len] },
        else => if (idx % 3 == 0) .{ .number = @as(f32, @floatFromInt(seed % 10)) } else .{ .string = string_pool[(seed +% @as(u8, @intCast(idx))) % string_pool.len] },
    };
    return .{ .field = field, .op = op, .value = value };
}

// Feature: query-comparison-operators, Property 1: Refactor is
// behavior-preserving for existing operators
test "property: refactor is behavior-preserving for existing operators (P1)" {
    const seed_gen = gen.intRange(u8, 0, 255);

    try minish.check(testing.allocator, seed_gen, struct {
        fn prop(seed: u8) !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const n_events: usize = @as(usize, seed % 5) + 1;
            const n_conds: usize = @as(usize, (seed >> 3) % 4);
            const events = try alloc.alloc(StructuralEvent, n_events);
            for (0..n_events) |i| events[i] = try eventFromSeed(alloc, seed, i);

            if (n_conds == 0) return;
            const conds = try alloc.alloc(AttributeCondition, n_conds);
            for (0..n_conds) |i| {
                var c = try condFromSeed(seed +% @as(u8, @intCast(i * 5)), i);
                // P1 compares ONLY legacy ops (eq/neq/gt) against the reference.
                if (c.op == .contains or c.op == .prefix or c.op == .suffix) {
                    c = .{
                        .field = c.field,
                        .op = if (c.value == .number) .gt else .eq,
                        .value = c.value,
                    };
                }
                conds[i] = c;
            }

            const f = QueryFilter{ .type_selector = .wildcard, .conditions = conds };
            const result = try evaluate(events, f, alloc);

            const expected = try alloc.alloc(StructuralEvent, events.len);
            var n: usize = 0;
            for (events) |event| {
                var ok = true;
                for (conds) |cond| {
                    if (!refMatchesCondition(event, cond)) {
                        ok = false;
                        break;
                    }
                }
                if (ok) {
                    expected[n] = event;
                    n += 1;
                }
            }
            try testing.expectEqual(n, result.len);
            for (result, 0..) |r, i| {
                try testing.expectEqualStrings(expected[i].type_name, r.type_name);
                try testing.expectEqual(expected[i].confidence, r.confidence);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: query-comparison-operators, Property 2: Contains semantics
test "property: contains semantics (P2)" {
    const tuple_gen = comptime gen.tuple3(
        []const u8,
        []const u8,
        bool,
        gen.string(.{ .min_len = 0, .max_len = 12, .charset = .alphanumeric }),
        gen.string(.{ .min_len = 0, .max_len = 6, .charset = .alphanumeric }),
        gen.boolean(),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { []const u8, []const u8, bool }) !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            var ev = try eventFromSeed(alloc, 7, 2);
            const caps = if (vals[2]) blk: {
                const c = try alloc.alloc(CaptureEntry, 1);
                c[0] = .{ .field_name = "f", .value = vals[0] };
                break :blk c;
            } else &[_]CaptureEntry{};
            ev = makeEventFull(ev.type_name, caps, ev.int_fields, ev.confidence);
            const cond = AttributeCondition{ .field = "f", .op = .contains, .value = .{ .string = vals[1] } };
            const result = matchesCondition(ev, cond);
            const expected = blk: {
                const cap = lookupCapture(caps, "f");
                break :blk if (cap) |s| std.mem.indexOf(u8, s, vals[1]) != null else false;
            };
            try testing.expectEqual(expected, result);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: query-comparison-operators, Property 3: Prefix and suffix semantics
test "property: prefix and suffix semantics (P3)" {
    const tuple_gen = comptime gen.tuple3(
        []const u8,
        []const u8,
        bool,
        gen.string(.{ .min_len = 0, .max_len = 12, .charset = .alphanumeric }),
        gen.string(.{ .min_len = 0, .max_len = 6, .charset = .alphanumeric }),
        gen.boolean(),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { []const u8, []const u8, bool }) !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            var ev = try eventFromSeed(alloc, 7, 2);
            const caps = if (vals[2]) blk: {
                const c = try alloc.alloc(CaptureEntry, 1);
                c[0] = .{ .field_name = "f", .value = vals[0] };
                break :blk c;
            } else &[_]CaptureEntry{};
            ev = makeEventFull(ev.type_name, caps, ev.int_fields, ev.confidence);
            const cap = lookupCapture(caps, "f");
            const prefix_cond = AttributeCondition{ .field = "f", .op = .prefix, .value = .{ .string = vals[1] } };
            const suffix_cond = AttributeCondition{ .field = "f", .op = .suffix, .value = .{ .string = vals[1] } };
            const expected_prefix = if (cap) |s| std.mem.startsWith(u8, s, vals[1]) else false;
            const expected_suffix = if (cap) |s| std.mem.endsWith(u8, s, vals[1]) else false;
            try testing.expectEqual(expected_prefix, matchesCondition(ev, prefix_cond));
            try testing.expectEqual(expected_suffix, matchesCondition(ev, suffix_cond));
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: query-comparison-operators, Property 7: Field resolution is
// single-sourced and language-agnostic
test "property: field resolution is single-sourced (P7)" {
    const tuple_gen = comptime gen.tuple3(
        u8,
        []const u8,
        u32,
        gen.intRange(u8, 0, 3),
        gen.string(.{ .min_len = 0, .max_len = 8, .charset = .alphanumeric }),
        gen.intRange(u32, 0, 1000),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { u8, []const u8, u32 }) !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // Scenario: 0=string capture, 1=integer field, 2=confidence,
            // 3=absent.
            var ev = try eventFromSeed(alloc, 7, 2);
            switch (vals[0]) {
                0 => {
                    const caps = try alloc.alloc(CaptureEntry, 1);
                    caps[0] = .{ .field_name = "f", .value = vals[1] };
                    ev = makeEventFull(ev.type_name, caps, &.{}, ev.confidence);
                    const r = resolveField(ev, "f");
                    try testing.expect(r == .string);
                    try testing.expectEqualStrings(vals[1], r.string);
                },
                1 => {
                    const ints = try alloc.alloc(IntegerField, 1);
                    ints[0] = .{ .field_name = "f", .value = vals[2] };
                    ev = makeEventFull(ev.type_name, &.{}, ints, ev.confidence);
                    const r = resolveField(ev, "f");
                    try testing.expect(r == .integer);
                    try testing.expectEqual(vals[2], r.integer);
                },
                2 => {
                    const r = resolveField(ev, "confidence");
                    try testing.expect(r == .floating);
                    try testing.expectEqual(ev.confidence, r.floating);
                },
                else => {
                    ev = makeEventFull(ev.type_name, &.{}, &.{}, ev.confidence);
                    const r = resolveField(ev, "f");
                    try testing.expect(r == .absent);
                },
            }
        }
    }.prop, .{ .num_runs = 100 });
}
