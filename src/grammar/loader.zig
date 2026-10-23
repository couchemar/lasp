const std = @import("std");
const toml = @import("toml");
const tokenizer = @import("../parser/tokenizer.zig");
const TokenKind = tokenizer.TokenKind;

// --- Data Types ---

pub const EvidenceWeights = struct {
    keyword: f32 = 0.5,
    identifier: f32 = 0.2,
    symbol: f32 = 0.2,
    block: f32 = 0.3,
    relaxed_keyword: f32 = 0.1,
};

pub const Grammar = struct {
    language_name: ?[]const u8,
    keyword_categories: []const KeywordCategory,
    keyword_table: []const []const u8,
    patterns: []const Pattern,
    blocks: BlockConfig,
    weights: EvidenceWeights = .{},
    comments: CommentConfig = .{},
    tokens: ?tokenizer.KindVocabulary = null,
};

pub const KeywordCategory = struct {
    name: []const u8,
    keywords: []const []const u8,
};

pub const PositionConstraint = enum {
    start, // column 0
};

pub const ConstraintType = enum {
    not,
};

pub const Constraint = struct {
    type: ConstraintType,
    depth: u8,
    field: ?[]const u8 = null,
    values: []const []const u8,
};

pub const SequenceElement = struct {
    matcher: ComposableMatcher,
    is_optional: bool = false,
};

pub const Pattern = struct {
    type_name: []const u8,
    sequence: []const SequenceElement,
    captures: []const Capture,
    position: ?PositionConstraint = null,
    constraints: []const Constraint = &.{},
    prior: f32 = 1.0,
};

/// Kind axis: a resolved reference, not a per-kind variant. The fixed default Kind_Table
/// is wrapped here; a later grammar-defined-token-kinds feature swaps the table source.
pub const KindRef = union(enum) {
    any,
    one: TokenKind,
    punctuation,
    id: usize,
};

pub const TextConstraint = union(enum) {
    any,
    exact: []const u8,
};

pub const ComposableMatcher = struct {
    kind: KindRef,
    text: TextConstraint = .any,
    capture: ?Capture = null,
};


pub const Capture = struct {
    field_name: []const u8,
    position: usize,
    separator: ?[]const u8 = null,
    suffix_set: ?[]const u8 = null,
};

pub const BlockConfig = struct {
    open: ?[]const u8 = null,
    close: ?[]const u8 = null,
    indentation: bool = false,
};

pub const CommentConfig = struct {
    line_prefixes: []const []const u8 = &.{ "//", "#" },
    block_open: ?[]const u8 = "/*",
    block_close: ?[]const u8 = "*/",

    pub const default = CommentConfig{};

    /// Returns a config with no comment recognition at all.
    pub const none = CommentConfig{
        .line_prefixes = &.{},
        .block_open = null,
        .block_close = null,
    };
};

pub const GrammarError = error{
    FileNotFound,
    InvalidToml,
    MissingPatterns,
    EmptyPatternSequence,
    InvalidCaptureFormat,
    InvalidPositionValue,
    InvalidWeightValue,
    InvalidPriorValue,
    InvalidKindName,
    InvalidConstraintType,
    InvalidConstraintDepth,
    InvalidConstraintField,
    InvalidConstraintValues,
    DeprecatedField,
    InvalidCommentLineType,
    InvalidCommentBlockType,
    UnpairedBlockDelimiter,
    CommentPrefixTooLong,
    TooManyLinePrefixes,
    BlockDelimiterTooLong,
    OutOfMemory,
    InvalidTokenSection,
    DuplicateKindName,
    EmptyKindName,
    InvalidRecognizer,
    InvalidCharSet,
    EmptyLiteralSet,
};

const delimiter_chars = "(){}[]";
const symbol_chars = ",;:.@?";
const operator_chars = "+-*/=<>!&|^%~";

/// Single-character punctuation: symbols, delimiters, and operators (unified
/// punctuation matching, spec: operator-token-matching).
fn isPunctuation(s: []const u8) bool {
    if (s.len != 1) return false;
    for (delimiter_chars ++ symbol_chars ++ operator_chars) |c| {
        if (s[0] == c) return true;
    }
    return false;
}

/// Extracts an f32 from a TOML value that may be either .float or .integer.
/// Returns null if the value is neither type.
fn tomlToF32(v: anytype) ?f32 {
    // The TOML value is a tagged union pointer — dereference and switch on tag
    return switch (v.*) {
        .float => |f| @as(f32, @floatCast(f)),
        .integer => |i| @as(f32, @floatFromInt(i)),
        else => null,
    };
}

// Writes a string with TOML basic-string escaping (backslash and double quote).
fn writeEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            else => try w.writeByte(c),
        }
    }
}

/// Compiles a char-set spec ("a-zA-Z0-9_") into a CharClass bitset.
fn compileCharSet(spec: []const u8) GrammarError!tokenizer.CharClass {
    var cc = tokenizer.CharClass{};
    var i: usize = 0;
    while (i < spec.len) {
        const lo = spec[i];
        if (i + 2 < spec.len and spec[i + 1] == '-' and spec[i + 2] != '?') {
            const hi = spec[i + 2];
            if (lo > hi) return error.InvalidCharSet;
            var ch = lo;
            while (ch <= hi) : (ch += 1) cc.set(ch);
            i += 3;
        } else {
            cc.set(lo);
            i += 1;
        }
    }
    return cc;
}
const CaptureParams = struct {
    separator: ?[]const u8,
    suffix_set: ?[]const u8,
};

/// Resolves a kind name against the fixed default Kind_Table. Unknown name → null.
/// The single resolution point a later grammar-defined-token-kinds feature swaps.
fn resolveKind(name: []const u8) ?KindRef {
    if (std.mem.eql(u8, name, "IDENTIFIER")) return .{ .one = .identifier };
    if (std.mem.eql(u8, name, "NUMBER")) return .{ .one = .number };
    if (std.mem.eql(u8, name, "STRING")) return .{ .one = .string };
    return null;
}

/// Resolves a kind name against the default table first, then the grammar's
/// declared [tokens] vocabulary. Unknown name → null.
fn vocabKindRef(name: []const u8, vocab: ?tokenizer.KindVocabulary) ?KindRef {
    if (resolveKind(name)) |r| return r;
    if (vocab) |v| {
        for (v.kinds, 0..) |def, id| {
            if (std.mem.eql(u8, def.name, name)) return .{ .id = id };
        }
    }
    return null;
}

/// Maps a vocabulary kind index back to its declared name for serialization.
fn vocabKindName(grammar: Grammar, id: usize) []const u8 {
    if (grammar.tokens) |v| {
        if (id < v.kinds.len) return v.kinds[id].name;
    }
    return "identifier";
}

/// Parses the tail of a $field:KIND... sequence element: either bare "KIND"
/// (single-token capture) or "KIND(sep="...", suffix="...")".
fn parseCaptureTail(tail: []const u8, allocator: std.mem.Allocator, vocab: ?tokenizer.KindVocabulary) GrammarError!struct { kind: KindRef, span: CaptureParams } {
    const colon = std.mem.indexOfScalar(u8, tail, '(') orelse tail.len;
    const kind_name = tail[0..colon];
    const kind = vocabKindRef(kind_name, vocab) orelse return error.InvalidKindName;
    const rest = tail[colon..];
    if (rest.len == 0) {
        return .{ .kind = kind, .span = .{ .separator = null, .suffix_set = null } };
    }
    if (rest.len >= 2 and rest[0] == '(' and rest[rest.len - 1] == ')') {
        const params = rest[1 .. rest.len - 1];
        const span = try parseParamList(params, allocator);
        return .{ .kind = kind, .span = span };
    }
    return error.InvalidCaptureFormat;
}

fn parseParamList(params: []const u8, allocator: std.mem.Allocator) GrammarError!CaptureParams {
    var separator: ?[]const u8 = null;
    var suffix_set: ?[]const u8 = null;

    if (params.len == 0) return error.InvalidCaptureFormat; // empty "()"
    var it = std.mem.splitScalar(u8, params, ',');
    while (it.next()) |raw_seg| {
        const seg = std.mem.trim(u8, raw_seg, " \t");
        if (seg.len == 0) return error.InvalidCaptureFormat;
        const eq = std.mem.indexOfScalar(u8, seg, '=') orelse return error.InvalidCaptureFormat;
        const key = std.mem.trim(u8, seg[0..eq], " \t");
        const raw_val = std.mem.trim(u8, seg[eq + 1 ..], " \t");
        if (raw_val.len < 2 or raw_val[0] != '"' or raw_val[raw_val.len - 1] != '"') return error.InvalidCaptureFormat;
        const val = raw_val[1 .. raw_val.len - 1];
        if (val.len == 0) return error.InvalidCaptureFormat; // empty separator / suffix
        if (std.mem.eql(u8, key, "sep")) {
            if (separator != null) return error.InvalidCaptureFormat; // duplicate
            separator = try allocator.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "suffix")) {
            if (suffix_set != null) return error.InvalidCaptureFormat; // duplicate
            suffix_set = try allocator.dupe(u8, val);
        } else {
            return error.InvalidCaptureFormat; // unknown parameter
        }
    }
    if (separator == null and suffix_set == null) return error.InvalidCaptureFormat;
    return .{ .separator = separator, .suffix_set = suffix_set };
}

const SequenceElementResult = struct {
    element: SequenceElement,
    capture: ?Capture,
};

fn parseSequenceElement(raw: []const u8, position: usize, allocator: std.mem.Allocator) GrammarError!SequenceElementResult {
    return parseSequenceElementV(raw, position, allocator, null);
}

/// Parses a single pattern sequence string into a SequenceElement.
/// Handles trailing `?` suffix for optional elements.
fn parseSequenceElementV(raw: []const u8, position: usize, allocator: std.mem.Allocator, vocab: ?tokenizer.KindVocabulary) GrammarError!SequenceElementResult {
    // Check for trailing `?` suffix (optional element)
    var s = raw;
    var optional = false;
    if (s.len > 1 and s[s.len - 1] == '?') {
        optional = true;
        s = s[0 .. s.len - 1];
    }

    // Capture: $field:KIND[(params)] — kind resolved via resolveKind.
    if (s.len > 0 and s[0] == '$') {
        const colon_idx = std.mem.indexOf(u8, s, ":") orelse return error.InvalidCaptureFormat;
        if (colon_idx < 2) return error.InvalidCaptureFormat; // need at least $x
        const field_name = try allocator.dupe(u8, s[1..colon_idx]);
        const tail = s[colon_idx + 1 ..];
        const parsed = try parseCaptureTail(tail, allocator, vocab);
        const cap = Capture{
            .field_name = field_name,
            .position = position,
            .separator = parsed.span.separator,
            .suffix_set = parsed.span.suffix_set,
        };
        const matcher = ComposableMatcher{ .kind = parsed.kind, .capture = cap };
        return .{ .element = .{ .matcher = matcher, .is_optional = optional }, .capture = cap };
    }
    // Kind wildcards: identifier, number (string added in task 5)
    if (std.mem.eql(u8, s, "identifier")) {
        return .{ .element = .{ .matcher = .{ .kind = .{ .one = .identifier } }, .is_optional = optional }, .capture = null };
    }
    if (std.mem.eql(u8, s, "number")) {
        return .{ .element = .{ .matcher = .{ .kind = .{ .one = .number } }, .is_optional = optional }, .capture = null };
    }
    if (std.mem.eql(u8, s, "string")) {
        return .{ .element = .{ .matcher = .{ .kind = .{ .one = .string } }, .is_optional = optional }, .capture = null };
    }
    // Grammar vocabulary kind wildcards: bare kind name matches any token of that kind.
    if (vocab) |v| {
        for (v.kinds, 0..) |def, id| {
            if (std.mem.eql(u8, s, def.name)) {
                return .{ .element = .{ .matcher = .{ .kind = .{ .id = id } }, .is_optional = optional }, .capture = null };
            }
        }
    }
    // EXACT KIND matching (Name:KIND) — not starting with '$'
    if (s[0] != '$') {
        if (std.mem.indexOfScalar(u8, s, ':')) |colon_idx| {
            if (colon_idx > 0) {
                const kind_name = s[colon_idx + 1 ..];
                if (kind_name.len == 0) return error.InvalidKindName;
                const kind = vocabKindRef(kind_name, vocab) orelse return error.InvalidKindName;
                const exact_text = try allocator.dupe(u8, s[0..colon_idx]);
                return .{ .element = .{ .matcher = .{ .kind = kind, .text = .{ .exact = exact_text } }, .is_optional = optional }, .capture = null };
            }
        }
    }
    // Punctuation literal (single char: symbol, delimiter, or operator)
    if (isPunctuation(s)) {
        return .{ .element = .{ .matcher = .{ .kind = .punctuation, .text = .{ .exact = try allocator.dupe(u8, s) } }, .is_optional = optional }, .capture = null };
    }
    // Keyword literal
    return .{ .element = .{ .matcher = .{ .kind = .{ .one = .keyword }, .text = .{ .exact = try allocator.dupe(u8, s) } }, .is_optional = optional }, .capture = null };
}


/// Parses the optional [tokens] section into a KindVocabulary. Returns null when
/// the section is absent. Each kind declaration must contain exactly one of
/// char_class_run, delimited_span, or literal_set.
fn parseTokensSection(root: anytype, allocator: std.mem.Allocator) GrammarError!?tokenizer.KindVocabulary {
    const tokens_table = root.get("tokens") orelse return null;
    var defs: std.ArrayList(tokenizer.KindDefinition) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var it = tokens_table.table.map.iterator();
    while (it.next()) |entry| {
        const name = try allocator.dupe(u8, entry.key_ptr.*);
        if (name.len == 0) return error.EmptyKindName;
        for (names.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return error.DuplicateKindName;
        }
        try names.append(allocator, name);

        const val = entry.value_ptr.*;
        if (val.* != .table) return error.InvalidTokenSection;
        const t = val.table;
        var rec_count: usize = 0;
        if (t.map.get("char_class_run")) |ccr| {
            if (ccr.* != .table) return error.InvalidRecognizer;
            const start_spec = ccr.table.map.get("start") orelse return error.InvalidRecognizer;
            if (start_spec.* != .string) return error.InvalidRecognizer;
            if (start_spec.string.len == 0) return error.InvalidCharSet;
            const start = try compileCharSet(start_spec.string);
            const cont = if (ccr.table.map.get("continue")) |csp| blk: {
                if (csp.* != .string) return error.InvalidRecognizer;
                break :blk try compileCharSet(csp.string);
            } else start;
            try defs.append(allocator, .{
                .name = name,
                .recognizer = .{ .char_class_run = .{ .start = start, .cont = cont } },
            });
            rec_count += 1;
        }
        if (t.map.get("delimited_span")) |ds| {
            if (ds.* != .table) return error.InvalidRecognizer;
            const open = ds.table.map.get("open") orelse return error.InvalidRecognizer;
            const close = ds.table.map.get("close") orelse return error.InvalidRecognizer;
            if (open.* != .string or close.* != .string) return error.InvalidRecognizer;
            if (open.string.len == 0 or close.string.len == 0) return error.InvalidRecognizer;
            var escape: ?u8 = null;
            if (ds.table.map.get("escape")) |esc| {
                if (esc.* != .string or esc.string.len != 1) return error.InvalidRecognizer;
                escape = esc.string[0];
            }
            try defs.append(allocator, .{
                .name = name,
                .recognizer = .{ .delimited_span = .{
                    .open = try allocator.dupe(u8, open.string),
                    .close = try allocator.dupe(u8, close.string),
                    .escape = escape,
                } },
            });
            rec_count += 1;
        }
        if (t.map.get("literal_set")) |ls| {
            if (ls.* != .array) return error.InvalidRecognizer;
            if (ls.array.items.items.len == 0) return error.EmptyLiteralSet;
            var lits: std.ArrayList([]const u8) = .empty;
            for (ls.array.items.items) |item| {
                if (item != .string) return error.InvalidRecognizer;
                if (item.string.len == 0) return error.EmptyLiteralSet;
                try lits.append(allocator, try allocator.dupe(u8, item.string));
            }
            try defs.append(allocator, .{
                .name = name,
                .recognizer = .{ .literal_set = try lits.toOwnedSlice(allocator) },
            });
            rec_count += 1;
        }
        if (rec_count != 1) return error.InvalidRecognizer;
    }
    return .{ .kinds = try defs.toOwnedSlice(allocator) };
}

