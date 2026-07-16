# 0011 — Session Radar: per-session Claude state in the menu

- **Status:** Accepted — v0.2 minimal slice (Claude Code only)
- **Date:** 2026-07-05
- **Deciders:** Kirill Chistov (product owner); researched & implemented by Claude Code under the
  owner's explicit authorization to build the minimal safe version.
- **Builds on:** [`0008`](0008-claude-heartbeat-detection.md) (hook heartbeat),
  [`0010`](0010-quiet-work-hold.md) (quiet-work hold / `automationIntent`).

## Context

Product research (the "Evidence-Ranked Opportunity Map") found that the strongest,
best-evidenced pain for agent-heavy developers is **agent handoff blindness** — not knowing
which session is working, waiting, done, or stuck — especially across parallel sessions. The
current app collapses all Claude activity into **one** global status row (`Claude:
Active/Idle/Not detected`), which is right for the menu-bar icon and the keep-awake loop but
hides which session is in which state.

A survey of the competing tools (Vibe Island, Open Island, Ping Island, MioIsland/CodeIsland,
Vibe Notch, AgentNotch, and the keep-awake reference Adrafinil) shows the category has
converged on **hook-based detection + a per-session list + in-UI approval + terminal jump**,
almost always in the **notch**. Two findings shaped this decision:

