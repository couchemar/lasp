const std = @import("std");
const grammar_loader = @import("../grammar/loader.zig");
const grammar_compiler = @import("../grammar/compiler.zig");
const diagnostics = @import("diagnostics.zig");
const fatalError = diagnostics.fatalError;
const grammarErrorMessage = diagnostics.grammarErrorMessage;
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
        const grammar_source = readSourceFile(io, allocator, path) catch {
            fatalError("failed to read grammar file: {s}", .{path});
        };
        const grammar = grammar_loader.parseGrammar(grammar_source, allocator) catch |err| {
            const msg: []const u8 = grammarErrorMessage(err);
            fatalError("{s}: {s}", .{ msg, path });
        };
        try loaded.append(allocator, .{
            .name = name,
            .grammar = grammar,
            .automaton = try grammar_compiler.compile(grammar.patterns, allocator),
        });
    }
    return try loaded.toOwnedSlice(allocator);
}

/// Last path segment; posix separator only (targets are CLI paths).
fn fileBasename(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
}

/// Default grammar set for a single target file: all grammars from
/// .lasp/grammars whose extensions suffix-match the target's basename.
/// null when target is "-" (stdin, no basename) or the default dir is absent.
pub fn resolveDefaultGrammars(io: std.Io, allocator: std.mem.Allocator, target_path: []const u8) !?[]LoadedGrammar {
    if (std.mem.eql(u8, target_path, "-")) return null;
    const loaded = loadGrammarsFromDir(io, allocator, default_grammar_dir) catch |e| switch (e) {
        error.GrammarDirNotFound => return null,
        else => return e,
    };
    var matches: std.ArrayList(LoadedGrammar) = .empty;
    for (loaded) |lg| {
        if (lg.grammar.extensions.len == 0) continue;
        const base = fileBasename(target_path);
        for (lg.grammar.extensions) |ext| {
            if (basenameMatchesExtension(base, ext)) {
                try matches.append(allocator, lg);
                break;
            }
        }
    }
    return try matches.toOwnedSlice(allocator);
}
