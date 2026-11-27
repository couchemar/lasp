const std = @import("std");
const grammar_loader = @import("../grammar/loader.zig");
const grammar_compiler = @import("../grammar/compiler.zig");
const diagnostics = @import("diagnostics.zig");
const fatalError = diagnostics.fatalError;
const grammarErrorDetail = diagnostics.grammarErrorDetail;
const readSourceFile = @import("source.zig").readSourceFile;
/// Suffix match test in `--grammar-dir` extension matching. The dot-less form
/// (e.g. `erl`) is the broader documented suffix.
pub fn basenameMatchesExtension(basename: []const u8, ext: []const u8) bool {
    return std.mem.endsWith(u8, basename, ext);
}

pub const default_grammar_dir = ".lasp/grammars";

pub const LoadedGrammar = struct {
    name: []const u8,
    grammar: grammar_loader.Grammar,
    automaton: grammar_compiler.Automaton,
};

/// Loads every *.toml from gdir (sorted by filename), compiling each automaton
/// once. Fatal (existing messages, naming the offending path) on read/parse
/// failure; only a missing/not-a-directory gdir yields error.GrammarDirNotFound.
pub fn loadGrammarsFromDir(io: std.Io, allocator: std.mem.Allocator, gdir: []const u8) ![]LoadedGrammar {
    var handle = std.Io.Dir.cwd().openDir(io, gdir, .{ .iterate = true }) catch return error.GrammarDirNotFound;
    defer handle.close(io);

    // Deterministic order: sort the *.toml basenames.
    var names: std.ArrayList([]const u8) = .empty;
    var it = handle.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var loaded: std.ArrayList(LoadedGrammar) = .empty;
    for (names.items) |name| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ gdir, name });
        try loaded.append(allocator, try loadGrammarFile(io, allocator, path, name));
    }
    return try loaded.toOwnedSlice(allocator);
}

/// The only place a grammar file becomes a compiled grammar. Fatal (existing
/// messages, naming `path`) on read or parse failure.
pub fn loadGrammarFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, name: []const u8) !LoadedGrammar {
    const grammar_source = readSourceFile(io, allocator, path) catch {
        fatalError("failed to read grammar file: {s}", .{path});
    };
    var diag: grammar_loader.Diagnostic = .{};
    const grammar = grammar_loader.parseGrammarDiag(grammar_source, allocator, &diag) catch |err| {
        var detail_buf: [256]u8 = undefined;
        const msg: []const u8 = grammarErrorDetail(err, &diag, &detail_buf);
        fatalError("{s}: {s}", .{ msg, path });
    };
    return .{
        .name = name,
        .grammar = grammar,
        .automaton = try grammar_compiler.compile(grammar.patterns, allocator),
    };
}

/// The only extension-match rule: a grammar with no extensions never matches;
/// otherwise any extension that suffix-matches the basename.
pub fn grammarMatches(grammar: grammar_loader.Grammar, basename: []const u8) bool {
    for (grammar.extensions) |ext| {
        if (basenameMatchesExtension(basename, ext)) return true;
    }
    return false;
}

/// Grammars of the default dir (.lasp/grammars); an absent or not-a-directory
/// default yields an empty slice.
pub fn loadDefaultGrammars(io: std.Io, allocator: std.mem.Allocator) ![]LoadedGrammar {
    return loadGrammarsFromDir(io, allocator, default_grammar_dir) catch |e| switch (e) {
        error.GrammarDirNotFound => &.{},
        else => return e,
    };
}

/// Last path segment; posix separator only (targets are CLI paths).
fn fileBasename(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
}

/// Default grammar set for a single target file: all grammars from
/// .lasp/grammars whose extensions suffix-match the target's basename.
/// Empty for stdin ("-", no basename; the default dir is not loaded) and for
/// an absent default dir.
pub fn resolveDefaultGrammars(io: std.Io, allocator: std.mem.Allocator, target_path: []const u8) ![]LoadedGrammar {
    if (std.mem.eql(u8, target_path, "-")) return &.{};
    const loaded = try loadDefaultGrammars(io, allocator);
    const base = fileBasename(target_path);
    var matches: std.ArrayList(LoadedGrammar) = .empty;
    for (loaded) |lg| {
        if (grammarMatches(lg.grammar, base)) try matches.append(allocator, lg);
    }
    return try matches.toOwnedSlice(allocator);
}

test "grammarMatches: no extensions never match, otherwise any suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pattern = "[[patterns]]\ntype = \"call\"\nsequence = [\"$callee:IDENTIFIER\", \"(\"]\n";
    const none = try grammar_loader.parseGrammar(pattern, a);
    try std.testing.expect(!grammarMatches(none, "foo.erl"));
    const some = try grammar_loader.parseGrammar("[language]\nextensions = [\".erl\", \"cxx\"]\n" ++ pattern, a);
    try std.testing.expect(grammarMatches(some, "foo.erl"));
    try std.testing.expect(grammarMatches(some, "file.cxx"));
    try std.testing.expect(!grammarMatches(some, "foo.py"));
}