/// Parses a TOML grammar file from bytes into a Grammar struct.
/// All allocations use the provided arena allocator.
/// The TOML Document's internal arena is freed before returning;
/// all strings are duped into the caller's allocator.
pub fn parseGrammar(source: []const u8, allocator: std.mem.Allocator) GrammarError!Grammar {
    var doc = toml.parse(allocator, source, .{}) catch return error.InvalidToml;
    defer doc.deinit();

    const root = doc.root;

    // --- [language] (optional) ---
    const language_name: ?[]const u8 = if (root.get("language")) |lang_table| blk: {
        if (lang_table.get("name")) |name_val| {
            break :blk try allocator.dupe(u8, name_val.string);
        }
        break :blk null;
    } else null;

    // --- [keywords] (optional) ---
    var categories: std.ArrayList(KeywordCategory) = .empty;
    var all_keywords: std.ArrayList([]const u8) = .empty;

    if (root.get("keywords")) |kw_table| {
        var kw_it = kw_table.table.map.iterator();
        while (kw_it.next()) |entry| {
            var kws: std.ArrayList([]const u8) = .empty;
            for (entry.value_ptr.*.array.items.items) |item| {
                const kw = try allocator.dupe(u8, item.string);
                try kws.append(allocator, kw);
                try all_keywords.append(allocator, kw);
            }
            try categories.append(allocator, .{
                .name = try allocator.dupe(u8, entry.key_ptr.*),
                .keywords = try kws.toOwnedSlice(allocator),
            });
        }
    }

    const tokens_vocab = try parseTokensSection(root, allocator);

    // --- [[patterns]] (required) ---
    const patterns_val = root.get("patterns") orelse return error.MissingPatterns;
    var patterns: std.ArrayList(Pattern) = .empty;

    for (patterns_val.array.items.items) |pattern_table| {
        const type_name = if (pattern_table.get("type")) |t|
            try allocator.dupe(u8, t.string)
        else
            return error.MissingPatterns;

        const seq_val = pattern_table.get("sequence") orelse return error.EmptyPatternSequence;
        if (seq_val.array.items.items.len == 0) return error.EmptyPatternSequence;

        var matchers: std.ArrayList(SequenceElement) = .empty;
        var captures: std.ArrayList(Capture) = .empty;

        for (seq_val.array.items.items, 0..) |item, idx| {
            const result = try parseSequenceElementV(item.string, idx, allocator, tokens_vocab);
            try matchers.append(allocator, result.element);
            if (result.capture) |cap| {
                try captures.append(allocator, cap);
            }
        }

        try patterns.append(allocator, .{
            .type_name = type_name,
            .sequence = try matchers.toOwnedSlice(allocator),
            .captures = try captures.toOwnedSlice(allocator),
            .position = blk: {
                if (pattern_table.get("position")) |pos_val| {
                    if (std.mem.eql(u8, pos_val.string, "start")) {
                        break :blk .start;
                    } else {
                        return error.InvalidPositionValue;
                    }
                }
                break :blk null;
            },
            .prior = blk: {
                if (pattern_table.get("prior")) |v| {
                    const val = tomlToF32(v) orelse return error.InvalidPriorValue;
                    if (val <= 0.0 or val > 2.0) return error.InvalidPriorValue;
                    break :blk val;
                }
                break :blk 1.0;
            },
            .constraints = blk: {
                // Reject deprecated fields
                if (pattern_table.get("exclude") != null) return error.DeprecatedField;
                if (pattern_table.get("not_preceded_by") != null) return error.DeprecatedField;

                if (pattern_table.get("constraints")) |constraints_val| {
                    var constraint_list: std.ArrayList(Constraint) = .empty;
                    for (constraints_val.array.items.items) |ct| {
                        // Parse type
                        const type_str = if (ct.get("type")) |t| t.string else return error.InvalidConstraintType;
                        const constraint_type: ConstraintType = if (std.mem.eql(u8, type_str, "not"))
                            .not
                        else
                            return error.InvalidConstraintType;

                        // Parse depth
                        const depth_val = ct.get("depth") orelse return error.InvalidConstraintDepth;
                        const depth: u8 = @intCast(depth_val.integer);

                        // Parse field (optional)
                        const field: ?[]const u8 = if (ct.get("field")) |f|
                            try allocator.dupe(u8, f.string)
                        else
                            null;

                        // Validate depth/field combination
                        if (depth == 0 and field == null) return error.InvalidConstraintDepth;
                        if (depth > 0 and field != null) return error.InvalidConstraintField;

                        // Parse values
                        const values_val = ct.get("values") orelse return error.InvalidConstraintValues;
                        if (values_val.array.items.items.len == 0) return error.InvalidConstraintValues;
                        var vals: std.ArrayList([]const u8) = .empty;
                        for (values_val.array.items.items) |item| {
                            try vals.append(allocator, try allocator.dupe(u8, item.string));
                        }

                        try constraint_list.append(allocator, .{
                            .type = constraint_type,
                            .depth = depth,
                            .field = field,
                            .values = try vals.toOwnedSlice(allocator),
                        });
                    }
                    break :blk try constraint_list.toOwnedSlice(allocator);
                }
                break :blk &.{};
            },
        });
    }

    // --- [blocks] (optional) ---
    var blocks = BlockConfig{};
    if (root.get("blocks")) |blocks_table| {
        if (blocks_table.get("open")) |v| {
            if (v.string.len > 0) blocks.open = try allocator.dupe(u8, v.string);
        }
        if (blocks_table.get("close")) |v| {
            if (v.string.len > 0) blocks.close = try allocator.dupe(u8, v.string);
        }
        if (blocks_table.get("indentation")) |v| blocks.indentation = v.bool;
    }

    // --- [comments] (optional) ---
    var comments = CommentConfig{};
    if (root.get("comments")) |comments_table| {
        // Explicit [comments] section exists, so we start with empty config
        // (overrides defaults)
        comments = .{
            .line_prefixes = &.{}, // Will be set below if line key exists
            .block_open = null, // Will be set below if block keys exist
            .block_close = null, // Will be set below if block keys exist
        };

        // Parse line comment prefixes
        if (comments_table.get("line")) |line_val| {
            if (line_val.* != .array) return error.InvalidCommentLineType;
            if (line_val.array.items.items.len > 16) return error.TooManyLinePrefixes;

            var line_prefixes: std.ArrayList([]const u8) = .empty;
            for (line_val.array.items.items) |item| {
                if (item != .string) return error.InvalidCommentLineType;
                const prefix = item.string;
                if (prefix.len == 0) continue; // Skip empty entries
                if (prefix.len > 8) return error.CommentPrefixTooLong;
                try line_prefixes.append(allocator, try allocator.dupe(u8, prefix));
            }
            comments.line_prefixes = try line_prefixes.toOwnedSlice(allocator);
        }
        // else: no line key -> line_prefixes stays empty (already set above)

        // Parse block comment delimiters
        const has_open = comments_table.get("block_open") != null;
        const has_close = comments_table.get("block_close") != null;

        if (has_open and !has_close) return error.UnpairedBlockDelimiter;
        if (!has_open and has_close) return error.UnpairedBlockDelimiter;

        if (has_open and has_close) {
            const open_val = comments_table.get("block_open").?;
            const close_val = comments_table.get("block_close").?;

            if (open_val.* != .string) return error.InvalidCommentBlockType;
            if (close_val.* != .string) return error.InvalidCommentBlockType;

            const open = open_val.string;
            const close = close_val.string;

            if (open.len == 0 and close.len == 0) {
                // Both empty strings -> treat as absent (already null)
            } else {
                if (open.len == 0 or close.len == 0) {
                    // Only one is empty -> treat as absent pair (already null)
                } else {
                    if (open.len > 8) return error.BlockDelimiterTooLong;
                    if (close.len > 8) return error.BlockDelimiterTooLong;

                    comments.block_open = try allocator.dupe(u8, open);
                    comments.block_close = try allocator.dupe(u8, close);
                }
            }
        }
        // else: no block keys -> null (already set above)
    }
    // else: no [comments] section -> use default CommentConfig{}


    return Grammar{
        .language_name = language_name,
        .keyword_categories = try categories.toOwnedSlice(allocator),
        .keyword_table = try all_keywords.toOwnedSlice(allocator),
        .patterns = try patterns.toOwnedSlice(allocator),
        .blocks = blocks,
        .weights = blk: {
            var w = EvidenceWeights{};
            if (root.get("weights")) |wt| {
                if (wt.get("keyword")) |v| {
                    const val = tomlToF32(v) orelse return error.InvalidWeightValue;
                    if (val < 0.0) return error.InvalidWeightValue;
                    w.keyword = val;
                }
                if (wt.get("identifier")) |v| {
                    const val = tomlToF32(v) orelse return error.InvalidWeightValue;
                    if (val < 0.0) return error.InvalidWeightValue;
                    w.identifier = val;
                }
                if (wt.get("symbol")) |v| {
                    const val = tomlToF32(v) orelse return error.InvalidWeightValue;
                    if (val < 0.0) return error.InvalidWeightValue;
                    w.symbol = val;
                }
                if (wt.get("block")) |v| {
                    const val = tomlToF32(v) orelse return error.InvalidWeightValue;
                    if (val < 0.0) return error.InvalidWeightValue;
                    w.block = val;
                }
                if (wt.get("relaxed_keyword")) |v| {
                    const val = tomlToF32(v) orelse return error.InvalidWeightValue;
                    if (val < 0.0) return error.InvalidWeightValue;
                    w.relaxed_keyword = val;
                }
            }
            break :blk w;
        },
        .comments = comments,
        .tokens = tokens_vocab,
    };
}

/// Formats a Grammar struct back into a TOML string.
/// Used for round-trip testing.
pub fn formatGrammar(grammar: Grammar, allocator: std.mem.Allocator) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    const w = &aw.writer;

    // [language]
    if (grammar.language_name) |name| {
        try w.writeAll("[language]\nname = \"");
        try w.writeAll(name);
        try w.writeAll("\"\n\n");
    }

    // [keywords]
    if (grammar.keyword_categories.len > 0) {
        try w.writeAll("[keywords]\n");
        for (grammar.keyword_categories) |cat| {
            try w.writeAll(cat.name);
            try w.writeAll(" = [");
            for (cat.keywords, 0..) |kw, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll("\"");
                try w.writeAll(kw);
                try w.writeAll("\"");
            }
            try w.writeAll("]\n");
        }
        try w.writeAll("\n");
    }

    // [[patterns]]
    for (grammar.patterns) |pattern| {
        try w.writeAll("[[patterns]]\ntype = \"");
        try w.writeAll(pattern.type_name);
        try w.writeAll("\"\nsequence = [");
        for (pattern.sequence, 0..) |elem, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll("\"");
            const m = elem.matcher;
            if (m.capture) |cap| {
                // Capture: $field:KIND[(sep=..., suffix=...)]
                try w.writeAll("$");
                try w.writeAll(cap.field_name);
                try w.writeAll(":");
                if (m.kind == .one) {
                    switch (m.kind.one) {
                        .identifier => try w.writeAll("IDENTIFIER"),
                        .number => try w.writeAll("NUMBER"),
                        .string => try w.writeAll("STRING"),
                        else => {},
                    }
                } else if (m.kind == .id) {
                    try w.writeAll(vocabKindName(grammar, m.kind.id));
                }
                if (cap.separator != null or cap.suffix_set != null) {
                    try w.writeAll("(");
                    if (cap.separator) |sep| {
                        try w.writeAll("sep=\\\"");
                        try writeEscaped(w, sep);
                        try w.writeAll("\\\"");
                    }
                    if (cap.suffix_set) |suf| {
                        if (cap.separator != null) try w.writeAll(", ");
                        try w.writeAll("suffix=\\\"");
                        try writeEscaped(w, suf);
                        try w.writeAll("\\\"");
                    }
                    try w.writeAll(")");
                }
            } else switch (m.kind) {
                .any => {},
                .one => |k| switch (k) {
                    .identifier => switch (m.text) {
                        .any => try w.writeAll("identifier"),
                        .exact => |t| {
                            try w.writeAll(t);
                            try w.writeAll(":IDENTIFIER");
                        },
                    },
                    .number => switch (m.text) {
                        .any => try w.writeAll("number"),
                        .exact => |t| {
                            try w.writeAll(t);
                            try w.writeAll(":NUMBER");
                        },
                    },
                    .string => switch (m.text) {
                        .any => try w.writeAll("string"),
                        .exact => |t| {
                            try w.writeAll(t);
                            try w.writeAll(":STRING");
                        },
                    },
                    .keyword => {
                        if (m.text == .exact) try w.writeAll(m.text.exact);
                    },
                    .operator, .symbol, .delimiter => {
                        if (m.text == .exact) try w.writeAll(m.text.exact);
                    },
                    else => {},
                },
                .punctuation => {
                    if (m.text == .exact) try w.writeAll(m.text.exact);
                },
                .id => |id| {
                    try w.writeAll(vocabKindName(grammar, id));
                },
            }
            if (elem.is_optional) try w.writeAll("?");
            try w.writeAll("\"");
        }
        try w.writeAll("]\n");

        // position field
        if (pattern.position) |pos| {
            switch (pos) {
                .start => try w.writeAll("position = \"start\"\n"),
            }
        }

        // prior field (only when non-default)
        if (pattern.prior != 1.0) {
            try w.print("prior = {d}\n", .{pattern.prior});
        }

        // constraints
        for (pattern.constraints) |constraint| {
            try w.writeAll("\n[[patterns.constraints]]\n");
            try w.writeAll("type = \"");
            switch (constraint.type) {
                .not => try w.writeAll("not"),
            }
            try w.writeAll("\"\n");
            try w.print("depth = {d}\n", .{constraint.depth});
            if (constraint.field) |field| {
                try w.writeAll("field = \"");
                try w.writeAll(field);
                try w.writeAll("\"\n");
            }
            try w.writeAll("values = [");
            for (constraint.values, 0..) |val, j| {
                if (j > 0) try w.writeAll(", ");
                try w.writeAll("\"");
                try w.writeAll(val);
                try w.writeAll("\"");
            }
            try w.writeAll("]\n");
        }

        try w.writeAll("\n");
    }

    // [blocks]
    if (grammar.blocks.open != null or grammar.blocks.close != null or grammar.blocks.indentation) {
        try w.writeAll("[blocks]\n");
        if (grammar.blocks.open) |open| {
            try w.writeAll("open = \"");
            try w.writeAll(open);
            try w.writeAll("\"\n");
        }
        if (grammar.blocks.close) |close| {
            try w.writeAll("close = \"");
            try w.writeAll(close);
            try w.writeAll("\"\n");
        }
        if (grammar.blocks.indentation) {
            try w.writeAll("indentation = true\n");
        }
    }

    // [comments] — always serialize when present (even if equals default)
    if (grammar.comments.line_prefixes.len > 0 or grammar.comments.block_open != null) {
        try w.writeAll("\n[comments]\n");

        // line prefixes
        if (grammar.comments.line_prefixes.len > 0) {
            try w.writeAll("line = [");
            for (grammar.comments.line_prefixes, 0..) |prefix, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll("\"");
                // Escape backslash and double-quote characters
                for (prefix) |ch| {
                    switch (ch) {
                        '\\' => try w.writeAll("\\\\"),
                        '"' => try w.writeAll("\\\""),
                        else => try w.writeByte(ch),
                    }
                }
                try w.writeAll("\"");
            }
            try w.writeAll("]\n");
        }

        // block delimiters
        if (grammar.comments.block_open) |open| {
            try w.writeAll("block_open = \"");
            for (open) |ch| {
                switch (ch) {
                    '\\' => try w.writeAll("\\\\"),
                    '"' => try w.writeAll("\\\""),
                    else => try w.writeByte(ch),
                }
            }
            try w.writeAll("\"\n");
        }
        if (grammar.comments.block_close) |close| {
            try w.writeAll("block_close = \"");
            for (close) |ch| {
                switch (ch) {
                    '\\' => try w.writeAll("\\\\"),
                    '"' => try w.writeAll("\\\""),
                    else => try w.writeByte(ch),
                }
            }
            try w.writeAll("\"\n");
        }
    }

    // [weights] — only serialize when values differ from defaults
    {
        const defaults = EvidenceWeights{};
        const wts = grammar.weights;
        if (wts.keyword != defaults.keyword or
            wts.identifier != defaults.identifier or
            wts.symbol != defaults.symbol or
            wts.block != defaults.block or
            wts.relaxed_keyword != defaults.relaxed_keyword)
        {
            try w.writeAll("\n[weights]\n");
            if (wts.keyword != defaults.keyword) {
                try w.print("keyword = {d}\n", .{wts.keyword});
            }
            if (wts.identifier != defaults.identifier) {
                try w.print("identifier = {d}\n", .{wts.identifier});
            }
            if (wts.symbol != defaults.symbol) {
                try w.print("symbol = {d}\n", .{wts.symbol});
            }
            if (wts.block != defaults.block) {
                try w.print("block = {d}\n", .{wts.block});
            }
            if (wts.relaxed_keyword != defaults.relaxed_keyword) {
                try w.print("relaxed_keyword = {d}\n", .{wts.relaxed_keyword});
            }
        }
    }

    // [tokens] — serialize the grammar-declared vocabulary when present
    if (grammar.tokens) |vocab| {
        try w.writeAll("\n[tokens]\n");
        for (vocab.kinds) |def| {
            try w.writeAll("[tokens.");
            try w.writeAll(def.name);
            try w.writeAll("]\n");
            switch (def.recognizer) {
                .char_class_run => |r| {
                    try w.writeAll("char_class_run = { start = \"");
                    try tokenizer.writeCharSetSpec(r.start, w);
                    try w.writeAll("\", \"continue\" = \"");
                    try tokenizer.writeCharSetSpec(r.cont, w);
                    try w.writeAll("\" }\n");
                },
                .delimited_span => |d| {
                    try w.writeAll("delimited_span = { open = \"");
                    try w.writeAll(d.open);
                    try w.writeAll("\", close = \"");
                    try w.writeAll(d.close);
                    try w.writeAll("\"");
                    if (d.escape) |esc| {
                        try w.writeAll(", escape = \"");
                        try tokenizer.writeCharSpec(esc, w);
                        try w.writeAll("\"");
                    }
                    try w.writeAll(" }\n");
                },
                .literal_set => |lits| {
                    try w.writeAll("literal_set = [");
                    for (lits, 0..) |lit, j| {
                        if (j > 0) try w.writeAll(", ");
                        try w.writeAll("\"");
                        for (lit) |ch| {
                            switch (ch) {
                                '\\' => try w.writeAll("\\\\"),
                                '"' => try w.writeAll("\\\""),
                                else => try w.writeByte(ch),
                            }
                        }
                        try w.writeAll("\"");
                    }
                    try w.writeAll("]\n");
                },
            }
        }
    }

    return aw.toOwnedSlice();
}

// --- Unit Tests ---

const testing = std.testing;

test "parseGrammar: full Rust-style grammar" {
    const source =
        \\[language]
        \\name = "rust"
        \\
        \\[keywords]
        \\function = ["fn"]
        \\struct = ["struct"]
        \\import = ["use"]
        \\
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[[patterns]]
        \\type = "struct"
        \\sequence = ["struct", "$name:IDENTIFIER"]
        \\
        \\[blocks]
        \\open = "{"
        \\close = "}"
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqualStrings("rust", grammar.language_name.?);
    try testing.expectEqual(@as(usize, 3), grammar.keyword_categories.len);
    try testing.expectEqual(@as(usize, 3), grammar.keyword_table.len);
    try testing.expectEqual(@as(usize, 2), grammar.patterns.len);
    try testing.expectEqualStrings("function", grammar.patterns[0].type_name);
    try testing.expectEqual(@as(usize, 3), grammar.patterns[0].sequence.len);
    try testing.expectEqual(@as(usize, 1), grammar.patterns[0].captures.len);
    try testing.expectEqualStrings("name", grammar.patterns[0].captures[0].field_name);
    try testing.expectEqualStrings("{", grammar.blocks.open.?);
    try testing.expectEqualStrings("}", grammar.blocks.close.?);
}

