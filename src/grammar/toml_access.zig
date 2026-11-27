//! Typed reads over parsed TOML values for the grammar loader.
//!
//! This is the only file that reads `toml.Value` union payloads for the
//! loader. Callers hold values as opaque `Node`s and read them through a
//! `Reader`, so every read checks the active tag first. A wrong tag (or an
//! integer outside the requested range) returns the error named by the
//! `Key`; when that error is `WrongValueType` the `Diagnostic` is filled with
//! the key path and the expected type.
const std = @import("std");
const toml = @import("toml");
const GrammarError = @import("loader.zig").GrammarError;

pub const Expected = enum { string, string_array, integer, number, boolean, table, table_array, array };

/// Filled when an accessor returns `error.WrongValueType`. The path is copied
/// into a fixed buffer because the TOML document is freed before the grammar
/// loader returns.
pub const Diagnostic = struct {
    path_buf: [96]u8 = undefined,
    path_len: usize = 0,
    expected: Expected = .string,
    /// Integer range, valid when `expected == .integer`.
    lo: i64 = 0,
    hi: i64 = 0,

    pub fn path(self: *const Diagnostic) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn set(self: *Diagnostic, display_path: []const u8, expected: Expected, lo: i64, hi: i64) void {
        const n = @min(display_path.len, self.path_buf.len);
        @memcpy(self.path_buf[0..n], display_path[0..n]);
        self.path_len = n;
        self.expected = expected;
        self.lo = lo;
        self.hi = hi;
    }
};

/// Describes one key: the TOML key to look up, the path shown in messages,
/// and the error returned for a wrong tag or an out-of-range integer.
pub const Key = struct {
    name: []const u8,
    path: []const u8 = "",
    invalid: GrammarError = error.WrongValueType,
};

/// Opaque handle to a parsed TOML value. The payload is never read outside
/// this file.
pub const Node = struct {
    _v: *const toml.Value,

    pub fn wrap(v: *const toml.Value) Node {
        return .{ ._v = v };
    }

    /// True when the receiver is a table that holds `name`.
    pub fn has(self: Node, name: []const u8) bool {
        return self._v.get(name) != null;
    }
};

/// Read-only view of a TOML array's elements.
pub const NodeList = struct {
    _items: []const toml.Value,

    pub fn len(self: NodeList) usize {
        return self._items.len;
    }

    pub fn at(self: NodeList, i: usize) Node {
        return .{ ._v = &self._items[i] };
    }
};

/// One `key = value` entry of a table.
pub const Entry = struct {
    key: []const u8,
    value: Node,
};

pub const Iterator = struct {
    _it: std.StringArrayHashMapUnmanaged(*toml.Value).Iterator,

    pub fn next(self: *Iterator) ?Entry {
        const e = self._it.next() orelse return null;
        return .{ .key = e.key_ptr.*, .value = Node.wrap(e.value_ptr.*) };
    }
};

/// Parses a TOML document. The caller owns the result and frees it with
/// `deinit`. Syntax errors map to `InvalidToml`.
pub fn parseDocument(allocator: std.mem.Allocator, source: []const u8) GrammarError!*toml.Document {
    return toml.parse(allocator, source, .{}) catch return error.InvalidToml;
}

