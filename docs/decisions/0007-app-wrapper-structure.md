# 0007 — macOS `.app` wrapper project structure

- **Status:** Accepted
- **Date:** 2026-07-02
- **Deciders:** Kirill Chistov (product owner); implemented by Claude Code.

## Context

Through v0.0 the repo was a pure Swift Package: `VibeMenuApp` compiled as a command-line
executable but there was no launchable `.app`, so `LSUIElement`, the menu-bar item, and
quit behavior were all unverified (see [`../ROADMAP.md`](../ROADMAP.md) v0.1 and
[`0005-v0-1-scope.md`](0005-v0-1-scope.md)). SwiftPM alone cannot produce a signed,
`Info.plist`-bearing macOS app bundle; that needs an Xcode app target.

Full Xcode is now installed, so we can add the wrapper. The constraint: do it with the
**minimum** additional structure, without duplicating the tested core and without
disturbing the existing `swift build` / `scripts/test.sh` flow.

## Decision

Add a minimal Xcode project that **wraps**, rather than replaces, the Swift package:

- The project lives at **`App/VibeMenu.xcodeproj`**. App-bundle-only files (`Info.plist`)
  live beside it under `App/`.
- It references the **root Swift package** as a local package
  (`XCLocalSwiftPackageReference`, `relativePath = ..`) and the app target links only the
  **`VibeMenuCore`** product. The core is never recompiled or copied into the app target,
  so it stays the single, testable source of the decision logic
  ([`../ARCHITECTURE.md`](../ARCHITECTURE.md)).
- The app target compiles the **existing shell source**
  `Sources/VibeMenuApp/VibeMenuApp.swift` directly (a file reference, not a copy). That
  file remains the one source of truth for the menu-bar UI: `swift build` still builds it
  as the package's `VibeMenuApp` executable, and Xcode builds it into the launchable
  `.app`.
- Key settings: target name `VibeMenu`, bundle id `com.kirillchistov.VibeMenu`,
  `MACOSX_DEPLOYMENT_TARGET = 15.0`, `SWIFT_VERSION = 6.0`, `LSUIElement = true`, and
  ad-hoc "Sign to Run Locally" (`CODE_SIGN_IDENTITY = -`). No app icon, Developer-ID
  signing, or notarization yet — those are deferred (ROADMAP v0.2).

## Consequences

- One source of truth for both the core and the UI shell; no duplicated logic to drift.
- Two build entry points, by design: `swift build` / `scripts/test.sh` for fast,
  Xcode-free core iteration and CI, and `xcodebuild -project App/VibeMenu.xcodeproj` for
  the launchable app. The same `VibeMenuApp.swift` is a member of both the SPM executable
  target and the Xcode app target — intended, not a mistake.
- The `project.pbxproj` is hand-authored and minimal; it must be edited carefully (no
  `xcodegen`/generator dependency was added, per the no-dependencies rule).
- When app-only bundle needs grow (icon, entitlements, signing), they attach to this
  target without touching `VibeMenuCore`.

## Alternatives considered

- **Move the app shell into the Xcode target and drop the SPM `VibeMenuApp` executable.**
  Rejected: it would stop `swift build` from exercising the shell and give up the
  Xcode-free build path.
- **Make `VibeMenuApp` a package library the app links, with `@main` in the library.**
  Rejected: `@main` belongs to the app's own module; hoisting the SwiftUI `App` entry
  point into a linked library is fragile for little gain over sharing one file.
- **Recompile `VibeMenuCore` sources inside the app target.** Rejected: duplicates the
  core and breaks the "core is separate and testable" rule.
- **Generate the project with `xcodegen`/Tuist.** Rejected for now: adds a tool
  dependency ([`0004-direct-distribution.md`](0004-direct-distribution.md) / AGENTS.md
  §5) the single hand-authored project does not justify.