test "parseGrammar: patterns only (minimal grammar)" {
    const source =
        \\[[patterns]]
        \\type = "call"
        \\sequence = ["identifier", "("]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expect(grammar.language_name == null);
    try testing.expectEqual(@as(usize, 0), grammar.keyword_categories.len);
    try testing.expectEqual(@as(usize, 0), grammar.keyword_table.len);
    try testing.expectEqual(@as(usize, 1), grammar.patterns.len);
    try testing.expectEqualStrings("call", grammar.patterns[0].type_name);
}

test "parseGrammar: capture parsing" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    const seq = grammar.patterns[0].sequence;
    try testing.expectEqual(@as(usize, 3), seq.len);
    try testing.expect(seq[0].matcher.kind == .one and seq[0].matcher.kind.one == .keyword);
    try testing.expect(seq[1].matcher.capture != null);
    try testing.expectEqualStrings("name", seq[1].matcher.capture.?.field_name);
    try testing.expectEqual(@as(usize, 1), seq[1].matcher.capture.?.position);
    try testing.expect(seq[2].matcher.kind == .punctuation);
}

test "parseGrammar: identifier_literal parsing" {
    const source =
        \\[[patterns]]
        \\type = "call"
        \\sequence = ["Config:IDENTIFIER", "identifier"]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    const seq = grammar.patterns[0].sequence;
    try testing.expectEqual(@as(usize, 2), seq.len);
    try testing.expect(seq[0].matcher.kind == .one and seq[0].matcher.kind.one == .identifier and seq[0].matcher.text == .exact);
    try testing.expectEqualStrings("Config", seq[0].matcher.text.exact);
    try testing.expect(seq[1].matcher.kind == .one and seq[1].matcher.kind.one == .identifier and seq[1].matcher.text == .any);
}

test "parseGrammar: missing patterns returns error" {
    const source =
        \\[language]
        \\name = "test"
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());
    try testing.expectError(error.MissingPatterns, result);
}

test "parseGrammar: empty sequence returns error" {
    const source =
        \\[[patterns]]
        \\type = "bad"
        \\sequence = []
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());
    try testing.expectError(error.EmptyPatternSequence, result);
}

test "parseGrammar: invalid TOML returns error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar("this is not valid toml [[[", arena.allocator());
    try testing.expectError(error.InvalidToml, result);
}

test "parseGrammar: keyword flattening" {
    const source =
        \\[keywords]
        \\function = ["fn", "def"]
        \\class = ["class", "struct"]
        \\
        \\[[patterns]]
        \\type = "x"
        \\sequence = ["fn", "identifier"]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqual(@as(usize, 4), grammar.keyword_table.len);
    // All keywords from both categories should be in the flat table
    var found_fn = false;
    var found_def = false;
    var found_class = false;
    var found_struct = false;
    for (grammar.keyword_table) |kw| {
        if (std.mem.eql(u8, kw, "fn")) found_fn = true;
        if (std.mem.eql(u8, kw, "def")) found_def = true;
        if (std.mem.eql(u8, kw, "class")) found_class = true;
        if (std.mem.eql(u8, kw, "struct")) found_struct = true;
    }
    try testing.expect(found_fn);
    try testing.expect(found_def);
    try testing.expect(found_class);
    try testing.expect(found_struct);
}

test "parseGrammar: position = start" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["$name:IDENTIFIER", "("]
        \\position = "start"
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqual(@as(usize, 1), grammar.patterns.len);
    try testing.expect(grammar.patterns[0].position != null);
    try testing.expectEqual(PositionConstraint.start, grammar.patterns[0].position.?);
}

test "parseGrammar: invalid position value returns error" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["$name:IDENTIFIER", "("]
        \\position = "invalid"
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());
    try testing.expectError(error.InvalidPositionValue, result);
}

test "parseGrammar: pattern with no constraints defaults to empty" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["$name:IDENTIFIER", "("]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqual(@as(usize, 0), grammar.patterns[0].constraints.len);
}

test "parseGrammar: Phase 2 grammar backward compatibility (no position/constraints)" {
    const source =
        \\[[patterns]]
        \\type = "call"
        \\sequence = ["identifier", "("]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expect(grammar.patterns[0].position == null);
    try testing.expectEqual(@as(usize, 0), grammar.patterns[0].constraints.len);
}

test "parseGrammar: depth=0 constraint with field and values" {
    const source =
        \\[[patterns]]
        \\type = "method"
        \\sequence = ["$name:IDENTIFIER", "("]
        \\
        \\[[patterns.constraints]]
        \\type = "not"
        \\depth = 0
        \\field = "name"
        \\values = ["print", "RegExp"]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqual(@as(usize, 1), grammar.patterns[0].constraints.len);
    const c = grammar.patterns[0].constraints[0];
    try testing.expectEqual(ConstraintType.not, c.type);
    try testing.expectEqual(@as(u8, 0), c.depth);
    try testing.expectEqualStrings("name", c.field.?);
    try testing.expectEqual(@as(usize, 2), c.values.len);
    try testing.expectEqualStrings("print", c.values[0]);
    try testing.expectEqualStrings("RegExp", c.values[1]);
}

test "parseGrammar: depth=1 constraint (no field)" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["$name:IDENTIFIER", "("]
        \\
        \\[[patterns.constraints]]
        \\type = "not"
        \\depth = 1
        \\values = ["fun", "="]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqual(@as(usize, 1), grammar.patterns[0].constraints.len);
    const c = grammar.patterns[0].constraints[0];
    try testing.expectEqual(ConstraintType.not, c.type);
    try testing.expectEqual(@as(u8, 1), c.depth);
    try testing.expect(c.field == null);
    try testing.expectEqual(@as(usize, 2), c.values.len);
    try testing.expectEqualStrings("fun", c.values[0]);
    try testing.expectEqualStrings("=", c.values[1]);
}

test "parseGrammar: depth=4 constraint (lookback window)" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["$name:IDENTIFIER", "("]
        \\
        \\[[patterns.constraints]]
        \\type = "not"
        \\depth = 4
        \\values = ["-spec", "-type"]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqual(@as(usize, 1), grammar.patterns[0].constraints.len);
    const c = grammar.patterns[0].constraints[0];
    try testing.expectEqual(ConstraintType.not, c.type);
    try testing.expectEqual(@as(u8, 4), c.depth);
    try testing.expect(c.field == null);
    try testing.expectEqual(@as(usize, 2), c.values.len);
    try testing.expectEqualStrings("-spec", c.values[0]);
    try testing.expectEqualStrings("-type", c.values[1]);
}

test "parseGrammar: multiple constraints on one pattern" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["$name:IDENTIFIER", "("]
        \\position = "start"
        \\
        \\[[patterns.constraints]]
        \\type = "not"
        \\depth = 4
        \\values = ["-spec", "-type"]
        \\
        \\[[patterns.constraints]]
        \\type = "not"
        \\depth = 1
        \\values = ["fun", "="]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqual(@as(usize, 2), grammar.patterns[0].constraints.len);

    const c0 = grammar.patterns[0].constraints[0];
    try testing.expectEqual(@as(u8, 4), c0.depth);
    try testing.expectEqual(@as(usize, 2), c0.values.len);
    try testing.expectEqualStrings("-spec", c0.values[0]);

    const c1 = grammar.patterns[0].constraints[1];
    try testing.expectEqual(@as(u8, 1), c1.depth);
    try testing.expectEqual(@as(usize, 2), c1.values.len);
    try testing.expectEqualStrings("fun", c1.values[0]);

    // Position should also be parsed
    try testing.expect(grammar.patterns[0].position != null);
    try testing.expectEqual(PositionConstraint.start, grammar.patterns[0].position.?);
}

test "parseGrammar: pattern with no constraints defaults to empty slice" {
    const source =
        \\[[patterns]]
        \\type = "call"
        \\sequence = ["identifier", "("]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqual(@as(usize, 0), grammar.patterns[0].constraints.len);
    try testing.expect(grammar.patterns[0].position == null);
}

// --- Formatter: Constraint Serialization Tests ---

test "formatGrammar: depth=0 constraint with field serialized" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const grammar = Grammar{
        .language_name = null,
        .keyword_categories = &.{},
        .keyword_table = &.{},
        .patterns = &.{
            .{
                .type_name = "method",
                .sequence = &.{
                    .{ .matcher = .{ .kind = .{ .one = .identifier }, .capture = .{ .field_name = "name", .position = 0 } } },
                    .{ .matcher = .{ .kind = .punctuation, .text = .{ .exact = "(" } } },
                },
                .captures = &.{
                    .{ .field_name = "name", .position = 0 },
                },
                .constraints = &.{
                    .{
                        .type = .not,
                        .depth = 0,
                        .field = "name",
                        .values = &.{ "print", "RegExp" },
                    },
                },
            },
        },
        .blocks = .{},
    };

    const toml_str = try formatGrammar(grammar, alloc);

    // Verify the output contains the constraint section with field
    try testing.expect(std.mem.indexOf(u8, toml_str, "[[patterns.constraints]]") != null);
    try testing.expect(std.mem.indexOf(u8, toml_str, "type = \"not\"") != null);
    try testing.expect(std.mem.indexOf(u8, toml_str, "depth = 0") != null);
    try testing.expect(std.mem.indexOf(u8, toml_str, "field = \"name\"") != null);
    try testing.expect(std.mem.indexOf(u8, toml_str, "values = [\"print\", \"RegExp\"]") != null);

    // Round-trip: parse back and verify
    const parsed = try parseGrammar(toml_str, alloc);
    try testing.expectEqual(@as(usize, 1), parsed.patterns[0].constraints.len);
    const c = parsed.patterns[0].constraints[0];
    try testing.expectEqual(ConstraintType.not, c.type);
    try testing.expectEqual(@as(u8, 0), c.depth);
    try testing.expectEqualStrings("name", c.field.?);
    try testing.expectEqual(@as(usize, 2), c.values.len);
    try testing.expectEqualStrings("print", c.values[0]);
    try testing.expectEqualStrings("RegExp", c.values[1]);
}

test "formatGrammar: depth=1 constraint without field serialized" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const grammar = Grammar{
        .language_name = null,
        .keyword_categories = &.{},
        .keyword_table = &.{},
        .patterns = &.{
            .{
                .type_name = "function",
                .sequence = &.{
                    .{ .matcher = .{ .kind = .{ .one = .identifier }, .capture = .{ .field_name = "name", .position = 0 } } },
                    .{ .matcher = .{ .kind = .punctuation, .text = .{ .exact = "(" } } },
                },
                .captures = &.{
                    .{ .field_name = "name", .position = 0 },
                },
                .constraints = &.{
                    .{
                        .type = .not,
                        .depth = 1,
                        .values = &.{ "fun", "=" },
                    },
                },
            },
        },
        .blocks = .{},
    };

    const toml_str = try formatGrammar(grammar, alloc);

    // Verify the output contains the constraint section without field
    try testing.expect(std.mem.indexOf(u8, toml_str, "[[patterns.constraints]]") != null);
    try testing.expect(std.mem.indexOf(u8, toml_str, "type = \"not\"") != null);
    try testing.expect(std.mem.indexOf(u8, toml_str, "depth = 1") != null);
    try testing.expect(std.mem.indexOf(u8, toml_str, "field = ") == null);
    try testing.expect(std.mem.indexOf(u8, toml_str, "values = [\"fun\", \"=\"]") != null);

    // Round-trip: parse back and verify
    const parsed = try parseGrammar(toml_str, alloc);
    try testing.expectEqual(@as(usize, 1), parsed.patterns[0].constraints.len);
    const c = parsed.patterns[0].constraints[0];
    try testing.expectEqual(ConstraintType.not, c.type);
    try testing.expectEqual(@as(u8, 1), c.depth);
    try testing.expect(c.field == null);
    try testing.expectEqual(@as(usize, 2), c.values.len);
    try testing.expectEqualStrings("fun", c.values[0]);
    try testing.expectEqualStrings("=", c.values[1]);
}

test "formatGrammar: multiple constraints on one pattern" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const grammar = Grammar{
        .language_name = null,
        .keyword_categories = &.{},
        .keyword_table = &.{},
        .patterns = &.{
            .{
                .type_name = "function",
                .sequence = &.{
                    .{ .matcher = .{ .kind = .{ .one = .identifier }, .capture = .{ .field_name = "name", .position = 0 } } },
                    .{ .matcher = .{ .kind = .punctuation, .text = .{ .exact = "(" } } },
                },
                .captures = &.{
                    .{ .field_name = "name", .position = 0 },
                },
                .position = .start,
                .constraints = &.{
                    .{
                        .type = .not,
                        .depth = 4,
                        .values = &.{ "-spec", "-type" },
                    },
                    .{
                        .type = .not,
                        .depth = 1,
                        .values = &.{ "fun", "=" },
                    },
                },
            },
        },
        .blocks = .{},
    };

    const toml_str = try formatGrammar(grammar, alloc);

    // Should contain two [[patterns.constraints]] sections
    // Count occurrences
    var count: usize = 0;
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, toml_str, search_start, "[[patterns.constraints]]")) |pos| {
        count += 1;
        search_start = pos + 1;
    }
    try testing.expectEqual(@as(usize, 2), count);

    // Verify both depth values appear
    try testing.expect(std.mem.indexOf(u8, toml_str, "depth = 4") != null);
    try testing.expect(std.mem.indexOf(u8, toml_str, "depth = 1") != null);

    // Round-trip: parse back and verify
    const parsed = try parseGrammar(toml_str, alloc);
    try testing.expectEqual(@as(usize, 2), parsed.patterns[0].constraints.len);
    try testing.expectEqual(@as(u8, 4), parsed.patterns[0].constraints[0].depth);
    try testing.expectEqual(@as(u8, 1), parsed.patterns[0].constraints[1].depth);
    // Position should also survive
    try testing.expect(parsed.patterns[0].position != null);
    try testing.expectEqual(PositionConstraint.start, parsed.patterns[0].position.?);
}

test "formatGrammar: no constraints emits no constraints section" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const grammar = Grammar{
        .language_name = null,
        .keyword_categories = &.{},
        .keyword_table = &.{},
        .patterns = &.{
            .{
                .type_name = "call",
                .sequence = &.{
                    .{ .matcher = .{ .kind = .{ .one = .identifier } } },
                    .{ .matcher = .{ .kind = .punctuation, .text = .{ .exact = "(" } } },
                },
                .captures = &.{},
            },
        },
        .blocks = .{},
    };

    const toml_str = try formatGrammar(grammar, alloc);

    // Should NOT contain any constraints section
    try testing.expect(std.mem.indexOf(u8, toml_str, "[[patterns.constraints]]") == null);
    try testing.expect(std.mem.indexOf(u8, toml_str, "constraints") == null);

    // Round-trip: parse back and verify empty constraints
    const parsed = try parseGrammar(toml_str, alloc);
    try testing.expectEqual(@as(usize, 0), parsed.patterns[0].constraints.len);
}

// --- Property Tests ---

const minish = @import("minish");
const gen = minish.gen;