pub const Reader = struct {
    diag: *Diagnostic,

    fn fail(r: Reader, k: Key, expected: Expected, lo: i64, hi: i64) GrammarError {
        if (k.invalid == error.WrongValueType) r.diag.set(k.path, expected, lo, hi);
        return k.invalid;
    }

    fn lookup(t: Node, k: Key) ?*const toml.Value {
        return t._v.get(k.name);
    }

    // --- Reads of a node itself (array items, table entries) ---

    pub fn stringOf(r: Reader, n: Node, k: Key) GrammarError![]const u8 {
        return switch (n._v.*) {
            .string => |s| s,
            else => r.fail(k, .string, 0, 0),
        };
    }

    /// Like `stringOf`, for an item of an array of strings: a wrong tag reports
    /// the whole value as an array of strings.
    pub fn stringItemOf(r: Reader, n: Node, k: Key) GrammarError![]const u8 {
        return r.stringOf(n, k) catch |e| switch (e) {
            error.WrongValueType => r.fail(k, .string_array, 0, 0),
            else => e,
        };
    }

    pub fn tableOf(r: Reader, n: Node, k: Key) GrammarError!Node {
        return switch (n._v.*) {
            .table => n,
            else => r.fail(k, .table, 0, 0),
        };
    }

    // --- Optional keyed reads: null means the key is absent ---

    pub fn optString(r: Reader, t: Node, k: Key) GrammarError!?[]const u8 {
        const v = lookup(t, k) orelse return null;
        return try r.stringOf(Node.wrap(v), k);
    }

    pub fn optArray(r: Reader, t: Node, k: Key) GrammarError!?NodeList {
        return r.optArrayExpecting(t, k, .array);
    }

    /// Like `optArray`; a non-array value is reported as `expected` (for
    /// callers that read the items as strings or tables next).
    pub fn optArrayExpecting(r: Reader, t: Node, k: Key, expected: Expected) GrammarError!?NodeList {
        const v = lookup(t, k) orelse return null;
        return switch (v.*) {
            .array => |a| NodeList{ ._items = a.items.items },
            else => r.fail(k, expected, 0, 0),
        };
    }

    /// Array whose items must all be strings. The returned slice is allocated
    /// from `allocator`; the strings still point into the document.
    pub fn optStringArray(r: Reader, t: Node, k: Key, allocator: std.mem.Allocator) GrammarError!?[]const []const u8 {
        const list = (try r.optArrayExpecting(t, k, .string_array)) orelse return null;
        const out = try allocator.alloc([]const u8, list.len());
        errdefer allocator.free(out);
        for (0..list.len()) |i| {
            out[i] = r.stringOf(list.at(i), k) catch |e| switch (e) {
                error.WrongValueType => return r.fail(k, .string_array, 0, 0),
                else => return e,
            };
        }
        return out;
    }

    /// Integer within `lo..hi` (inclusive). A float, another tag, or an
    /// out-of-range integer returns `k.invalid`.
    pub fn optInt(r: Reader, t: Node, k: Key, lo: i64, hi: i64) GrammarError!?i64 {
        const v = lookup(t, k) orelse return null;
        return switch (v.*) {
            .integer => |i| if (i < lo or i > hi) r.fail(k, .integer, lo, hi) else i,
            else => r.fail(k, .integer, lo, hi),
        };
    }

    /// A float or an integer, as an f32.
    pub fn optNumber(r: Reader, t: Node, k: Key) GrammarError!?f32 {
        const v = lookup(t, k) orelse return null;
        return switch (v.*) {
            .float => |f| @as(f32, @floatCast(f)),
            .integer => |i| @as(f32, @floatFromInt(i)),
            else => r.fail(k, .number, 0, 0),
        };
    }

    pub fn optBool(r: Reader, t: Node, k: Key) GrammarError!?bool {
        const v = lookup(t, k) orelse return null;
        return switch (v.*) {
            .bool => |b| b,
            else => r.fail(k, .boolean, 0, 0),
        };
    }

    pub fn optTable(r: Reader, t: Node, k: Key) GrammarError!?Node {
        const v = lookup(t, k) orelse return null;
        return try r.tableOf(Node.wrap(v), k);
    }

    /// Array of tables: the value must be an array and every element a table.
    pub fn optTableArray(r: Reader, t: Node, k: Key) GrammarError!?NodeList {
        const list = (try r.optArrayExpecting(t, k, .table_array)) orelse return null;
        for (0..list.len()) |i| {
            _ = r.tableOf(list.at(i), k) catch |e| switch (e) {
                error.WrongValueType => return r.fail(k, .table_array, 0, 0),
                else => return e,
            };
        }
        return list;
    }

    /// Iterates the entries of a table node; the node must be a table.
    pub fn tableEntries(r: Reader, t: Node, k: Key) GrammarError!Iterator {
        return switch (t._v.*) {
            .table => |tb| Iterator{ ._it = tb.map.iterator() },
            else => r.fail(k, .table, 0, 0),
        };
    }

    // --- Required keyed reads: absent returns `missing` ---

    pub fn reqString(r: Reader, t: Node, k: Key, missing: GrammarError) GrammarError![]const u8 {
        return (try r.optString(t, k)) orelse missing;
    }

    pub fn reqTableArray(r: Reader, t: Node, k: Key, missing: GrammarError) GrammarError!NodeList {
        return (try r.optTableArray(t, k)) orelse missing;
    }
};

// --- Tests ---

const testing = std.testing;

fn testDoc(src: []const u8) !*toml.Document {
    return parseDocument(testing.allocator, src);
}

fn rootNode(doc: *toml.Document) Node {
    return Node.wrap(doc.root);
}

test "toml_access: parseDocument maps syntax errors to InvalidToml" {
    try testing.expectError(error.InvalidToml, parseDocument(testing.allocator, "a = = ["));
}

