const std = @import("std");
const events_mod = @import("../parser/events.zig");
const StructuralEvent = events_mod.StructuralEvent;
const CaptureEntry = events_mod.CaptureEntry;
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
fn matchesCondition(event: StructuralEvent, cond: AttributeCondition) bool {
    switch (cond.op) {
        .eq => {
            // Look up field in captures; include only if found and value matches
            const capture_value = lookupCapture(event.captures, cond.field);
            if (capture_value) |val| {
                return std.mem.eql(u8, val, cond.value.string);
            }
            return false; // field not found → exclude
        },
        .neq => {
            // Include if field not found OR value differs
            const capture_value = lookupCapture(event.captures, cond.field);
            if (capture_value) |val| {
                return !std.mem.eql(u8, val, cond.value.string);
            }
            return true; // field not found → include
        },
        .gt => {
            const threshold = cond.value.number;
            // Special-case: confidence field reads event.confidence directly
            if (std.mem.eql(u8, cond.field, "confidence")) {
                return event.confidence > threshold;
            }
            // Otherwise, attempt float parse of capture value
            const capture_value = lookupCapture(event.captures, cond.field);
            if (capture_value) |val| {
                const parsed = std.fmt.parseFloat(f32, val) catch return false;
                return parsed > threshold;
            }
            return false; // field not found → exclude
        },
    }
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