// Feature: phase2-grammar-automaton, Property 1: Grammar TOML round-trip
test "property: grammar TOML round-trip" {
    // Generate a random language name
    const name_gen = gen.string(.{ .min_len = 1, .max_len = 16, .charset = .alpha });

    try minish.check(testing.allocator, name_gen, struct {
        fn prop(lang_name: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // Build a Grammar struct with the random name and a fixed pattern
            const original = Grammar{
                .language_name = lang_name,
                .keyword_categories = &.{
                    .{ .name = "function", .keywords = &.{"fn"} },
                },
                .keyword_table = &.{"fn"},
                .patterns = &.{
                    .{
                        .type_name = "function",
                        .sequence = &.{
                            .{ .matcher = .{ .kind = .{ .one = .keyword }, .text = .{ .exact = "fn" } } },
                            .{ .matcher = .{ .kind = .{ .one = .identifier }, .capture = .{ .field_name = "name", .position = 1 } } },
                            .{ .matcher = .{ .kind = .punctuation, .text = .{ .exact = "(" } } },
                        },
                        .captures = &.{
                            .{ .field_name = "name", .position = 1 },
                        },
                    },
                },
                .blocks = .{ .open = "{", .close = "}" },
            };

            // Round-trip: format → parse
            const toml_str = try formatGrammar(original, alloc);
            const parsed = try parseGrammar(toml_str, alloc);

            // Verify equivalence
            try testing.expectEqualStrings(lang_name, parsed.language_name.?);
            try testing.expectEqual(original.keyword_categories.len, parsed.keyword_categories.len);
            try testing.expectEqual(original.keyword_table.len, parsed.keyword_table.len);
            try testing.expectEqual(original.patterns.len, parsed.patterns.len);
            try testing.expectEqualStrings("function", parsed.patterns[0].type_name);
            try testing.expectEqual(original.patterns[0].sequence.len, parsed.patterns[0].sequence.len);
            try testing.expectEqual(original.patterns[0].captures.len, parsed.patterns[0].captures.len);
            try testing.expectEqualStrings("{", parsed.blocks.open.?);
            try testing.expectEqualStrings("}", parsed.blocks.close.?);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: configurable-comment-prefixes, Property 1: Comment Config Round-Trip
// **Validates: Requirements 6.4**
test "property: comment config round-trip" {
    // Generate a random valid CommentConfig: prefix count seed, per-prefix length seed,
    // and whether block delimiters are present. Map seeds into valid ranges inside the body.
    const cfg_gen = comptime gen.tuple3(u8, u8, bool, gen.intRange(u8, 0, 255), gen.intRange(u8, 0, 255), gen.boolean());

    try minish.check(testing.allocator, cfg_gen, struct {
        fn prop(vals: struct { u8, u8, bool }) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // 0-16 prefixes
            const count: usize = @as(usize, vals[0]) % 17;
            // per-prefix length 1-8
            const prefix_len: usize = @as(usize, vals[1]) % 8 + 1;
            const has_block: bool = vals[2];

            // An all-empty config (no prefixes AND no block delimiters) is intentionally
            // serialized as NO [comments] section, which parses back as CommentConfig.default
            // (documented behavior). That case is not a faithful round-trip of the empty config,
            // so skip it here — it is covered by the dedicated formatGrammar unit test.
            if (count == 0 and !has_block) return;

            // Build arena-allocated ASCII prefixes. Avoid `"` and `\` so escaping is not
            // under test here (a separate unit test already covers escaping).
            const prefixes = try alloc.alloc([]const u8, count);
            for (prefixes, 0..) |*p, i| {
                const buf = try alloc.alloc(u8, prefix_len);
                for (buf) |*ch| {
                    // Deterministic printable ASCII letters based on index
                    ch.* = 'a' + @as(u8, @intCast(i % 26));
                }
                p.* = buf;
            }

            const cfg = CommentConfig{
                .line_prefixes = prefixes,
                .block_open = if (has_block) "/*" else null,
                .block_close = if (has_block) "*/" else null,
            };

            // Assemble a minimal Grammar (one pattern, required) carrying the config.
            const original = Grammar{
                .language_name = "test",
                .keyword_categories = &.{},
                .keyword_table = &.{},
                .patterns = &.{
                    .{
                        .type_name = "function",
                        .sequence = &.{
                            .{ .matcher = .{ .kind = .{ .one = .keyword }, .text = .{ .exact = "fn" } } },
                        },
                        .captures = &.{},
                    },
                },
                .blocks = .{},
                .weights = .{},
                .comments = cfg,
            };

            const toml_str = try formatGrammar(original, alloc);
            const parsed = try parseGrammar(toml_str, alloc);

            // Line prefixes round-trip exactly.
            try testing.expectEqual(cfg.line_prefixes.len, parsed.comments.line_prefixes.len);
            for (cfg.line_prefixes, 0..) |p, i| {
                try testing.expectEqualStrings(p, parsed.comments.line_prefixes[i]);
            }

            // Block delimiters: both null or both equal.
            if (cfg.block_open) |open| {
                try testing.expect(parsed.comments.block_open != null);
                try testing.expectEqualStrings(open, parsed.comments.block_open.?);
                try testing.expectEqualStrings(cfg.block_close.?, parsed.comments.block_close.?);
            } else {
                try testing.expect(parsed.comments.block_open == null);
                try testing.expect(parsed.comments.block_close == null);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: configurable-comment-prefixes, Property 7: Unpaired Block Delimiter Rejection
// **Validates: Requirements 1.5**
test "property: unpaired block delimiter rejection" {
    // Choose which single block key to emit: true = block_open only, false = block_close only.
    const which_gen = comptime gen.boolean();

    try minish.check(testing.allocator, which_gen, struct {
        fn prop(open_only: bool) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            var aw: std.Io.Writer.Allocating = .init(alloc);
            const w = &aw.writer;
            // Minimal [[patterns]] block so parseGrammar does not fail with MissingPatterns.
            try w.writeAll("[[patterns]]\ntype = \"x\"\nsequence = [\"identifier\"]\n\n[comments]\n");
            if (open_only) {
                try w.writeAll("block_open = \"/*\"\n");
            } else {
                try w.writeAll("block_close = \"*/\"\n");
            }
            const source = aw.written();

            try testing.expectError(error.UnpairedBlockDelimiter, parseGrammar(source, alloc));
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase3-multi-language-patterns, Property 2: Grammar TOML round-trip with position
test "property: grammar TOML round-trip with position" {
    // Generate a random boolean for position (true = .start, false = null)
    const bool_gen = comptime gen.boolean();

    try minish.check(testing.allocator, bool_gen, struct {
        fn prop(has_position: bool) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const original = Grammar{
                .language_name = "test",
                .keyword_categories = &.{},
                .keyword_table = &.{},
                .patterns = &.{
                    .{
                        .type_name = "function",
                        .sequence = &.{
                            .{ .matcher = .{ .kind = .{ .one = .keyword }, .text = .{ .exact = "fn" } } },
                            .{ .matcher = .{ .kind = .{ .one = .identifier }, .capture = .{ .field_name = "name", .position = 1 } } },
                            .{ .matcher = .{ .kind = .punctuation, .text = .{ .exact = "(" } } },
                        },
                        .captures = &.{
                            .{ .field_name = "name", .position = 1 },
                        },
                        .position = if (has_position) .start else null,
                    },
                },
                .blocks = .{},
            };

            // Round-trip: format → parse
            const toml_str = try formatGrammar(original, alloc);
            const parsed = try parseGrammar(toml_str, alloc);

            // Verify position round-trips
            if (has_position) {
                try testing.expect(parsed.patterns[0].position != null);
                try testing.expectEqual(PositionConstraint.start, parsed.patterns[0].position.?);
            } else {
                try testing.expect(parsed.patterns[0].position == null);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase2-grammar-automaton, Property 2: Keyword table flattening
test "property: keyword table flattening" {
    // Generate random keyword strings
    const kw_gen = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha });

    try minish.check(testing.allocator, kw_gen, struct {
        fn prop(kw: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // Build TOML with two categories each containing the random keyword
            var aw: std.Io.Writer.Allocating = .init(alloc);
            const w = &aw.writer;
            try w.writeAll("[keywords]\ncat_a = [\"");
            try w.writeAll(kw);
            try w.writeAll("\"]\ncat_b = [\"other\"]\n\n[[patterns]]\ntype = \"x\"\nsequence = [\"identifier\"]\n");
            const source = aw.written();

            const grammar = try parseGrammar(source, alloc);

            // Flat table should contain both keywords
            try testing.expectEqual(@as(usize, 2), grammar.keyword_table.len);
            var found_kw = false;
            var found_other = false;
            for (grammar.keyword_table) |k| {
                if (std.mem.eql(u8, k, kw)) found_kw = true;
                if (std.mem.eql(u8, k, "other")) found_other = true;
            }
            try testing.expect(found_kw);
            try testing.expect(found_other);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: phase2-grammar-automaton, Property 3: Invalid TOML rejection
test "property: invalid TOML rejection" {
    // Generate random strings that are unlikely to be valid TOML with [[patterns]]
    const garbage_gen = gen.string(.{ .min_len = 1, .max_len = 64, .charset = .ascii });

    try minish.check(testing.allocator, garbage_gen, struct {
        fn prop(input: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();

            const result = parseGrammar(input, arena.allocator());
            // Should either fail with InvalidToml or MissingPatterns (valid TOML but no patterns)
            // It should NOT succeed unless the random string happens to be a valid grammar
            if (result) |grammar| {
                // If it somehow parsed, it must at least have patterns
                try testing.expect(grammar.patterns.len > 0);
            } else |err| {
                try testing.expect(err == error.InvalidToml or err == error.MissingPatterns);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// --- Example Grammar File Verification Tests ---

test "example grammar: erlang.toml parses without errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const file = try std.Io.Dir.cwd().openFile(testing.io, "examples/grammars/erlang.toml", .{});
    defer file.close(testing.io);
    var fbuf: [4096]u8 = undefined;
    var file_reader = file.reader(testing.io, &fbuf);
    const source = try file_reader.interface.allocRemaining(alloc, .unlimited);
    const grammar = try parseGrammar(source, alloc);
    try testing.expectEqualStrings("erlang", grammar.language_name.?);
    try testing.expect(grammar.patterns.len >= 7);
    try testing.expect(grammar.keyword_table.len > 0);
    try testing.expectEqualStrings("begin", grammar.blocks.open.?);
    try testing.expectEqualStrings("end", grammar.blocks.close.?);
    // Verify function pattern has position and constraints
    for (grammar.patterns) |p| {
        if (std.mem.eql(u8, p.type_name, "function")) {
            try testing.expect(p.position != null);
            try testing.expectEqual(PositionConstraint.start, p.position.?);
            // Verify constraints replaced exclude/not_preceded_by
            try testing.expectEqual(@as(usize, 2), p.constraints.len);
            // First constraint: depth=4 lookback (replaces exclude)
            try testing.expectEqual(ConstraintType.not, p.constraints[0].type);
            try testing.expectEqual(@as(u8, 4), p.constraints[0].depth);
            try testing.expect(p.constraints[0].field == null);
            try testing.expectEqual(@as(usize, 2), p.constraints[0].values.len);
            try testing.expectEqualStrings("-spec", p.constraints[0].values[0]);
            try testing.expectEqualStrings("-type", p.constraints[0].values[1]);
            // Second constraint: depth=1 preceding token (replaces not_preceded_by)
            try testing.expectEqual(ConstraintType.not, p.constraints[1].type);
            try testing.expectEqual(@as(u8, 1), p.constraints[1].depth);
            try testing.expect(p.constraints[1].field == null);
            try testing.expectEqual(@as(usize, 2), p.constraints[1].values.len);
            try testing.expectEqualStrings("fun", p.constraints[1].values[0]);
            try testing.expectEqualStrings("=", p.constraints[1].values[1]);
            break;
        }
    }
}

test "example grammar: zig.toml parses without errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const file = try std.Io.Dir.cwd().openFile(testing.io, "examples/grammars/zig.toml", .{});
    defer file.close(testing.io);
    var fbuf: [4096]u8 = undefined;
    var file_reader = file.reader(testing.io, &fbuf);
    const source = try file_reader.interface.allocRemaining(alloc, .unlimited);
    const grammar = try parseGrammar(source, alloc);
    try testing.expectEqualStrings("zig", grammar.language_name.?);
    try testing.expect(grammar.patterns.len >= 5);
    try testing.expect(grammar.keyword_table.len > 0);
    try testing.expectEqualStrings("{", grammar.blocks.open.?);
    try testing.expectEqualStrings("}", grammar.blocks.close.?);
}

// --- Bug Condition Exploration Tests (empty-blocks-misleading-error) ---
// Property 1: Empty Block Delimiters Cause Misleading Error
// These tests encode the EXPECTED (correct) behavior.
// They MUST FAIL on unfixed code — failure confirms the bug exists.

// Concrete unit test: both open and close empty
test "bug exploration: both empty block delimiters treated as absent" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[blocks]
        \\open = ""
        \\close = ""
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());

    // Expected: parsing succeeds (no MissingPatterns error)
    const grammar = result catch |err| {
        std.debug.print("COUNTEREXAMPLE: both empty delimiters caused {s}\n", .{@errorName(err)});
        return err;
    };

    // Expected: empty strings become null, not non-null empty slices
    if (grammar.blocks.open) |open| {
        std.debug.print("COUNTEREXAMPLE: blocks.open is non-null with len={d}\n", .{open.len});
        return error.TestUnexpectedResult;
    }
    if (grammar.blocks.close) |close| {
        std.debug.print("COUNTEREXAMPLE: blocks.close is non-null with len={d}\n", .{close.len});
        return error.TestUnexpectedResult;
    }
}

// Concrete unit test: empty open only
test "bug exploration: empty open delimiter treated as absent" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[blocks]
        \\open = ""
        \\close = "}"
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());

    const grammar = result catch |err| {
        std.debug.print("COUNTEREXAMPLE: empty open + non-empty close caused {s}\n", .{@errorName(err)});
        return err;
    };

    // Expected: open = null (was empty string)
    if (grammar.blocks.open) |open| {
        std.debug.print("COUNTEREXAMPLE: blocks.open is non-null with len={d}\n", .{open.len});
        return error.TestUnexpectedResult;
    }

    // Expected: close = "}" (preserved)
    try testing.expectEqualStrings("}", grammar.blocks.close.?);
}

// Concrete unit test: empty close only
test "bug exploration: empty close delimiter treated as absent" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[blocks]
        \\open = "{"
        \\close = ""
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());

    const grammar = result catch |err| {
        std.debug.print("COUNTEREXAMPLE: non-empty open + empty close caused {s}\n", .{@errorName(err)});
        return err;
    };

    // Expected: open = "{" (preserved)
    try testing.expectEqualStrings("{", grammar.blocks.open.?);

    // Expected: close = null (was empty string)
    if (grammar.blocks.close) |close| {
        std.debug.print("COUNTEREXAMPLE: blocks.close is non-null with len={d}\n", .{close.len});
        return error.TestUnexpectedResult;
    }
}

// Property-based test: empty block delimiters should be treated as absent
test "property: empty block delimiters treated as absent" {
    // Generate a boolean (true = open empty, false = close empty) and a random pattern type
    const pair_gen = comptime gen.tuple2(
        bool,
        []const u8,
        gen.boolean(),
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
    );

    try minish.check(testing.allocator, pair_gen, struct {
        fn prop(vals: struct { bool, []const u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const open_empty = vals[0];
            const pattern_type = vals[1];

            // Build TOML with empty delimiter(s) and a valid [[patterns]] section
            var aw: std.Io.Writer.Allocating = .init(alloc);
            const w = &aw.writer;

            try w.writeAll("[[patterns]]\ntype = \"");
            try w.writeAll(pattern_type);
            try w.writeAll("\"\nsequence = [\"identifier\", \"(\"]\n\n[blocks]\n");

            if (open_empty) {
                try w.writeAll("open = \"\"\nclose = \"}\"\n");
            } else {
                try w.writeAll("open = \"{\"\nclose = \"\"\n");
            }

            const source = aw.written();
            const result = parseGrammar(source, alloc);

            // Expected: parsing succeeds (no MissingPatterns)
            const grammar = result catch |err| {
                std.debug.print("COUNTEREXAMPLE: pattern_type=\"{s}\" open_empty={} caused {s}\n", .{ pattern_type, open_empty, @errorName(err) });
                return err;
            };

            // Expected: empty delimiter becomes null
            if (open_empty) {
                if (grammar.blocks.open) |open| {
                    std.debug.print("COUNTEREXAMPLE: open_empty=true but blocks.open is non-null len={d}\n", .{open.len});
                    return error.TestUnexpectedResult;
                }
                // Non-empty delimiter preserved
                try testing.expectEqualStrings("}", grammar.blocks.close.?);
            } else {
                if (grammar.blocks.close) |close| {
                    std.debug.print("COUNTEREXAMPLE: close_empty=true but blocks.close is non-null len={d}\n", .{close.len});
                    return error.TestUnexpectedResult;
                }
                // Non-empty delimiter preserved
                try testing.expectEqualStrings("{", grammar.blocks.open.?);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// --- Preservation Property Tests (empty-blocks-misleading-error) ---
// Property 2: Non-Empty Delimiter Behavior Unchanged
// These tests capture baseline behavior on UNFIXED code for non-buggy inputs.
// They MUST PASS on both unfixed and fixed code.

// Concrete preservation test: non-empty delimiters preserved
test "preservation: non-empty delimiters preserved correctly" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[blocks]
        \\open = "{"
        \\close = "}"
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqualStrings("{", grammar.blocks.open.?);
    try testing.expectEqualStrings("}", grammar.blocks.close.?);
}

// Concrete preservation test: multi-char delimiters preserved
test "preservation: multi-char delimiters preserved correctly" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["$name:IDENTIFIER", "("]
        \\
        \\[blocks]
        \\open = "begin"
        \\close = "end"
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqualStrings("begin", grammar.blocks.open.?);
    try testing.expectEqualStrings("end", grammar.blocks.close.?);
}

// Concrete preservation test: no [blocks] section → null defaults
test "preservation: no blocks section returns null defaults" {
    const source =
        \\[[patterns]]
        \\type = "call"
        \\sequence = ["identifier", "("]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expect(grammar.blocks.open == null);
    try testing.expect(grammar.blocks.close == null);
    try testing.expect(grammar.blocks.indentation == false);
}

// Concrete preservation test: missing [[patterns]] still returns error
test "preservation: missing patterns still returns MissingPatterns" {
    const source =
        \\[language]
        \\name = "test"
        \\
        \\[blocks]
        \\open = "{"
        \\close = "}"
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());
    try testing.expectError(error.MissingPatterns, result);
}

// Concrete preservation test: indentation-only blocks
test "preservation: indentation-only blocks with null delimiters" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["def", "$name:IDENTIFIER", "("]
        \\
        \\[blocks]
        \\indentation = true
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expect(grammar.blocks.open == null);
    try testing.expect(grammar.blocks.close == null);
    try testing.expect(grammar.blocks.indentation == true);
}

// Property-based test: non-empty delimiters are always preserved
test "property: non-empty block delimiters preserved" {
    // Generate random non-empty delimiter strings (alpha, len 1-8)
    const pair_gen = comptime gen.tuple2(
        []const u8,
        []const u8,
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
    );

    try minish.check(testing.allocator, pair_gen, struct {
        fn prop(vals: struct { []const u8, []const u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const open_delim = vals[0];
            const close_delim = vals[1];

            // Build TOML with non-empty delimiters and a valid [[patterns]] section
            var aw: std.Io.Writer.Allocating = .init(alloc);
            const w = &aw.writer;

            try w.writeAll("[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"(\"]\n\n[blocks]\nopen = \"");
            try w.writeAll(open_delim);
            try w.writeAll("\"\nclose = \"");
            try w.writeAll(close_delim);
            try w.writeAll("\"\n");

            const source = aw.written();
            const grammar = try parseGrammar(source, alloc);

            // Non-empty delimiters must be preserved exactly
            try testing.expectEqualStrings(open_delim, grammar.blocks.open.?);
            try testing.expectEqualStrings(close_delim, grammar.blocks.close.?);
        }
    }.prop, .{ .num_runs = 100 });
}

// --- Phase 2: Optional Element Tests ---

// Feature: probabilistic-confidence-scoring, Property 4: Optional element parsing round-trip
// **Validates: Requirements 2.1, 2.5, 2.6**
test "property: optional element parsing round-trip" {
    // Generate a random boolean for is_optional and a random matcher type (0-3)
    // 0 = keyword_literal, 1 = symbol_literal, 2 = identifier, 3 = identifier_literal
    const pair_gen = comptime gen.tuple2(
        bool,
        u8,
        gen.boolean(),
        gen.intRange(u8, 0, 3),
    );

    try minish.check(testing.allocator, pair_gen, struct {
        fn prop(vals: struct { bool, u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const is_optional = vals[0];
            const matcher_type = vals[1];

            // Build a Grammar with a single pattern containing one element
            const elem: SequenceElement = switch (matcher_type) {
                0 => .{ .matcher = .{ .kind = .{ .one = .keyword }, .text = .{ .exact = "fn" } }, .is_optional = is_optional },
                1 => .{ .matcher = .{ .kind = .punctuation, .text = .{ .exact = "{" } }, .is_optional = is_optional },
                2 => .{ .matcher = .{ .kind = .{ .one = .identifier } }, .is_optional = is_optional },
                3 => .{ .matcher = .{ .kind = .{ .one = .identifier }, .text = .{ .exact = "Config" } }, .is_optional = is_optional },
                else => unreachable,
            };

            // We need at least one required element for a valid pattern,
            // so add a required keyword before the test element
            const original = Grammar{
                .language_name = "test",
                .keyword_categories = &.{},
                .keyword_table = &.{},
                .patterns = &.{
                    .{
                        .type_name = "test_pattern",
                        .sequence = &.{
                            .{ .matcher = .{ .kind = .{ .one = .keyword }, .text = .{ .exact = "def" } } },
                            elem,
                        },
                        .captures = &.{},
                    },
                },
                .blocks = .{},
            };

            // Round-trip: format → parse
            const toml_str = try formatGrammar(original, alloc);
            const parsed = try parseGrammar(toml_str, alloc);

            // Verify the second element's is_optional flag is preserved
            try testing.expectEqual(@as(usize, 1), parsed.patterns.len);
            try testing.expectEqual(@as(usize, 2), parsed.patterns[0].sequence.len);

            const parsed_elem = parsed.patterns[0].sequence[1];
            try testing.expectEqual(is_optional, parsed_elem.is_optional);

            // Verify the matcher type is preserved
            const orig_tag: u8 = matcherTag(elem.matcher);
            const parsed_tag: u8 = matcherTag(parsed_elem.matcher);
            try testing.expectEqual(orig_tag, parsed_tag);
        }
    }.prop, .{ .num_runs = 100 });
}

// --- Phase 2: Optional Element Unit Tests (loader) ---

test "parseGrammar: optional symbol_literal with ? suffix" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "{?"]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    const seq = grammar.patterns[0].sequence;
    try testing.expectEqual(@as(usize, 3), seq.len);
    // "{?" → symbol_literal "{" with is_optional = true
    try testing.expect(seq[2].matcher.kind == .punctuation);
    try testing.expectEqualStrings("{", seq[2].matcher.text.exact);
    try testing.expect(seq[2].is_optional);
    // First two elements should NOT be optional
    try testing.expect(!seq[0].is_optional);
    try testing.expect(!seq[1].is_optional);
}

test "parseGrammar: optional keyword_literal with ? suffix" {
    const source =
        \\[[patterns]]
        \\type = "test"
        \\sequence = ["fn?", "identifier"]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    const seq = grammar.patterns[0].sequence;
    try testing.expectEqual(@as(usize, 2), seq.len);
    // "fn?" → keyword_literal "fn" with is_optional = true
    try testing.expect(seq[0].matcher.kind == .one and seq[0].matcher.kind.one == .keyword);
    try testing.expectEqualStrings("fn", seq[0].matcher.text.exact);
    try testing.expect(seq[0].is_optional);
    // "identifier" → identifier with is_optional = false
    try testing.expect(seq[1].matcher.kind == .one and seq[1].matcher.kind.one == .identifier);
    try testing.expect(!seq[1].is_optional);
}

test "parseGrammar: optional identifier with ? suffix" {
    const source =
        \\[[patterns]]
        \\type = "test"
        \\sequence = ["fn", "identifier?"]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    const seq = grammar.patterns[0].sequence;
    try testing.expectEqual(@as(usize, 2), seq.len);
    // "identifier?" → identifier with is_optional = true
    try testing.expect(seq[1].matcher.kind == .one and seq[1].matcher.kind.one == .identifier);
    try testing.expect(seq[1].is_optional);
}

test "formatGrammar: round-trip preserves optional elements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const original = Grammar{
        .language_name = null,
        .keyword_categories = &.{},
        .keyword_table = &.{},
        .patterns = &.{
            .{
                .type_name = "function",
                .sequence = &.{
                    .{ .matcher = .{ .kind = .{ .one = .keyword }, .text = .{ .exact = "fn" } } },
                    .{ .matcher = .{ .kind = .{ .one = .identifier } } },
                    .{ .matcher = .{ .kind = .punctuation, .text = .{ .exact = "{" } }, .is_optional = true },
                },
                .captures = &.{},
            },
        },
        .blocks = .{},
    };

    const toml_str = try formatGrammar(original, alloc);
    const parsed = try parseGrammar(toml_str, alloc);

    try testing.expectEqual(@as(usize, 3), parsed.patterns[0].sequence.len);
    try testing.expect(!parsed.patterns[0].sequence[0].is_optional);
    try testing.expect(!parsed.patterns[0].sequence[1].is_optional);
    try testing.expect(parsed.patterns[0].sequence[2].is_optional);
    try testing.expect(parsed.patterns[0].sequence[2].matcher.kind == .punctuation);
    try testing.expectEqualStrings("{", parsed.patterns[0].sequence[2].matcher.text.exact);
}

// --- Phase 5: Configurable Weights Property Tests ---

// Feature: probabilistic-confidence-scoring, Property 9: Weight parsing with defaults
// **Validates: Requirements 5.1, 5.2, 5.3**
test "property: weight parsing with defaults" {
    // Generate a random bitmask (0-31) to select which weight keys to include,
    // and random percentage values (0-100) for each key.
    const tuple_gen = comptime gen.tuple2(
        u8,
        u8,
        gen.intRange(u8, 0, 31),
        gen.intRange(u8, 0, 100),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { u8, u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const bitmask = vals[0];
            const pct = vals[1];
            const weight_val: f32 = @as(f32, @floatFromInt(pct)) / 100.0;

            const keys = [_][]const u8{ "keyword", "identifier", "symbol", "block", "relaxed_keyword" };
            const defaults = [_]f32{ 0.5, 0.2, 0.2, 0.3, 0.1 };

            // Build TOML with a [weights] section containing only selected keys
            var aw: std.Io.Writer.Allocating = .init(alloc);
            const w = &aw.writer;
            try w.writeAll("[[patterns]]\ntype = \"test\"\nsequence = [\"identifier\", \"(\"]\n\n");

            var has_any = false;
            for (0..5) |i| {
                if (bitmask & (@as(u8, 1) << @intCast(i)) != 0) {
                    if (!has_any) {
                        try w.writeAll("[weights]\n");
                        has_any = true;
                    }
                    try w.print("{s} = {d:.2}\n", .{ keys[i], weight_val });
                }
            }

            const source = aw.written();
            const grammar = try parseGrammar(source, alloc);

            // Verify: specified keys have custom values, omitted keys have defaults
            const parsed_vals = [_]f32{
                grammar.weights.keyword,
                grammar.weights.identifier,
                grammar.weights.symbol,
                grammar.weights.block,
                grammar.weights.relaxed_keyword,
            };

            for (0..5) |i| {
                if (bitmask & (@as(u8, 1) << @intCast(i)) != 0) {
                    // Specified key: should have custom value
                    try testing.expectApproxEqAbs(weight_val, parsed_vals[i], 0.01);
                } else {
                    // Omitted key: should have default value
                    try testing.expectApproxEqAbs(defaults[i], parsed_vals[i], 0.001);
                }
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: probabilistic-confidence-scoring, Property 10: Negative weight rejection
// **Validates: Requirements 5.5**
test "property: negative weight rejection" {
    // Generate a random key index (0-4) and a random negative percentage (1-100)
    const tuple_gen = comptime gen.tuple2(
        u8,
        u8,
        gen.intRange(u8, 0, 4),
        gen.intRange(u8, 1, 100),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { u8, u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const key_idx = vals[0];
            const pct = vals[1];
            const neg_val: f32 = -@as(f32, @floatFromInt(pct)) / 100.0;

            const keys = [_][]const u8{ "keyword", "identifier", "symbol", "block", "relaxed_keyword" };

            // Build TOML with a negative weight value
            var aw: std.Io.Writer.Allocating = .init(alloc);
            const w = &aw.writer;
            try w.writeAll("[[patterns]]\ntype = \"test\"\nsequence = [\"identifier\", \"(\"]\n\n[weights]\n");
            try w.print("{s} = {d:.2}\n", .{ keys[key_idx], neg_val });

            const source = aw.written();
            const result = parseGrammar(source, alloc);
            try testing.expectError(error.InvalidWeightValue, result);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: probabilistic-confidence-scoring, Property 11: Grammar TOML round-trip with weights
// **Validates: Requirements 5.6**
test "property: grammar TOML round-trip with weights" {
    // Generate 5 random percentage values (0-100) for each weight key
    const tuple_gen = comptime gen.tuple3(
        u8,
        u8,
        u8,
        gen.intRange(u8, 0, 100),
        gen.intRange(u8, 0, 100),
        gen.intRange(u8, 0, 100),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { u8, u8, u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // Use the 3 generated values to derive 5 weight values
            const w_keyword: f32 = @as(f32, @floatFromInt(vals[0])) / 100.0;
            const w_identifier: f32 = @as(f32, @floatFromInt(vals[1])) / 100.0;
            const w_symbol: f32 = @as(f32, @floatFromInt(vals[2])) / 100.0;
            // Derive block and relaxed_keyword from combinations
            const w_block: f32 = @as(f32, @floatFromInt((vals[0] +% vals[1]) % 101)) / 100.0;
            const w_relaxed: f32 = @as(f32, @floatFromInt((vals[1] +% vals[2]) % 101)) / 100.0;

            const original = Grammar{
                .language_name = "test",
                .keyword_categories = &.{},
                .keyword_table = &.{},
                .patterns = &.{
                    .{
                        .type_name = "function",
                        .sequence = &.{
                            .{ .matcher = .{ .kind = .{ .one = .keyword }, .text = .{ .exact = "fn" } } },
                            .{ .matcher = .{ .kind = .{ .one = .identifier } } },
                            .{ .matcher = .{ .kind = .punctuation, .text = .{ .exact = "(" } } },
                        },
                        .captures = &.{},
                    },
                },
                .blocks = .{},
                .weights = .{
                    .keyword = w_keyword,
                    .identifier = w_identifier,
                    .symbol = w_symbol,
                    .block = w_block,
                    .relaxed_keyword = w_relaxed,
                },
            };

            // Round-trip: format → parse
            const toml_str = try formatGrammar(original, alloc);
            const parsed = try parseGrammar(toml_str, alloc);

            // Verify weight values are preserved
            try testing.expectApproxEqAbs(w_keyword, parsed.weights.keyword, 0.01);
            try testing.expectApproxEqAbs(w_identifier, parsed.weights.identifier, 0.01);
            try testing.expectApproxEqAbs(w_symbol, parsed.weights.symbol, 0.01);
            try testing.expectApproxEqAbs(w_block, parsed.weights.block, 0.01);
            try testing.expectApproxEqAbs(w_relaxed, parsed.weights.relaxed_keyword, 0.01);
        }
    }.prop, .{ .num_runs = 100 });
}

// --- Phase 5: Configurable Weights Unit Tests (loader) ---

test "parseGrammar: partial weight spec uses defaults for omitted keys" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[weights]
        \\keyword = 0.6
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    // keyword overridden
    try testing.expectApproxEqAbs(@as(f32, 0.6), grammar.weights.keyword, 0.001);
    // others use defaults
    try testing.expectApproxEqAbs(@as(f32, 0.2), grammar.weights.identifier, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.2), grammar.weights.symbol, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.3), grammar.weights.block, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.1), grammar.weights.relaxed_keyword, 0.001);
}

test "parseGrammar: negative weight returns InvalidWeightValue" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[weights]
        \\keyword = -0.5
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());
    try testing.expectError(error.InvalidWeightValue, result);
}

test "parseGrammar: round-trip with all weight fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const original = Grammar{
        .language_name = null,
        .keyword_categories = &.{},
        .keyword_table = &.{},
        .patterns = &.{
            .{
                .type_name = "function",
                .sequence = &.{
                    .{ .matcher = .{ .kind = .{ .one = .keyword }, .text = .{ .exact = "fn" } } },
                    .{ .matcher = .{ .kind = .{ .one = .identifier } } },
                },
                .captures = &.{},
            },
        },
        .blocks = .{},
        .weights = .{
            .keyword = 0.7,
            .identifier = 0.3,
            .symbol = 0.15,
            .block = 0.4,
            .relaxed_keyword = 0.05,
        },
    };

    const toml_str = try formatGrammar(original, alloc);
    const parsed = try parseGrammar(toml_str, alloc);

    try testing.expectApproxEqAbs(@as(f32, 0.7), parsed.weights.keyword, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.3), parsed.weights.identifier, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.15), parsed.weights.symbol, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.4), parsed.weights.block, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.05), parsed.weights.relaxed_keyword, 0.01);
}

test "parseGrammar: omitted weights section uses all defaults" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    const defaults = EvidenceWeights{};
    try testing.expectApproxEqAbs(defaults.keyword, grammar.weights.keyword, 0.001);
    try testing.expectApproxEqAbs(defaults.identifier, grammar.weights.identifier, 0.001);
    try testing.expectApproxEqAbs(defaults.symbol, grammar.weights.symbol, 0.001);
    try testing.expectApproxEqAbs(defaults.block, grammar.weights.block, 0.001);
    try testing.expectApproxEqAbs(defaults.relaxed_keyword, grammar.weights.relaxed_keyword, 0.001);
}

test "parseGrammar: exclude field returns DeprecatedField error" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["$name:IDENTIFIER", "("]
        \\exclude = ["-spec"]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());
    try testing.expectError(error.DeprecatedField, result);
}

test "parseGrammar: not_preceded_by field returns DeprecatedField error" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["$name:IDENTIFIER", "("]
        \\not_preceded_by = ["fun"]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());
    try testing.expectError(error.DeprecatedField, result);
}

// Feature: unified-constraint-system, Property 2: Invalid constraint configuration rejection
// **Validates: Requirements 1.3, 1.4, 1.6, 1.7**
test "property: invalid constraint configuration rejection" {
    // Generate a case selector (0-3) and random strings for type/field names
    const tuple_gen = comptime gen.tuple3(
        u8,
        []const u8,
        u8,
        gen.intRange(u8, 0, 3),
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha }),
        gen.intRange(u8, 1, 10),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { u8, []const u8, u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const case = vals[0];
            const rand_str = vals[1];
            const rand_depth = vals[2];

            var aw: std.Io.Writer.Allocating = .init(alloc);
            const w = &aw.writer;

            // Common pattern prefix
            try w.writeAll(
                \\[[patterns]]
                \\type = "function"
                \\sequence = ["$name:IDENTIFIER", "("]
                \\
                \\[[patterns.constraints]]
                \\
            );

            switch (case) {
                0 => {
                    // Case 1: type is a random non-"not" string → InvalidConstraintType
                    // Ensure the random string is not "not"
                    const type_str = if (std.mem.eql(u8, rand_str, "not")) "invalid" else rand_str;
                    try w.writeAll("type = \"");
                    try w.writeAll(type_str);
                    try w.writeAll("\"\ndepth = 1\nvalues = [\"x\"]\n");

                    const source = aw.written();
                    const result = parseGrammar(source, alloc);
                    try testing.expectError(error.InvalidConstraintType, result);
                },
                1 => {
                    // Case 2: depth=0 with no field → InvalidConstraintDepth
                    try w.writeAll("type = \"not\"\ndepth = 0\nvalues = [\"x\"]\n");

                    const source = aw.written();
                    const result = parseGrammar(source, alloc);
                    try testing.expectError(error.InvalidConstraintDepth, result);
                },
                2 => {
                    // Case 3: depth>0 with a field present → InvalidConstraintField
                    try w.print("type = \"not\"\ndepth = {d}\nfield = \"{s}\"\nvalues = [\"x\"]\n", .{ rand_depth, rand_str });

                    const source = aw.written();
                    const result = parseGrammar(source, alloc);
                    try testing.expectError(error.InvalidConstraintField, result);
                },
                3 => {
                    // Case 4: values is empty array → InvalidConstraintValues
                    try w.writeAll("type = \"not\"\ndepth = 1\nvalues = []\n");

                    const source = aw.written();
                    const result = parseGrammar(source, alloc);
                    try testing.expectError(error.InvalidConstraintValues, result);
                },
                else => unreachable,
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: unified-constraint-system, Property 1: Grammar TOML round-trip with constraints
// **Validates: Requirements 1.1, 1.2, 1.5, 7.1, 7.2, 7.3, 7.4, 10.3, 10.4**
test "property: grammar TOML round-trip with constraints" {
    // Generate depth (0-8), a random alphanumeric string (for field name and values),
    // and num_values (1-3)
    const tuple_gen = comptime gen.tuple3(
        u8,
        []const u8,
        u8,
        gen.intRange(u8, 0, 8),
        gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alphanumeric }),
        gen.intRange(u8, 1, 3),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { u8, []const u8, u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const depth = vals[0];
            const rand_str = vals[1];
            const num_values = vals[2];

            // Build TOML source with a pattern containing a constraint
            var aw: std.Io.Writer.Allocating = .init(alloc);
            const w = &aw.writer;

            try w.writeAll(
                \\[[patterns]]
                \\type = "method"
                \\sequence = ["$name:IDENTIFIER", "("]
                \\
                \\[[patterns.constraints]]
                \\type = "not"
                \\
            );

            try w.print("depth = {d}\n", .{depth});

            // For depth=0, include a field key; for depth>0, omit it
            if (depth == 0) {
                try w.writeAll("field = \"");
                try w.writeAll(rand_str);
                try w.writeAll("\"\n");
            }

            // Build values array with num_values entries derived from rand_str
            try w.writeAll("values = [");
            for (0..num_values) |i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll("\"");
                try w.writeAll(rand_str);
                try w.print("{d}", .{i});
                try w.writeAll("\"");
            }
            try w.writeAll("]\n");

            const source = aw.written();

            // Step 1: Parse the TOML source
            const grammar1 = try parseGrammar(source, alloc);

            // Step 2: Format back to TOML
            const formatted = try formatGrammar(grammar1, alloc);

            // Step 3: Parse the formatted output
            const grammar2 = try parseGrammar(formatted, alloc);

            // Step 4: Verify constraints match
            try testing.expectEqual(@as(usize, 1), grammar1.patterns.len);
            try testing.expectEqual(@as(usize, 1), grammar2.patterns.len);

            const c1 = grammar1.patterns[0].constraints;
            const c2 = grammar2.patterns[0].constraints;

            try testing.expectEqual(c1.len, c2.len);
            try testing.expectEqual(@as(usize, 1), c1.len);

            // Verify constraint type
            try testing.expectEqual(c1[0].type, c2[0].type);
            try testing.expectEqual(ConstraintType.not, c2[0].type);

            // Verify depth
            try testing.expectEqual(c1[0].depth, c2[0].depth);
            try testing.expectEqual(depth, c2[0].depth);

            // Verify field
            if (depth == 0) {
                try testing.expect(c1[0].field != null);
                try testing.expect(c2[0].field != null);
                try testing.expectEqualStrings(c1[0].field.?, c2[0].field.?);
                try testing.expectEqualStrings(rand_str, c2[0].field.?);
            } else {
                try testing.expect(c1[0].field == null);
                try testing.expect(c2[0].field == null);
            }

            // Verify values
            try testing.expectEqual(c1[0].values.len, c2[0].values.len);
            try testing.expectEqual(@as(usize, num_values), c2[0].values.len);
            for (c1[0].values, c2[0].values) |v1, v2| {
                try testing.expectEqualStrings(v1, v2);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// --- Phase 6: Configurable Comment Prefixes Unit Tests ---

test "parseGrammar: valid line array with single prefix" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[comments]
        \\line = ["%"]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqual(@as(usize, 1), grammar.comments.line_prefixes.len);
    try testing.expectEqualStrings("%", grammar.comments.line_prefixes[0]);
    try testing.expect(grammar.comments.block_open == null);
    try testing.expect(grammar.comments.block_close == null);
}

test "parseGrammar: valid line array with multiple prefixes" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[comments]
        \\line = ["//", "#", "--"]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqual(@as(usize, 3), grammar.comments.line_prefixes.len);
    try testing.expectEqualStrings("//", grammar.comments.line_prefixes[0]);
    try testing.expectEqualStrings("#", grammar.comments.line_prefixes[1]);
    try testing.expectEqualStrings("--", grammar.comments.line_prefixes[2]);
    try testing.expect(grammar.comments.block_open == null);
    try testing.expect(grammar.comments.block_close == null);
}

test "parseGrammar: valid block_open/block_close pair" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[comments]
        \\block_open = "/*"
        \\block_close = "*/"
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqual(@as(usize, 0), grammar.comments.line_prefixes.len); // no line key -> empty
    try testing.expectEqualStrings("/*", grammar.comments.block_open.?);
    try testing.expectEqualStrings("*/", grammar.comments.block_close.?);
}

test "parseGrammar: missing [comments] section produces default config" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    const default = CommentConfig.default;
    try testing.expectEqual(default.line_prefixes.len, grammar.comments.line_prefixes.len);
    try testing.expectEqualStrings("//", grammar.comments.line_prefixes[0]);
    try testing.expectEqualStrings("#", grammar.comments.line_prefixes[1]);
    try testing.expectEqualStrings("/*", grammar.comments.block_open.?);
    try testing.expectEqualStrings("*/", grammar.comments.block_close.?);
}

test "parseGrammar: empty line array produces empty prefixes" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[comments]
        \\line = []
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqual(@as(usize, 0), grammar.comments.line_prefixes.len);
    try testing.expect(grammar.comments.block_open == null);
    try testing.expect(grammar.comments.block_close == null);
}

test "parseGrammar: empty string entries treated as absent" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[comments]
        \\line = ["//", "", "#"]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqual(@as(usize, 2), grammar.comments.line_prefixes.len);
    try testing.expectEqualStrings("//", grammar.comments.line_prefixes[0]);
    try testing.expectEqualStrings("#", grammar.comments.line_prefixes[1]);
    // Empty string should be skipped, not included
    try testing.expect(!std.mem.eql(u8, "", grammar.comments.line_prefixes[0]));
    try testing.expect(!std.mem.eql(u8, "", grammar.comments.line_prefixes[1]));
}

test "parseGrammar: UnpairedBlockDelimiter when only block_open present" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[comments]
        \\block_open = "/*"
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());
    try testing.expectError(error.UnpairedBlockDelimiter, result);
}