test "toml_access: optString absent, correct and wrong tags" {
    const doc = try testDoc("s = \"x\"\nn = 1\nb = true\narr = [\"a\"]\ntb = { a = 1 }\n");
    defer doc.deinit();
    var d: Diagnostic = .{};
    const r = Reader{ .diag = &d };
    const root = rootNode(doc);
    try testing.expectEqual(@as(?[]const u8, null), try r.optString(root, .{ .name = "missing" }));
    try testing.expectEqualStrings("x", (try r.optString(root, .{ .name = "s" })).?);
    for ([_][]const u8{ "n", "b", "arr", "tb" }) |name| {
        try testing.expectError(error.WrongValueType, r.optString(root, .{ .name = name, .path = "p" }));
    }
    try testing.expectError(error.InvalidPriorValue, r.optString(root, .{ .name = "n", .invalid = error.InvalidPriorValue }));
}

test "toml_access: optInt range edges and wrong tags" {
    const doc = try testDoc("lo = 0\nhi = 255\nbelow = -1\nabove = 256\nmin = -9223372036854775808\nmax = 9223372036854775807\nf = 1.5\ns = \"a\"\n");
    defer doc.deinit();
    var d: Diagnostic = .{};
    const r = Reader{ .diag = &d };
    const root = rootNode(doc);
    try testing.expectEqual(@as(?i64, 0), try r.optInt(root, .{ .name = "lo" }, 0, 255));
    try testing.expectEqual(@as(?i64, 255), try r.optInt(root, .{ .name = "hi" }, 0, 255));
    try testing.expectEqual(@as(?i64, null), try r.optInt(root, .{ .name = "nope" }, 0, 255));
    for ([_][]const u8{ "below", "above", "min", "max", "f", "s" }) |name| {
        try testing.expectError(error.WrongValueType, r.optInt(root, .{ .name = name, .path = "depth" }, 0, 255));
    }
    try testing.expectEqual(Expected.integer, d.expected);
    try testing.expectEqual(@as(i64, 0), d.lo);
    try testing.expectEqual(@as(i64, 255), d.hi);
    try testing.expectEqualStrings("depth", d.path());
    try testing.expectEqual(@as(?i64, std.math.maxInt(i64)), try r.optInt(root, .{ .name = "max" }, std.math.minInt(i64), std.math.maxInt(i64)));
    try testing.expectError(error.InvalidExtentAtColumn, r.optInt(root, .{ .name = "above", .invalid = error.InvalidExtentAtColumn }, 0, 255));
}

test "toml_access: optNumber accepts float and integer only" {
    const doc = try testDoc("f = 0.5\ni = 2\ns = \"x\"\n");
    defer doc.deinit();
    var d: Diagnostic = .{};
    const r = Reader{ .diag = &d };
    const root = rootNode(doc);
    try testing.expectEqual(@as(?f32, 0.5), try r.optNumber(root, .{ .name = "f" }));
    try testing.expectEqual(@as(?f32, 2.0), try r.optNumber(root, .{ .name = "i" }));
    try testing.expectEqual(@as(?f32, null), try r.optNumber(root, .{ .name = "none" }));
    try testing.expectError(error.InvalidWeightValue, r.optNumber(root, .{ .name = "s", .invalid = error.InvalidWeightValue }));
}

test "toml_access: optBool and optTable and optArray tags" {
    const doc = try testDoc("b = true\nn = 1\nt = { a = 1 }\na = [1, 2]\n");
    defer doc.deinit();
    var d: Diagnostic = .{};
    const r = Reader{ .diag = &d };
    const root = rootNode(doc);
    try testing.expectEqual(@as(?bool, true), try r.optBool(root, .{ .name = "b" }));
    try testing.expectError(error.WrongValueType, r.optBool(root, .{ .name = "n" }));
    try testing.expect((try r.optTable(root, .{ .name = "t" })) != null);
    try testing.expectError(error.WrongValueType, r.optTable(root, .{ .name = "n" }));
    try testing.expectEqual(@as(usize, 2), (try r.optArray(root, .{ .name = "a" })).?.len());
    try testing.expectError(error.WrongValueType, r.optArray(root, .{ .name = "t" }));
    try testing.expectEqual(Expected.array, d.expected);
}

test "toml_access: a scalar given for a table key is a wrong type, not absent" {
    const doc = try testDoc("blocks = 1\n");
    defer doc.deinit();
    var d: Diagnostic = .{};
    const r = Reader{ .diag = &d };
    try testing.expectError(error.WrongValueType, r.optTable(rootNode(doc), .{ .name = "blocks", .path = "blocks" }));
    try testing.expectEqual(Expected.table, d.expected);
    try testing.expectEqualStrings("blocks", d.path());
}

