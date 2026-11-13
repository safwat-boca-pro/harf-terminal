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

    // zig-out/lib/libharf.a. The C header is hand-written: include/harf.h.
    const lib = b.addLibrary(.{
        .name = "harf",
        .linkage = .static,
        .root_module = core,
    });
    b.installArtifact(lib);

    const tests = b.addTest(.{ .root_module = core });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