test "parseGrammar: UnpairedBlockDelimiter when only block_close present" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[comments]
        \\block_close = "*/"
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());
    try testing.expectError(error.UnpairedBlockDelimiter, result);
}

test "parseGrammar: CommentPrefixTooLong for prefix > 8 chars" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[comments]
        \\line = ["//", "123456789"]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());
    try testing.expectError(error.CommentPrefixTooLong, result);
}

test "parseGrammar: TooManyLinePrefixes for > 16 entries" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[comments]
        \\line = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q"]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());
    try testing.expectError(error.TooManyLinePrefixes, result);
}

test "parseGrammar: BlockDelimiterTooLong for delimiter > 8 chars" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[comments]
        \\block_open = "123456789"
        \\block_close = "*/"
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());
    try testing.expectError(error.BlockDelimiterTooLong, result);
}

test "parseGrammar: multi-character prefixes accepted" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[comments]
        \\line = ["--", "%%", "<!--"]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar(source, arena.allocator());

    try testing.expectEqual(@as(usize, 3), grammar.comments.line_prefixes.len);
    try testing.expectEqualStrings("--", grammar.comments.line_prefixes[0]);
    try testing.expectEqualStrings("%%", grammar.comments.line_prefixes[1]);
    try testing.expectEqualStrings("<!--", grammar.comments.line_prefixes[2]);
}

