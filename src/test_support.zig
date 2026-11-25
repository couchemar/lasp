const std = @import("std");

/// Scratch directory for CLI tests that must create files (fixture trees,
/// throwaway grammars, `.lasp/grammars`). It lives under `.zig-cache/tmp`
/// (`std.testing.tmpDir`: unique random name, removed by `deinit`), never in the
/// repo root. `tests` and `examples` are symlinked into it, so after `enter()`
/// the spawned binary runs with the sandbox as its cwd and repo-relative
/// arguments (`tests/fixtures/...`, `examples/grammars/...`) plus sandbox-relative
/// ones (`tree/a.erl`, `.lasp/grammars`) resolve exactly as they did from the
/// repo root, so output and error-message assertions are unchanged.
pub const Sandbox = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    /// Absolute sandbox path.
    abs: []u8,
    /// Absolute path of the binary under test (the child's cwd is not the repo root).
    bin: []u8,

    pub fn init(allocator: std.mem.Allocator) !Sandbox {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const abs = try allocator.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
        errdefer allocator.free(abs);
        const repo = buf[0..try std.Io.Dir.cwd().realPathFile(io, ".", &buf)];
        const bin = try std.fmt.allocPrint(allocator, "{s}/zig-out/bin/lasp", .{repo});
        errdefer allocator.free(bin);
        for ([_][]const u8{ "tests", "examples" }) |name| {
            const target = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo, name });
            defer allocator.free(target);
            try tmp.dir.symLink(io, target, name, .{ .is_directory = true });
        }
        return .{ .allocator = allocator, .tmp = tmp, .abs = abs, .bin = bin };
    }

    /// Makes `runLasp`/`runLaspWithStdin`/`runLaspEarlyClose` spawn with this
    /// sandbox as cwd until `deinit`. Tests run serially, so one active at a time.
    pub fn enter(self: *const Sandbox) void {
        active_sandbox = .{ .cwd = self.abs, .bin = self.bin };
    }

    pub fn deinit(self: *Sandbox) void {
        active_sandbox = null;
        self.tmp.cleanup();
        self.allocator.free(self.abs);
        self.allocator.free(self.bin);
    }

    /// Caller-owned absolute path of `rel` inside the sandbox.
    pub fn join(self: *const Sandbox, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.abs, rel });
    }
};

pub const ActiveSandbox = struct { cwd: []const u8, bin: []const u8 };

pub var active_sandbox: ?ActiveSandbox = null;

pub fn laspBinary() []const u8 {
    return if (active_sandbox) |a| a.bin else "zig-out/bin/lasp";
}

pub fn laspCwd() std.process.Child.Cwd {
    return if (active_sandbox) |a| .{ .path = a.cwd } else .inherit;
}

pub fn runLasp(allocator: std.mem.Allocator, args: []const []const u8) !struct { stdout: []u8, stderr: []u8, term: std.process.Child.Term } {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, laspBinary());
    for (args) |a| try argv.append(allocator, a);
    const result = try std.process.run(allocator, std.testing.io, .{ .argv = argv.items, .cwd = laspCwd() });
    return .{ .stdout = result.stdout, .stderr = result.stderr, .term = result.term };
}

pub fn writeFixtureFile(dir: std.Io.Dir, io: std.Io, path: []const u8, content: []const u8) !void {
    const file = try dir.createFile(io, path, .{});
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(content);
    try w.interface.flush();
    file.close(io);
}

/// Best-effort removal of a fixture directory tree (two passes: files, then
/// directories — walk order is undefined).
pub fn removeDirTree(dir: std.Io.Dir, allocator: std.mem.Allocator, io: std.Io, path: []const u8) void {
    var root = dir.openDir(io, path, .{ .iterate = true }) catch return;
    defer root.close(io);

    var walker = root.walk(allocator) catch return;
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind == .file) root.deleteFile(io, entry.path) catch {};
    }
    var walker2 = root.walk(allocator) catch return;
    defer walker2.deinit();
    while (walker2.next(io) catch null) |entry| {
        if (entry.kind == .directory) root.deleteDir(io, entry.path) catch {};
    }
    dir.deleteDir(io, path) catch {};
}

/// Creates (inside the given sandbox) a dir tree with a `.erl`, a `.py`, an unmatched `.txt`, a
/// recursive `.erl` in a subdirectory, and a grammar dir where the Erlang
/// grammar declares `.erl` and the Python grammar `.py`.
pub const ParseDirFixture = struct {
    tree: []const u8,
    grammars: []const u8,
};

