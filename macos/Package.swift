// swift-tools-version: 6.0
import PackageDescription

// libharf.a comes from `zig build` at the repo root. macos/build-app.sh passes
// -Xlinker -L<repo>/zig-out/lib, so no unsafeFlags are needed here.
// A static lib cannot carry its framework dependencies, so the frameworks the Zig core
// uses (CoreText, CoreGraphics, CoreFoundation) are linked here too.
let package = Package(
    name: "Harf",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CHarf", path: "CHarf"),
        .executableTarget(
            name: "Harf",
            dependencies: ["CHarf"],
            path: "Sources/Harf",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("ImageIO"),
                // libharf.a does not carry libghostty-vt; zig build installs it next to libharf.a.
                .linkedLibrary("ghostty-vt-static"),
            ]
        ),
    ]
)