test "parseGrammar: invalid line type returns InvalidCommentLineType" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[comments]
        \\line = 123
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());
    try testing.expectError(error.InvalidCommentLineType, result);
}

test "parseGrammar: invalid block type returns InvalidCommentBlockType" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
        \\
        \\[comments]
        \\block_open = 123
        \\block_close = "*/"
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parseGrammar(source, arena.allocator());
    try testing.expectError(error.InvalidCommentBlockType, result);
}

test "formatGrammar: round-trip with comments section" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const original = Grammar{
        .language_name = "test",
        .keyword_categories = &.{},
        .keyword_table = &.{},
        .patterns = &.{
            .{
                .type_name = "function",
                .sequence = &.{
                    .{ .matcher = .{ .kind = .{ .one = .keyword }, .text = .{ .exact = "fn" } } },
                    .{ .matcher = .{ .kind = .{ .one = .identifier } } },
                },
                .captures = &.{},
            },
        },
        .blocks = .{},
        .weights = .{},
        .comments = .{
            .line_prefixes = &.{ "%", "--" },
            .block_open = "/*",
            .block_close = "*/",
        },
    };

    const toml_str = try formatGrammar(original, alloc);
    const parsed = try parseGrammar(toml_str, alloc);

    try testing.expectEqual(@as(usize, 2), parsed.comments.line_prefixes.len);
    try testing.expectEqualStrings("%", parsed.comments.line_prefixes[0]);
    try testing.expectEqualStrings("--", parsed.comments.line_prefixes[1]);
    try testing.expectEqualStrings("/*", parsed.comments.block_open.?);
    try testing.expectEqualStrings("*/", parsed.comments.block_close.?);
}

test "formatGrammar: comments with special characters escaped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const original = Grammar{
        .language_name = null,
        .keyword_categories = &.{},
        .keyword_table = &.{},
        .patterns = &.{
            .{
                .type_name = "test",
                .sequence = &.{
                    .{ .matcher = .{ .kind = .{ .one = .keyword }, .text = .{ .exact = "fn" } } },
                },
                .captures = &.{},
            },
        },
        .blocks = .{},
        .weights = .{},
        .comments = .{
            .line_prefixes = &.{ "\"q\"", "b\\s" },
            .block_open = "o\"q",
            .block_close = "c\\s",
        },
    };

    const toml_str = try formatGrammar(original, alloc);
    // Should contain escaped versions
    try testing.expect(std.mem.indexOf(u8, toml_str, "\\\"q\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, toml_str, "b\\\\s") != null);
    try testing.expect(std.mem.indexOf(u8, toml_str, "o\\\"q") != null);
    try testing.expect(std.mem.indexOf(u8, toml_str, "c\\\\s") != null);

    // Round-trip should work
    const parsed = try parseGrammar(toml_str, alloc);
    try testing.expectEqual(@as(usize, 2), parsed.comments.line_prefixes.len);
    try testing.expectEqualStrings("\"q\"", parsed.comments.line_prefixes[0]);
    try testing.expectEqualStrings("b\\s", parsed.comments.line_prefixes[1]);
    try testing.expectEqualStrings("o\"q", parsed.comments.block_open.?);
    try testing.expectEqualStrings("c\\s", parsed.comments.block_close.?);
}

test "formatGrammar: empty config omits [comments] section" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const original = Grammar{
        .language_name = null,
        .keyword_categories = &.{},
        .keyword_table = &.{},
        .patterns = &.{
            .{
                .type_name = "test",
                .sequence = &.{
                    .{ .matcher = .{ .kind = .{ .one = .keyword }, .text = .{ .exact = "fn" } } },
                },
                .captures = &.{},
            },
        },
        .blocks = .{},
        .weights = .{},
        .comments = .{
            .line_prefixes = &.{},
            .block_open = null,
            .block_close = null,
        },
    };

    const toml_str = try formatGrammar(original, alloc);
    // Should NOT contain [comments] section
    try testing.expect(std.mem.indexOf(u8, toml_str, "[comments]") == null);

    // Parse back - with no [comments] section, we get defaults
    const parsed = try parseGrammar(toml_str, alloc);
    try testing.expectEqual(@as(usize, 2), parsed.comments.line_prefixes.len); // defaults
    try testing.expectEqualStrings("//", parsed.comments.line_prefixes[0]);
    try testing.expectEqualStrings("#", parsed.comments.line_prefixes[1]);
    try testing.expectEqualStrings("/*", parsed.comments.block_open.?);
    try testing.expectEqualStrings("*/", parsed.comments.block_close.?);
}

test "formatGrammar: default config produces explicit section" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const original = Grammar{
        .language_name = null,
        .keyword_categories = &.{},
        .keyword_table = &.{},
        .patterns = &.{
            .{
                .type_name = "test",
                .sequence = &.{
                    .{ .matcher = .{ .kind = .{ .one = .keyword }, .text = .{ .exact = "fn" } } },
                },
                .captures = &.{},
            },
        },
        .blocks = .{},
        .weights = .{},
        .comments = CommentConfig.default,
    };

    const toml_str = try formatGrammar(original, alloc);
    // Should contain [comments] section even though it's the default
    try testing.expect(std.mem.indexOf(u8, toml_str, "[comments]") != null);
    try testing.expect(std.mem.indexOf(u8, toml_str, "line = [\"//\", \"#\"]") != null);
    try testing.expect(std.mem.indexOf(u8, toml_str, "block_open = \"/*\"") != null);
    try testing.expect(std.mem.indexOf(u8, toml_str, "block_close = \"*/\"") != null);
}

test "parseGrammar + formatGrammar round-trip without [comments] section" {
    const source =
        \\[[patterns]]
        \\type = "function"
        \\sequence = ["fn", "$name:IDENTIFIER", "("]
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Parse grammar without [comments] section
    const grammar = try parseGrammar(source, alloc);
    // Should have default comment config
    const default = CommentConfig.default;
    try testing.expectEqual(default.line_prefixes.len, grammar.comments.line_prefixes.len);
    try testing.expectEqualStrings("//", grammar.comments.line_prefixes[0]);
    try testing.expectEqualStrings("#", grammar.comments.line_prefixes[1]);
    try testing.expectEqualStrings("/*", grammar.comments.block_open.?);
    try testing.expectEqualStrings("*/", grammar.comments.block_close.?);

    // Format it back - should now have explicit [comments] section
    const formatted = try formatGrammar(grammar, alloc);
    try testing.expect(std.mem.indexOf(u8, formatted, "[comments]") != null);

    // Parse the formatted version
    const parsed2 = try parseGrammar(formatted, alloc);
    // Should still have the same config
    try testing.expectEqual(grammar.comments.line_prefixes.len, parsed2.comments.line_prefixes.len);
    try testing.expectEqualStrings("//", parsed2.comments.line_prefixes[0]);
    try testing.expectEqualStrings("#", parsed2.comments.line_prefixes[1]);
    try testing.expectEqualStrings("/*", parsed2.comments.block_open.?);
    try testing.expectEqualStrings("*/", parsed2.comments.block_close.?);
}

// Feature: operator-token-matching, Unit: parseSequenceElement routing
// **Validates: Requirements 5.1, 5.2, 5.3, 5.4**
test "parseSequenceElement: operator characters route to symbol_literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ops = "+-*/=<>!&|^%~";
    for (ops) |c| {
        const s = [1]u8{c};
        const res = try parseSequenceElement(&s, 0, alloc);
        try testing.expect(res.element.matcher.kind == .punctuation);
        try testing.expectEqualStrings(&s, res.element.matcher.text.exact);
    }

    // Existing symbol/delimiter characters continue to route identically.
    const sym_delim = "(){}[],;:.@?";
    for (sym_delim) |c| {
        const s = [1]u8{c};
        const res = try parseSequenceElement(&s, 0, alloc);
        try testing.expect(res.element.matcher.kind == .punctuation);
        try testing.expectEqualStrings(&s, res.element.matcher.text.exact);
    }
}

test "parseSequenceElement: non-punctuation routes to non-punctuation matchers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        const res = try parseSequenceElement("module", 0, alloc);
        try testing.expect(res.element.matcher.kind == .one and res.element.matcher.kind.one == .keyword);
        try testing.expectEqualStrings("module", res.element.matcher.text.exact);
    }
    {
        const res = try parseSequenceElement("$name:IDENTIFIER", 0, alloc);
        try testing.expect(res.element.matcher.capture != null);
        try testing.expectEqualStrings("name", res.element.matcher.capture.?.field_name);
    }
    {
        const res = try parseSequenceElement("Config:IDENTIFIER", 0, alloc);
        try testing.expect(res.element.matcher.kind == .one and res.element.matcher.kind.one == .identifier and res.element.matcher.text == .exact);
        try testing.expectEqualStrings("Config", res.element.matcher.text.exact);
    }
    {
        const res = try parseSequenceElement("identifier", 0, alloc);
        try testing.expect(res.element.matcher.kind == .one and res.element.matcher.kind.one == .identifier);
    }
}

test "parseSequenceElement: optional suffix preserved on punctuation routing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const res = try parseSequenceElement("-?", 0, alloc);
    try testing.expect(res.element.is_optional);
    try testing.expect(res.element.matcher.kind == .punctuation);
    try testing.expectEqualStrings("-", res.element.matcher.text.exact);
}

// Feature: operator-token-matching, Property 4: Loader routes punctuation characters
// to the punctuation matcher
// **Validates: Requirements 5.1, 5.2, 5.3, 5.4**
test "property: loader routes punctuation characters to the punctuation matcher" {
    const punct = "(){}[],;:.@?+-*/=<>!&|^%~";
    const idx_gen = gen.intRange(u8, 0, punct.len - 1);

    try minish.check(testing.allocator, idx_gen, struct {
        fn prop(idx: u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const c = punct[idx];
            const s = [1]u8{c};
            const res = try parseSequenceElement(&s, 0, alloc);
            try testing.expect(res.element.matcher.kind == .punctuation);
            try testing.expectEqualStrings(&s, res.element.matcher.text.exact);
        }
    }.prop, .{ .num_runs = 100 });

    const word_gen = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha });
    try minish.check(testing.allocator, word_gen, struct {
        fn prop(word: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const res = try parseSequenceElement(word, 0, alloc);
            if (std.mem.eql(u8, word, "identifier")) {
                try testing.expect(res.element.matcher.kind == .one and res.element.matcher.kind.one == .identifier);
            } else {
                try testing.expect(res.element.matcher.kind == .one and res.element.matcher.kind.one == .keyword);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: number-token-primitive, Unit: loader parse and format
// **Validates: Requirements 1.1, 2.1, 2.2, 7.1, 7.2, 8.3**
test "parseSequenceElement: number parses to non-capturing number matcher" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        const res = try parseSequenceElement("number", 0, alloc);
        try testing.expect(res.element.matcher.kind == .one and res.element.matcher.kind.one == .number);
        try testing.expect(!res.element.is_optional);
        try testing.expect(res.capture == null);
    }
    {
        const res = try parseSequenceElement("number?", 0, alloc);
        try testing.expect(res.element.matcher.kind == .one and res.element.matcher.kind.one == .number);
        try testing.expect(res.element.is_optional);
        try testing.expect(res.capture == null);
    }
}

test "parseSequenceElement: near-miss number strings fall through to keyword literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const near_misses = [_][]const u8{ "numbers", "number2", "Number" };
    for (near_misses) |nm| {
        const res = try parseSequenceElement(nm, 0, alloc);
        try testing.expect(res.element.matcher.kind == .one and res.element.matcher.kind.one == .keyword);
        try testing.expectEqualStrings(nm, res.element.matcher.text.exact);
    }
}

test "formatGrammar: number emits number / number?" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\[[patterns]]
        \\type = "num"
        \\sequence = ["number", "number?"]
    ;
    const grammar = try parseGrammar(source, alloc);
    const formatted = try formatGrammar(grammar, alloc);
    try testing.expect(std.mem.indexOf(u8, formatted, "\"number\", \"number?\"") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "\"number?\"") != null);
}

