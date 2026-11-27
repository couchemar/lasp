const std = @import("std");
pub const cli = @import("cli/args.zig");
pub const tokenizer = @import("parser/tokenizer.zig");
pub const json = @import("output/json.zig");
pub const grammar_loader = @import("grammar/loader.zig");
pub const grammar_compiler = @import("grammar/compiler.zig");
pub const events = @import("parser/events.zig");
pub const engine = @import("parser/engine.zig");
pub const resemblance = @import("parser/resemblance.zig");
pub const query_filter = @import("query/filter.zig");
pub const query_parser = @import("query/parser.zig");
pub const query_evaluator = @import("query/evaluator.zig");
const build_options = @import("build_options");
pub const diagnostics = @import("cli/diagnostics.zig");
const reportError = diagnostics.reportError;
const fatalError = diagnostics.fatalError;
pub const source_reader = @import("cli/source.zig");
pub const grammar_set = @import("cli/grammar_set.zig");
pub const pipeline = @import("cli/pipeline.zig");
pub const output = @import("cli/output.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // 1. Set up arena allocator
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 2. Collect CLI args (skip binary name)
    var arg_list: std.ArrayList([]const u8) = .empty;
    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip binary name
    while (args_iter.next()) |arg| {
        try arg_list.append(allocator, arg);
    }

    // 3. Parse CLI args
    const parsed = cli.parseArgs(arg_list.items) catch |err| {
        fatalError("{s}", .{cli.formatCliError(err)});
    };

    // 4. Stdout setup
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    run(io, allocator, parsed, stdout) catch |err| switch (err) {
        error.WriteFailed => {
            // A broken pipe (downstream reader closed early) is a normal,
            // expected event in shell pipelines: exit quietly and successfully.
            // Any other write failure (or an unknown cause) stays fatal.
            if (shouldCleanExitOnWriteFailed(stdout_writer.err)) return;
            fatalError("{s}", .{@errorName(err)});
        },
        else => return err,
    };
}

/// True only when a stdout write failure's concrete cause is a broken pipe
/// (EPIPE). Unknown cause (null) or any other error → false, so those stay
/// fatal. Broken-pipe write failures are a normal, expected shell-pipeline
/// event and become a clean exit.
fn shouldCleanExitOnWriteFailed(cause: ?std.Io.File.Writer.Error) bool {
    return if (cause) |c| c == error.BrokenPipe else false;
}

// Property 1 (classifier): the one decision the fix adds.
// Broken pipe → clean exit; any other concrete cause or unknown (null) → fatal.
test "broken pipe classifier: BrokenPipe cleans, others stay fatal" {
    try std.testing.expect(shouldCleanExitOnWriteFailed(error.BrokenPipe));
    try std.testing.expect(!shouldCleanExitOnWriteFailed(error.NoSpaceLeft));
    try std.testing.expect(!shouldCleanExitOnWriteFailed(error.InputOutput));
    try std.testing.expect(!shouldCleanExitOnWriteFailed(null));
}

/// Everything after stdout setup: help/version early returns, source read,
/// command dispatch, trailing newline, and final flush — verbatim from the
/// original `main` body so non-broken-pipe behavior is byte-identical.
fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    parsed: cli.ParsedArgs,
    stdout: *std.Io.Writer,
) !void {

    // 4.5 Help report: exits before version and before any file I/O (Req 3, 6).
    if (parsed.command == .help) {
        try stdout.writeAll(cli.helpText(parsed.help_topic));
        try stdout.flush();
        return;
    }

    // 5. Version report: exits before any file I/O
    if (parsed.command == .version) {
        try stdout.print("lasp {s}\n", .{build_options.version});
        try stdout.flush();
        return;
    }

    // 7. Dispatch based on command (source reads live inside the arms that
    // need them: query and single-file parse; parse-dir never reads its target
    // path as a file).
    switch (parsed.command) {
        .query => try runQuery(io, allocator, parsed, stdout),
        .parse => try runParse(io, allocator, parsed, stdout),
        .parse_dir => try runParseDir(io, allocator, parsed, stdout),
        .version => unreachable,
        .help => unreachable,
    }
    try stdout.flush();
}

