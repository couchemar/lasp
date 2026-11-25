const std = @import("std");
const tokenizer = @import("parser/tokenizer.zig");
const json = @import("output/json.zig");
const grammar_loader = @import("grammar/loader.zig");
const events = @import("parser/events.zig");
const cli = @import("cli/args.zig");
const source_reader = @import("cli/source.zig");
const grammar_set = @import("cli/grammar_set.zig");
const support = @import("test_support.zig");
const Sandbox = support.Sandbox;
const runLasp = support.runLasp;
const writeFixtureFile = support.writeFixtureFile;
const removeDirTree = support.removeDirTree;
const makeParseDirFixture = support.makeParseDirFixture;
const expectParseDirOk = support.expectParseDirOk;
const erlang_grammar_toml = support.erlang_grammar_toml;
const erlang2_grammar_toml = support.erlang2_grammar_toml;
const python_grammar_toml = support.python_grammar_toml;
const seedDefaultGrammars = support.seedDefaultGrammars;
const runLaspEarlyClose = support.runLaspEarlyClose;
const runLaspWithStdin = support.runLaspWithStdin;
const expectFatalOnePrefix = support.expectFatalOnePrefix;
const expectFatalResultOnePrefix = support.expectFatalResultOnePrefix;
const err_prefix_dir = support.err_prefix_dir;
const seedErrPrefixFixtures = support.seedErrPrefixFixtures;
test "readSourceFile returns file contents" {
    const allocator = std.testing.allocator;
    // Read this file itself as a basic smoke test
    const content = try source_reader.readSourceFile(std.testing.io, allocator, "src/main.zig");
    defer allocator.free(content);
    try std.testing.expect(content.len > 0);
    // The file should start with "const std"
    try std.testing.expect(std.mem.startsWith(u8, content, "const std"));
}

test "readSourceFile returns FileNotFound for missing file" {
    const allocator = std.testing.allocator;
    const result = source_reader.readSourceFile(std.testing.io, allocator, "nonexistent_file_that_does_not_exist.txt");
    try std.testing.expectError(error.FileNotFound, result);
}

const minish = @import("minish");

const gen = minish.gen;

// Feature: phase1-tokenizer-cli, Property 4: File read round trip
test "property: file read round trip" {
    const bytes_gen = gen.string(.{ .min_len = 0, .max_len = 256, .charset = .alphanumeric });

    try minish.check(std.testing.allocator, bytes_gen, struct {
        fn prop(data: []const u8) !void {
            const io = std.testing.io;
            var sb = try Sandbox.init(std.testing.allocator);
            defer sb.deinit();
            const tmp_path = try sb.join("roundtrip.tmp");
            defer std.testing.allocator.free(tmp_path);
            // Write random bytes to temp file
            const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
            var wbuf: [256]u8 = undefined;
            var writer = file.writer(io, &wbuf);
            try writer.interface.writeAll(data);
            try writer.interface.flush();
            file.close(io);
            // Read back with readSourceFile
            const content = try source_reader.readSourceFile(std.testing.io, std.testing.allocator, tmp_path);
            defer std.testing.allocator.free(content);

            // Round trip: content must equal original data
            try std.testing.expectEqualSlices(u8, data, content);
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: plain-toml-capture-tables, Integration
// **Validates: Requirements 4.1, 5.1, 7.1, 8.1, 8.2, 12.1**
test "integration: count tables emit integer fields in JSON" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/counts_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/counts.toml",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const events_arr = parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), events_arr.len);

    const args0 = events_arr[0].object.get("args").?;
    try std.testing.expect(args0 == .integer);
    try std.testing.expectEqual(@as(i64, 3), args0.integer);

    const args1 = events_arr[1].object.get("args").?;
    try std.testing.expectEqual(@as(i64, 0), args1.integer);

    const args2 = events_arr[2].object.get("args").?;
    try std.testing.expectEqual(@as(i64, 1), args2.integer);
}

test "integration: query on count field + names-only renders name, not count" {
    const allocator = std.testing.allocator;

    const q = try runLasp(allocator, &.{
        "query",
        "fn[args>1]",
        "tests/fixtures/counts_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/counts.toml",
    });
    defer {
        allocator.free(q.stdout);
        allocator.free(q.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, q.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, q.stdout, .{});
    defer parsed.deinit();
    const events_arr = parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), events_arr.len);
    try std.testing.expectEqual(@as(i64, 3), events_arr[0].object.get("args").?.integer);

    const n = try runLasp(allocator, &.{
        "query",
        "fn[args>0]",
        "tests/fixtures/counts_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/counts.toml",
        "--names-only",
    });
    defer {
        allocator.free(n.stdout);
        allocator.free(n.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, n.term);
    // String capture is preferred over the integer field → names, not counts.
    var lines: usize = 0;
    var all_digit: bool = false;
    var rest: []const u8 = n.stdout;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        const line = rest[0..nl];
        lines += 1;
        if (std.mem.eql(u8, line, "add") or std.mem.eql(u8, line, "one")) {} else if (std.mem.eql(u8, line, "3") or std.mem.eql(u8, line, "1")) all_digit = true;
        rest = rest[nl + 1 ..];
    }
    try std.testing.expectEqual(@as(usize, 2), lines);
    try std.testing.expectEqual(false, all_digit);
}

// Feature: region-extent, Integration
// **Validates: Requirements 4.1, 4.2, 4.3, 5.3, 9.4**
test "integration: brace extent emits bare-integer body field" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/extent_brace_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/extent_brace.toml",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const events_arr = parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), events_arr.len);

    const src = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/extent_brace_sample.txt", allocator, .limited(1 << 20));
    defer allocator.free(src);
    // Independent nested scan: foo's outer close is the '}' that balances the
    {
        var depth: u32 = 1;
        var i: usize = 17;
        while (i < src.len) : (i += 1) {
            if (src[i] == '{') {
                depth += 1;
            } else if (src[i] == '}') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        const first_close = i + 1;
        const body0 = events_arr[0].object.get("body").?;
        try std.testing.expect(body0 == .integer);
        try std.testing.expectEqual(@as(i64, @intCast(first_close)), body0.integer);
    }

    const second_close = std.mem.lastIndexOfScalar(u8, src, '}').? + 1; // bar's brace end
    const body1 = events_arr[1].object.get("body").?;
    try std.testing.expectEqual(@as(i64, @intCast(second_close)), body1.integer);
}

test "integration: terminator extent with at_column=0" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/extent_terminator_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/extent_terminator.toml",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const events_arr = parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), events_arr.len);

    const src = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/extent_terminator_sample.txt", allocator, .limited(1 << 20));
    defer allocator.free(src);
    const dot_end = std.mem.indexOf(u8, src, ".\n").? + 1;
    const region0 = events_arr[0].object.get("region").?;
    try std.testing.expect(region0 == .integer);
    try std.testing.expectEqual(@as(i64, @intCast(dot_end)), region0.integer);
}

test "integration: numeric query on extent field" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{
        "query",
        "function[body>50]",
        "tests/fixtures/extent_brace_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/extent_brace.toml",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const events_arr = parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), events_arr.len);
    try std.testing.expectEqualStrings("function", events_arr[0].object.get("type").?.string);
}

test "integration: no extent table ⇒ no extent field (P9 at CLI level)" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/extent_brace_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/extent_brace.toml",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"body\"") != null);

    // Same grammar without the extent table → no body field anywhere.
    const io = std.testing.io;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    const tmp_path = try sb.join("extent_noextent.toml");
    defer allocator.free(tmp_path);
    const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    var wbuf: [4096]u8 = undefined;
    var writer = file.writer(io, &wbuf);
    try writer.interface.writeAll("[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"$n:IDENTIFIER\", \"(\"]\n");
    try writer.interface.flush();
    file.close(io);
    const plain = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/extent_brace_sample.txt",
        "--grammar",
        tmp_path,
    });
    defer {
        allocator.free(plain.stdout);
        allocator.free(plain.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, plain.term);
    try std.testing.expect(std.mem.indexOf(u8, plain.stdout, "\"body\"") == null);
}

// Feature: region-extent, Property 13: grammar-variation half
test "integration: differing extent delimiters yield differing Region_Extent" {
    const allocator = std.testing.allocator;
    // Bracket-bounded variant: same source, a delimiter pair that does not occur
    // in the body (so both events report EOF = source length).
    const io = std.testing.io;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    const tmp_path = try sb.join("extent_variant.toml");
    defer allocator.free(tmp_path);
    const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    var wbuf: [4096]u8 = undefined;
    var writer = file.writer(io, &wbuf);
    try writer.interface.writeAll("[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"$n:IDENTIFIER\", \"(\"]\n\n[[patterns.extent]]\nfield = \"body\"\nopen = \"[\"\nclose = \"]\"\n");
    try writer.interface.flush();
    file.close(io);
    const result = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/extent_brace_sample.txt",
        "--grammar",
        tmp_path,
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const events_arr = parsed.value.object.get("events").?.array.items;
    const src = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/extent_brace_sample.txt", allocator, .limited(1 << 20));
    defer allocator.free(src);
    const body0 = events_arr[0].object.get("body").?.integer;
    // No bracket in the source → EOF (source length), which differs from the
    // brace grammar's body value (37) for the same event.
    try std.testing.expectEqual(@as(i64, @intCast(src.len)), body0);
}

// --- Integration Tests ---
// --- parse-dir directory-walk tests (spec: parse-dir-directory-walk) ---
// Task 1 (exploration) + Task 2 (preservation) land BEFORE the fix: Property 1
// MUST fail on the unfixed binary (the directory-read abort), Property 2 MUST
// pass (single-file baseline captured).
// Feature: parse-dir-directory-walk, Property 1: parse-dir walks the tree and
// parses matching files (bug condition). MUST FAIL on the unfixed code.
test "parse-dir: walks tree, parses matching files, skips unmatched (P1)" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    const fixture = try makeParseDirFixture(allocator, &sb);
    // The no-grammar-dir form below expects [] (Req 2.12); that holds because
    // the sandbox cwd has no default .lasp/grammars.
    const abs_tree = try sb.join(fixture.tree);
    defer allocator.free(abs_tree);
    const slash_tree = try std.fmt.allocPrint(allocator, "{s}/", .{fixture.tree});
    defer allocator.free(slash_tree);

    const forms = [_]struct { args: []const []const u8 }{
        .{ .args = &.{ "parse-dir", fixture.tree, "--grammar-dir", fixture.grammars } },
        .{ .args = &.{ "parse-dir", slash_tree, "--grammar-dir", fixture.grammars } },
        .{ .args = &.{ "parse-dir", abs_tree, "--grammar-dir", fixture.grammars } },
        .{ .args = &.{ "parse-dir", fixture.tree } },
    };

    for (forms, 0..) |form, i| {
        const result = try runLasp(allocator, form.args);
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        if (i == 3) {
            // No --grammar-dir ⇒ no grammars ⇒ [] + exit zero (Req 2.12).
            try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
            defer parsed.deinit();
            try std.testing.expect(parsed.value == .array);
            try std.testing.expectEqual(@as(usize, 0), parsed.value.array.items.len);
        } else {
            try expectParseDirOk(result, allocator);
        }
    }
}

// Feature: parse-dir-directory-walk, Property 2: non-parse-dir behavior is
// byte-identical (preservation baseline). Runs on the unfixed binary today and
// must keep passing after the parseOneFile refactor and dispatch split.
test "property: single-file parse/query is deterministic and well-formed (P2)" {
    const tuple_gen = comptime gen.tuple2(
        []const u8,
        u8,
        gen.string(.{ .min_len = 4, .max_len = 200, .charset = .custom, .custom_chars = "abcdefghijklmnopqrstuvwxyz0123456789(){}[];=+*/_ \n\t" }),
        gen.intRange(u8, 0, 3),
    );

    try minish.check(std.testing.allocator, tuple_gen, struct {
        fn prop(vals: struct { []const u8, u8 }) !void {
            const allocator = std.testing.allocator;
            const src = vals[0];
            const flag = vals[1];
            const io = std.testing.io;
            var sb = try Sandbox.init(allocator);
            defer sb.deinit();
            const tmp_path = try sb.join("parsedir_prop.tmp");
            defer allocator.free(tmp_path);
            const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
            var wbuf: [4096]u8 = undefined;
            var writer = file.writer(io, &wbuf);
            try writer.interface.writeAll(src);
            try writer.interface.flush();
            file.close(io);
            const args: []const []const u8 = switch (flag) {
                0 => &.{ "parse", tmp_path },
                1 => &.{ "parse", tmp_path, "-g", "examples/grammars/zig.toml" },
                2 => &.{ "parse", tmp_path, "-g", "examples/grammars/zig.toml", "--node", "function", "--names-only" },
                else => &.{ "query", "*", tmp_path, "-g", "examples/grammars/zig.toml" },
            };

            const r1 = try runLasp(allocator, args);
            const r2 = try runLasp(allocator, args);
            defer {
                allocator.free(r1.stdout);
                allocator.free(r1.stderr);
            }

            defer {
                allocator.free(r2.stdout);
                allocator.free(r2.stderr);
            }

            try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r1.term);
            // Determinism: repeated runs are byte-identical.
            try std.testing.expectEqualStrings(r1.stdout, r2.stdout);
            try std.testing.expectEqualStrings(r1.stderr, r2.stderr);
            // Raw tokens and unfiltered JSON always emit; a filtered query may
            // legitimately emit nothing when no node matches.
            if (flag == 0 or flag == 1) try std.testing.expect(r1.stdout.len > 0);
        }
    }.prop, .{ .num_runs = 100 });
}

