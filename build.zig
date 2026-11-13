const std = @import("std");

pub fn build(b: *std.Build) void {
    // Apple Silicon, macOS 14+ (matches macos/Package.swift). Overridable with -Dtarget.
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .aarch64,
            .os_tag = .macos,
            .os_version_min = .{ .semver = .{ .major = 14, .minor = 0, .patch = 0 } },
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    // The core's root is the C ABI file; modules it @imports are compiled in.
    const core = b.createModule(.{
        .root_source_file = b.path("src/capi.zig"),
        .target = target,
        .optimize = optimize,
    });

    // An explicit target (needed for os_version_min) disables Zig's automatic macOS SDK
    // detection, so ask xcrun for the SDK ourselves.
    if (target.result.os.tag == .macos) {
        if (std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result)) |sdk| {
            core.addSystemFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
            // The frameworks' .tbd files depend on /usr/lib/libobjc etc.; resolve them in the SDK.
            core.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
        }
    }

    // A static lib cannot carry these; macos/Package.swift links them into the app.
    // They are declared here so the Zig tests link too.
    core.linkFramework("CoreText", .{});
    core.linkFramework("CoreGraphics", .{});
    core.linkFramework("CoreFoundation", .{});

    // libghostty-vt (VT parser + grid), reached through its C API only. translate-c turns the
    // header into the `ghostty_c` module; simd=false keeps it free of C++ dependencies.
    // Built optimized even in a Debug build: a Debug libghostty parses about 100x slower, which
    // makes flood tests and day-to-day runs unusable. ReleaseSafe keeps its safety checks.
    const ghostty_optimize: std.builtin.OptimizeMode = if (optimize == .debug) .safe else optimize;
    const ghostty = b.dependency("ghostty", .{ .target = target, .optimize = ghostty_optimize, .simd = false });
    const tc = b.addTranslateC(.{ .root_source_file = b.path("src/vt_c.h"), .target = target, .optimize = optimize });
    tc.defineCMacro("GHOSTTY_STATIC", null);
    tc.addIncludePath(ghostty.path("include"));
    core.addImport("ghostty_c", tc.createModule());
    core.linkLibrary(ghostty.artifact("ghostty-vt-static"));
    b.installArtifact(ghostty.artifact("ghostty-vt-static"));

    // zig-out/lib/libharf.a. The C header is hand-written: include/harf.h.
    const lib = b.addLibrary(.{
        .name = "harf",
        .linkage = .static,
        .root_module = core,
    });
    b.installArtifact(lib);

    const test_filter = b.option([]const u8, "test-filter", "Run only tests whose name contains this text");
    const tests = b.addTest(.{ .root_module = core, .filters = if (test_filter) |f| &.{f} else &.{} });
    const run_tests = b.addRunArtifact(tests);
    // The bidi conformance suites read pinned Unicode data from test/ucd; this downloads it
    // on first use and re-checks the SHA-256 on every run (a no-op once present).
    const fetch_ucd = b.addSystemCommand(&.{ "sh", "test/fetch-ucd.sh" });
    run_tests.step.dependOn(&fetch_ucd.step);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