fn runQuery(io: std.Io, allocator: std.mem.Allocator, parsed: cli.ParsedArgs, stdout: *std.Io.Writer) !void {
    const inputs = try pipeline.loadInputs(io, allocator, parsed, .require_grammar);
    const filter = pipeline.parseSelectorOrFatal(allocator, parsed.query_selector);
    const framing = output.framingOf(parsed);
    pipeline.rejectNamesOnlyMulti(framing, inputs.grammars.len);
    var results: std.ArrayList(json.DirResult) = .empty;
    for (inputs.grammars) |lg| {
        const structural_events = try pipeline.parseEvents(allocator, lg, inputs.source, null, false, false);
        try results.append(allocator, .{
            .file = parsed.target_path,
            .grammar = lg.name,
            .events = try query_evaluator.evaluate(structural_events, filter, allocator),
        });
    }
    try output.write(stdout, output.forGrammars(results.items, false), framing);
}

fn runParse(io: std.Io, allocator: std.mem.Allocator, parsed: cli.ParsedArgs, stdout: *std.Io.Writer) !void {
    const inputs = try pipeline.loadInputs(io, allocator, parsed, .raw_tokens_if_none);
    const framing = output.framingOf(parsed);
    pipeline.rejectNamesOnlyMulti(framing, inputs.grammars.len);
    if (inputs.grammars.len == 0) {
        // No grammar applies: raw token output.
        const tokens = try tokenizer.tokenize(inputs.source, null, .{}, allocator);
        return output.write(stdout, .{ .tokens = tokens }, framing);
    }
    var results: std.ArrayList(json.DirResult) = .empty;
    for (inputs.grammars) |lg| {
        try results.append(allocator, .{
            .file = parsed.target_path,
            .grammar = lg.name,
            .events = try pipeline.parseEvents(allocator, lg, inputs.source, parsed.node_filter, parsed.alternatives, parsed.resemble),
        });
    }
    try output.write(stdout, output.forGrammars(results.items, parsed.alternatives or parsed.resemble), framing);
}

fn runParseDir(io: std.Io, allocator: std.mem.Allocator, parsed: cli.ParsedArgs, stdout: *std.Io.Writer) !void {
    // Grammars compiled once and reused for every file each one matches.
    const loaded = try pipeline.loadDirGrammars(io, allocator, parsed.grammar_dir);
    // A non-directory or missing target is an error (Req 2.8).
    var root = std.Io.Dir.cwd().openDir(io, parsed.target_path, .{ .iterate = true }) catch {
        fatalError("directory not found: {s}", .{parsed.target_path});
    };
    defer root.close(io);
    var entries: std.ArrayList(json.DirResult) = .empty;
    var walker = root.walk(allocator) catch {
        fatalError("directory not found: {s}", .{parsed.target_path});
    };
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        for (loaded) |lg| {
            if (!grammar_set.grammarMatches(lg.grammar, entry.basename)) continue;
            // Walker paths are relative to the walked root; read through the
            // target path so cwd-relative and absolute targets both work.
            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parsed.target_path, entry.path });
            const source = source_reader.readFileOrFatal(io, allocator, full_path);
            const events_list = try pipeline.parseEvents(allocator, lg, source, parsed.node_filter, parsed.alternatives, parsed.resemble);
            // The walker reuses its path buffers on the next `next()` call,
            // so entries must own their strings.
            const file_copy = try allocator.dupe(u8, entry.path);
            try entries.append(allocator, .{
                .file = file_copy,
                .grammar = lg.name,
                .events = events_list,
            });
        }
    }
    try output.write(stdout, .{ .dir_results = .{ .entries = entries.items, .include_alternatives = parsed.alternatives or parsed.resemble } }, output.framingOf(parsed));
}

test {
    std.testing.refAllDecls(@This());
}

test {
    // Pull in tests from all modules.
    _ = cli;
    _ = tokenizer;
    _ = resemblance;
    _ = @import("grammar/toml_access.zig");
    _ = @import("main_test.zig");
}
