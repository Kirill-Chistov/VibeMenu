# CLAUDE.md — Claude Code workflow

Operational notes for Claude Code in this repo. **Read [`AGENTS.md`](AGENTS.md) first** —
it is the universal contract and its rules bind you. This file adds Claude-specific
workflow on top.

## Source of truth

`AGENTS.md` is authoritative. If this file and `AGENTS.md` ever differ, follow
`AGENTS.md` and update this file rather than inventing a conflicting rule. The human
product owner makes product, architecture, privacy, and release decisions.

## Before you start

- **Read `AGENTS.md`.** All of its rules apply, especially the hard privacy/network
  invariants and "the human owns product decisions."
- **Follow the spec and the docs.** [`PRODUCT.md`](docs/PRODUCT.md),
  [`ARCHITECTURE.md`](docs/ARCHITECTURE.md), and the [`docs/decisions/`](docs/decisions/) ADRs are the
  source of truth. Don't contradict them without a new ADR.

## How to work

- **Keep tasks small.** One logical change at a time; small, reversible diffs.
- **Propose before non-trivial product/architecture work.** For anything touching power
  assertions, automation policy, Claude hook/heartbeat behavior, privacy/security, app
  lifecycle/background monitoring, settings/onboarding, release/distribution, or new
  user-visible features, first produce a proposal with options and tradeoffs, then wait
  for product approval before implementing. Use this exact format:
  ```md
  ## Problem
  ## Constraints
  ## Options
  ## Recommendation
  ## Risks
  ## Testing plan
  ## Waiting for product approval
  ```
  You may still implement small fixes directly: typo/comment cleanup, tests for an
  already-approved behavior, or an obvious bugfix with no product tradeoff.
- **Use `TODO`s, don't implement the future.** For anything beyond the current task's
  scope (clamshell, unattended-run guardrails, additional agents), leave a clear `TODO` and
  a protocol/stub rather than building it now.
- **Prefer testable core logic.** Put real decision logic in `VibeMenuCore` as pure,
  I/O-free code with unit tests. Keep side effects (UI, IOKit, files) in thin adapters in
  `VibeMenuApp` or behind protocols.
- **Ask before adding dependencies.** Default to system frameworks; if you think a
  dependency is warranted, propose it with an ADR and wait for approval.

## After code changes

- **Run the relevant build/test commands and paste the real output:**
  ```sh
  swift build
  scripts/test.sh      # wrapper around `swift test`; see CONTRIBUTING.md
  # When you touch the app wrapper, also build the .app target:
  xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug build
  ```
- **Report assumptions and unverified behavior.** State clearly what you verified and what
  you did not (e.g. "the app compiles but was not launched; menu-bar/`LSUIElement`
  behavior is unverified"). Never fake results.
- **Summarize changed files** (path + one line each) and **flag uncertainty**, especially
  anything version-fragile or untested on this hardware.
- **Update `docs/DEVELOPMENT_LOG.md`** (AGENTS.md §19): append a short entry with the commands
  run, validation results, errors/fixes, verified vs. unverified behavior, and next step.

## Claude Code handoff checklist

Before handing work back:

1. Confirm the diff is limited to the requested logical change.
2. Check that no transcript content, network call, telemetry, or unapproved dependency was
   introduced.
3. Run the relevant real checks and include their actual output.
4. State macOS API assumptions, hardware/OS uncertainty, and anything not tested.
5. List every changed file with a one-line explanation.

## Environment notes

- `scripts/test.sh` works under both toolchains: it adds the `Testing.framework` search
  paths when only the **Command Line Tools** are installed, and just runs `swift test`
  under **full Xcode**. Prefer it over plain `swift test`. See
  [`CONTRIBUTING.md`](CONTRIBUTING.md).
- A launchable menu-bar `.app` exists: `App/VibeMenu.xcodeproj` (target `VibeMenu`,
  `LSUIElement = true`). It wraps the package's `VibeMenuApp` shell and links
  `VibeMenuCore`; see [`docs/decisions/0007-app-wrapper-structure.md`](docs/decisions/0007-app-wrapper-structure.md).
  App and menu-bar icons are in place (`App/Assets.xcassets`). Builds are **unsigned and not
  notarized**, and stay that way for the current validation phase — signing is a declined cost
  for now rather than a pending task, and is revisitable if adoption justifies it
  ([`docs/ROADMAP.md`](docs/ROADMAP.md)). Only claim the app runs when you have actually built
  and launched it.

## When to bring in a second model

For risky changes (`AutomationPolicy`, IOKit adapters, a future privileged helper, the
no-network invariant), get an independent review from a **different** model (e.g. Codex)
before the human approves. The implementer and reviewer must differ.