1. **Menu-bar-first is a real differentiator.** Every notch tool is hardware-gated (no notch,
   Intel, external displays) and several have explicit user requests to move to the menu bar
   (e.g. Vibe Notch issue #58). VibeMenu already lives in the menu bar and reaches every Mac.
2. **The fragile machinery is what breaks.** The most-cited competitor complaints are flaky
   detection and multi-display bugs, largely from `ps`/`lsof` process scanning and
   AppleScript/Accessibility probing (Open Island's disk-I/O, memory, and crash issues; Ping
   Island's multi-monitor bugs). VibeMenu's **hooks + own heartbeat files, metadata only**
   avoids that entire class.

The enabling fact: the per-session machinery **already exists** internally
(`latestRecordPerSession`, the per-session iteration in `automationIntent`, and the
`{schemaVersion, updatedAt, event, sessionID}` heartbeat files). Exposing it is the seam.

### Hook capability research (honestly qualified)

- **Reliable today** (already captured): `SessionStart`, `UserPromptSubmit`, `PreToolUse`,
  `PostToolUse`, `SubagentStart`, `SubagentStop`, `Stop`, `SessionEnd`. These cleanly yield
  **working / waiting / done**.
- **`Notification`** can (per docs) carry a `notification_type` distinguishing
  `permission_prompt` from `idle_prompt`, **but two independent sources confirm it is
  unreliable** ("often doesn't fire"). VibeMenu records the event, not the subtype.
- **Programmatic Allow/Deny** (a permission-decision hook) is reported by one source, not
  corroborated by the other, and would need a blocking socket round-trip. **Unverified in our
  environment — not built on.**

## Decision

Add **Session Radar** as a pure, display-only layer over the existing heartbeat records. It
reads **nothing new** (only the existing files + process presence + `now`) and **does not
touch the keep-awake decision** — the proven `automationIntent` path is unchanged.

1. **New pure types** in `VibeMenuCore/ClaudeSession.swift`:
   - `ClaudeSessionState { working, quietWorking, waitingForInput, permissionRequested, done,
     stale, unknown }` with `label`, framework-free `displayStyle`, `sortPriority`,
     `needsAttention`, and `holdsSleepPrevention`.
   - `ClaudeSession` — a Sendable value with `id`, `state`, `event`, `startedAt` (first
     observed), `lastEventAt`, `agent` (always `"Claude"`), and documented-`nil` placeholders
     `terminal` / `currentActivity` (no privacy-safe source yet).
   - `ClaudeSessionStore` — a stateful value type with a pure `mutating update(records:
     processPresent:now:)`: dedupes via `latestRecordPerSession`, derives each state, tracks
     `startedAt` across ticks, **prunes** sessions past a 30-min horizon (the hook never
     deletes files — see Consequences), and sorts **attention-first**.

2. **Per-session derivation is defined to be identical to the keep-awake decision.**
   `ClaudeSessionState.derive(event:age:processPresent:)` uses the same active window (120s)
   and quiet-hold cap (900s) as `automationIntent`, so that `working ∨ quietWorking` (i.e.
   `holdsSleepPrevention`) holds a session **iff** `event.indicatesWorkInProgress ∧ age ≤
   quietHoldCap ∧ processPresent` — exactly `automationIntent`'s per-session hold predicate. A
   unit test asserts `sessionsKeepAwakeIntent(derivedSessions) == automationIntent(...)` across
   the full automation timeline battery, so **the radar and the wired power decision can never
   silently drift**.

3. **`permissionRequested` is a reserved placeholder that is never produced.** A unit test
   proves `derive` never returns it for any input. Enabling it honestly needs the
   `Notification` hook's `notification_type` — a small, safe, opt-in future hook change, not
   built here (so the UI never fabricates a permission prompt).

4. **Wiring.** `ClaudeActivityProvider` owns one `ClaudeSessionStore`, folds it each ~2s tick
   (behind its existing lock), and emits `[ClaudeSession]` on a **new first-then-on-change
   `onSessions` stream** — separate from the display-state and intent streams.
   `ClaudeActivityModel` republishes it as `sessions`. The keep-awake feed
   (`automationIntent` → `updateClaudeAutomation`) is **untouched**.

5. **UI.** The single `Claude:` row becomes a `SessionRadarView`: one compact two-line row per
   session (state-coloured dot, state label + elapsed on top; the `Claude` tag + a short
   opaque session-id fragment below), sorted attention-first, in a `TimelineView` so elapsed
   ticks while the menu is open. **With no live sessions — including whenever the hook isn't
   installed, so there are no heartbeat files — it falls back to the exact pre-radar
   `Claude: …` label**, so non-hook users see no change. Gated by the existing "Show Claude
   status" preference; thermal and the keep-awake toggle are unchanged.

**Invariants preserved.** No network, no telemetry, no backend. Metadata only — the radar
reads only VibeMenu's own heartbeat files, process presence, and mtime; never transcripts,
cwd, tool input, or contents. Manual keep-awake still always wins. The power decision logic is
unchanged.

## Consequences

- The menu now answers "which session is working / waiting / done?" at a glance, for Claude
  Code, using data already on disk — the app's first step from "keep-awake" toward a
  local agent status center, without touching the proven automation or any invariant.
- **Heartbeat files accumulate on disk** (the hook overwrites per session but never deletes;
  a live machine showed **105 files**, mostly days old). The radar's 30-min prune keeps the
  *list* correct (verified: 105 files → 3 shown), but the on-disk pile still grows. Cleaning it
  up (hook-side deletion on `SessionEnd`, or a VibeMenu maintenance sweep) is **future work**,
  not done here (it would add a write path).
- **Process presence is global**, not per-session — attributing a PID to a session would need
  reading its command line, which we deliberately don't. Documented; matches existing behavior.
- **Elapsed is "since VibeMenu first observed the session"** — it resets on app restart and
  underestimates sessions that predate launch (heartbeat files retain no start time). Honest
  and documented.

## Open decisions (flagged for the product owner)

- **Short session-id fragment in the UI.** The radar shows the first 6 characters of the
  opaque session id to tell concurrent sessions apart — a fragment of a random id, with no
  project name, path, or content, and never logged. This is the only new user-visible id
  exposure; trivially removable (one `Text`). Flagged for veto.
- **Enabling `permissionRequested`** needs an opt-in hook change to record
  `notification_type` — proposed, not built.
- **Unifying the power feed onto the session aggregate** (routing `updateClaudeAutomation`
  through `sessionsKeepAwakeIntent`) is deliberately deferred; it touches the power decision
  and so needs the second-model review AGENTS.md §18 requires. The equivalence test makes this
  a validated future step.

## Non-goals (explicitly out of this slice)

Multi-agent (Codex/Cursor/Gemini/Aider); real permission Allow/Deny; terminal/window jump;
notch or floating-pill presentation; Accessibility; a root/privileged helper;
cloud/backend/telemetry; a cost/usage dashboard; task/title/activity-text extraction (needs
sensitive reads); changing the hook script or heartbeat schema.

## Alternatives considered

- **Duplicate the keep-awake logic in the store.** Rejected: two hold/release decisions could
  drift. Instead the per-session states are *defined* to reproduce `automationIntent`, and a
  test pins the equivalence — one source of truth, validated.
- **Route power through the new session aggregate now.** Rejected for this slice: it changes
  the power decision (second-model-review-gated). Kept as a validated future step.
- **Add project/terminal/title to rows now.** Rejected: no privacy-safe source without reading
  cwd/transcript or process command lines / Accessibility. Left as documented-`nil`
  placeholders with an opt-in path.
- **Notch/floating presentation.** Rejected for now: hardware-gated, multi-display and
  fullscreen complexity, high polish burden. The pure `ClaudeSession` model is presentation-
  agnostic, so a future notch/pill layer can consume the same state — a deliberately separate
  future decision.
- **A one-shot GUI screenshot to verify layout.** Not done: the owner's real VibeMenu was
  running, and launching a second instance would create a duplicate menu-bar item / assertion.
  The pipeline was instead verified end-to-end against the real heartbeat files; the SwiftUI
  layout remains a manual smoke-test step.