pub fn makeParseDirFixture(allocator: std.mem.Allocator, sb: *const Sandbox) !ParseDirFixture {
    const io = std.testing.io;
    const dir = sb.tmp.dir;
    const tree = "test_parsedir_tree";
    const grammars = "test_parsedir_grammars";
    try dir.createDir(io, tree, .default_dir);
    try dir.createDir(io, tree ++ "/sub", .default_dir);
    try dir.createDir(io, grammars, .default_dir);
    try writeFixtureFile(dir, io, tree ++ "/a.erl", "foo() -> 1.\n");
    try writeFixtureFile(dir, io, tree ++ "/b.py", "bar()\n");
    try writeFixtureFile(dir, io, tree ++ "/notes.txt", "irrelevant\n");
    try writeFixtureFile(dir, io, tree ++ "/sub/c.erl", "baz() -> 2.\n");

    const erlang = try std.fmt.allocPrint(allocator, "[language]\nname = \"erlang\"\nextensions = [\".erl\"]\n\n[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"(\"]\n", .{});
    const python = try std.fmt.allocPrint(allocator, "[language]\nname = \"python\"\nextensions = [\".py\"]\n\n[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"(\", \")\"]\n", .{});
    try writeFixtureFile(dir, io, grammars ++ "/erlang.toml", erlang);
    try writeFixtureFile(dir, io, grammars ++ "/python.toml", python);
    allocator.free(erlang);
    allocator.free(python);

    return .{ .tree = tree, .grammars = grammars };
}

/// Asserts the EXPECTED post-fix behavior for one parse-dir form:
/// exit zero, valid JSON array, every entry's `file` is `.erl`/`.py`, the
/// `.txt` appears in no entry, and no `failed to read file` on stderr.
pub fn expectParseDirOk(result: anytype, allocator: std.mem.Allocator) !void {
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "failed to read file") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "notes.txt") == null);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    for (parsed.value.array.items) |entry| {
        const f = entry.object.get("file").?.string;
        try std.testing.expect(
            std.mem.endsWith(u8, f, ".erl") or std.mem.endsWith(u8, f, ".py"),
        );
        try std.testing.expect(entry.object.get("grammar").? == .string);
        try std.testing.expect(entry.object.get("events").? == .array);
        try std.testing.expect(std.mem.indexOf(u8, f, "notes.txt") == null);
    }
}