test "toml_access: optStringArray rejects a bad element" {
    const doc = try testDoc("ok = [\"a\", \"b\"]\nbad = [\"a\", 1]\nscalar = \"a\"\n");
    defer doc.deinit();
    var d: Diagnostic = .{};
    const r = Reader{ .diag = &d };
    const root = rootNode(doc);
    const ok = (try r.optStringArray(root, .{ .name = "ok" }, testing.allocator)).?;
    defer testing.allocator.free(ok);
    try testing.expectEqual(@as(usize, 2), ok.len);
    try testing.expectEqualStrings("b", ok[1]);
    try testing.expectError(error.WrongValueType, r.optStringArray(root, .{ .name = "bad", .path = "bad" }, testing.allocator));
    try testing.expectEqual(Expected.string_array, d.expected);
    try testing.expectError(error.InvalidExtensionsList, r.optStringArray(root, .{ .name = "scalar", .invalid = error.InvalidExtensionsList }, testing.allocator));
    try testing.expectEqual(@as(?[]const []const u8, null), try r.optStringArray(root, .{ .name = "none" }, testing.allocator));
}

test "toml_access: optTableArray rejects non-table elements" {
    const doc = try testDoc("good = [{ a = 1 }, { a = 2 }]\nbad = [{ a = 1 }, 2]\nscalar = 1\n");
    defer doc.deinit();
    var d: Diagnostic = .{};
    const r = Reader{ .diag = &d };
    const root = rootNode(doc);
    const good = (try r.optTableArray(root, .{ .name = "good" })).?;
    try testing.expectEqual(@as(usize, 2), good.len());
    try testing.expectError(error.WrongValueType, r.optTableArray(root, .{ .name = "bad" }));
    try testing.expectError(error.WrongValueType, r.optTableArray(root, .{ .name = "scalar" }));
    try testing.expectError(error.MissingPatterns, r.reqTableArray(root, .{ .name = "none" }, error.MissingPatterns));
}

test "toml_access: reqString returns the caller's missing error only when absent" {
    const doc = try testDoc("s = \"x\"\nn = 1\n");
    defer doc.deinit();
    var d: Diagnostic = .{};
    const r = Reader{ .diag = &d };
    const root = rootNode(doc);
    try testing.expectEqualStrings("x", try r.reqString(root, .{ .name = "s" }, error.InvalidCountTable));
    try testing.expectError(error.InvalidCountTable, r.reqString(root, .{ .name = "none" }, error.InvalidCountTable));
    try testing.expectError(error.WrongValueType, r.reqString(root, .{ .name = "n" }, error.InvalidCountTable));
}

test "toml_access: tableEntries iterates in order and rejects non-tables" {
    const doc = try testDoc("[t]\na = 1\nb = 2\n");
    defer doc.deinit();
    var d: Diagnostic = .{};
    const r = Reader{ .diag = &d };
    const root = rootNode(doc);
    const t = (try r.optTable(root, .{ .name = "t" })).?;
    var it = try r.tableEntries(t, .{ .name = "t" });
    try testing.expectEqualStrings("a", it.next().?.key);
    try testing.expectEqualStrings("b", it.next().?.key);
    try testing.expect(it.next() == null);
    const doc2 = try testDoc("t = 1\n");
    defer doc2.deinit();
    try testing.expectError(error.WrongValueType, r.tableEntries(Node.wrap(doc2.root.get("t").?), .{ .name = "t" }));
}

test "toml_access: Diagnostic path survives freeing the document" {
    var d: Diagnostic = .{};
    const r = Reader{ .diag = &d };
    {
        const doc = try testDoc("k = 1\n");
        defer doc.deinit();
        var buf: [16]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "[{s}] {s}", .{ "sec", "k" });
        try testing.expectError(error.WrongValueType, r.optString(rootNode(doc), .{ .name = "k", .path = p }));
    }
    try testing.expectEqualStrings("[sec] k", d.path());
}

test "toml_access: a 200-byte path truncates without failure" {
    const long = "x" ** 200;
    const doc = try testDoc("k = 1\n");
    defer doc.deinit();
    var d: Diagnostic = .{};
    const r = Reader{ .diag = &d };
    try testing.expectError(error.WrongValueType, r.optString(rootNode(doc), .{ .name = "k", .path = long }));
    try testing.expectEqual(@as(usize, 96), d.path().len);
}

test "toml_access: guarded variants leave the diagnostic untouched" {
    const doc = try testDoc("k = 1\n");
    defer doc.deinit();
    var d: Diagnostic = .{};
    const r = Reader{ .diag = &d };
    try testing.expectError(error.InvalidCountTable, r.optString(rootNode(doc), .{ .name = "k", .path = "p", .invalid = error.InvalidCountTable }));
    try testing.expectEqual(@as(usize, 0), d.path().len);
}
