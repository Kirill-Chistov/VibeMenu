# 0006 — Hard lightweight resource budget

- **Status:** Accepted
- **Date:** 2026-07-02
- **Deciders:** Kirill Chistov (product owner).

## Context

VibeMenu's whole promise is *not* being the blunt, always-on, battery-cooking keep-awake
tool. It must be lightweight *by design*, or it undercuts its own reason to exist. The
target user is privacy- and resource-sensitive. This budget is a first-class product
constraint, not an optimization to do "later".

## Decision

VibeMenu commits to a hard lightweight resource budget:

- **Idle CPU should be effectively zero.** When no agent is working, VibeMenu is
  essentially dormant.
- **Active overhead must be negligible.** Watching an agent and holding an assertion costs
  almost nothing.
- **No aggressive polling.** Prefer event-driven observation (thermal-state
  notifications, FSEvents / `DispatchSource` file watching, process lifecycle) over timer
  loops. Where a small timer is unavoidable, it must be coarse and justified.
- **No local database** unless a concrete need is justified later in its own ADR.
- **No transcript copying.** Session files are read as metadata (mtime/append) only, never
  copied or parsed for content.
- **No network.** (Except a possible future Sparkle update check — see
  [`0004-direct-distribution.md`](0004-direct-distribution.md).)
- **No resource-heavy monitoring dashboard.** Just enough status to drive and explain the
  automation; no high-frequency sensor scraping, no long time-series buffers.

## Consequences

- Architecture choices favor notifications and OS events over polling loops
  (see [`../ARCHITECTURE.md`](../ARCHITECTURE.md)). `AgentMonitor` is specified as
  event-driven; a busy `while`-loop poller would violate this ADR.
- State models are kept small (e.g. `SystemSnapshot` holds a single moment, no history).
- Any feature that would introduce a database, a heavy dashboard, continuous high-rate
  sampling, or a busy loop is out of budget and needs an explicit ADR justifying the cost.
- Reviewers should treat "does this add idle CPU or memory growth?" as a standing review
  question.

## Alternatives considered

- **Treat performance as a later optimization.** Rejected: lightness *is* the
  differentiator here; regressing it would defeat the product's purpose.
- **Allow a small local DB for history/telemetry-style features.** Rejected for v0.1: no
  such feature is in scope, and it would invite scope creep and privacy surface.
