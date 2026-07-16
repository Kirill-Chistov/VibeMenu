// swift-tools-version: 6.0
import PackageDescription

// VibeMenu — lightweight, local-first macOS menu-bar utility that keeps the Mac
// awake while a local AI coding agent is genuinely working, and releases sleep
// prevention when the agent goes idle.
//
// v0.0 scope: a buildable Swift package skeleton (pure, testable core + a
// compile-only menu-bar app shell). No real monitoring, power assertions, or
// thermal reads are implemented yet — see docs/decisions/0005-v0-1-scope.md.
//
// The launchable `.app` bundle wrapper (Info.plist with LSUIElement = true,
// Developer-ID signing/notarization) is intentionally NOT part of this package;
// it is the documented next step via an Xcode app target. See README.md.
let package = Package(
    name: "VibeMenu",
    platforms: [
        // macOS 15+ baseline, Apple Silicon first. See docs/decisions/0002-macos-baseline.md.
        .macOS(.v15)
    ],
    products: [
        .library(name: "VibeMenuCore", targets: ["VibeMenuCore"]),
        .executable(name: "VibeMenuApp", targets: ["VibeMenuApp"])
    ],
    targets: [
        // Vendored, decompression-only Zstandard (BSD-3-Clause). macOS has no system zstd and
        // Apple's Compression framework can't decode it, so this lets VibeMenuCore read the
        // zstd-compressed Claude Desktop usage cache locally — no network, no shelling out, no
        // Homebrew. See Sources/CZstd/README.md and docs/decisions/0016-claude-usage-limits.md.
        .target(
            name: "CZstd"
        ),
        // Pure, I/O-free decision logic + lightweight state models. Fully testable.
        .target(
            name: "VibeMenuCore",
            dependencies: ["CZstd"]
        ),
        // SwiftUI menu-bar shell. Compiles from the command line; not yet a
        // launchable/notarized .app (that is the Xcode-wrapper next step).
        .executableTarget(
            name: "VibeMenuApp",
            dependencies: ["VibeMenuCore"]
        ),
        .testTarget(
            name: "VibeMenuCoreTests",
            dependencies: ["VibeMenuCore"]
        )
    ]
)