pub const erlang_grammar_toml = "[language]\nname = \"erlang\"\nextensions = [\".erl\"]\n\n[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"(\"]\n";

pub const erlang2_grammar_toml = "[language]\nname = \"erlang2\"\nextensions = [\".erl\"]\n\n[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"(\"]\n";

pub const python_grammar_toml = "[language]\nname = \"python\"\nextensions = [\".py\"]\n\n[[patterns]]\ntype = \"function\"\nsequence = [\"identifier\", \"(\", \")\"]\n";

pub const SeedGrammar = struct {
    name: []const u8,
    content: []const u8,
};

/// Recreates `.lasp/grammars` inside the sandbox (removing any pre-existing
/// `.lasp` there) with the given grammar files.
pub fn seedDefaultGrammars(allocator: std.mem.Allocator, sb: *const Sandbox, seeds: []const SeedGrammar) !void {
    const io = std.testing.io;
    const dir = sb.tmp.dir;
    removeDirTree(dir, allocator, io, ".lasp");
    try dir.createDir(io, ".lasp", .default_dir);
    try dir.createDir(io, ".lasp/grammars", .default_dir);
    for (seeds) |s| {
        const path = try std.fmt.allocPrint(allocator, ".lasp/grammars/{s}", .{s.name});
        defer allocator.free(path);
        try writeFixtureFile(dir, io, path, s.content);
    }
}

/// Spawns LASP, reads exactly `prefix_len` bytes of stdout, closes the read end
/// (simulating `head -c N`), then waits. Returns the term and captured stderr.
pub fn runLaspEarlyClose(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    prefix_len: usize,
) !struct { term: std.process.Child.Term, stderr: []u8 } {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, laspBinary());
    for (args) |a| try argv.append(allocator, a);
    var child = try std.process.spawn(std.testing.io, .{
        .argv = argv.items,
        .cwd = laspCwd(),
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer if (child.stdout) |f| f.close(std.testing.io);
    defer if (child.stderr) |f| f.close(std.testing.io);

    // Drain a small prefix of stdout, then close the read end.
    var buf: [4096]u8 = undefined;
    if (child.stdout) |out| {
        var prefix_read: usize = 0;
        var r = out.reader(std.testing.io, &buf);
        while (prefix_read < prefix_len) {
            var slices = [1][]u8{buf[prefix_read..]};
            const n = try r.interface.readVec(&slices);
            if (n == 0) break;
            prefix_read += n;
        }
        out.close(std.testing.io);
        child.stdout = null;
    }

    const term = try child.wait(std.testing.io);

    var stderr_out: []u8 = &[_]u8{};
    if (child.stderr) |err_f| {
        var ebuf: [4096]u8 = undefined;
        var er = err_f.reader(std.testing.io, &ebuf);
        stderr_out = try er.interface.allocRemaining(allocator, .limited(1 << 20));
        child.stderr = null;
    }
    return .{ .term = term, .stderr = stderr_out };
}

pub fn runLaspWithStdin(allocator: std.mem.Allocator, args: []const []const u8, stdin_data: []const u8) !struct { stdout: []u8, stderr: []u8, term: std.process.Child.Term } {
    const io = std.testing.io;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, laspBinary());
    for (args) |a| try argv.append(allocator, a);
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = laspCwd(),
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    // Write stdin data and close the pipe
    if (child.stdin) |stdin_file| {
        var wbuf: [4096]u8 = undefined;
        var writer = stdin_file.writer(io, &wbuf);
        try writer.interface.writeAll(stdin_data);
        try writer.interface.flush();
        stdin_file.close(io);
        child.stdin = null;
    }

    // Collect stdout and stderr concurrently (mirrors std.process.run).
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try multi_reader.checkAnyError();

    const term = try child.wait(io);

    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);

    return .{ .stdout = stdout_slice, .stderr = stderr_slice, .term = term };
}

/// Asserts every non-empty stderr line starts with `error: ` and that
/// `error: error:` occurs nowhere.
pub fn expectOnePrefixPerLine(stderr: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, stderr, "error: error:") == null);
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(std.mem.startsWith(u8, line, "error: "));
    }
}

/// Runs lasp and asserts: exit code 1, empty stdout, one prefix per error
/// line, and (when given) the exact stderr bytes.
pub fn expectFatalOnePrefix(allocator: std.mem.Allocator, args: []const []const u8, expected_stderr: ?[]const u8) !void {
    const r = try runLasp(allocator, args);
    defer {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    try expectFatalResultOnePrefix(r.term, r.stdout, r.stderr, expected_stderr);
}

pub fn expectFatalResultOnePrefix(term: std.process.Child.Term, stdout: []const u8, stderr: []const u8, expected_stderr: ?[]const u8) !void {
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, term);
    try std.testing.expectEqual(@as(usize, 0), stdout.len);
    try expectOnePrefixPerLine(stderr);
    if (expected_stderr) |exp| try std.testing.expectEqualStrings(exp, stderr);
}

pub const err_prefix_dir = "test_errprefix_tmp";

/// Creates `test_errprefix_tmp` in the sandbox, holding the throwaway grammars the cases use.
pub fn seedErrPrefixFixtures(sb: *const Sandbox) !void {
    const io = std.testing.io;
    const dir = sb.tmp.dir;
    try dir.createDir(io, err_prefix_dir, .default_dir);
    const pat = "[[patterns]]\ntype = \"t\"\nsequence = [\"ident\"]\n\n";
    try writeFixtureFile(dir, io, err_prefix_dir ++ "/bad_charset.toml", pat ++ "[tokens]\nident = { char_class_run = { start = \"z-a\" } }\n");
    try writeFixtureFile(dir, io, err_prefix_dir ++ "/bad_comments.toml", pat ++ "[comments]\nline = \"x\"\n");
    try writeFixtureFile(dir, io, err_prefix_dir ++ "/bad_toml.toml", "this is [[ not toml");
    try writeFixtureFile(dir, io, err_prefix_dir ++ "/good.toml", "[[patterns]]\ntype = \"function\"\nsequence = [\"fn\", \"$name:IDENTIFIER\", \"(\"]\n");
}