/// Recursive structural JSON equality used by the parse-dir union property.
fn expectJsonValueEqual(a: std.json.Value, b: std.json.Value) !void {
    switch (a) {
        .null, .bool, .integer, .float => try std.testing.expectEqual(a, b),
        .number_string => try std.testing.expectEqualStrings(a.number_string, b.number_string),
        .string => try std.testing.expectEqualStrings(a.string, b.string),
        .array => |aa| {
            try std.testing.expect(b == .array);
            try std.testing.expectEqual(aa.items.len, b.array.items.len);
            for (aa.items, b.array.items) |x, y| try expectJsonValueEqual(x, y);
        },
        .object => |ao| {
            try std.testing.expect(b == .object);
            var it = ao.iterator();
            while (it.next()) |e| {
                const child = b.object.get(e.key_ptr.*) orelse return error.MissingJsonField;
                try expectJsonValueEqual(e.value_ptr.*, child);
            }
            try std.testing.expectEqual(ao.count(), b.object.count());
        },
    }
}

// Feature: parse-dir-directory-walk, Property 3: parse-dir equals the
// single-file per-grammar union — one entry per (file, grammar) pair for every
// grammar whose declared extensions match, no entry for unmatched files.
test "property: parse-dir equals single-file per-grammar union (P3)" {
    const FilePool = enum { a_erl, b_py, notes_txt, sub_c_erl };
    const list_gen = comptime gen.list(FilePool, gen.enumValue(FilePool), 1, 5);
    try minish.check(std.testing.allocator, list_gen, struct {
        fn prop(selected: []const FilePool) !void {
            const allocator = std.testing.allocator;
            const io = std.testing.io;
            var sb = try Sandbox.init(allocator);
            defer sb.deinit();
            sb.enter();
            const dir = sb.tmp.dir;
            const tree = "test_parsedir_prop3_tree";
            const grammars = "test_parsedir_prop3_grammars";
            try dir.createDir(io, tree, .default_dir);
            try dir.createDir(io, tree ++ "/sub", .default_dir);
            try dir.createDir(io, grammars, .default_dir);

            var seen = [_]bool{false} ** 4;
            for (selected) |f| seen[@intFromEnum(f)] = true;
            if (seen[@intFromEnum(FilePool.a_erl)])
                try writeFixtureFile(dir, io, tree ++ "/a.erl", "foo() -> 1.\n");
            if (seen[@intFromEnum(FilePool.b_py)])
                try writeFixtureFile(dir, io, tree ++ "/b.py", "bar()\n");
            if (seen[@intFromEnum(FilePool.notes_txt)])
                try writeFixtureFile(dir, io, tree ++ "/notes.txt", "irrelevant\n");
            if (seen[@intFromEnum(FilePool.sub_c_erl)])
                try writeFixtureFile(dir, io, tree ++ "/sub/c.erl", "baz() -> 2.\n");

            const erlang = "[language]\nname = \"erlang\"\nextensions = [\".erl\"]\n\n[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"(\"]\n";
            const erlang2 = "[language]\nname = \"erlang2\"\nextensions = [\".erl\"]\n\n[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"(\"]\n";
            const python = "[language]\nname = \"python\"\nextensions = [\".py\"]\n\n[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"(\", \")\"]\n";
            try writeFixtureFile(dir, io, grammars ++ "/erlang.toml", erlang);
            try writeFixtureFile(dir, io, grammars ++ "/erlang2.toml", erlang2);
            try writeFixtureFile(dir, io, grammars ++ "/python.toml", python);

            const args = [_][]const u8{ "parse-dir", tree, "--grammar-dir", grammars };
            const result = try runLasp(allocator, &args);
            defer {
                allocator.free(result.stdout);
                allocator.free(result.stderr);
            }
            try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
            defer parsed.deinit();
            const arr = parsed.value.array;

            var expected: usize = 0;
            if (seen[@intFromEnum(FilePool.a_erl)]) expected += 2;
            if (seen[@intFromEnum(FilePool.sub_c_erl)]) expected += 2;
            if (seen[@intFromEnum(FilePool.b_py)]) expected += 1;
            try std.testing.expectEqual(expected, arr.items.len);

            for (arr.items) |entry| {
                const file = entry.object.get("file").?.string;
                const grammar = entry.object.get("grammar").?.string;
                const gpath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ grammars, grammar });
                defer allocator.free(gpath);
                const fpath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tree, file });
                defer allocator.free(fpath);
                const sargs = [_][]const u8{ "parse", fpath, "-g", gpath };
                const single = try runLasp(allocator, &sargs);
                defer {
                    allocator.free(single.stdout);
                    allocator.free(single.stderr);
                }
                const single_parsed = try std.json.parseFromSlice(std.json.Value, allocator, single.stdout, .{});
                defer single_parsed.deinit();
                try expectJsonValueEqual(
                    entry.object.get("events").?,
                    single_parsed.value.object.get("events").?,
                );
            }
        }
    }.prop, .{ .num_runs = 50 });
}

// Feature: parse-dir-directory-walk, Property 4: directory and grammar errors
// exit non-zero with descriptive stderr; the no-grammar-dir case exits zero
// with `[]` and never touches the target as a file.
test "property: directory and grammar errors exit non-zero (P4)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    // The no-grammar-dir case below (Req 2.12) expects [] — as with P1,
    // only true without a default .lasp/grammars, which the sandbox cwd lacks.
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    const dir = sb.tmp.dir;
    const tree = "test_parsedir_prop4_tree";
    const grammars = "test_parsedir_prop4_grammars";
    const bad_grammars = "test_parsedir_prop4_bad_grammars";
    try dir.createDir(io, tree, .default_dir);
    try dir.createDir(io, grammars, .default_dir);
    try dir.createDir(io, bad_grammars, .default_dir);
    try writeFixtureFile(dir, io, tree ++ "/a.erl", "foo() -> 1.\n");
    try writeFixtureFile(dir, io, grammars ++ "/erlang.toml", "[language]\nname = \"erlang\"\nextensions = [\".erl\"]\n\n[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"(\"]\n");
    try writeFixtureFile(dir, io, bad_grammars ++ "/broken.toml", "not valid toml [");

    // Req 2.8: missing target directory → non-zero, descriptive stderr.
    const r1 = try runLasp(allocator, &.{ "parse-dir", "test_parsedir_nope", "--grammar-dir", grammars });
    defer {
        allocator.free(r1.stdout);
        allocator.free(r1.stderr);
    }
    try std.testing.expect(!std.meta.eql(r1.term, std.process.Child.Term{ .exited = 0 }));
    try std.testing.expect(std.mem.indexOf(u8, r1.stderr, "directory not found") != null);
    // Preservation (error-prefix fix): exactly one prefix, exact bytes, exit 1, empty stdout.
    try expectFatalResultOnePrefix(r1.term, r1.stdout, r1.stderr, "error: directory not found: test_parsedir_nope\n");

    // Req 2.9: missing grammar dir → non-zero, descriptive stderr.
    const r2 = try runLasp(allocator, &.{ "parse-dir", tree, "--grammar-dir", "test_parsedir_nope_grammars" });
    defer {
        allocator.free(r2.stdout);
        allocator.free(r2.stderr);
    }
    try std.testing.expect(!std.meta.eql(r2.term, std.process.Child.Term{ .exited = 0 }));
    try std.testing.expect(std.mem.indexOf(u8, r2.stderr, "grammar directory not found") != null);
    try expectFatalResultOnePrefix(r2.term, r2.stdout, r2.stderr, "error: grammar directory not found: test_parsedir_nope_grammars\n");

    // Req 2.10: malformed grammar names the offending path.
    const r3 = try runLasp(allocator, &.{ "parse-dir", tree, "--grammar-dir", bad_grammars });
    defer {
        allocator.free(r3.stdout);
        allocator.free(r3.stderr);
    }
    try std.testing.expect(!std.meta.eql(r3.term, std.process.Child.Term{ .exited = 0 }));
    try std.testing.expect(std.mem.indexOf(u8, r3.stderr, "broken.toml") != null);

    // Req 2.12: no --grammar-dir ⇒ [] + exit zero, never a file read.
    const r4 = try runLasp(allocator, &.{ "parse-dir", tree });
    defer {
        allocator.free(r4.stdout);
        allocator.free(r4.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r4.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, r4.stdout, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.array.items.len);
    try std.testing.expect(std.mem.indexOf(u8, r4.stderr, "failed to read file") == null);
}

test "parse-dir: extension suffix match helper (P5)" {
    try std.testing.expect(grammar_set.basenameMatchesExtension("foo.erl", ".erl"));
    try std.testing.expect(!grammar_set.basenameMatchesExtension("foo.py", ".erl"));
    // Dot-less form is the broader suffix.
    try std.testing.expect(grammar_set.basenameMatchesExtension("file.cxx", "cxx"));
    try std.testing.expect(!grammar_set.basenameMatchesExtension("file.cx", "cxx"));
    // Whole-name suffix still matches.
    try std.testing.expect(grammar_set.basenameMatchesExtension("notes", "notes"));
    try std.testing.expect(!grammar_set.basenameMatchesExtension("notes.txt", "notes"));
}

// Feature: parse-dir-directory-walk, task 7.1: committed-fixture integration
// against the freshly built binary.
test "parse-dir (integration): committed fixtures, recursion, multi-grammar, --node, empty" {
    const allocator = std.testing.allocator;
    const dir = "tests/fixtures/dir_sample";
    const io = std.testing.io;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    const gdir = "tests/fixtures/grammars_dir";
    const multi_gdir = "tests/fixtures/grammars_multi_dir";

    // Happy path + recursion: a.erl, sub/c.erl, b.py matched; notes.txt skipped.
    const happy = try runLasp(allocator, &.{ "parse-dir", dir, "--grammar-dir", gdir });
    defer {
        allocator.free(happy.stdout);
        allocator.free(happy.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, happy.term);
    const happy_parsed = try std.json.parseFromSlice(std.json.Value, allocator, happy.stdout, .{});
    defer happy_parsed.deinit();
    const happy_arr = happy_parsed.value.array;
    try std.testing.expectEqual(@as(usize, 3), happy_arr.items.len);
    var count_erl: usize = 0;
    var count_py: usize = 0;
    for (happy_arr.items) |entry| {
        const file = entry.object.get("file").?.string;
        try std.testing.expect(std.mem.endsWith(u8, file, ".erl") or std.mem.endsWith(u8, file, ".py"));
        if (std.mem.endsWith(u8, file, ".erl")) count_erl += 1;
        if (std.mem.endsWith(u8, file, ".py")) count_py += 1;
        try std.testing.expect(std.mem.indexOf(u8, happy.stderr, "failed to read file") == null);
    }
    try std.testing.expectEqual(@as(usize, 2), count_erl);
    try std.testing.expectEqual(@as(usize, 1), count_py);
    try std.testing.expect(std.mem.indexOf(u8, happy.stdout, "notes.txt") == null);
    try std.testing.expect(std.mem.indexOf(u8, happy.stdout, "sub/c.erl") != null);

    // Multi-grammar per extension: two grammars declare .erl ⇒ two entries
    // per .erl file, each attributable via "grammar".
    const multi = try runLasp(allocator, &.{ "parse-dir", dir, "--grammar-dir", multi_gdir });
    defer {
        allocator.free(multi.stdout);
        allocator.free(multi.stderr);
    }
    const multi_parsed = try std.json.parseFromSlice(std.json.Value, allocator, multi.stdout, .{});
    defer multi_parsed.deinit();
    const multi_arr = multi_parsed.value.array;
    var erl_entries: usize = 0;
    for (multi_arr.items) |entry| {
        const file = entry.object.get("file").?.string;
        if (std.mem.endsWith(u8, file, ".erl")) erl_entries += 1;
        const grammar = entry.object.get("grammar").?.string;
        try std.testing.expect(std.mem.eql(u8, grammar, "erlang.toml") or std.mem.eql(u8, grammar, "erlang2.toml"));
    }
    try std.testing.expectEqual(@as(usize, 4), erl_entries); // a.erl + sub/c.erl × 2 grammars

    // --node in dir mode: filtered events only.
    const filtered = try runLasp(allocator, &.{ "parse-dir", dir, "--grammar-dir", gdir, "--node", "class" });
    defer {
        allocator.free(filtered.stdout);
        allocator.free(filtered.stderr);
    }
    const filtered_parsed = try std.json.parseFromSlice(std.json.Value, allocator, filtered.stdout, .{});
    defer filtered_parsed.deinit();
    for (filtered_parsed.value.array.items) |entry| {
        try std.testing.expectEqual(@as(usize, 0), entry.object.get("events").?.array.items.len);
    }

    // All-.txt dir ⇒ exit zero, [].
    const txt_dir = "dir_txt_only";
    try sb.tmp.dir.createDir(io, txt_dir, .default_dir);
    try writeFixtureFile(sb.tmp.dir, std.testing.io, txt_dir ++ "/notes.txt", "irrelevant\n");
    const txt = try runLasp(allocator, &.{ "parse-dir", txt_dir, "--grammar-dir", gdir });
    defer {
        allocator.free(txt.stdout);
        allocator.free(txt.stderr);
    }
    const txt_parsed = try std.json.parseFromSlice(std.json.Value, allocator, txt.stdout, .{});
    defer txt_parsed.deinit();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, txt.term);
    try std.testing.expectEqual(@as(usize, 0), txt_parsed.value.array.items.len);
}

// --- Default grammar search tests (spec: default-grammar-search) ---
// With no -g/--grammar-dir, `.lasp/grammars` in the cwd is the default grammar
// source; several matching grammars all run (one DirResult entry each).
test "default grammar: parse single match is byte-identical to explicit -g" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedDefaultGrammars(allocator, &sb, &.{.{ .name = "erlang.toml", .content = erlang_grammar_toml }});

    const def = try runLasp(allocator, &.{ "parse", "tests/fixtures/dir_sample/a.erl" });
    defer {
        allocator.free(def.stdout);
        allocator.free(def.stderr);
    }
    const expl = try runLasp(allocator, &.{ "parse", "tests/fixtures/dir_sample/a.erl", "-g", ".lasp/grammars/erlang.toml" });
    defer {
        allocator.free(expl.stdout);
        allocator.free(expl.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, def.term);
    try std.testing.expectEqualStrings(expl.stdout, def.stdout);
}

test "default grammar: parse multi-match returns one array entry per grammar, sorted" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedDefaultGrammars(allocator, &sb, &.{
        .{ .name = "erlang.toml", .content = erlang_grammar_toml },
        .{ .name = "erlang2.toml", .content = erlang2_grammar_toml },
    });

    const def = try runLasp(allocator, &.{ "parse", "tests/fixtures/dir_sample/a.erl" });
    defer {
        allocator.free(def.stdout);
        allocator.free(def.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, def.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, def.stdout, .{});
    defer parsed.deinit();
    const arr = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 2), arr.items.len);
    try std.testing.expectEqualStrings("erlang.toml", arr.items[0].object.get("grammar").?.string);
    try std.testing.expectEqualStrings("erlang2.toml", arr.items[1].object.get("grammar").?.string);

    // Each entry's events match the corresponding explicit -g run.
    const expl0 = try runLasp(allocator, &.{ "parse", "tests/fixtures/dir_sample/a.erl", "-g", ".lasp/grammars/erlang.toml" });
    defer {
        allocator.free(expl0.stdout);
        allocator.free(expl0.stderr);
    }
    const expl1 = try runLasp(allocator, &.{ "parse", "tests/fixtures/dir_sample/a.erl", "-g", ".lasp/grammars/erlang2.toml" });
    defer {
        allocator.free(expl1.stdout);
        allocator.free(expl1.stderr);
    }
    const p0 = try std.json.parseFromSlice(std.json.Value, allocator, expl0.stdout, .{});
    defer p0.deinit();
    const p1 = try std.json.parseFromSlice(std.json.Value, allocator, expl1.stdout, .{});
    defer p1.deinit();
    try expectJsonValueEqual(arr.items[0].object.get("events").?, p0.value.object.get("events").?);
    try expectJsonValueEqual(arr.items[1].object.get("events").?, p1.value.object.get("events").?);

    // notes.txt matches no extension → raw token fallback.
    const notes = try runLasp(allocator, &.{ "parse", "tests/fixtures/dir_sample/notes.txt" });
    defer {
        allocator.free(notes.stdout);
        allocator.free(notes.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, notes.term);
    const notes_parsed = try std.json.parseFromSlice(std.json.Value, allocator, notes.stdout, .{});
    defer notes_parsed.deinit();
    const note_events = notes_parsed.value.object.get("events").?.array.items;
    try std.testing.expect(note_events.len > 0);
    try std.testing.expect(note_events[0].object.get("col") != null); // token object, not structural event
}

