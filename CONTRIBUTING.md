# Contributing to VibeMenu

VibeMenu is a small, focused, local-first macOS utility. Contributions should keep it
that way. Read [`AGENTS.md`](AGENTS.md) (rules for automated agents, but the norms apply
to humans too) and [`ARCHITECTURE.md`](docs/ARCHITECTURE.md) before starting.

## Requirements

- macOS 15+ on Apple Silicon.
- A Swift 6 toolchain (full Xcode **or** the standalone Command Line Tools — see the note
  under "Testing").

## Build & test

```sh
# Build the package: VibeMenuCore (library) + VibeMenuApp (compile-only shell)
swift build

# Run the unit tests
scripts/test.sh
```

### Testing: why `scripts/test.sh`?

The tests use **Swift Testing** (`import Testing`). Swift Testing ships with both full
Xcode and the standalone Command Line Tools, but when only the Command Line Tools are
installed, SPM does not automatically add the `Testing.framework` / interop-dylib search
paths, so plain `swift test` fails to build/load the tests. `scripts/test.sh`:

- detects whether you are on Command Line Tools vs full Xcode, and
- on Command Line Tools, passes the `-F` / `-rpath` flags for
  `.../Library/Developer/Frameworks` and `.../Library/Developer/usr/lib`;
- with full Xcode, it just runs `swift test`.

You can always run plain `swift test` if your toolchain already resolves Swift Testing.

## Norms

- **Small, focused diffs.** One logical change per PR. Prefer additive, reversible
  changes; no broad rewrites without prior approval.
- **Build the shape, not the future.** Use `TODO`s and protocols/stubs for deferred
  behavior (clamshell, unattended-run guardrails). Don't overbuild.
- **Keep the core pure.** Put decision logic in `VibeMenuCore` as pure, I/O-free,
  unit-tested code. Keep side effects (UI, IOKit, files) in thin adapters or behind
  protocols. Never let private-API/root/clamshell code into `VibeMenuCore`.
- **Respect the invariants.** No transcript-content reading, no telemetry/analytics, no
  network, no new third-party dependency without justification. See
  [`PRIVACY.md`](docs/PRIVACY.md) and [`SECURITY.md`](docs/SECURITY.md). These are the
  product, not red tape — a PR that weakens one needs an ADR and the owner's approval,
  however good the feature is.
- **Verify, don't assume.** Run `swift build` and `scripts/test.sh` for relevant changes
  and paste the real output. Never claim a build/test/launch result you didn't produce.

## Dependency-justification rule

Default to system frameworks. Any new third-party dependency must be proposed in the PR
**with a justification and a `docs/decisions/` ADR**, and approved by the human owner before it
lands. VibeMenu currently has **no package dependencies** — the only third-party code is a
vendored zstd decoder ([`Sources/CZstd/`](Sources/CZstd/)), needed to read Claude Desktop's
compressed local cache. Keep it that way unless there's a compelling reason not to.

## Adding a decision record (ADR)

Non-trivial design or product choices are recorded as ADRs in [`docs/decisions/`](docs/decisions/):

1. Copy the style of an existing ADR (e.g.
   [`0005-v0-1-scope.md`](docs/decisions/0005-v0-1-scope.md)).
2. Name it `NNNN-short-slug.md` with the next number.
3. Include: **Status**, **Context**, **Decision**, **Consequences**, and who decided.
4. Reference it from the relevant doc/code and link related ADRs.

## Code style

- Swift 6 with strict concurrency. SwiftUI-first; AppKit only where needed.
- Match the surrounding code's naming, comment density, and idiom.
- Document non-obvious macOS API assumptions inline (public vs private? root/entitlements?
  sandbox? chip/OS variance?).
- Formatting/linting (SwiftFormat/SwiftLint) may be added later; until then keep style
  consistent with existing files.
