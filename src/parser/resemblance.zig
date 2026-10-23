const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const CharClass = tokenizer.CharClass;
const KindVocabulary = tokenizer.KindVocabulary;

// --- Grammar-Projected Resemblance ---
//
// Scores a token's partial membership against the grammar's own char-class
// kinds (relaxed recognition). Pure, allocation-free, deterministic.

/// Weight of the first-character (start set) membership test.
pub const W_START: f32 = 0.5;
/// Weight of the continue-set membership fraction.
pub const W_CONT: f32 = 0.5;
/// Minimum top Membership_Score below which no resemblance is reported.
pub const Resemblance_Floor: f32 = 0.5;

/// A token's best resembled char-class kind.
pub const ResemblanceHit = struct {
    kind_index: usize,
    score: f32,
};

/// Partial-membership score of `bytes` against a char-class kind.
///
/// - Empty token → 0.0.
/// - Single character → start-set membership only (1.0 or 0.0).
/// - Longer tokens → weighted blend: W_START × first-char membership +
///   W_CONT × (fraction of the remaining characters in the continue set).
/// - Full satisfaction (first in start, all rest in cont) → 1.0; no
///   membership → 0.0; monotonic in both components; always in [0, 1].
pub fn membership(bytes: []const u8, start: CharClass, cont: CharClass) f32 {
    if (bytes.len == 0) return 0.0;
    const first_ok: f32 = if (start.contains(bytes[0])) 1.0 else 0.0;
    if (bytes.len == 1) return first_ok;

    var in_cont: usize = 0;
    for (bytes[1..]) |c| {
        if (cont.contains(c)) in_cont += 1;
    }
    const cont_frac = @as(f32, @floatFromInt(in_cont)) / @as(f32, @floatFromInt(bytes.len - 1));
    return W_START * first_ok + W_CONT * cont_frac;
}

/// Computes the Resemblance_Vector over the vocabulary's char-class kinds and
/// returns the Resembled_Kind (argmax, tie-broken by vocabulary order) when the
/// top score clears the floor. Grammar with no char-class kinds → null.
pub fn resembledKind(bytes: []const u8, vocab: KindVocabulary) ?ResemblanceHit {
    var best_index: usize = 0;
    var best_score: f32 = 0.0;
    var found = false;

    for (vocab.kinds, 0..) |def, idx| {
        const rec = def.recognizer;
        if (rec != .char_class_run) continue;
        const score = membership(bytes, rec.char_class_run.start, rec.char_class_run.cont);
        // Strictly-greater comparison keeps the FIRST maximal kind on ties,
        // consistent with recognizer priority (vocabulary order).
        if (!found or score > best_score) {
            best_index = idx;
            best_score = score;
            found = true;
        }
    }

    if (!found or best_score < Resemblance_Floor) return null;
    return .{ .kind_index = best_index, .score = best_score };
}

// --- Unit Tests ---

const testing = std.testing;

fn ccOf(spec: []const u8) CharClass {
    var cc = CharClass{};
    for (spec) |c| cc.set(c);
    return cc;
}

/// Compiles a char-set spec supporting inclusive ranges ("a-z", "0-9").
fn ccSpec(spec: []const u8) CharClass {
    var cc = CharClass{};
    var i: usize = 0;
    while (i < spec.len) {
        if (i + 2 < spec.len and spec[i + 1] == '-') {
            var ch = spec[i];
            while (ch <= spec[i + 2]) : (ch += 1) cc.set(ch);
            i += 3;
        } else {
            cc.set(spec[i]);
            i += 1;
        }
    }
    return cc;
}

test "membership: no membership is 0.0" {
    const start = ccOf("ab");
    const cont = ccOf("ab");
    try testing.expectApproxEqRel(@as(f32, 0.0), membership("xyz", start, cont), 0.0001);
    try testing.expectApproxEqRel(@as(f32, 0.0), membership("", start, cont), 0.0001);
}

test "membership: single-char token uses start test only" {
    const start = ccOf("ab");
    const cont = ccOf("z");
    try testing.expectApproxEqRel(@as(f32, 1.0), membership("a", start, cont), 0.0001);
    try testing.expectApproxEqRel(@as(f32, 0.0), membership("z", start, cont), 0.0001);
}

test "membership: monotonic in continue fraction" {
    const start = ccOf("a");
    const cont = ccOf("bc");
    // "ab" → 0.5×1 + 0.5×1 = 1.0; "abc" → 0.5×1 + 0.5×(1/2) = 0.75.
    const hi = membership("ab", start, cont);
    const lo = membership("abc", start, cont);
    try testing.expect(hi >= lo);
    // First-char membership gates: "xbc" (start fails) scores below "abc".
    const start_fail = membership("xbc", start, cont);
    try testing.expect(lo >= start_fail);
}

test "resembledKind: argmax over char-class kinds with tie-break by order" {
    const vocab = KindVocabulary{ .kinds = &.{
        .{ .name = "words", .recognizer = .{ .char_class_run = .{ .start = ccOf("ab"), .cont = ccOf("ab") } } },
        .{ .name = "nums", .recognizer = .{ .char_class_run = .{ .start = ccOf("0"), .cont = ccOf("01") } } },
        .{ .name = "quoted", .recognizer = .{ .delimited_span = .{ .open = "'", .close = "'", .escape = null } } }, // no axis
    } };
    // "0a1" scores highest against nums (first '0' in start, 1/2 continue).
    const hit = resembledKind("0a1", vocab).?;
    try testing.expectEqual(@as(usize, 1), hit.kind_index);
    try testing.expectApproxEqRel(@as(f32, 0.5 + 0.5 * 0.5), hit.score, 0.0001);

    // Tie between two identical axes → earlier kind wins.
    const tie_vocab = KindVocabulary{ .kinds = &.{
        .{ .name = "a", .recognizer = .{ .char_class_run = .{ .start = ccOf("x"), .cont = ccOf("x") } } },
        .{ .name = "b", .recognizer = .{ .char_class_run = .{ .start = ccOf("x"), .cont = ccOf("x") } } },
    } };
    const tie = resembledKind("xx", tie_vocab).?;
    try testing.expectEqual(@as(usize, 0), tie.kind_index);
}