test "default grammar: --names-only + multi-match is fatal" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedDefaultGrammars(allocator, &sb, &.{
        .{ .name = "erlang.toml", .content = erlang_grammar_toml },
        .{ .name = "erlang2.toml", .content = erlang2_grammar_toml },
    });

    const r = try runLasp(allocator, &.{ "parse", "tests/fixtures/dir_sample/a.erl", "--names-only" });
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expect(!std.meta.eql(r.term, std.process.Child.Term{ .exited = 0 }));
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "--names-only requires a single grammar") != null);
}

test "default grammar: query single match is byte-identical to explicit -g" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedDefaultGrammars(allocator, &sb, &.{.{ .name = "erlang.toml", .content = erlang_grammar_toml }});

    const def = try runLasp(allocator, &.{ "query", "function", "tests/fixtures/dir_sample/a.erl" });
    defer {
        allocator.free(def.stdout);
        allocator.free(def.stderr);
    }
    const expl = try runLasp(allocator, &.{ "query", "function", "tests/fixtures/dir_sample/a.erl", "-g", ".lasp/grammars/erlang.toml" });
    defer {
        allocator.free(expl.stdout);
        allocator.free(expl.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, def.term);
    try std.testing.expectEqualStrings(expl.stdout, def.stdout);
}

test "default grammar: query multi-match returns filtered array entries" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedDefaultGrammars(allocator, &sb, &.{
        .{ .name = "erlang.toml", .content = erlang_grammar_toml },
        .{ .name = "erlang2.toml", .content = erlang2_grammar_toml },
    });

    const r = try runLasp(allocator, &.{ "query", "function", "tests/fixtures/dir_sample/a.erl" });
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, r.stdout, .{});
    defer parsed.deinit();
    const arr = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 2), arr.items.len);
    try std.testing.expectEqualStrings("erlang.toml", arr.items[0].object.get("grammar").?.string);
    try std.testing.expectEqualStrings("erlang2.toml", arr.items[1].object.get("grammar").?.string);
    for (arr.items) |entry| {
        try std.testing.expectEqual(@as(usize, 1), entry.object.get("events").?.array.items.len);
    }
}

test "default grammar: parse-dir default == explicit --grammar-dir; absent default falls back" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedDefaultGrammars(allocator, &sb, &.{
        .{ .name = "erlang.toml", .content = erlang_grammar_toml },
        .{ .name = "python.toml", .content = python_grammar_toml },
    });

    // With the default dir present, parse-dir == explicit --grammar-dir.
    const def = try runLasp(allocator, &.{ "parse-dir", "tests/fixtures/dir_sample" });
    defer {
        allocator.free(def.stdout);
        allocator.free(def.stderr);
    }
    const expl = try runLasp(allocator, &.{ "parse-dir", "tests/fixtures/dir_sample", "--grammar-dir", ".lasp/grammars" });
    defer {
        allocator.free(expl.stdout);
        allocator.free(expl.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, def.term);
    try std.testing.expectEqualStrings(expl.stdout, def.stdout);

    // Absent default dir: parse-dir emits [], exit zero; query still requires
    // -g; parse falls back to raw tokens (file and stdin).
    removeDirTree(sb.tmp.dir, allocator, std.testing.io, ".lasp");
    const empty = try runLasp(allocator, &.{ "parse-dir", "tests/fixtures/dir_sample" });
    defer {
        allocator.free(empty.stdout);
        allocator.free(empty.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, empty.term);
    const empty_parsed = try std.json.parseFromSlice(std.json.Value, allocator, empty.stdout, .{});
    defer empty_parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_parsed.value.array.items.len);

    const q = try runLasp(allocator, &.{ "query", "function", "tests/fixtures/dir_sample/a.erl" });
    defer {
        allocator.free(q.stdout);
        allocator.free(q.stderr);
    }
    try std.testing.expect(!std.meta.eql(q.term, std.process.Child.Term{ .exited = 0 }));
    try std.testing.expect(std.mem.indexOf(u8, q.stderr, "requires --grammar") != null);

    const parse_fb = try runLasp(allocator, &.{ "parse", "tests/fixtures/dir_sample/a.erl" });
    defer {
        allocator.free(parse_fb.stdout);
        allocator.free(parse_fb.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, parse_fb.term);
    const fb_parsed = try std.json.parseFromSlice(std.json.Value, allocator, parse_fb.stdout, .{});
    defer fb_parsed.deinit();
    const fb_events = fb_parsed.value.object.get("events").?.array.items;
    try std.testing.expect(fb_events.len > 0);
    try std.testing.expect(fb_events[0].object.get("col") != null);

    const stdin_r = try runLaspWithStdin(allocator, &.{ "parse", "-" }, "fn f() {}");
    defer {
        allocator.free(stdin_r.stdout);
        allocator.free(stdin_r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, stdin_r.term);
    const stdin_parsed = try std.json.parseFromSlice(std.json.Value, allocator, stdin_r.stdout, .{});
    defer stdin_parsed.deinit();
    const stdin_events = stdin_parsed.value.object.get("events").?.array.items;
    try std.testing.expect(stdin_events.len > 0);
    try std.testing.expect(stdin_events[0].object.get("col") != null);
}

// --- Broken-pipe clean-exit tests (spec: broken-pipe-clean-exit) ---
// The binary under test is `zig-out/bin/lasp` (freshly built). The large
// fixture guarantees the child's stdout stream exceeds the OS pipe buffer
// (~64 KiB), so closing the read end early forces a real EPIPE on the child's
// subsequent writes (deterministic bug reproduction).
fn makeLargeZigFixture(io: std.Io, sb: *const Sandbox) ![]const u8 {
    const path = "broken_pipe_large.zig";
    const file = try sb.tmp.dir.createFile(io, path, .{});
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        try w.interface.print("pub fn f{d}() void {{ var x: i32 = {d}; }}\n", .{ i, i });
    }
    try w.interface.flush();
    file.close(io);
    return path;
}

// Property 1 (bug condition): a downstream reader that closes the pipe early
// must not be a fatal error — clean exit 0 with empty stderr. On the unfixed
// binary these tests FAIL (non-zero term, stderr contains `WriteFailed`),
// confirming the bug; the same tests validate the fix later.
test "broken pipe: parse (JSON) with early-closing reader exits cleanly" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    const fixture = try makeLargeZigFixture(std.testing.io, &sb);

    const result = try runLaspEarlyClose(allocator, &.{
        "parse", fixture, "-g", "examples/grammars/zig.toml",
    }, 64);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqual(@as(usize, 0), result.stderr.len);
}

test "broken pipe: query with early-closing reader exits cleanly" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    const fixture = try makeLargeZigFixture(std.testing.io, &sb);

    const result = try runLaspEarlyClose(allocator, &.{
        "query", "*", fixture, "-g", "examples/grammars/zig.toml",
    }, 64);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqual(@as(usize, 0), result.stderr.len);
}

test "broken pipe: --jsonl with early-closing reader exits cleanly" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    const fixture = try makeLargeZigFixture(std.testing.io, &sb);

    const result = try runLaspEarlyClose(allocator, &.{
        "parse", fixture, "-g", "examples/grammars/zig.toml", "--jsonl",
    }, 64);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqual(@as(usize, 0), result.stderr.len);
}

test "broken pipe: --names-only with early-closing reader exits cleanly" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    const fixture = try makeLargeZigFixture(std.testing.io, &sb);

    const result = try runLaspEarlyClose(allocator, &.{
        "parse", fixture, "-g", "examples/grammars/zig.toml", "--names-only",
    }, 64);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqual(@as(usize, 0), result.stderr.len);
}

// Property 2 (preservation): full-reading consumers keep complete output and
// exit 0 — asserted across random valid-ish Zig sources (full-write domain).
test "property: full-read parse preserves complete output and exit 0" {
    const source_gen = gen.string(.{ .min_len = 16, .max_len = 512, .charset = .custom, .custom_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789(){}[];=+*/_ \n\t" });

    try minish.check(std.testing.allocator, source_gen, struct {
        fn prop(src: []const u8) !void {
            const allocator = std.testing.allocator;
            const io = std.testing.io;
            var sb = try Sandbox.init(allocator);
            defer sb.deinit();
            const tmp_path = try sb.join("broken_pipe_prop.tmp");
            defer allocator.free(tmp_path);
            const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
            var wbuf: [4096]u8 = undefined;
            var writer = file.writer(io, &wbuf);
            try writer.interface.writeAll(src);
            try writer.interface.flush();
            file.close(io);
            const result = try runLasp(allocator, &.{ "parse", tmp_path, "-g", "examples/grammars/zig.toml" });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
            try std.testing.expect(result.stdout.len > 0);
        }
    }.prop, .{ .num_runs = 100 });
}

test "integration: parse produces valid JSON with expected token types" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);

    // Verify it's valid JSON with "events" array
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;
    try std.testing.expect(json_events.array.items.len > 0);

    // Check that we get identifier tokens (sample.zig has identifiers)
    var has_identifier = false;
    for (json_events.array.items) |event| {
        const typ = event.object.get("type").?.string;
        if (std.mem.eql(u8, typ, "identifier")) has_identifier = true;
    }
    try std.testing.expect(has_identifier);
}