// Feature: number-token-primitive, Property 1: `number` and `number?` parse to a
// non-capturing number matcher
// **Validates: Requirements 1.1, 1.2, 1.3, 2.1, 2.2**
test "property: number and number? parse to a non-capturing number matcher" {
    const opt_gen = gen.boolean();

    try minish.check(testing.allocator, opt_gen, struct {
        fn prop(optional: bool) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const elem_text = if (optional) "number?" else "number";
            const source = try std.fmt.allocPrint(alloc, "[[patterns]]\ntype = \"num\"\nsequence = [\"{s}\"]\n", .{elem_text});
            const grammar = try parseGrammar(source, alloc);
            const elem = grammar.patterns[0].sequence[0];
            try testing.expect(elem.matcher.kind == .one and elem.matcher.kind.one == .number);
            try testing.expectEqual(optional, elem.is_optional);
            try testing.expectEqual(@as(usize, 0), grammar.patterns[0].captures.len);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: number-token-primitive, Property 2: existing primitives are unaffected by the
// number branch
// **Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5, 8.1**
test "property: existing primitives are unaffected by the number branch" {
    const punct = "(){}[],;:.@?+-*/=<>!&|^%~";
    const tuple_gen = comptime gen.tuple2(
        u8,
        []const u8,
        gen.intRange(u8, 0, 4),
        gen.string(.{ .min_len = 2, .max_len = 8, .charset = .alpha }),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { u8, []const u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const form: []const u8 = switch (vals[0]) {
                0 => "identifier",
                1 => "Config:IDENTIFIER",
                2 => "$name:IDENTIFIER",
                3 => &[1]u8{punct[vals[0]]},
                else => vals[1],
            };
            if (std.mem.eql(u8, form, "number")) return;

            const res = try parseSequenceElement(form, 0, alloc);
            switch (vals[0]) {
                0 => try testing.expect(res.element.matcher.kind == .one and res.element.matcher.kind.one == .identifier),
                1 => {
                    try testing.expect(res.element.matcher.kind == .one and res.element.matcher.kind.one == .identifier and res.element.matcher.text == .exact);
                    try testing.expectEqualStrings("Config", res.element.matcher.text.exact);
                },
                2 => {
                    try testing.expect(res.element.matcher.capture != null);
                    try testing.expectEqualStrings("name", res.element.matcher.capture.?.field_name);
                },
                3 => {
                    try testing.expect(res.element.matcher.kind == .punctuation);
                    try testing.expectEqualStrings(&[1]u8{punct[vals[0]]}, res.element.matcher.text.exact);
                },
                else => try testing.expect(res.element.matcher.kind == .one and res.element.matcher.kind.one == .keyword),
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: number-token-primitive, Property 6: round-trip through grammar formatting
// **Validates: Requirements 7.1, 7.2, 7.3**
test "property: round-trip through grammar formatting" {
    const opt_gen = gen.boolean();

    try minish.check(testing.allocator, opt_gen, struct {
        fn prop(optional: bool) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const seq = if (optional)
                "[\"fn\", \"number?\", \"$name:IDENTIFIER\", \"(\", \"number\"]"
            else
                "[\"fn\", \"number\", \"$name:IDENTIFIER\", \"(\"]";
            const source = try std.fmt.allocPrint(alloc, "[[patterns]]\ntype = \"t\"\nsequence = {s}\n", .{seq});
            const grammar = try parseGrammar(source, alloc);
            const formatted = try formatGrammar(grammar, alloc);
            const re = try parseGrammar(formatted, alloc);

            try testing.expectEqual(@as(usize, 1), re.patterns.len);
            try testing.expectEqual(grammar.patterns[0].sequence.len, re.patterns[0].sequence.len);
            for (grammar.patterns[0].sequence, re.patterns[0].sequence) |a, b| {
                try testing.expectEqual(a.is_optional, b.is_optional);
                try testing.expectEqual(@as(u8, matcherTag(a.matcher)), @as(u8, matcherTag(b.matcher)));
            }
        }
    }.prop, .{ .num_runs = 100 });
}

fn matcherTag(m: ComposableMatcher) u8 {
    const kind_tag: u8 = switch (m.kind) {
        .any => 0,
        .one => |k| switch (k) {
            .keyword => 1,
            .operator, .symbol, .delimiter => 2,
            .identifier => 3,
            .number => 4,
            .string => 5,
            else => 6,
        },
        .punctuation => 2,
        .id => 7,
    };
    const text_tag: u8 = switch (m.text) {
        .any => 0,
        .exact => 1,
    };
    return kind_tag * 4 + text_tag;
}

// Feature: number-token-primitive, Property 7: grammars without number are byte-for-byte
// stable (the new branch is never taken)
// **Validates: Requirements 8.1, 8.2**
test "property: grammars without number are stable through formatting" {
    const word_gen = gen.string(.{ .min_len = 2, .max_len = 8, .charset = .alpha });

    try minish.check(testing.allocator, word_gen, struct {
        fn prop(word: []const u8) !void {
            if (std.mem.eql(u8, word, "number") or std.mem.eql(u8, word, "identifier")) return;
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const source = try std.fmt.allocPrint(alloc, "[[patterns]]\ntype = \"t\"\nsequence = [\"{s}\", \"$name:IDENTIFIER\", \"(\"]\n", .{word});
            const grammar = try parseGrammar(source, alloc);
            const formatted = try formatGrammar(grammar, alloc);
            // The number branch must never contribute: no bare "number" primitive in output.
            try testing.expect(std.mem.indexOf(u8, formatted, "\"number\"") == null);
            try testing.expect(std.mem.indexOf(u8, formatted, "\"number?\"") == null);
            // Re-parse is stable.
            const re = try parseGrammar(formatted, alloc);
            try testing.expectEqual(grammar.patterns[0].sequence.len, re.patterns[0].sequence.len);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: multi-token-captures, Unit: parseSequenceElement parameter list
// **Validates: Requirements 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8**
test "parseSequenceElement: parameterized capture forms" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        const res = try parseSequenceElement("$name:IDENTIFIER", 0, alloc);
        try testing.expect(res.element.matcher.capture != null);
        try testing.expect(res.element.matcher.capture.?.separator == null);
        try testing.expect(res.element.matcher.capture.?.suffix_set == null);
        try testing.expectEqualStrings("name", res.element.matcher.capture.?.field_name);
    }
    {
        const res = try parseSequenceElement("$name:IDENTIFIER(sep=\".\")", 0, alloc);
        try testing.expectEqualStrings(".", res.element.matcher.capture.?.separator.?);
        try testing.expect(res.element.matcher.capture.?.suffix_set == null);
    }
    {
        const res = try parseSequenceElement("$name:IDENTIFIER(suffix=\"!?\")", 0, alloc);
        try testing.expect(res.element.matcher.capture.?.separator == null);
        try testing.expectEqualStrings("!?", res.element.matcher.capture.?.suffix_set.?);
    }
    {
        const res = try parseSequenceElement("$name:IDENTIFIER(sep=\"::\", suffix=\"!?\")", 0, alloc);
        try testing.expectEqualStrings("::", res.element.matcher.capture.?.separator.?);
        try testing.expectEqualStrings("!?", res.element.matcher.capture.?.suffix_set.?);
    }
    {
        const res = try parseSequenceElement("$name:IDENTIFIER(suffix=\"!?\", sep=\".\")", 0, alloc);
        try testing.expectEqualStrings(".", res.element.matcher.capture.?.separator.?);
        try testing.expectEqualStrings("!?", res.element.matcher.capture.?.suffix_set.?);
    }
    {
        const res = try parseSequenceElement("$name:IDENTIFIER(sep=\".\")?", 0, alloc);
        try testing.expect(res.element.is_optional);
        try testing.expectEqualStrings(".", res.element.matcher.capture.?.separator.?);
    }
}

test "parseSequenceElement: parameterized capture error cases" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bad = [_][]const u8{
        "$name:IDENTIFIER(sep=\"\")",
        "$name:IDENTIFIER(suffix=\"\")",
        "$name:IDENTIFIER(foo=\"x\")",
        "$name:IDENTIFIER(sep)",
        "$name:IDENTIFIER(sep=x)",
        "$name:IDENTIFIER(sep=\".\"",
        "$name:IDENTIFIER()",
        "$name:IDENTIFIER(sep=\".\", sep=\",\")",
        "$name:IDENTIFIER(sep=\".\", suffix=\"!\", suffix=\"?\")",
        "$name:IDENTIFIER(sep=\".\",)",
    };
    for (bad) |elem| {
        const res = parseSequenceElement(elem, 0, alloc);
        try testing.expectError(error.InvalidCaptureFormat, res);
    }
}

// Feature: multi-token-captures, Property 1: parameter list parses to the correct Capture fields
// **Validates: Requirements 1.1, 1.2, 1.3, 1.4, 1.5**
test "property: parameter list parses to the correct capture fields" {
    const P1Input = struct {
        field: []const u8,
        sep: []const u8,
        suffix: []const u8,
        mode: u8, // 0 bare, 1 sep, 2 suffix, 3 both
    };
    const p1_gen = gen.structure(P1Input, .{
        .field = gen.string(.{ .min_len = 1, .max_len = 6, .charset = .alpha }),
        .sep = gen.string(.{ .min_len = 1, .max_len = 6, .charset = .alpha }),
        .suffix = gen.string(.{ .min_len = 1, .max_len = 6, .charset = .alpha }),
        .mode = gen.intRange(u8, 0, 3),
    });

    try minish.check(testing.allocator, p1_gen, struct {
        fn prop(inp: P1Input) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const elem: []const u8 = switch (inp.mode) {
                0 => try std.fmt.allocPrint(alloc, "${s}:IDENTIFIER", .{inp.field}),
                1 => try std.fmt.allocPrint(alloc, "${s}:IDENTIFIER(sep=\"{s}\")", .{ inp.field, inp.sep }),
                2 => try std.fmt.allocPrint(alloc, "${s}:IDENTIFIER(suffix=\"{s}\")", .{ inp.field, inp.suffix }),
                else => try std.fmt.allocPrint(alloc, "${s}:IDENTIFIER(sep=\"{s}\", suffix=\"{s}\")", .{ inp.field, inp.sep, inp.suffix }),
            };
            const res = try parseSequenceElement(elem, 0, alloc);
            const cap = res.element.matcher.capture;
            try testing.expectEqualStrings(inp.field, cap.?.field_name);
            try testing.expectEqual(inp.mode == 0 or inp.mode == 2, cap.?.separator == null);
            try testing.expectEqual(inp.mode == 0 or inp.mode == 1, cap.?.suffix_set == null);
            if (inp.mode == 1 or inp.mode == 3) {
                try testing.expectEqualStrings(inp.sep, cap.?.separator.?);
            }
            if (inp.mode == 2 or inp.mode == 3) {
                try testing.expectEqualStrings(inp.suffix, cap.?.suffix_set.?);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: multi-token-captures, Property 2: malformed, empty, or unknown parameters are rejected
// **Validates: Requirements 1.6, 1.7, 1.8**
test "property: malformed, empty, or unknown parameters are rejected" {
    const bad = [_][]const u8{
        "$n:IDENTIFIER(sep=\"\")",
        "$n:IDENTIFIER(suffix=\"\")",
        "$n:IDENTIFIER(unknown=\"x\")",
        "$n:IDENTIFIER(sep)",
        "$n:IDENTIFIER(sep=x)",
        "$n:IDENTIFIER(sep=\".\"",
        "$n:IDENTIFIER()",
        "$n:IDENTIFIER(sep=\".\", sep=\",\")",
        "$n:IDENTIFIER(sep=\".\",)",
    };
    const idx_gen = gen.intRange(u8, 0, bad.len - 1);

    try minish.check(testing.allocator, idx_gen, struct {
        fn prop(idx: u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const res = parseSequenceElement(bad[idx], 0, arena.allocator());
            try testing.expectError(error.InvalidCaptureFormat, res);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: multi-token-captures, Property 9: capture parameters survive the round-trip
// **Validates: Requirements 7.1, 7.2, 7.3, 7.4**
test "property: capture parameters survive the round-trip" {
    const P9Input = struct {
        sep: []const u8,
        suffix: []const u8,
    };
    const p9_gen = gen.structure(P9Input, .{
        .sep = gen.string(.{ .min_len = 1, .max_len = 4, .charset = .alphanumeric }),
        .suffix = gen.string(.{ .min_len = 1, .max_len = 4, .charset = .alphanumeric }),
    });

    try minish.check(testing.allocator, p9_gen, struct {
        fn prop(inp: P9Input) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const source = try std.fmt.allocPrint(alloc,
                "[[patterns]]\ntype = \"t\"\nsequence = [\"$a:IDENTIFIER\", \"$b:IDENTIFIER(sep=\\\"{s}\\\")\", \"$c:IDENTIFIER(suffix=\\\"{s}\\\")\", \"$d:IDENTIFIER(sep=\\\"{s}\\\", suffix=\\\"{s}\\\")\"]\n",
                .{ inp.sep, inp.suffix, inp.sep, inp.suffix });
            const grammar = try parseGrammar(source, alloc);
            const formatted = try formatGrammar(grammar, alloc);
            const re = try parseGrammar(formatted, alloc);

            try testing.expectEqual(grammar.patterns[0].captures.len, re.patterns[0].captures.len);
            for (grammar.patterns[0].captures, re.patterns[0].captures) |a, b| {
                try testing.expectEqualStrings(a.field_name, b.field_name);
                try testing.expectEqual(a.separator != null, b.separator != null);
                try testing.expectEqual(a.suffix_set != null, b.suffix_set != null);
                if (a.separator) |sep| try testing.expectEqualStrings(sep, b.separator.?);
                if (a.suffix_set) |suf| try testing.expectEqualStrings(suf, b.suffix_set.?);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

test "formatGrammar: emits canonical parameter lists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\[[patterns]]
        \\type = "t"
        \\sequence = ["$a:IDENTIFIER", "$b:IDENTIFIER(sep=\".\")", "$c:IDENTIFIER(suffix=\"!?\")", "$d:IDENTIFIER(sep=\"::\", suffix=\"!?\")"]
    ;
    const grammar = try parseGrammar(source, alloc);
    const formatted = try formatGrammar(grammar, alloc);
    try testing.expect(std.mem.indexOf(u8, formatted, "$a:IDENTIFIER\"") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "$b:IDENTIFIER(sep=\\\".\\\")") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "$c:IDENTIFIER(suffix=\\\"!?\\\")") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "$d:IDENTIFIER(sep=\\\"::\\\", suffix=\\\"!?\\\")") != null);
    // Bare capture has no parameter list.
    try testing.expect(std.mem.indexOf(u8, formatted, "$a:IDENTIFIER(") == null);
}

// Feature: per-pattern-priors, Unit: prior parsing and validation
// **Validates: Requirements 1.1, 1.2, 1.3, 2.1, 2.2, 2.3, 2.4**
test "parseGrammar: prior parsing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        const source =
            \\[[patterns]]
            \\type = "t"
            \\sequence = ["identifier"]
            \\prior = 0.5
        ;
        const grammar = try parseGrammar(source, alloc);
        try testing.expectApproxEqRel(@as(f32, 0.5), grammar.patterns[0].prior, 0.001);
    }
    {
        const source =
            \\[[patterns]]
            \\type = "t"
            \\sequence = ["identifier"]
            \\prior = 2
        ;
        const grammar = try parseGrammar(source, alloc);
        try testing.expectApproxEqRel(@as(f32, 2.0), grammar.patterns[0].prior, 0.001);
    }
    {
        const source =
            \\[[patterns]]
            \\type = "t"
            \\sequence = ["identifier"]
        ;
        const grammar = try parseGrammar(source, alloc);
        try testing.expectApproxEqRel(@as(f32, 1.0), grammar.patterns[0].prior, 0.001);
    }
}

test "parseGrammar: invalid prior values rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bad = [_][]const u8{ "0.0", "-0.1", "2.5", "\"x\"" };
    for (bad) |val| {
        const source = try std.fmt.allocPrint(alloc,
            "[[patterns]]\ntype = \"t\"\nsequence = [\"identifier\"]\nprior = {s}\n",
            .{val});
        const result = parseGrammar(source, alloc);
        try testing.expectError(error.InvalidPriorValue, result);
    }
}

// Feature: per-pattern-priors, Property 4: Prior validation accepts in-range and rejects out-of-range
// **Validates: Requirements 2.1, 2.2, 2.3, 2.4**
test "property: prior validation accepts in-range and rejects out-of-range" {
    const tuple_gen = comptime gen.tuple2(
        i32,
        u8,
        gen.intRange(i32, -50, 50),
        gen.intRange(u8, 0, 2),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { i32, u8 }) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const value: f32 = 1.0 + @as(f32, @floatFromInt(vals[0])) / 50.0;
            const text: []const u8 = switch (vals[1]) {
                0 => try std.fmt.allocPrint(alloc, "{d}", .{value}),
                1 => try std.fmt.allocPrint(alloc, "0", .{}),
                else => "\"x\"",
            };
            const source = try std.fmt.allocPrint(alloc,
                "[[patterns]]\ntype = \"t\"\nsequence = [\"identifier\"]\nprior = {s}\n",
                .{text});
            const result = parseGrammar(source, alloc);
            const valid = vals[1] == 0 and value > 0.0 and value <= 2.0;
            if (valid) {
                const grammar = try result;
                try testing.expectApproxEqRel(value, grammar.patterns[0].prior, 0.001);
            } else {
                try testing.expectError(error.InvalidPriorValue, result);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: per-pattern-priors, Property 6: Round-trip preserves prior
// **Validates: Requirements 6.1, 6.2, 6.3**
test "property: round-trip preserves prior" {
    const prior_val_gen = gen.intRange(u16, 1, 200);

    try minish.check(testing.allocator, prior_val_gen, struct {
        fn prop(pct: u16) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const prior: f32 = @as(f32, @floatFromInt(pct)) / 100.0;
            const source = try std.fmt.allocPrint(alloc,
                "[[patterns]]\ntype = \"t\"\nsequence = [\"identifier\"]\nprior = {d}\n",
                .{prior});
            const grammar = try parseGrammar(source, alloc);
            const formatted = try formatGrammar(grammar, alloc);
            const re = try parseGrammar(formatted, alloc);
            try testing.expectApproxEqRel(prior, re.patterns[0].prior, 0.001);

            // Default prior omits the key; re-parse restores 1.0.
            const source_default = "[[patterns]]\ntype = \"t\"\nsequence = [\"identifier\"]\n";
            const def = try parseGrammar(source_default, alloc);
            const formatted_def = try formatGrammar(def, alloc);
            try testing.expect(std.mem.indexOf(u8, formatted_def, "prior =") == null);
            const re_def = try parseGrammar(formatted_def, alloc);
            try testing.expectApproxEqRel(@as(f32, 1.0), re_def.patterns[0].prior, 0.001);
        }
    }.prop, .{ .num_runs = 100 });
}

test "formatGrammar: prior emitted before constraints and only when non-default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\[[patterns]]
        \\type = "t"
        \\sequence = ["identifier"]
        \\prior = 0.4
        \\[[patterns.constraints]]
        \\type = "not"
        \\depth = 1
        \\values = ["fun"]
    ;
    const grammar = try parseGrammar(source, alloc);
    const formatted = try formatGrammar(grammar, alloc);
    const prior_pos = std.mem.indexOf(u8, formatted, "prior = 0.4").?;
    const constraints_pos = std.mem.indexOf(u8, formatted, "[[patterns.constraints]]").?;
    try testing.expect(prior_pos < constraints_pos);
}

// Feature: composable-matcher-model, Unit: new surface forms
// **Validates: Requirements 3.1, 3.2, 3.4, 4.1, 4.4, 9.1, 9.2**
test "parseSequenceElement: typed captures and kind wildcards" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        const res = try parseSequenceElement("$n:NUMBER", 0, alloc);
        try testing.expect(res.element.matcher.kind == .one and res.element.matcher.kind.one == .number);
        try testing.expect(res.element.matcher.capture != null);
        try testing.expectEqualStrings("n", res.element.matcher.capture.?.field_name);
    }
    {
        const res = try parseSequenceElement("$s:STRING", 0, alloc);
        try testing.expect(res.element.matcher.kind == .one and res.element.matcher.kind.one == .string);
        try testing.expect(res.element.matcher.capture != null);
        try testing.expectEqualStrings("s", res.element.matcher.capture.?.field_name);
    }
    {
        const res = try parseSequenceElement("string", 0, alloc);
        try testing.expect(res.element.matcher.kind == .one and res.element.matcher.kind.one == .string);
        try testing.expect(res.element.matcher.text == .any);
        try testing.expect(res.element.matcher.capture == null);
    }
    {
        const res = try parseSequenceElement("limit:NUMBER", 0, alloc);
        try testing.expect(res.element.matcher.kind == .one and res.element.matcher.kind.one == .number);
        try testing.expect(res.element.matcher.text == .exact);
        try testing.expectEqualStrings("limit", res.element.matcher.text.exact);
        try testing.expect(res.element.matcher.capture == null);
    }
    {
        const res = try parseSequenceElement("tag:STRING", 0, alloc);
        try testing.expect(res.element.matcher.kind == .one and res.element.matcher.kind.one == .string);
        try testing.expect(res.element.matcher.text == .exact);
        try testing.expectEqualStrings("tag", res.element.matcher.text.exact);
    }
    {
        const bad = [_][]const u8{ "$f:BOGUS", "Name:BOGUS" };
        for (bad) |elem| {
            try testing.expectError(error.InvalidKindName, parseSequenceElement(elem, 0, alloc));
        }
    }
}

// Feature: composable-matcher-model, Property 8: Unknown-kind rejection
// **Validates: Requirements 3.4, 9.2**
test "property: unknown kind names are rejected" {
    const word_gen = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha });

    try minish.check(testing.allocator, word_gen, struct {
        fn prop(word: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const source = try std.fmt.allocPrint(alloc, "[[patterns]]\ntype = \"t\"\nsequence = [\"$f:{s}\"]\n", .{word});
            const result = parseGrammar(source, alloc);
            if (std.mem.eql(u8, word, "IDENTIFIER") or std.mem.eql(u8, word, "NUMBER") or std.mem.eql(u8, word, "STRING")) {
                const grammar = try result;
                try testing.expect(grammar.patterns[0].captures.len > 0);
            } else {
                try testing.expectError(error.InvalidKindName, result);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: composable-matcher-model, Property 6: new-form round-trip
// **Validates: Requirements 7.1, 7.4**
test "property: new surface forms round-trip" {
    const word_gen = gen.string(.{ .min_len = 1, .max_len = 6, .charset = .alpha });

    try minish.check(testing.allocator, word_gen, struct {
        fn prop(word: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const source = try std.fmt.allocPrint(alloc,
                "[[patterns]]\ntype = \"t\"\nsequence = [\"$a:NUMBER\", \"$b:STRING\", \"string\", \"{s}:NUMBER\"]\n",
                .{word});
            const grammar = try parseGrammar(source, alloc);
            const formatted = try formatGrammar(grammar, alloc);
            const re = try parseGrammar(formatted, alloc);
            try testing.expectEqual(grammar.patterns[0].sequence.len, re.patterns[0].sequence.len);
            for (grammar.patterns[0].sequence, re.patterns[0].sequence) |a, b| {
                try testing.expectEqual(matcherTag(a.matcher), matcherTag(b.matcher));
            }
        }
    }.prop, .{ .num_runs = 100 });
}


// --- configurable-token-kinds loader tests ---

test "char-set compiler: literals, ranges, mixed" {
    {
        const cc = try compileCharSet("abc");
        try testing.expect(cc.contains('a'));
        try testing.expect(cc.contains('b'));
        try testing.expect(cc.contains('c'));
        try testing.expect(!cc.contains('d'));
    }
    {
        const cc = try compileCharSet("a-z");
        try testing.expect(cc.contains('a'));
        try testing.expect(cc.contains('m'));
        try testing.expect(cc.contains('z'));
        try testing.expect(!cc.contains('A'));
        try testing.expect(!cc.contains('{'));
    }
    {
        const cc = try compileCharSet("a-zA-Z0-9_");
        try testing.expect(cc.contains('q'));
        try testing.expect(cc.contains('Q'));
        try testing.expect(cc.contains('7'));
        try testing.expect(cc.contains('_'));
        try testing.expect(!cc.contains('-'));
        try testing.expect(!cc.contains(' '));
    }
    {
        const cc = try compileCharSet("-a");
        try testing.expect(cc.contains('-'));
        try testing.expect(cc.contains('a'));
    }
}

test "char-set compiler: inverted range rejected" {
    try testing.expectError(error.InvalidCharSet, compileCharSet("z-a"));
    try testing.expectError(error.InvalidCharSet, compileCharSet("9-0"));
}

fn expectGrammarError(source: []const u8, expected: anyerror) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(expected, parseGrammar(source, arena.allocator()));
}

test "parseGrammar: [tokens] custom kinds parse into vocabulary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\[[patterns]]
        \\type = "t"
        \\sequence = ["ident", "$v:ident", "->", "quoted"]
        \\
        \\[tokens]
        \\ident = { char_class_run = { start = "a-zA-Z_", continue = "a-zA-Z0-9_" } }
        \\number = { char_class_run = { start = "0-9" } }
        \\quoted = { delimited_span = { open = "'", close = "'" } }
        \\arrow = { literal_set = ["->", "=>"] }
    ;
    const grammar = try parseGrammar(source, alloc);
    const vocab = grammar.tokens.?;
    try testing.expectEqual(@as(usize, 4), vocab.kinds.len);

    // Declaration order preserved as priority.
    try testing.expectEqualStrings("ident", vocab.kinds[0].name);
    try testing.expectEqualStrings("number", vocab.kinds[1].name);
    try testing.expectEqualStrings("quoted", vocab.kinds[2].name);
    try testing.expectEqualStrings("arrow", vocab.kinds[3].name);

    try testing.expect(vocab.kinds[0].recognizer == .char_class_run);
    try testing.expect(vocab.kinds[0].recognizer.char_class_run.start.contains('A'));
    try testing.expect(vocab.kinds[0].recognizer.char_class_run.start.contains('_'));
    try testing.expect(vocab.kinds[0].recognizer.char_class_run.cont.contains('9'));
    try testing.expect(vocab.kinds[1].recognizer == .char_class_run);
    try testing.expect(vocab.kinds[1].recognizer.char_class_run.start.contains('5'));
    try testing.expect(!vocab.kinds[1].recognizer.char_class_run.cont.contains('.'));
    try testing.expect(vocab.kinds[2].recognizer == .delimited_span);
    try testing.expectEqualStrings("'", vocab.kinds[2].recognizer.delimited_span.open);
    try testing.expect(vocab.kinds[3].recognizer == .literal_set);
    try testing.expectEqual(@as(usize, 2), vocab.kinds[3].recognizer.literal_set.len);

    // Sequence matchers: bare custom kind references resolve to .id.
    const seq = grammar.patterns[0].sequence;
    try testing.expectEqual(@as(usize, 4), seq.len);
    try testing.expect(seq[0].matcher.kind == .id and seq[0].matcher.kind.id == 0);
    try testing.expect(seq[1].matcher.kind == .id and seq[1].matcher.kind.id == 0);
    try testing.expect(seq[1].matcher.capture != null);
    try testing.expect(seq[3].matcher.kind == .id and seq[3].matcher.kind.id == 2);
}

test "parseGrammar: [tokens] validation errors" {
    // Duplicate kind names cannot be expressed in TOML (the parser rejects duplicate
    // keys as InvalidToml before the loader sees them); the DuplicateKindName guard
    // remains as defense-in-depth for non-TOML frontends.

    // Empty kind name.
    try expectGrammarError(
        \\[[patterns]]
        \\type = "t"
        \\sequence = ["identifier"]
        \\
        \\[tokens]
        \\"" = { char_class_run = { start = "a-z" } }
    , error.EmptyKindName);

    // Zero recognizers on a kind.
    try expectGrammarError(
        \\[[patterns]]
        \\type = "t"
        \\sequence = ["identifier"]
        \\
        \\[tokens]
        \\a = { }
    , error.InvalidRecognizer);

    // Multiple recognizers on a kind.
    try expectGrammarError(
        \\[[patterns]]
        \\type = "t"
        \\sequence = ["identifier"]
        \\
        \\[tokens]
        \\a = { char_class_run = { start = "a-z" }, literal_set = ["x"] }
    , error.InvalidRecognizer);

    // Empty char-class start set.
    try expectGrammarError(
        \\[[patterns]]
        \\type = "t"
        \\sequence = ["identifier"]
        \\
        \\[tokens]
        \\a = { char_class_run = { start = "" } }
    , error.InvalidCharSet);

    // Inverted char-class range.
    try expectGrammarError(
        \\[[patterns]]
        \\type = "t"
        \\sequence = ["identifier"]
        \\
        \\[tokens]
        \\a = { char_class_run = { start = "z-a" } }
    , error.InvalidCharSet);

    // Empty span open/close.
    try expectGrammarError(
        \\[[patterns]]
        \\type = "t"
        \\sequence = ["identifier"]
        \\
        \\[tokens]
        \\a = { delimited_span = { open = "", close = "'" } }
    , error.InvalidRecognizer);

    // Empty literal set / member.
    try expectGrammarError(
        \\[[patterns]]
        \\type = "t"
        \\sequence = ["identifier"]
        \\
        \\[tokens]
        \\a = { literal_set = [] }
    , error.EmptyLiteralSet);
    try expectGrammarError(
        \\[[patterns]]
        \\type = "t"
        \\sequence = ["identifier"]
        \\
        \\[tokens]
        \\a = { literal_set = [""] }
    , error.EmptyLiteralSet);
}

test "parseGrammar: [tokens] absent yields no vocabulary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grammar = try parseGrammar("[[patterns]]\ntype = \"t\"\nsequence = [\"identifier\"]\n", arena.allocator());
    try testing.expect(grammar.tokens == null);
}

test "formatGrammar: [tokens] round-trips to an equivalent vocabulary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\[[patterns]]
        \\type = "t"
        \\sequence = ["ident", "number", "$s:quoted", "arrow"]
        \\
        \\[tokens]
        \\ident = { char_class_run = { start = "a-zA-Z_", continue = "a-zA-Z0-9_" } }
        \\number = { char_class_run = { start = "0-9", continue = "0-9." } }
        \\quoted = { delimited_span = { open = "'", close = "'", escape = "\\" } }
        \\arrow = { literal_set = ["->", "=>"] }
    ;
    const grammar = try parseGrammar(source, alloc);
    const formatted = try formatGrammar(grammar, alloc);
    const re = try parseGrammar(formatted, alloc);

    const v1 = grammar.tokens.?;
    const v2 = re.tokens.?;
    try testing.expectEqual(v1.kinds.len, v2.kinds.len);
    for (v1.kinds, v2.kinds) |a, b| {
        try testing.expectEqualStrings(a.name, b.name);
        try testing.expect(std.meta.activeTag(a.recognizer) == std.meta.activeTag(b.recognizer));
        switch (a.recognizer) {
            .char_class_run => |ra| {
                const rb = b.recognizer.char_class_run;
                var ch: usize = 0;
                while (ch < 256) : (ch += 1) {
                    try testing.expectEqual(ra.start.bits[ch], rb.start.bits[ch]);
                    try testing.expectEqual(ra.cont.bits[ch], rb.cont.bits[ch]);
                }
            },
            .delimited_span => |da| {
                const db = b.recognizer.delimited_span;
                try testing.expectEqualStrings(da.open, db.open);
                try testing.expectEqualStrings(da.close, db.close);
                try testing.expectEqual(da.escape, db.escape);
            },
            .literal_set => |la| {
                const lb = b.recognizer.literal_set;
                try testing.expectEqual(la.len, lb.len);
                for (la, lb) |x, y| try testing.expectEqualStrings(x, y);
            },
        }
    }

    // Matchers survive with identical kind ids.
    try testing.expectEqual(grammar.patterns[0].sequence.len, re.patterns[0].sequence.len);
    for (grammar.patterns[0].sequence, re.patterns[0].sequence) |a, b| {
        try testing.expectEqual(@as(u8, matcherTag(a.matcher)), @as(u8, matcherTag(b.matcher)));
        if (a.matcher.kind == .id) {
            try testing.expect(b.matcher.kind == .id and b.matcher.kind.id == a.matcher.kind.id);
        }
    }
}

test "formatGrammar: default-profile grammar emits no [tokens]" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const grammar = try parseGrammar("[[patterns]]\ntype = \"t\"\nsequence = [\"identifier\"]\n", alloc);
    const formatted = try formatGrammar(grammar, alloc);
    try testing.expect(std.mem.indexOf(u8, formatted, "[tokens]") == null);
}

// Feature: configurable-token-kinds, Property 6: Custom-kind matching and capture
test "property: custom kind bare reference resolves to kind id" {
    const word_gen = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha });

    try minish.check(testing.allocator, word_gen, struct {
        fn prop(word: []const u8) !void {
            if (std.mem.eql(u8, word, "identifier") or std.mem.eql(u8, word, "number") or std.mem.eql(u8, word, "string")) return;
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            const source = try std.fmt.allocPrint(alloc,
                "[[patterns]]\ntype = \"t\"\nsequence = [\"{s}\"]\n\n[tokens]\n{s} = {{ char_class_run = {{ start = \"a-z\" }} }}\n",
                .{ word, word });
            const grammar = try parseGrammar(source, alloc);
            const elem = grammar.patterns[0].sequence[0];
            try testing.expect(elem.matcher.kind == .id);
            try testing.expectEqual(@as(usize, 0), elem.matcher.kind.id);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: configurable-token-kinds, Property 7: Unknown-kind reference rejected
test "property: unknown custom kind reference rejected" {
    const word_gen = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha });

    try minish.check(testing.allocator, word_gen, struct {
        fn prop(word: []const u8) !void {
            if (std.mem.eql(u8, word, "IDENTIFIER") or std.mem.eql(u8, word, "NUMBER") or std.mem.eql(u8, word, "STRING")) return;
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            const source = try std.fmt.allocPrint(alloc,
                "[[patterns]]\ntype = \"t\"\nsequence = [\"$f:{s}\"]\n\n[tokens]\nother = {{ char_class_run = {{ start = \"a-z\" }} }}\n",
                .{word});
            const result = parseGrammar(source, alloc);
            if (!std.mem.eql(u8, word, "other")) {
                try testing.expectError(error.InvalidKindName, result);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: configurable-token-kinds, Property 9: [tokens] validation rejects malformed declarations
test "property: [tokens] validation rejects malformed declarations" {
    const bad_sources = [_][]const u8{
        "[tokens]\na = { char_class_run = { start = \"\" } }\n",
        "[tokens]\na = { char_class_run = { start = \"z-a\" } }\n",
        "[tokens]\na = { char_class_run = { start = \"a-z\" }, literal_set = [\"x\"] }\n",
        "[tokens]\na = { delimited_span = { open = \"\", close = \"'\" } }\n",
        "[tokens]\na = { literal_set = [] }\n",
        "[tokens]\na = { literal_set = [\"\"] }\n",
        "[tokens]\n\"\" = { char_class_run = { start = \"a-z\" } }\n",
    };
    const idx_gen = gen.intRange(u8, 0, bad_sources.len - 1);

    try minish.check(testing.allocator, idx_gen, struct {
        fn prop(idx: u8) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            const source = try std.fmt.allocPrint(alloc,
                "[[patterns]]\ntype = \"t\"\nsequence = [\"identifier\"]\n{s}",
                .{bad_sources[idx]});
            const result = parseGrammar(source, alloc);
            if (result) |_| {
                try testing.expect(false); // malformed declaration must fail
            } else |e| {
                switch (e) {
                    error.InvalidCharSet, error.InvalidRecognizer, error.EmptyLiteralSet, error.EmptyKindName => {},
                    else => return e,
                }
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: configurable-token-kinds, Property 10: [tokens] round-trip
test "property: [tokens] round-trip preserves vocabulary" {
    const tuple_gen = comptime gen.tuple2(
        []const u8,
        []const u8,
        gen.string(.{ .min_len = 1, .max_len = 6, .charset = .alpha }),
        gen.string(.{ .min_len = 1, .max_len = 4, .charset = .alpha }),
    );

    try minish.check(testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { []const u8, []const u8 }) !void {
            const name = vals[0];
            const lit = vals[1];
            if (std.mem.eql(u8, name, "identifier")) return;
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const source = try std.fmt.allocPrint(alloc,
                "[[patterns]]\ntype = \"t\"\nsequence = [\"{s}\", \"$f:{s}\"]\n\n[tokens]\n{s} = {{ literal_set = [\"{s}\"] }}\n",
                .{ name, name, name, lit });
            const grammar = try parseGrammar(source, alloc);
            const formatted = try formatGrammar(grammar, alloc);
            const re = try parseGrammar(formatted, alloc);

            try testing.expectEqual(grammar.tokens.?.kinds.len, re.tokens.?.kinds.len);
            try testing.expectEqualStrings(grammar.tokens.?.kinds[0].name, re.tokens.?.kinds[0].name);
            try testing.expectEqualStrings(lit, re.tokens.?.kinds[0].recognizer.literal_set[0]);
            try testing.expectEqual(grammar.patterns[0].sequence.len, re.patterns[0].sequence.len);
            for (grammar.patterns[0].sequence, re.patterns[0].sequence) |a, b| {
                try testing.expectEqual(@as(u8, matcherTag(a.matcher)), @as(u8, matcherTag(b.matcher)));
            }
        }
    }.prop, .{ .num_runs = 100 });
}
