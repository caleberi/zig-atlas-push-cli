const std = @import("std");

const manifest_url = "https://downloads.mongodb.com/app-services-cli/versions/cloud-prod/MANIFEST";

fn packageVersion(b: *std.Build) []const u8 {
    const contents = @embedFile("package.toml");
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "version")) continue;
        var rest = std.mem.trim(u8, line["version".len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        rest = std.mem.trim(u8, rest[1..], " \t");
        if (rest.len < 2 or rest[0] != '"') continue;
        const end = std.mem.indexOfScalar(u8, rest[1..], '"') orelse continue;
        return b.dupe(rest[1 .. 1 + end]);
    }
    @panic("package.toml missing version");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const config = b.addOptions();
    config.addOption([]const u8, "manifest_url", manifest_url);
    config.addOption([]const u8, "package_version", packageVersion(b));

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_mod.addOptions("config", config);

    const exe = b.addExecutable(.{
        .name = "atlas-push-cli",
        .root_module = root_mod,
    });

    b.installArtifact(exe);
    b.installBinFile("package.toml", "package.toml");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Forward args to the downloaded appservices binary");
    run_step.dependOn(&run_cmd.step);

    const postinstall_cmd = b.addRunArtifact(exe);
    postinstall_cmd.addArg("--postinstall");
    postinstall_cmd.step.dependOn(b.getInstallStep());
    postinstall_cmd.setCwd(.{ .cwd_relative = b.getInstallPath(.bin, "") });
    const postinstall_step = b.step("postinstall", "Download and extract the appservices CLI");
    postinstall_step.dependOn(&postinstall_cmd.step);

    const test_install_cmd = b.addRunArtifact(exe);
    test_install_cmd.addArg("--test-install");
    test_install_cmd.step.dependOn(b.getInstallStep());
    const test_install_step = b.step("test-install", "Smoke-test the install flow");
    test_install_step.dependOn(&test_install_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addOptions("config", config);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