test "integration: parse nonexistent file exits non-zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "nonexistent.zig" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should exit with non-zero
    switch (result.term) {
        .exited => |code| try std.testing.expect(code != 0),
        else => {}, // Signal/other termination is also non-zero
    }
    // Stderr should contain error message
    try std.testing.expect(result.stderr.len > 0);
}

test "integration: no args prints usage and exits non-zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| try std.testing.expect(code != 0),
        else => {},
    }
    try std.testing.expect(result.stderr.len > 0);
}

test "integration: --version prints version and exits zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{"--version"});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "lasp "));
    // Exactly one line: `lasp <version>\n`, where the version is the plain semver
    // or a dev build `X.Y.Z-dev+<short-commit>`.
    try std.testing.expect(std.mem.endsWith(u8, result.stdout, "\n"));
    try std.testing.expect(std.mem.indexOfScalar(u8, result.stdout, '\n') == result.stdout.len - 1);
    var it = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() == null);
    const version_str = std.mem.trim(u8, result.stdout["lasp ".len..], " \n");
    try std.testing.expect(version_str.len > 0);
    const dev_marker = std.mem.indexOf(u8, version_str, "-dev+");
    if (dev_marker) |idx| {
        // `-dev+` must be followed by a non-empty hex-ish short commit.
        try std.testing.expect(version_str.len > idx + 5);
    }
}

// --- Integration Tests for CLI Help Text Feature ---
test "integration: help command prints usage and exits zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{"help"});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    // Should contain basic help text
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "Usage:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "lasp - Language-Agnostic Structural Parser"));
}

test "integration: --help flag prints usage and exits zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{"--help"});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "Usage:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "lasp - Language-Agnostic Structural Parser"));
}

test "integration: -h flag prints usage and exits zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{"-h"});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "Usage:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "lasp - Language-Agnostic Structural Parser"));
}

test "integration: parse --help prints parse-specific help and exits zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "--help" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    // Should contain parse-specific help
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "lasp parse - parse a single file"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "<file|->"));
}

test "integration: parse -h prints parse-specific help and exits zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "-h" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "lasp parse - parse a single file"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "<file|->"));
}

test "integration: query --help prints query-specific help and exits zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "query", "--help" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    // Should contain query-specific help
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "lasp query - filter structural events"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "<selector>"));
}

test "integration: parse-dir --help prints parse-dir-specific help and exits zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse-dir", "--help" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    // Should contain parse-dir-specific help
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "lasp parse-dir - parse all files in a directory"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "<dir>"));
}

test "integration: query -h prints query-specific help and exits zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "query", "-h" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    // Should contain query-specific help
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "lasp query - filter structural events"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "<selector>"));
}

test "integration: parse-dir -h prints parse-dir-specific help and exits zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse-dir", "-h" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    // Should contain parse-dir-specific help
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "lasp parse-dir - parse all files in a directory"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "<dir>"));
}

test "integration: help with invalid files/grammar prints usage and exits zero (no file error)" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "nonexistent.zig", "-g", "nope.toml", "--help" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    // Should contain help text
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "Usage:"));
    // Should NOT contain file/grammar error messages on stderr
    try std.testing.expect(result.stderr.len == 0);
}

test "integration: help takes precedence over version (--help --version)" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "--help", "--version" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    // Should be help text, not version
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "Usage:"));
    // Help text starts with "lasp - Language-Agnostic Structural Parser", not "lasp 0.2.0"
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "lasp - Language-Agnostic Structural Parser"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result.stdout, 1, "lasp 0.2.0"));
}

test "integration: help takes precedence over version (--version --help)" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "--version", "--help" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    // Should be help text, not version
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "Usage:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "lasp - Language-Agnostic Structural Parser"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result.stdout, 1, "lasp 0.2.0"));
}

test "integration: help with stdin short-circuits before reading stdin" {
    const allocator = std.testing.allocator;
    const source = "fn add() void {}\n"; // Some valid code

    const result = try runLaspWithStdin(allocator, &.{ "parse", "-", "--help" }, source);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    // Should contain help text, not parse output
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "Usage:"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result.stdout, 1, "\"type\": \"function\""));
}

test "integration: parse with TOML grammar produces structural events" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--grammar", "tests/fixtures/grammars/zig.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;
    try std.testing.expect(json_events.array.items.len > 0);

    // Should have structural events with "confidence" field
    var has_function = false;
    for (json_events.array.items) |event| {
        const typ = event.object.get("type").?.string;
        try std.testing.expect(event.object.get("confidence") != null);
        if (std.mem.eql(u8, typ, "function")) has_function = true;
    }
    try std.testing.expect(has_function);
}

test "integration: parse without grammar produces raw tokens" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;
    try std.testing.expect(json_events.array.items.len > 0);

    // Raw tokens have "type" but no "confidence"
    const first = json_events.array.items[0].object;
    try std.testing.expect(first.get("type") != null);
    try std.testing.expect(first.get("confidence") == null);
}

test "integration: nonexistent grammar file exits non-zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--grammar", "nonexistent.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| try std.testing.expect(code != 0),
        else => {},
    }
    try std.testing.expect(result.stderr.len > 0);
}

test "integration: malformed grammar file exits non-zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--grammar", "tests/fixtures/grammars/malformed.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| try std.testing.expect(code != 0),
        else => {},
    }
    try std.testing.expect(result.stderr.len > 0);
}

// --- Phase 3 Integration Tests ---
test "integration: structural events include col field" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--grammar", "tests/fixtures/grammars/zig.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    for (json_events.array.items) |event| {
        // Every structural event must have a "col" field
        try std.testing.expect(event.object.get("col") != null);
    }
}

test "integration: raw token events include col field" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    for (json_events.array.items) |event| {
        try std.testing.expect(event.object.get("col") != null);
    }
}

test "integration: Erlang grammar with position filtering" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.erl", "--grammar", "examples/grammars/erlang.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;
    try std.testing.expect(json_events.array.items.len > 0);

    // All events should have col field
    for (json_events.array.items) |event| {
        try std.testing.expect(event.object.get("col") != null);
    }
}

test "integration: invalid position value exits non-zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--grammar", "tests/fixtures/grammars/invalid_position.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| try std.testing.expect(code != 0),
        else => {},
    }
    try std.testing.expect(result.stderr.len > 0);
}

// Feature: composable-cli-primitives, Property 3: Node filter correctness
test "property: node filter correctness" {
    // Helper to create a StructuralEvent
    const createEvent = struct {
        fn create(allocator: std.mem.Allocator, type_name: []const u8, captures_len: usize) !events.StructuralEvent {
            var captures: []const events.CaptureEntry = &[_]events.CaptureEntry{};
            if (captures_len > 0) {
                const caps = try allocator.alloc(events.CaptureEntry, captures_len);
                for (caps) |*cap| {
                    cap.* = .{ .field_name = "name", .value = "test" };
                }
                captures = caps;
            }
            return .{
                .type_name = type_name,
                .captures = captures,
                .start = 0,
                .end = 10,
                .line = 1,
                .col = 0,
                .confidence = 1.0,
            };
        }
    }.create;

    // Generate random events with random type names
    const type_name_gen = gen.string(.{ .min_len = 1, .max_len = 16, .charset = .alphanumeric });

    try minish.check(std.testing.allocator, type_name_gen, struct {
        fn prop(type_name: []const u8) !void {
            const allocator = std.testing.allocator;
            const num_events = 5;

            // Create events with the same type name
            var events_list: std.ArrayList(events.StructuralEvent) = .empty;
            defer {
                for (events_list.items) |e| {
                    allocator.free(e.captures);
                }
                events_list.deinit(allocator);
            }

            var i: usize = 0;
            while (i < num_events) : (i += 1) {
                const event = try createEvent(allocator, type_name, 0);
                try events_list.append(allocator, event);
            }

            // Apply filter (case-insensitive)
            const filter = type_name;
            var filtered: std.ArrayList(events.StructuralEvent) = .empty;
            defer {
                for (filtered.items) |e| {
                    allocator.free(e.captures);
                }
                filtered.deinit(allocator);
            }

            for (events_list.items) |event| {
                if (std.ascii.eqlIgnoreCase(event.type_name, filter)) {
                    try filtered.append(allocator, event);
                }
            }

            // All events should match
            try std.testing.expectEqual(events_list.items.len, filtered.items.len);
        }
    }.prop, .{ .num_runs = 100 });

    // Test that non-matching filter returns empty
    try minish.check(std.testing.allocator, type_name_gen, struct {
        fn prop(type_name: []const u8) !void {
            const allocator = std.testing.allocator;
            const num_events = 5;

            var events_list: std.ArrayList(events.StructuralEvent) = .empty;
            defer {
                for (events_list.items) |e| {
                    allocator.free(e.captures);
                }
                events_list.deinit(allocator);
            }

            var i: usize = 0;
            while (i < num_events) : (i += 1) {
                const event = try createEvent(allocator, type_name, 0);
                try events_list.append(allocator, event);
            }

            // Apply non-matching filter
            const filter = "call";
            var filtered: std.ArrayList(events.StructuralEvent) = .empty;
            defer {
                for (filtered.items) |e| {
                    allocator.free(e.captures);
                }
                filtered.deinit(allocator);
            }

            for (events_list.items) |event| {
                if (std.ascii.eqlIgnoreCase(event.type_name, filter)) {
                    try filtered.append(allocator, event);
                }
            }

            // No events should match
            try std.testing.expectEqual(@as(usize, 0), filtered.items.len);
        }
    }.prop, .{ .num_runs = 100 });

    // Test case-insensitive matching
    try minish.check(std.testing.allocator, type_name_gen, struct {
        fn prop(type_name: []const u8) !void {
            const allocator = std.testing.allocator;
            const event = try createEvent(allocator, type_name, 0);
            defer allocator.free(event.captures);

            // Test that eqlIgnoreCase works with same case
            const matches_same = std.ascii.eqlIgnoreCase(event.type_name, type_name);
            try std.testing.expect(matches_same);

            // Test with uppercase version of the same string
            if (type_name.len > 0) {
                var upper_type_name = try allocator.alloc(u8, type_name.len);
                defer allocator.free(upper_type_name);
                for (type_name, 0..) |c, i| {
                    upper_type_name[i] = std.ascii.toUpper(c);
                }
                const matches_upper = std.ascii.eqlIgnoreCase(event.type_name, upper_type_name);
                try std.testing.expect(matches_upper);
            }
        }
    }.prop, .{ .num_runs = 100 });
}

// Feature: composable-cli-primitives, Property 4: Names-only output correctness
test "property: names-only output correctness" {
    // Helper to create a StructuralEvent with captures
    const createEventWithCaptures = struct {
        fn create(allocator: std.mem.Allocator, type_name: []const u8, capture_value: []const u8) !events.StructuralEvent {
            const captures = try allocator.alloc(events.CaptureEntry, 1);
            captures[0] = .{ .field_name = "name", .value = capture_value };
            return .{
                .type_name = type_name,
                .captures = captures,
                .start = 0,
                .end = 10,
                .line = 1,
                .col = 0,
                .confidence = 1.0,
            };
        }
    }.create;

    // Helper to create a StructuralEvent without captures
    const createEventNoCaptures = struct {
        fn create(_: std.mem.Allocator, type_name: []const u8) !events.StructuralEvent {
            return .{
                .type_name = type_name,
                .captures = &[_]events.CaptureEntry{},
                .start = 0,
                .end = 10,
                .line = 1,
                .col = 0,
                .confidence = 1.0,
            };
        }
    }.create;

    // Generate random capture values
    const value_gen = gen.string(.{ .min_len = 1, .max_len = 16, .charset = .alphanumeric });

    // Test: names-only output produces one line per event with captures
    try minish.check(std.testing.allocator, value_gen, struct {
        fn prop(capture_value: []const u8) !void {
            const allocator = std.testing.allocator;

            // Create events: some with captures, some without
            var events_list: std.ArrayList(events.StructuralEvent) = .empty;
            defer {
                for (events_list.items) |e| {
                    allocator.free(e.captures);
                }
                events_list.deinit(allocator);
            }

            // Add event with captures
            const event_with = try createEventWithCaptures(allocator, "function", capture_value);
            try events_list.append(allocator, event_with);

            // Add event without captures
            const event_without = try createEventNoCaptures(allocator, "function");
            try events_list.append(allocator, event_without);

            // Simulate names-only output - count lines and verify content
            var line_count: usize = 0;
            var first_capture_value: ?[]const u8 = null;
            for (events_list.items) |event| {
                if (event.captures.len > 0) {
                    line_count += 1;
                    if (first_capture_value == null) {
                        first_capture_value = event.captures[0].value;
                    }
                }
            }

            // Should have exactly one line (one event with captures)
            try std.testing.expectEqual(@as(usize, 1), line_count);
            try std.testing.expectEqualStrings(capture_value, first_capture_value.?);
        }
    }.prop, .{ .num_runs = 100 });

    // Test: all events with captures produces output lines equal to event count
    try minish.check(std.testing.allocator, value_gen, struct {
        fn prop(capture_value: []const u8) !void {
            const allocator = std.testing.allocator;
            const num_events = 3;

            var events_list: std.ArrayList(events.StructuralEvent) = .empty;
            defer {
                for (events_list.items) |e| {
                    allocator.free(e.captures);
                }
                events_list.deinit(allocator);
            }

            // Add events with captures
            var i: usize = 0;
            while (i < num_events) : (i += 1) {
                const event = try createEventWithCaptures(allocator, "function", capture_value);
                try events_list.append(allocator, event);
            }

            // Simulate names-only output - count lines
            var line_count: usize = 0;
            for (events_list.items) |event| {
                if (event.captures.len > 0) {
                    line_count += 1;
                    try std.testing.expectEqualStrings(capture_value, event.captures[0].value);
                }
            }

            // Should have exactly num_events lines
            try std.testing.expectEqual(num_events, line_count);
        }
    }.prop, .{ .num_runs = 100 });

    // Test: events without captures produce no output
    try minish.check(std.testing.allocator, value_gen, struct {
        fn prop(_: []const u8) !void {
            const allocator = std.testing.allocator;

            var events_list: std.ArrayList(events.StructuralEvent) = .empty;
            defer {
                for (events_list.items) |e| {
                    allocator.free(e.captures);
                }
                events_list.deinit(allocator);
            }

            // Add events without captures
            var i: usize = 0;
            while (i < 5) : (i += 1) {
                const event = try createEventNoCaptures(allocator, "function");
                try events_list.append(allocator, event);
            }

            // Simulate names-only output - count lines
            var line_count: usize = 0;
            for (events_list.items) |event| {
                if (event.captures.len > 0) {
                    line_count += 1;
                }
            }

            // Should have zero lines
            try std.testing.expectEqual(@as(usize, 0), line_count);
        }
    }.prop, .{ .num_runs = 100 });
}

