// swift-tools-version: 6.0
import PackageDescription

// libharf.a comes from `zig build` at the repo root. macos/build-app.sh passes
// -Xlinker -L<repo>/zig-out/lib, so no unsafeFlags are needed here.
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
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
    ]
)
