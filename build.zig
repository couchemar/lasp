const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "lasp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // Embed project version (single source of truth: build.zig.zon) into the binary.
    const version_options = b.addOptions();
    version_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    exe.root_module.addOptions("build_options", version_options);

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