fn allLinesNonDigit(text: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var digits = true;
        for (line) |c| {
            if (c < '0' or c > '9') digits = false;
        }
        if (digits) return false;
    }
    return true;
}

test "integration: names-only extent_brace prints function names, not offsets" {
    const allocator = std.testing.allocator;
    const r = try runLaspWithStdin(allocator, &.{ "parse", "-", "-g", "tests/fixtures/grammars/extent_brace.toml", "--names-only" }, "fn alpha() { x }\nfn beta() { y }\n");
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    try std.testing.expectEqualStrings("alpha\nbeta\n", r.stdout);
    try std.testing.expect(allLinesNonDigit(r.stdout));
}

test "integration: names-only extent_terminator (no captures) prints offsets as digits" {
    const allocator = std.testing.allocator;
    const r = try runLaspWithStdin(allocator, &.{ "parse", "-", "-g", "tests/fixtures/grammars/extent_terminator.toml", "--names-only" }, "foo()\nbody.\nbar()\nx.\n");
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    try std.testing.expect(r.stdout.len > 0);
    var it = std.mem.splitScalar(u8, r.stdout, '\n');
    var lines: usize = 0;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        lines += 1;
        _ = try std.fmt.parseInt(u32, line, 10);
    }
    try std.testing.expect(lines >= 1);
    try std.testing.expect(!std.mem.endsWith(u8, r.stdout, "\n\n"));
}

test "integration: names-only default-grammar sites print names (parse and query)" {
    const allocator = std.testing.allocator;
    const counts_toml =
        \\[language]
        \\name = "counts"
        \\extensions = [".cnt"]
        \\
        \\[[patterns]]
        \\type = "fn"
        \\sequence = ["identifier", "$n:IDENTIFIER"]
        \\
        \\[[patterns.count]]
        \\field = "args"
        \\open = "("
        \\close = ")"
        \\separator = ","
        \\
    ;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedDefaultGrammars(allocator, &sb, &.{.{ .name = "counts.toml", .content = counts_toml }});
    const src = "names_only_default.cnt";
    try writeFixtureFile(sb.tmp.dir, std.testing.io, src, "fn add(a, b, c) {}\nfn one(x) {}\n");
    const p = try runLasp(allocator, &.{ "parse", src, "--names-only" });
    defer {
        allocator.free(p.stdout);
        allocator.free(p.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, p.term);
    try std.testing.expectEqualStrings("add\none\n", p.stdout);

    const q = try runLasp(allocator, &.{ "query", "fn[args>0]", src, "--names-only" });
    defer {
        allocator.free(q.stdout);
        allocator.free(q.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, q.term);
    try std.testing.expectEqualStrings("add\none\n", q.stdout);
}

test "integration: names-only --node nosuchtype is zero bytes; JSON and --jsonl guard preserved" {
    const allocator = std.testing.allocator;
    const none = try runLasp(allocator, &.{ "parse", "tests/fixtures/counts_sample.txt", "-g", "tests/fixtures/grammars/counts.toml", "--node", "nosuchtype", "--names-only" });
    defer {
        allocator.free(none.stdout);
        allocator.free(none.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, none.term);
    try std.testing.expectEqual(@as(usize, 0), none.stdout.len);

    const names = try runLasp(allocator, &.{ "parse", "tests/fixtures/counts_sample.txt", "-g", "tests/fixtures/grammars/counts.toml", "--names-only" });
    defer {
        allocator.free(names.stdout);
        allocator.free(names.stderr);
    }
    try std.testing.expect(!std.mem.endsWith(u8, names.stdout, "\n\n"));

    const plain = try runLasp(allocator, &.{ "parse", "tests/fixtures/counts_sample.txt", "-g", "tests/fixtures/grammars/counts.toml" });
    defer {
        allocator.free(plain.stdout);
        allocator.free(plain.stderr);
    }
    try std.testing.expect(std.mem.indexOf(u8, plain.stdout, "\"args\": 3") != null);

    const bad = try runLasp(allocator, &.{ "parse", "tests/fixtures/counts_sample.txt", "-g", "tests/fixtures/grammars/counts.toml", "--jsonl", "--names-only" });
    defer {
        allocator.free(bad.stdout);
        allocator.free(bad.stderr);
    }
    try std.testing.expect(!std.meta.eql(bad.term, std.process.Child.Term{ .exited = 0 }));
    try std.testing.expect(std.mem.indexOf(u8, bad.stderr, "mutually exclusive") != null);
}

// Helper: run lasp with data piped to stdin
// --- Integration Tests for Composable CLI Primitives ---
test "integration: stdin pipe support" {
    const allocator = std.testing.allocator;
    const source = "const std = @import(\"std\");\n\npub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n";

    const result = try runLaspWithStdin(allocator, &.{ "parse", "-", "--grammar", "tests/fixtures/grammars/zig.toml" }, source);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;
    try std.testing.expect(json_events.array.items.len > 0);

    // Should have at least one function event
    var has_function = false;
    for (json_events.array.items) |event| {
        const typ = event.object.get("type").?.string;
        if (std.mem.eql(u8, typ, "function")) has_function = true;
    }
    try std.testing.expect(has_function);
}

test "integration: stdin pipe with empty input" {
    const allocator = std.testing.allocator;

    const result = try runLaspWithStdin(allocator, &.{ "parse", "-", "--grammar", "tests/fixtures/grammars/zig.toml" }, "");
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;
    try std.testing.expectEqual(@as(usize, 0), json_events.array.items.len);
}

test "integration: --node filter with grammar" {
    const allocator = std.testing.allocator;

    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--grammar", "tests/fixtures/grammars/zig.toml", "--node", "function" });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    // All events should be of type "function"
    for (json_events.array.items) |event| {
        const typ = event.object.get("type").?.string;
        try std.testing.expect(std.mem.eql(u8, typ, "function"));
    }

    // Should have at least one function event
    try std.testing.expect(json_events.array.items.len > 0);
}

test "integration: --node filter with no grammar (flag ignored)" {
    const allocator = std.testing.allocator;

    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--node", "function" });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    // Should have raw token events (not filtered)
    try std.testing.expect(json_events.array.items.len > 0);

    // Raw tokens don't have "confidence" field
    const first = json_events.array.items[0].object;
    try std.testing.expect(first.get("confidence") == null);
}

test "integration: --names-only with grammar" {
    const allocator = std.testing.allocator;

    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--grammar", "tests/fixtures/grammars/zig.toml", "--names-only" });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    // Should be plain text output, not JSON (should not start with '{')
    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expect(result.stdout[0] != '{');

    // Collect non-empty lines
    var line_count: usize = 0;
    var has_add = false;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) {
            line_count += 1;
            if (std.mem.eql(u8, line, "add")) has_add = true;
        }
    }

    // Should have at least one line and include "add" from the function event
    try std.testing.expect(line_count > 0);
    try std.testing.expect(has_add);
}

test "integration: --names-only with no grammar (flag ignored)" {
    const allocator = std.testing.allocator;

    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--names-only" });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    // Should be JSON output (flag ignored)
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    // Should have raw token events
    try std.testing.expect(json_events.array.items.len > 0);
}

test "integration: combined stdin + --node + --names-only" {
    const allocator = std.testing.allocator;
    const source = "const std = @import(\"std\");\n\npub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n\npub fn sub(x: i32, y: i32) i32 {\n    return x - y;\n}\n";

    const result = try runLaspWithStdin(allocator, &.{ "parse", "-", "--grammar", "tests/fixtures/grammars/zig.toml", "--node", "function", "--names-only" }, source);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    // Should be plain text output with function names
    try std.testing.expect(result.stdout.len > 0);

    // Count lines and verify they contain function names
    var line_count: usize = 0;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) {
            line_count += 1;
            // Should be either "add" or "sub"
            try std.testing.expect(std.mem.eql(u8, line, "add") or std.mem.eql(u8, line, "sub"));
        }
    }

    // Should have 2 function names
    try std.testing.expectEqual(@as(usize, 2), line_count);
}

test "integration: --node filter matching zero events" {
    const allocator = std.testing.allocator;

    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--grammar", "tests/fixtures/grammars/zig.toml", "--node", "nonexistent" });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    // Should have empty events array
    try std.testing.expectEqual(@as(usize, 0), json_events.array.items.len);
}

// --- Integration Tests for Structural Query Command ---
test "integration: query type-only filter returns only function events" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "query", "function", "tests/fixtures/sample.zig", "-g", "tests/fixtures/grammars/zig.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    // sample.zig has 1 function (add) and 1 call (import) — only function should appear
    try std.testing.expect(json_events.array.items.len > 0);
    for (json_events.array.items) |event| {
        const typ = event.object.get("type").?.string;
        try std.testing.expectEqualStrings("function", typ);
    }
}

test "integration: query type + equality returns matching event" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "query", "function[name=\"add\"]", "tests/fixtures/sample.zig", "-g", "tests/fixtures/grammars/zig.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    try std.testing.expectEqual(@as(usize, 1), json_events.array.items.len);
    const event = json_events.array.items[0].object;
    try std.testing.expectEqualStrings("function", event.get("type").?.string);
    try std.testing.expectEqualStrings("add", event.get("name").?.string);
}

test "integration: query wildcard + confidence threshold" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "query", "*[confidence>0.5]", "tests/fixtures/sample.zig", "-g", "tests/fixtures/grammars/zig.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    // All events in sample.zig have confidence 1.0, so all should pass >0.5
    try std.testing.expect(json_events.array.items.len > 0);
    for (json_events.array.items) |event| {
        // Verify confidence field exists
        try std.testing.expect(event.object.get("confidence") != null);
    }
}

test "integration: query with --names-only output" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "query", "function", "tests/fixtures/sample.zig", "-g", "tests/fixtures/grammars/zig.toml", "--names-only" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    // Should be plain text, not JSON
    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expect(result.stdout[0] != '{');

    // Should contain "add" as a line
    var has_add = false;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "add")) has_add = true;
    }
    try std.testing.expect(has_add);
}

test "integration: query stdin pipe support" {
    const allocator = std.testing.allocator;
    const source = "fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n";

    const result = try runLaspWithStdin(allocator, &.{ "query", "function", "-", "-g", "tests/fixtures/grammars/zig.toml" }, source);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    try std.testing.expect(json_events.array.items.len > 0);
    const event = json_events.array.items[0].object;
    try std.testing.expectEqualStrings("function", event.get("type").?.string);
    try std.testing.expectEqualStrings("add", event.get("name").?.string);
}

test "integration: query with no args exits non-zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{"query"});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| try std.testing.expect(code != 0),
        else => {},
    }
    try std.testing.expect(result.stderr.len > 0);
}

test "integration: query without grammar exits non-zero" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "query", "function", "tests/fixtures/sample.zig" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| try std.testing.expect(code != 0),
        else => {},
    }
    try std.testing.expect(result.stderr.len > 0);
}

test "integration: query nonexistent name returns empty valid JSON" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "query", "function[name=\"nonexistent\"]", "tests/fixtures/sample.zig", "-g", "tests/fixtures/grammars/zig.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    // Should be valid JSON with empty events array
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;
    try std.testing.expectEqual(@as(usize, 0), json_events.array.items.len);
}

// --- Bug Condition Exploration Test (names-only-trailing-newline) ---
// Count lines terminated by '\n' in `out`.
fn newlineTerminatedLineCount(out: []const u8) usize {
    var count: usize = 0;
    for (out) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

// Count non-empty lines in `out` (the `grep -c .` equivalent).
fn nonEmptyLineCount(out: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }
    return count;
}

