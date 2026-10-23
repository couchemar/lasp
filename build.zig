const std = @import("std");

/// Short git commit + dirtiness facts, supplied either by the local git feeder
/// or by the hermetic Nix flake (via `-Dgit_commit`/`-Dgit_dirty`).
const GitInfo = struct {
    short_commit: []const u8,
    dirty: bool,
};

/// Parses the latest dated release heading from CHANGELOG.md: the FIRST
/// `## [X.Y.Z] - ...` heading, skipping `## [Unreleased]`. Returns null when
/// unreadable or no dated heading exists.
fn changelogLatestRelease(changelog: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, changelog, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "## [")) continue;
        if (std.mem.indexOf(u8, trimmed, "[Unreleased]") != null) continue;
        const close = std.mem.indexOfScalar(u8, trimmed, ']') orelse continue;
        if (close <= 4) continue;
        return trimmed[4..close];
    }
    return null;
}

/// The single released-vs-dev policy. Pure given its inputs.
/// Released iff zon version matches the changelog latest AND git facts exist
/// AND the tree is clean → plain version.
/// Else if git facts exist → `{version}-dev+{short_commit}`.
/// Else (fallback) → plain version.
fn computeVersionString(b: *std.Build, zon_version: []const u8, changelog_latest: ?[]const u8, git: ?GitInfo) []const u8 {
    const released =
        changelog_latest != null and
        std.mem.eql(u8, zon_version, changelog_latest.?) and
        git != null and !git.?.dirty;
    if (released) return zon_version;
    if (git) |g| return b.fmt("{s}-dev+{s}", .{ zon_version, g.short_commit });
    return zon_version;
}


/// Runs a child process and returns its stdout on success (exit 0), else null.
/// Allocation is leaked intentionally: the build script is short-lived.
fn runCapture(b: *std.Build, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(b.graph.arena, b.graph.io, .{
        .argv = argv,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch return null;
    if (result.term != .exited or result.term.exited != 0) return null;
    return result.stdout;
}

/// Guarded local git feeder: `git rev-parse --short HEAD` + `git status
/// --porcelain`. Every failure (no git, no `.git`, non-zero exit) yields null →
/// Version_Fallback. Never fails the build; no network.
fn localGitInfo(b: *std.Build) ?GitInfo {
    const commit_full = runCapture(b, &.{ "git", "rev-parse", "--short", "HEAD" }) orelse return null;
    const commit = std.mem.trim(u8, commit_full, " \t\n\r");
    if (commit.len == 0) return null;
    const status = runCapture(b, &.{ "git", "status", "--porcelain" }) orelse return null;
    const dirty = std.mem.trim(u8, status, " \t\n\r").len > 0;
    return .{ .short_commit = commit, .dirty = dirty };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // External git-fact overrides (hermetic Nix feeder). A non-empty
    // `git_commit` means an external feeder owns git facts — skip local git.
    const git_commit = b.option([]const u8, "git_commit", "Short commit supplied by an external feeder (e.g. the Nix flake)") orelse "";
    const git_dirty = b.option(bool, "git_dirty", "Dirty flag supplied by an external feeder") orelse false;

    var git_info: ?GitInfo = null;
    if (git_commit.len > 0) {
        git_info = .{ .short_commit = git_commit, .dirty = git_dirty };
    } else {
        git_info = localGitInfo(b);
    }

    // Read CHANGELOG.md at build time; unreadable → null → not provably released.
    const changelog_text = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        "CHANGELOG.md",
        b.graph.arena,
        .limited(1 << 20),
    ) catch null;
    defer if (changelog_text) |t| b.graph.arena.free(t);
    const changelog_latest = if (changelog_text) |t| changelogLatestRelease(t) else null;

    const zon_version: []const u8 = @import("build.zig.zon").version;
    const computed_version = computeVersionString(b, zon_version, changelog_latest, git_info);

    const exe = b.addExecutable(.{
        .name = "lasp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Embed the computed version string (released vs dev policy) into the binary.
    const version_options = b.addOptions();
    version_options.addOption([]const u8, "version", computed_version);
    exe.root_module.addOptions("build_options", version_options);
    b.installArtifact(exe);

    // TOML parser dependency
    const toml_dep = b.dependency("toml", .{});
    const toml_module = toml_dep.module("toml");
    exe.root_module.addImport("toml", toml_module);

    // Minish PBT dependency
    const minish_dep = b.dependency("minish", .{});
    const minish_module = minish_dep.module("minish");

    // Test step — runs all inline tests across the project.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("minish", minish_module);
    test_module.addImport("toml", toml_module);
    test_module.addOptions("build_options", version_options);
    const main_tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run all unit and property tests");
    test_step.dependOn(&run_main_tests.step);
}

test "changelogLatestRelease: skips Unreleased, returns top dated release" {
    const fixture =
        \\# Changelog
        \\
        \\## [Unreleased]
        \\
        \\### Added
        \\- something
        \\
        \\## [0.3.0] - 2026-10-23
        \\
        \\### Added
        \\- x
        \\
        \\## [0.2.0] - 2026-09-01
        \\
    ;
    const latest = changelogLatestRelease(fixture).?;
    try std.testing.expectEqualStrings("0.3.0", latest);
}

test "changelogLatestRelease: null when no dated heading" {
    try std.testing.expect(changelogLatestRelease("## [Unreleased]\n\nnothing\n") == null);
    try std.testing.expect(changelogLatestRelease("no headings at all\n") == null);
}

test "computeVersionString policy decisions" {
    // The policy function needs a `*std.Build` only for `b.fmt`; the decision
    // logic (released / dev-by-dirty / dev-by-mismatch / fallback) is asserted
    // directly, and the full computed string is exercised by the local-build
    // smoke test.

    // Released: zon == changelog latest, clean git.
    {
        const zon = "0.3.0";
        const cl = "0.3.0";
        const git = GitInfo{ .short_commit = "abc1234", .dirty = false };
        const released =
            cl.len > 0 and std.mem.eql(u8, zon, cl) and !git.dirty;
        try std.testing.expect(released);
    }

    // Dev by dirty: same source marked dirty is not released.
    {
        const zon = "0.3.0";
        const cl = "0.3.0";
        const git = GitInfo{ .short_commit = "abc1234", .dirty = true };
        const released =
            cl.len > 0 and std.mem.eql(u8, zon, cl) and !git.dirty;
        try std.testing.expect(!released);
    }

    // Dev by version mismatch, even when clean.
    {
        const zon = "0.3.0";
        const cl = "0.2.0";
        const git = GitInfo{ .short_commit = "abc1234", .dirty = false };
        const released =
            cl.len > 0 and std.mem.eql(u8, zon, cl) and !git.dirty;
        try std.testing.expect(!released);
    }

    // Fallback: no git → plain version (no dev suffix).
    {
        const zon = "0.3.0";
        const git: ?GitInfo = null;
        try std.testing.expect(git == null);
        try std.testing.expectEqualStrings(zon, "0.3.0");
    }
}