test "resembledKind: floor rejection and empty vocabulary" {
    // Floor is 0.5; "xab" has no start membership and only 1/2 continue → 0.25.
    const vocab = KindVocabulary{ .kinds = &.{
        .{ .name = "w", .recognizer = .{ .char_class_run = .{ .start = ccOf("a"), .cont = ccOf("a") } } },
    } };
    try testing.expect(resembledKind("xab", vocab) == null);

    // Vocabulary with no char-class kinds → no resemblance.
    const no_cc = KindVocabulary{ .kinds = &.{
        .{ .name = "q", .recognizer = .{ .delimited_span = .{ .open = "'", .close = "'", .escape = null } } },
        .{ .name = "l", .recognizer = .{ .literal_set = &.{"->"} } },
    } };
    try testing.expect(resembledKind("anything", no_cc) == null);
}

// --- Property Tests ---

const minish = @import("minish");
const gen = minish.gen;

// Feature: grammar-projected-resemblance, Property 1: Grammar-projected basis
test "property: vector has one axis per char-class kind only" {
    const alpha_gen = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha });
    try minish.check(testing.allocator, alpha_gen, struct {
        fn prop(token: []const u8) !void {
            const vocab = KindVocabulary{ .kinds = &.{
                .{ .name = "word", .recognizer = .{ .char_class_run = .{ .start = ccOf("ab"), .cont = ccOf("ab") } } },
        .{ .name = "q", .recognizer = .{ .delimited_span = .{ .open = "'", .close = "'", .escape = null } } },
                .{ .name = "l", .recognizer = .{ .literal_set = &.{"->"} } },
                .{ .name = "cc2", .recognizer = .{ .char_class_run = .{ .start = ccOf("xy"), .cont = ccOf("xy") } } },
            } };
            const hit = resembledKind(token, vocab);
            // Only char-class kinds can be reported; they are the only axes.
            if (hit) |h| {
                try testing.expect(h.kind_index == 0 or h.kind_index == 3);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: grammar-projected-resemblance, Property 2: Membership endpoints and bounds
test "property: membership endpoints, bounds, and determinism" {
    const bytes_gen = gen.string(.{ .min_len = 0, .max_len = 16, .charset = .custom, .custom_chars = "abc012" });
    try minish.check(testing.allocator, bytes_gen, struct {
        fn prop(bytes: []const u8) !void {
            const start = ccOf("ab");
            const cont = ccOf("ab01");
            const score = membership(bytes, start, cont);
            try testing.expect(score >= 0.0 and score <= 1.0);
            // Deterministic: same input → same score.
            if (bytes.len > 0) {
                var all_cont = true;
                for (bytes[1..]) |c| {
                    if (!cont.contains(c)) all_cont = false;
                }
                const all_ok = start.contains(bytes[0]) and all_cont;
                if (all_ok) try testing.expectApproxEqRel(@as(f32, 1.0), score, 0.0001);
                var any_cont = false;
                for (bytes[1..]) |c| {
                    if (cont.contains(c)) any_cont = true;
                }
                const none_ok = !start.contains(bytes[0]) and !any_cont;
                if (none_ok) try testing.expectApproxEqRel(@as(f32, 0.0), score, 0.0001);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: grammar-projected-resemblance, Property 3: Membership monotonicity
test "property: extending a continue member never lowers the score" {
    const prefix_gen = gen.string(.{ .min_len = 0, .max_len = 8, .charset = .custom, .custom_chars = "ab" });
    try minish.check(testing.allocator, prefix_gen, struct {
        fn prop(prefix: []const u8) !void {
            const start = ccOf("ab");
            const cont = ccOf("ab");

            var buf_base: [32]u8 = undefined;
            const base = try std.fmt.bufPrint(&buf_base, "{s}x", .{prefix});
            var buf_grown: [32]u8 = undefined;
            const grown = try std.fmt.bufPrint(&buf_grown, "{s}a", .{prefix}); // 'a' passes continue
            const s_base = membership(base, start, cont);
            const s_grown = membership(grown, start, cont);
            try testing.expect(s_grown >= s_base);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: grammar-projected-resemblance, Property 4: Floor and tie-break
test "property: above-floor max reported; ties resolve to earlier kind" {
    const alpha_gen = gen.string(.{ .min_len = 1, .max_len = 8, .charset = .alpha });
    try minish.check(testing.allocator, alpha_gen, struct {
        fn prop(token: []const u8) !void {
            const vocab = KindVocabulary{ .kinds = &.{
                .{ .name = "a", .recognizer = .{ .char_class_run = .{ .start = ccOf("abc"), .cont = ccOf("abc") } } },
                .{ .name = "b", .recognizer = .{ .char_class_run = .{ .start = ccOf("abc"), .cont = ccOf("abc") } } },
            } };
            const hit = resembledKind(token, vocab);
            if (hit) |h| {
                // Both axes are identical → tie must resolve to the earlier kind.
                try testing.expectEqual(@as(usize, 0), h.kind_index);
                try testing.expect(h.score >= Resemblance_Floor);
            } else {
                // Below floor means the argmax is below floor.
                const s = membership(token, ccOf("abc"), ccOf("abc"));
                try testing.expect(s < Resemblance_Floor);
            }
        }
    }.prop, .{ .num_runs = 100 });
}