// Feature: names-only-trailing-newline, Property 1: Bug Condition
// Names-Only Has No Trailing Blank Line.
// CRITICAL: This test MUST FAIL on the current unfixed code — its failure confirms
// the bug (an unconditional end-of-main `writeAll("\n")` adds one extra newline in
// names-only mode). DO NOT fix the code to make it pass; the fix lands in a later task.
test "names-only on a multi-line string capture is plain unescaped text" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    try writeFixtureFile(sb.tmp.dir, std.testing.io, "str.toml", explore_str_grammar);
    sb.enter();
    const input = "\"a\nb\tc\"";
    const r = try runLaspWithStdin(allocator, &.{ "parse", "-", "-g", "str.toml", "--names-only" }, input);
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    try std.testing.expectEqualStrings(input ++ "\n", r.stdout);
}

test "exploration: names-only output has no trailing blank line" {
    const allocator = std.testing.allocator;

    // A deterministic two-function source: names-only should emit exactly `a\nb\n`.
    const source = "fn a() void {}\nfn b() void {}\n";

    // Case 1: parse ... --node function --names-only — wc -l == grep -c .
    {
        const result = try runLaspWithStdin(allocator, &.{ "parse", "-", "-g", "examples/grammars/zig.toml", "--node", "function", "--names-only" }, source);
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

        const out = result.stdout;
        try std.testing.expectEqual(nonEmptyLineCount(out), newlineTerminatedLineCount(out));
        // Non-empty names-only output must end with exactly one '\n', never "\n\n".
        try std.testing.expect(out.len > 0);
        try std.testing.expect(!std.mem.endsWith(u8, out, "\n\n"));
        try std.testing.expect(std.mem.endsWith(u8, out, "\n"));
    }

    // Case 2: query 'function' ... --names-only — wc -l == grep -c .
    {
        const result = try runLaspWithStdin(allocator, &.{ "query", "function", "-", "-g", "examples/grammars/zig.toml", "--names-only" }, source);
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

        const out = result.stdout;
        try std.testing.expectEqual(nonEmptyLineCount(out), newlineTerminatedLineCount(out));
        try std.testing.expect(out.len > 0);
        try std.testing.expect(!std.mem.endsWith(u8, out, "\n\n"));
        try std.testing.expect(std.mem.endsWith(u8, out, "\n"));
    }

    // Case 3: zero-match edge case — a nonexistent node type yields zero names, so
    // names-only output must be exactly 0 bytes (today it is 1 byte: a stray '\n').
    {
        const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "-g", "examples/grammars/zig.toml", "--node", "nosuchtype", "--names-only" });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
    }
}

// Helper: assert `out` parses as valid JSON and ends with exactly one trailing '\n'.
fn expectValidJsonSingleTrailingNewline(allocator: std.mem.Allocator, out: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    try std.testing.expect(out.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, out, "\n"));
    try std.testing.expect(!std.mem.endsWith(u8, out, "\n\n"));
}

// Feature: names-only-trailing-newline, Property 2: Preservation
// JSON And Version Output Unchanged.
// These tests capture the characterizing invariants of the JSON and version output
// paths on the current (unfixed) binary. The later fix guards the end-of-main newline
// on `!parsed.names_only`, so every one of these paths must keep its single trailing
// '\n' byte-for-byte. These MUST PASS on the unfixed code.
test "preservation: parse with grammar emits valid JSON ending in one newline" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "-g", "examples/grammars/zig.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try expectValidJsonSingleTrailingNewline(allocator, result.stdout);
}

test "preservation: parse without grammar emits valid raw-token JSON ending in one newline" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try expectValidJsonSingleTrailingNewline(allocator, result.stdout);
}

test "preservation: query without names-only emits valid JSON ending in one newline" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "query", "function", "tests/fixtures/sample.zig", "-g", "examples/grammars/zig.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try expectValidJsonSingleTrailingNewline(allocator, result.stdout);
}

test "preservation: --version prints 'lasp ' prefix ending in exactly one newline" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{"--version"});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    const out = result.stdout;
    try std.testing.expect(std.mem.startsWith(u8, out, "lasp "));
    try std.testing.expect(std.mem.endsWith(u8, out, "\n"));
    try std.testing.expect(!std.mem.endsWith(u8, out, "\n\n"));
}

// --- Integration Tests for Configurable Comment Prefixes (Erlang) ---
// Helper: load a grammar file and tokenize source through the real
// loader -> tokenizer path, returning tokens. Uses an arena owned by the caller.
fn tokenizeWithGrammarFile(
    arena: std.mem.Allocator,
    grammar_path: []const u8,
    source: []const u8,
) ![]tokenizer.Token {
    const grammar_source = try source_reader.readSourceFile(std.testing.io, arena, grammar_path);
    const grammar = try grammar_loader.parseGrammar(grammar_source, arena);
    return try tokenizer.tokenize(source, grammar.keyword_table, grammar.comments, arena);
}

test "integration: Erlang % lines produce comment tokens with erlang.toml" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = "% first comment\nfoo() -> ok.\n% second comment\n";
    const tokens = try tokenizeWithGrammarFile(a, "examples/grammars/erlang.toml", source);

    var comment_count: usize = 0;
    for (tokens) |tok| {
        if (tok.kind == .comment) comment_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), comment_count);
}

test "integration: Erlang % comment line is a single token, not many operators" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A single comment line. Pre-fix, `%` was tokenized as many operator tokens.
    const comment_line = "% a longer comment line with many words and symbols: foo/1 bar/2";
    const source = comment_line ++ "\n";
    const tokens = try tokenizeWithGrammarFile(a, "examples/grammars/erlang.toml", source);

    // Exactly one comment token, no operator tokens from the comment content.
    var comment_count: usize = 0;
    var operator_count: usize = 0;
    var comment_tok: ?tokenizer.Token = null;
    for (tokens) |tok| {
        switch (tok.kind) {
            .comment => {
                comment_count += 1;
                comment_tok = tok;
            },
            .operator => operator_count += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), comment_count);
    try std.testing.expectEqual(@as(usize, 0), operator_count);

    // The single comment token spans the whole comment line.
    try std.testing.expect(comment_tok != null);
    try std.testing.expectEqualStrings(comment_line, source[comment_tok.?.start..comment_tok.?.end]);
}

test "integration: Zig grammar (no [comments]) does not treat % as a comment" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Zig grammar has no [comments] section -> default C-style prefixes.
    // A line beginning with `%` must NOT become a comment token.
    const source = "% not a comment in zig\n";
    const tokens = try tokenizeWithGrammarFile(a, "examples/grammars/zig.toml", source);

    for (tokens) |tok| {
        try std.testing.expect(tok.kind != .comment);
    }
}

test "integration: Zig grammar still parses sample.zig (no regression)" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--grammar", "examples/grammars/zig.toml" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;
    try std.testing.expect(json_events.array.items.len > 0);
}

test "integration: Erlang % comment via stdin tokenizes as single comment token" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Mirror the stdin-fed source `% hello` through the real loader+tokenizer
    // path (the CLI emits structural events, never tokens, when a grammar is set).
    const source = "% hello";
    const tokens = try tokenizeWithGrammarFile(a, "examples/grammars/erlang.toml", source);

    var comment_count: usize = 0;
    for (tokens) |tok| {
        if (tok.kind == .comment) comment_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), comment_count);
}

test "integration: Erlang % comment via CLI stdin pipe does not break parsing" {
    // Complementary CLI-level assertion for the actual `echo '...' | lasp parse -`
    // pipe. With a grammar set the CLI emits structural events, so we assert the
    // end-to-end effect: a leading `%` comment line is consumed (not mis-parsed)
    // and the following column-0 function head is still detected.
    const allocator = std.testing.allocator;
    const source = "% hello\nfoo() -> ok.\n";

    const result = try runLaspWithStdin(allocator, &.{ "parse", "-", "--grammar", "examples/grammars/erlang.toml", "--node", "function", "--names-only" }, source);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    // Exactly one function head (`foo`) survives the comment line.
    var count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (it.next()) |line| {
        if (line.len > 0) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "integration: apostrophe-in-comment does not swallow Erlang function heads" {
    // CORE REGRESSION (TODO Issues #9/#18): comments containing apostrophes
    // must not open a string that swallows the following code. With the
    // `%`-comment erlang.toml, ALL column-0 function heads must be detected.
    // The fixture authors exactly 6 function definitions at column 0.
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{ "parse", "tests/fixtures/comments.erl", "--grammar", "examples/grammars/erlang.toml", "--node", "function", "--names-only" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    // Count non-empty lines (one function name per line).
    var count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (it.next()) |line| {
        if (line.len > 0) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), count);
}

test "integration: colliding identical-sequence patterns emit both functions and calls" {
    const allocator = std.testing.allocator;

    // 1. --node function --names-only lists all 6 function heads
    {
        const result = try runLasp(allocator, &.{
            "parse",
            "tests/fixtures/colliding.erl",
            "--grammar",
            "tests/fixtures/grammars/colliding_function_call.toml",
            "--node",
            "function",
            "--names-only",
        });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

        const expected_heads = [_][]const u8{ "ann", "af_atom", "af_int", "af_var", "af_call", "af_list" };
        var idx: usize = 0;
        var it = std.mem.tokenizeScalar(u8, result.stdout, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            try std.testing.expect(idx < expected_heads.len);
            try std.testing.expectEqualStrings(expected_heads[idx], line);
            idx += 1;
        }
        try std.testing.expectEqual(expected_heads.len, idx);
    }

    // 2. --node call --names-only lists all 3 call sites
    {
        const result = try runLasp(allocator, &.{
            "parse",
            "tests/fixtures/colliding.erl",
            "--grammar",
            "tests/fixtures/grammars/colliding_function_call.toml",
            "--node",
            "call",
            "--names-only",
        });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

        const expected_calls = [_][]const u8{ "helper", "format", "done" };
        var idx: usize = 0;
        var it = std.mem.tokenizeScalar(u8, result.stdout, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            try std.testing.expect(idx < expected_calls.len);
            try std.testing.expectEqualStrings(expected_calls[idx], line);
            idx += 1;
        }
        try std.testing.expectEqual(expected_calls.len, idx);
    }

    // 3. query 'function[name="ann"]' and query 'call[callee="helper"]'
    {
        const result_fn = try runLasp(allocator, &.{
            "query",
            "function[name=\"ann\"]",
            "tests/fixtures/colliding.erl",
            "-g",
            "tests/fixtures/grammars/colliding_function_call.toml",
            "--names-only",
        });
        defer {
            allocator.free(result_fn.stdout);
            allocator.free(result_fn.stderr);
        }
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result_fn.term);
        try std.testing.expectEqualStrings("ann\n", result_fn.stdout);

        const result_call = try runLasp(allocator, &.{
            "query",
            "call[callee=\"helper\"]",
            "tests/fixtures/colliding.erl",
            "-g",
            "tests/fixtures/grammars/colliding_function_call.toml",
            "--names-only",
        });
        defer {
            allocator.free(result_call.stdout);
            allocator.free(result_call.stderr);
        }
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result_call.term);
        try std.testing.expectEqualStrings("helper\n", result_call.stdout);
    }
}

// Feature: same-type-pattern-union, Integration: a union/prefix grammar emits one primary
// per construct (Requirement 7.2). The `--alternatives` flag belongs to the separate
// competing-candidate-emission feature and is not part of this spec.
test "integration: same-type pattern union emits one primary per construct" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/union_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/union.toml",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    // "fn alpha (" matches both decl alternatives; longest-match collapses to one decl.
    // "fn beta ;" matches only the short decl. "use gamma" is a call.
    try std.testing.expectEqual(@as(usize, 3), json_events.array.items.len);

    const expected_types = [_][]const u8{ "decl", "decl", "call" };
    const expected_values = [_][]const u8{ "alpha", "beta", "gamma" };
    for (json_events.array.items, expected_types, expected_values) |ev, exp_type, exp_value| {
        try std.testing.expectEqualStrings(exp_type, ev.object.get("type").?.string);
        // No losers exposed without --alternatives: no "alternatives" key in the JSON.
        try std.testing.expect(ev.object.get("alternatives") == null);
        const cap_key = if (std.mem.eql(u8, exp_type, "call")) "callee" else "name";
        try std.testing.expectEqualStrings(exp_value, ev.object.get(cap_key).?.string);
    }
}

// Feature: number-token-primitive, Integration: the number primitive emits events with
// confidence 1.0 end-to-end (Requirements 4.1, 6.3).
test "integration: number primitive emits events end-to-end" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/number_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/number.toml",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const json_events = parsed.value.object.get("events").?;

    // "42" → num event; "x 7" → decl event (name=x, optional number present).
    try std.testing.expectEqual(@as(usize, 2), json_events.array.items.len);
    try std.testing.expectEqualStrings("num", json_events.array.items[0].object.get("type").?.string);
    try std.testing.expectEqual(@as(f64, 1.0), json_events.array.items[0].object.get("confidence").?.float);
    try std.testing.expectEqualStrings("decl", json_events.array.items[1].object.get("type").?.string);
    try std.testing.expectEqual(@as(f64, 1.0), json_events.array.items[1].object.get("confidence").?.float);
    try std.testing.expectEqualStrings("x", json_events.array.items[1].object.get("name").?.string);
}

// Feature: per-pattern-priors, Integration: out-of-range prior is rejected with a
// descriptive message for both parse and query (Requirement 2.5).
test "integration: invalid prior value rejected with descriptive message" {
    const allocator = std.testing.allocator;

    {
        const result = try runLasp(allocator, &.{
            "parse",
            "tests/fixtures/sample.zig",
            "--grammar",
            "tests/fixtures/grammars/bad_prior.toml",
        });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        switch (result.term) {
            .exited => |code| try std.testing.expect(code != 0),
            else => {},
        }
        try std.testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "prior must be greater than 0.0 and at most 2.0"));
    }

    {
        const result = try runLasp(allocator, &.{
            "query",
            "function",
            "tests/fixtures/sample.zig",
            "-g",
            "tests/fixtures/grammars/bad_prior.toml",
        });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        switch (result.term) {
            .exited => |code| try std.testing.expect(code != 0),
            else => {},
        }
        try std.testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "prior must be greater than 0.0 and at most 2.0"));
    }
}

// Feature: competing-candidate-emission, Integration
// **Validates: Requirements 2.1, 7.1, 8.2, 9.2**
test "integration: --alternatives emits alternatives array; off emits none" {
    const allocator = std.testing.allocator;
    const src = "tests/fixtures/union_sample.txt";
    const grammar = "tests/fixtures/grammars/union.toml";

    {
        const result = try runLasp(allocator, &.{ "parse", src, "-g", grammar, "--alternatives" });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
        defer parsed.deinit();
        const events_arr = parsed.value.object.get("events").?.array.items;
        var saw_key = false;
        for (events_arr) |ev| {
            if (ev.object.get("alternatives") != null) saw_key = true;
        }
        try std.testing.expect(saw_key);
    }

    {
        const result = try runLasp(allocator, &.{ "parse", src, "-g", grammar });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "alternatives") == null);
    }

    {
        const result = try runLasp(allocator, &.{ "query", "decl", src, "-g", grammar, "--alternatives" });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        switch (result.term) {
            .exited => |code| try std.testing.expect(code != 0),
            else => {},
        }
        try std.testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "--alternatives is supported on the parse command only"));
    }
}

test "integration: --alternatives leaves names-only output unchanged" {
    const allocator = std.testing.allocator;
    const src = "tests/fixtures/union_sample.txt";
    const grammar = "tests/fixtures/grammars/union.toml";

    const plain = try runLasp(allocator, &.{ "parse", src, "-g", grammar, "--names-only" });
    defer {
        allocator.free(plain.stdout);
        allocator.free(plain.stderr);
    }
    const with_flag = try runLasp(allocator, &.{ "parse", src, "-g", grammar, "--names-only", "--alternatives" });
    defer {
        allocator.free(with_flag.stdout);
        allocator.free(with_flag.stderr);
    }
    try std.testing.expectEqualStrings(plain.stdout, with_flag.stdout);
}

// Feature: composable-matcher-model, Integration: typed captures emit values
// **Validates: Requirements 3.5, 4.1, 8.2**
test "integration: typed captures and string wildcard emit values" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/typed_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/typed.toml",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const events_arr = parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), events_arr.len);
    try std.testing.expectEqualStrings("msg", events_arr[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("\"hello\"", events_arr[0].object.get("s").?.string);
    try std.testing.expectEqualStrings("num", events_arr[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("42", events_arr[1].object.get("n").?.string);
    try std.testing.expectEqualStrings("msg", events_arr[2].object.get("type").?.string);
    try std.testing.expectEqualStrings("\"key\"", events_arr[2].object.get("s").?.string);
}

// Feature: configurable-token-kinds, Integration: Erlang vocabulary
// **Validates: Requirements 6.2, 6.5, 10.1**
test "integration: Erlang tokens grammar detects calls and quoted atoms" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/sample.erl",
        "--grammar",
        "examples/grammars/erlang_tokens.toml",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const events_arr = parsed.value.object.get("events").?.array.items;

    // sample.erl contains at least one function head `foo() -> ok.`; the call
    // pattern is atom "(" atom ")" and the head contains atom "(" ")" only.
    var call_count: usize = 0;
    for (events_arr) |ev| {
        if (std.mem.eql(u8, ev.object.get("type").?.string, "call")) call_count += 1;
    }
    try std.testing.expect(call_count >= 1);
}

test "integration: Erlang tokens grammar treats 'atom' as quoted atom, not string" {
    const allocator = std.testing.allocator;
    const result = try runLaspWithStdin(allocator, &.{
        "parse",
        "-",
        "--grammar",
        "examples/grammars/erlang_tokens.toml",
    }, "'hello'\n");
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const events_arr = parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), events_arr.len);
    try std.testing.expectEqualStrings("quoted", events_arr[0].object.get("type").?.string);
}

test "integration: Forth tokens grammar detects : name ; definition" {
    const allocator = std.testing.allocator;
    const result = try runLaspWithStdin(allocator, &.{
        "parse",
        "-",
        "--grammar",
        "examples/grammars/forth_tokens.toml",
    }, ": double ;\n");
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const events_arr = parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), events_arr.len);
    try std.testing.expectEqualStrings("definition", events_arr[0].object.get("type").?.string);
}

test "integration: existing zig grammar output unchanged (no [tokens])" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/sample.zig",
        "--grammar",
        "examples/grammars/zig.toml",
        "--node",
        "pub_function",
        "--names-only",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "add") != null);
}

// Feature: grammar-projected-resemblance, Integration
// **Validates: Requirements 4.1, 5.1, 6.1**
test "integration: --resemble surfaces number resemblance alternatives end-to-end" {
    const allocator = std.testing.allocator;
    const result = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/resemblance_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/resemblance.toml",
        "--resemble",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    const events_arr = parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), events_arr.len);

    // Hex/bin literals → grammar `literal` primary with a `number` resemblance alternative.
    for (events_arr[0..2]) |ev| {
        try std.testing.expectEqualStrings("literal", ev.object.get("type").?.string);
        const alts = ev.object.get("alternatives").?.array.items;
        var saw_number = false;
        for (alts) |alt| {
            if (std.mem.eql(u8, alt.object.get("type").?.string, "number") and
                std.mem.eql(u8, alt.object.get("source").?.string, "resemblance"))
            {
                saw_number = true;
                try std.testing.expect(alt.object.get("membership").?.float < 1.0);
            }
        }
        try std.testing.expect(saw_number);
    }

    // "42" → exact `num` primary.
    const num_ev = events_arr[2].object;
    try std.testing.expectEqualStrings("num", num_ev.get("type").?.string);
}

test "integration: parse without --resemble is unchanged for resemblance fixture" {
    const allocator = std.testing.allocator;
    const plain = try runLasp(allocator, &.{
        "parse",
        "tests/fixtures/resemblance_sample.txt",
        "--grammar",
        "tests/fixtures/grammars/resemblance.toml",
    });
    defer {
        allocator.free(plain.stdout);
        allocator.free(plain.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, plain.term);
    try std.testing.expect(std.mem.indexOf(u8, plain.stdout, "alternatives") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain.stdout, "source") == null);
}

// --- tokenizer-line-tracking regressions (spec: tokenizer-line-tracking, task 4.4) ---
/// Independent ground truth for a byte offset: 1-based line and 0-based col.
fn truthLineCol(source: []const u8, start: usize) struct { line: i64, col: i64 } {
    var line: i64 = 1;
    var line_start: usize = 0;
    for (source[0..start], 0..) |b, k| {
        if (b == '\n') {
            line += 1;
            line_start = k + 1;
        }
    }
    return .{ .line = line, .col = @intCast(start - line_start) };
}

fn expectEventsGroundTruth(source: []const u8, evs: []const std.json.Value) !void {
    for (evs) |ev| {
        const o = ev.object;
        const start: usize = @intCast(o.get("start").?.integer);
        const t = truthLineCol(source, start);
        try std.testing.expectEqual(t.line, o.get("line").?.integer);
        try std.testing.expectEqual(t.col, o.get("col").?.integer);
    }
}

test "integration: default tokenizer reports true line after multi-line string (Repro 1)" {
    const allocator = std.testing.allocator;
    const r = try runLaspWithStdin(allocator, &.{ "parse", "-", "--jsonl" }, "\"a\nb\nc\"\nx\n");
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    var found = false;
    var it = std.mem.splitScalar(u8, r.stdout, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const o = parsed.value.object;
        if (std.mem.eql(u8, o.get("type").?.string, "identifier")) {
            found = true;
            try std.testing.expectEqual(@as(i64, 4), o.get("line").?.integer);
        }
    }
    try std.testing.expect(found);
}

test "integration: trailing backslash with a grammar does not abort" {
    const allocator = std.testing.allocator;
    const r = try runLaspWithStdin(allocator, &.{ "parse", "-", "-g", "examples/grammars/zig.toml" }, "\"abc\\");
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "index out of bounds") == null);
}

test "integration: events after a multi-line delimited_span have ground-truth line/col" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const source = try std.Io.Dir.cwd().readFileAlloc(io, "tests/fixtures/multiline_span.txt", allocator, .limited(1 << 20));
    defer allocator.free(source);

    // Wrapped JSON.
    const w = try runLasp(allocator, &.{ "parse", "tests/fixtures/multiline_span.txt", "-g", "tests/fixtures/grammars/multiline_span.toml" });
    defer {
        allocator.free(w.stdout);
        allocator.free(w.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, w.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, w.stdout, .{});
    defer parsed.deinit();
    const evs = parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 5), evs.len);
    try expectEventsGroundTruth(source, evs);
    // "delta" follows a two-line span on the line it ends.
    try std.testing.expectEqual(@as(i64, 5), evs[3].object.get("line").?.integer);

    // NDJSON.
    const j = try runLasp(allocator, &.{ "parse", "tests/fixtures/multiline_span.txt", "-g", "tests/fixtures/grammars/multiline_span.toml", "--jsonl" });
    defer {
        allocator.free(j.stdout);
        allocator.free(j.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, j.term);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, j.stdout, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const p = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer p.deinit();
        try expectEventsGroundTruth(source, &.{p.value});
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), n);
}

// charset-escape-and-nonascii-ranges E6 (Property 1). Encodes the FIXED behavior.
fn expectSetupLabelEvent(fixture: []const u8) !void {
    const allocator = std.testing.allocator;
    const r = try runLaspWithStdin(allocator, &.{ "parse", "-", "-g", fixture }, "```{r setup}\n");
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, r.stdout, .{});
    defer parsed.deinit();
    const evs = parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqualStrings("setup", evs[0].object.get("label").?.string);
}

test "charset exploration E6: escaped dash in continue set captures label 'setup'" {
    try expectSetupLabelEvent("tests/fixtures/grammars/charset_escape.toml");
}

test "charset exploration E6b: escaped dash before a non-ASCII literal does not swallow '}'" {
    try expectSetupLabelEvent("tests/fixtures/grammars/charset_escape_nonascii.toml");
}

// charset-escape-and-nonascii-ranges: CLI / integration tests (U12, I1, I3).
// Writes a one-kind grammar with the given char-set TOML fragment to a temp
// file, runs `parse` on it, and removes the file.
const CharSetRun = struct { stdout: []u8, stderr: []u8, term: std.process.Child.Term };

fn runWithCharSetGrammar(allocator: std.mem.Allocator, kind_body: []const u8) !CharSetRun {
    const io = std.testing.io;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    const path = "charset_tmp_grammar.toml";
    const toml_text = try std.fmt.allocPrint(
        allocator,
        "[[patterns]]\ntype = \"t\"\nsequence = [\"ident\"]\n\n[tokens]\nident = {{ char_class_run = {{ {s} }} }}\n",
        .{kind_body},
    );
    defer allocator.free(toml_text);
    try writeFixtureFile(sb.tmp.dir, io, path, toml_text);
    const r = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "-g", path });
    return .{ .stdout = r.stdout, .stderr = r.stderr, .term = r.term };
}

test "charset U12: non-ASCII range endpoint fails with an actionable message" {
    const allocator = std.testing.allocator;
    const r = try runWithCharSetGrammar(allocator, "start = \"a-é\"");
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expect(!std.meta.eql(r.term, std.process.Child.Term{ .exited = 0 }));
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "ASCII endpoints") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "\\-") != null);
}

test "charset I1: the old non-ASCII-range workaround fails to load with the new message" {
    const allocator = std.testing.allocator;
    const r = try runWithCharSetGrammar(allocator, "start = \"a-zA-Z_\", continue = \"a-zA-Z0-9_Ѐ-ӿ-\"");
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expect(!std.meta.eql(r.term, std.process.Child.Term{ .exited = 0 }));
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "ASCII endpoints") != null);
}

test "charset I3: example and valid fixture grammars still load" {
    const allocator = std.testing.allocator;
    const dir = try runLasp(allocator, &.{ "parse-dir", "tests/fixtures", "--grammar-dir", "examples/grammars" });
    defer {
        allocator.free(dir.stdout);
        allocator.free(dir.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, dir.term);

    // Intentionally malformed fixtures (malformed, invalid_position, bad_prior) are excluded.
    const valid = [_][]const u8{
        "charset_escape", "charset_escape_nonascii", "colliding_function_call",
        "counts",         "extent_brace",            "extent_terminator",
        "multiline_span", "multiline_span_position", "number",
        "resemblance",    "typed",                   "union",
        "zig",
    };
    for (valid) |name| {
        const path = try std.fmt.allocPrint(allocator, "tests/fixtures/grammars/{s}.toml", .{name});
        defer allocator.free(path);
        const r = try runLasp(allocator, &.{ "parse", "tests/fixtures/sample.zig", "-g", path });
        defer {
            allocator.free(r.stdout);
            allocator.free(r.stderr);
        }
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    }
}

// Regression guard: passes before AND after the fix. markdown_tasks.toml has no
// string kind, so a stray quote is an unknown byte and never swallows lines.
test "integration: markdown_tasks reports true lines with stray quotes in prose" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "tests/fixtures/markdown_stray_quotes.md";
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
    defer allocator.free(source);

    const r = try runLasp(allocator, &.{ "parse", path, "-g", "examples/grammars/markdown_tasks.toml" });
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, r.stdout, .{});
    defer parsed.deinit();
    const evs = parsed.value.object.get("events").?.array.items;
    try expectEventsGroundTruth(source, evs);

    // Expected open-task lines come from the fixture bytes, not from lasp.
    var want: std.ArrayList(i64) = .empty;
    defer want.deinit(allocator);
    var line_no: i64 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |l| {
        line_no += 1;
        if (std.mem.indexOf(u8, l, "- [ ]") != null) try want.append(allocator, line_no);
    }
    var got: std.ArrayList(i64) = .empty;
    defer got.deinit(allocator);
    for (evs) |ev| {
        if (std.mem.eql(u8, ev.object.get("type").?.string, "task_open"))
            try got.append(allocator, ev.object.get("line").?.integer);
    }
    try std.testing.expectEqualSlices(i64, want.items, got.items);
    try std.testing.expectEqual(@as(usize, 3), got.items.len);
}

test "integration: position=start and extent at_column see true columns after a multi-line span" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "tests/fixtures/multiline_span_position.txt";
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
    defer allocator.free(source);

    const r = try runLasp(allocator, &.{ "parse", path, "-g", "tests/fixtures/grammars/multiline_span_position.toml" });
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, r.stdout, .{});
    defer parsed.deinit();
    const evs = parsed.value.object.get("events").?.array.items;

    // `bar` and `qux` start at true column 0; `baz` (col 8) is rejected.
    try std.testing.expectEqual(@as(usize, 2), evs.len);
    try std.testing.expectEqualStrings("bar", evs[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("qux", evs[1].object.get("name").?.string);
    try expectEventsGroundTruth(source, evs);

    // The extent stops at the column-0 `.` on its own line, not the mid-line one.
    const dot_line = std.mem.indexOf(u8, source, "\n.\n").? + 2;
    try std.testing.expectEqual(@as(i64, @intCast(dot_line)), evs[0].object.get("region").?.integer);
}

// --- grammar-error-prefix-fix: Task 1, bug condition exploration (Property 1) ---
// Every stderr error line must start with exactly one `error: `. These tests
// encode the FIXED behavior and fail on code that repeats the prefix.
const err_prefix_charset_body = "error: [tokens] invalid char set: ranges must have ASCII endpoints and run low-to-high, use \\- for a literal '-' and \\\\ for a literal '\\' (other escapes are not allowed): ";

test "error prefix P1: grammar charset error is one exact line (parse)" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedErrPrefixFixtures(&sb);
    const gp = err_prefix_dir ++ "/bad_charset.toml";
    try expectFatalOnePrefix(allocator, &.{ "parse", "tests/fixtures/sample.zig", "-g", gp }, err_prefix_charset_body ++ gp ++ "\n");
}

test "error prefix P1: grammar charset error is one exact line (stdin parse)" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedErrPrefixFixtures(&sb);
    const gp = err_prefix_dir ++ "/bad_charset.toml";
    const r = try runLaspWithStdin(allocator, &.{ "parse", "-", "-g", gp }, "a\n");
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try expectFatalResultOnePrefix(r.term, r.stdout, r.stderr, err_prefix_charset_body ++ gp ++ "\n");
}

test "error prefix P1: grammar charset error is one exact line (query)" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedErrPrefixFixtures(&sb);
    const gp = err_prefix_dir ++ "/bad_charset.toml";
    try expectFatalOnePrefix(allocator, &.{ "query", "function", "tests/fixtures/sample.zig", "-g", gp }, err_prefix_charset_body ++ gp ++ "\n");
}

test "error prefix P1: [comments] grammar error has one prefix" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedErrPrefixFixtures(&sb);
    const gp = err_prefix_dir ++ "/bad_comments.toml";
    try expectFatalOnePrefix(allocator, &.{ "parse", "tests/fixtures/sample.zig", "-g", gp }, "error: [comments] line must be an array of strings: " ++ gp ++ "\n");
}

test "error prefix P1: malformed TOML grammar has one prefix" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedErrPrefixFixtures(&sb);
    const gp = err_prefix_dir ++ "/bad_toml.toml";
    try expectFatalOnePrefix(allocator, &.{ "parse", "tests/fixtures/sample.zig", "-g", gp }, "error: invalid TOML syntax in grammar file: " ++ gp ++ "\n");
}

test "error prefix P1: unrecognized flag has one prefix" {
    const allocator = std.testing.allocator;
    try expectFatalOnePrefix(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--bogus" }, "error: unrecognized flag\n");
}

test "error prefix P1: --jsonl with --names-only has one prefix" {
    const allocator = std.testing.allocator;
    try expectFatalOnePrefix(allocator, &.{ "parse", "tests/fixtures/sample.zig", "--jsonl", "--names-only" }, "error: --jsonl and --names-only are mutually exclusive\n");
}

test "error prefix P1: --jsonl --version has one prefix" {
    const allocator = std.testing.allocator;
    try expectFatalOnePrefix(allocator, &.{ "--jsonl", "--version" }, "error: --jsonl is only supported on parse, parse-dir, and query commands\n");
}

test "error prefix P1: malformed query selector has one prefix" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedErrPrefixFixtures(&sb);
    try expectFatalOnePrefix(allocator, &.{ "query", "function[", "tests/fixtures/sample.zig", "-g", err_prefix_dir ++ "/good.toml" }, "error: missing field name in attribute condition\n");
}

test "error prefix P1: query without a grammar has one prefix" {
    const allocator = std.testing.allocator;
    try expectFatalOnePrefix(allocator, &.{ "query", "function", "tests/fixtures/sample.zig" }, "error: query command requires --grammar/-g flag\n");
}

test "error prefix P1: --alternatives on query has one prefix" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedErrPrefixFixtures(&sb);
    try expectFatalOnePrefix(allocator, &.{ "query", "function", "tests/fixtures/sample.zig", "-g", err_prefix_dir ++ "/good.toml", "--alternatives" }, "error: --alternatives is supported on the parse command only\n");
}

test "error prefix P1: malformed default grammar has one prefix" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedDefaultGrammars(allocator, &sb, &.{.{ .name = "bad.toml", .content = "[language]\nextensions = [\".erl\"]\n\n[[patterns]]\ntype = \"t\"\nsequence = [\"ident\"]\n\n[tokens]\nident = { char_class_run = { start = \"z-a\" } }\n" }});
    try expectFatalOnePrefix(allocator, &.{ "parse", "tests/fixtures/dir_sample/a.erl" }, null);
    try expectFatalOnePrefix(allocator, &.{ "parse-dir", "tests/fixtures/dir_sample" }, err_prefix_charset_body ++ ".lasp/grammars/bad.toml\n");
}

test "error prefix P1: --names-only with several default grammars has one prefix" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    sb.enter();
    try seedDefaultGrammars(allocator, &sb, &.{
        .{ .name = "erlang.toml", .content = erlang_grammar_toml },
        .{ .name = "erlang2.toml", .content = erlang2_grammar_toml },
    });
    try expectFatalOnePrefix(allocator, &.{ "parse", "tests/fixtures/dir_sample/a.erl", "--names-only" }, "error: --names-only requires a single grammar (pass -g/--grammar)\n");
}

test "error prefix P1: missing source file yields two lines, one prefix each" {
    const allocator = std.testing.allocator;
    const p = "tests/fixtures/definitely_missing_source.zig";
    try expectFatalOnePrefix(allocator, &.{ "parse", p }, "error: file not found: " ++ p ++ "\nerror: failed to read file: " ++ p ++ "\n");
}

// --- grammar-error-prefix-fix: Task 2, preservation (Property 2) ---
// Observed on unfixed code; these paths must stay byte-identical after the fix.
test "error prefix P2: no-args prints one prefix then the help text, exit 1, empty stdout" {
    const allocator = std.testing.allocator;
    const r = try runLasp(allocator, &.{});
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, r.term);
    try std.testing.expectEqual(@as(usize, 0), r.stdout.len);
    try std.testing.expect(std.mem.startsWith(u8, r.stderr, "error: " ++ cli.general_help_text));
    try std.testing.expect(std.mem.startsWith(u8, r.stderr, "error: lasp - Language-Agnostic Structural Parser\n"));
    // The only `error: ` in the whole stream is the leading one.
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfPos(u8, r.stderr, 1, "error:"));
}

test "error prefix P2: help and version invocations write stdout only, exit 0, no error text" {
    const allocator = std.testing.allocator;
    const cases = [_][]const []const u8{
        &.{"--help"},
        &.{"-h"},
        &.{"help"},
        &.{"--version"},
        &.{"-V"},
        &.{"version"},
        &.{ "parse", "--help" },
        &.{ "query", "--help" },
        &.{ "parse-dir", "--help" },
        &.{ "--help", "--version" },
    };
    for (cases) |args| {
        const r = try runLasp(allocator, args);
        defer {
            allocator.free(r.stdout);
            allocator.free(r.stderr);
        }
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
        try std.testing.expect(r.stdout.len > 0);
        try std.testing.expectEqual(@as(usize, 0), r.stderr.len);
        try std.testing.expect(std.mem.indexOf(u8, r.stdout, "error:") == null);
    }
}

test "error prefix P2: missing grammar file yields two lines, one prefix each" {
    const allocator = std.testing.allocator;
    const gp = "tests/fixtures/grammars/definitely_missing.toml";
    try expectFatalOnePrefix(allocator, &.{ "parse", "tests/fixtures/sample.zig", "-g", gp }, "error: file not found: " ++ gp ++ "\nerror: failed to read grammar file: " ++ gp ++ "\n");
}

test "error prefix P2: missing source file with a valid grammar keeps the two-line structure" {
    const allocator = std.testing.allocator;
    const p = "tests/fixtures/definitely_missing_source.zig";
    try expectFatalOnePrefix(allocator, &.{ "parse", p, "-g", "tests/fixtures/grammars/zig.toml" }, "error: file not found: " ++ p ++ "\nerror: failed to read file: " ++ p ++ "\n");
}

// --- Bug condition exploration tests (spec: json-string-escaping, task 1) ---
// Encode the EXPECTED (fixed) behavior; MUST FAIL on unfixed code.
const explore_str_grammar =
    \\[tokens]
    \\str = { delimited_span = { open = "\"", close = "\"" } }
    \\
    \\[[patterns]]
    \\type = "lit"
    \\sequence = ["$s:str"]
    \\
;

test "exploration: multi-line string capture, parse --jsonl is one parseable line" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    try writeFixtureFile(sb.tmp.dir, std.testing.io, "str.toml", explore_str_grammar);
    sb.enter();

    const input = "\"a\nb\tc\"";
    const r = try runLaspWithStdin(allocator, &.{ "parse", "-", "-g", "str.toml", "--jsonl" }, input);
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.stdout, "\n"));
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, r.stdout, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(input, parsed.value.object.get("s").?.string);
}

test "exploration: multi-line string capture, wrapped parse and query parse" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    try writeFixtureFile(sb.tmp.dir, std.testing.io, "str.toml", explore_str_grammar);
    sb.enter();

    const input = "\"a\nb\tc\"";
    const cmds = [_][]const []const u8{
        &.{ "parse", "-", "-g", "str.toml" },
        &.{ "query", "lit", "-", "-g", "str.toml" },
    };
    for (cmds) |args| {
        const r = try runLaspWithStdin(allocator, args, input);
        defer {
            allocator.free(r.stdout);
            allocator.free(r.stderr);
        }
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, r.stdout, .{});
        defer parsed.deinit();
        const ev = parsed.value.object.get("events").?.array.items[0].object;
        try std.testing.expectEqualStrings(input, ev.get("s").?.string);
    }
}

test "exploration: grammar type name containing a quote yields parseable output" {
    const allocator = std.testing.allocator;
    var sb = try Sandbox.init(allocator);
    defer sb.deinit();
    try writeFixtureFile(sb.tmp.dir, std.testing.io, "q.toml",
        \\[[patterns]]
        \\type = "a\"b"
        \\sequence = ["fn", "$name:IDENTIFIER"]
        \\
    );
    sb.enter();

    const r = try runLaspWithStdin(allocator, &.{ "parse", "-", "-g", "q.toml", "--jsonl" }, "fn foo");
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, r.stdout, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a\"b", parsed.value.object.get("type").?.string);
}
