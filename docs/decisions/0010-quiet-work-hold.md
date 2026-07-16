# 0010 — Finish-vs-silent-gap: bounded quiet-work hold for keep-awake

- **Status:** Accepted
- **Date:** 2026-07-04
- **Deciders:** Kirill Chistov (product owner); implemented by Claude Code.
- **Supersedes:** the "release automation the moment Claude leaves `.active`" behavior
  from [`0008`](0008-claude-heartbeat-detection.md).

## Context

v0.1 wired automatic keep-awake to Claude detection as: hold a power assertion **iff** the
detection state is `.active`, release on **every** other state
(`PowerAssertionModel.updateClaudeActivity` → `automationRequested = state == .active`).

That collapsed two very different situations into one "not active → release" bucket:

1. **Finished.** Claude ended its turn (`Stop`) and is waiting for the user. The L2
   heartbeat correctly reports `.waiting`. Releasing is right — the Mac should sleep.
2. **Quiet but still working.** Claude is in the middle of a long, silent phase — one long
   `Bash` build/test, a long tool call, or a subagent/Task run — during which **no hook
   fires for minutes**. The last heartbeat is an *active* event (`PreToolUse` etc.) that
   simply ages. Past the L2 active window (120s) the pure L2 evaluator ages it out to
   `.waiting`, so `updateClaudeActivity` released the assertion **and the Mac could sleep
   mid-run.**

The two are indistinguishable if you only look at the display state, because an aged-out
active heartbeat and a genuine `Stop` both surface as `.waiting`. Metadata/mtime can't fix
this (0008 already established that); only the *nature of the last event* plus *process
presence* plus a *time bound* can. Simply widening the 120s active window was rejected: any
single window either releases too early on genuine finishes or holds too long on hung
sessions.

The product owner chose the **"revised D + C"** approach over a simpler "just add a 180s
grace" idea: distinguish the states explicitly (D) **and** bound the hold with a cap (C).

## Decision

Introduce a **separate, pure keep-awake automation decision** that is decoupled from the
Active/Waiting/Idle *display* state, plus a bounded **quiet-hold cap**.

1. **New intent type.** `ClaudeAutomationIntent { hold, release }` — what automatic
   keep-awake should do, distinct from `ClaudeActivityState` (the display).

2. **Pure evaluator.** `ClaudeActivityState.automationIntent(heartbeats:signals:now:
   quietHoldCap:)`:
   - **Process gone / cross-check first:** no visible `claude` process ⇒ `.release`
     (a heartbeat is never proof of a live process).
   - Per live session (newest record wins): `SessionEnd` excluded; a session whose newest
     event does **not** indicate work-in-progress (`Stop`, `Notification`, `SessionStart`)
     does not hold.
   - A **work-in-progress** session holds iff its newest event is within the cap.
     **Any one holding session ⇒ `.hold`** — a finished session never forces a global
     release while another session is still working.
   - Otherwise ⇒ `.release`.

3. **Explicit four-way distinction** (never collapsed): **active** (work-in-progress within
   the cap → hold), **quiet-but-still-running** (active event older than the 120s display
   window but within the cap, process present, no finish → still hold), **finished**
   (`Stop`/`SessionEnd`/process-gone → release), **not detected / stale** (no live
   work-in-progress session, or last active event older than the cap → release).

4. **Bounded quiet-hold cap: 15 minutes** (`defaultQuietHoldCap`) since the last
   work-in-progress event. Past the cap with no new active event, automation releases, so a
   hung/stale session cannot keep the Mac awake forever. A new active event resets the cap
   (it becomes the session's newest record), which is how a "pending release" is cancelled.
   The cap — **not** the L2 display "stale" window (600s) — is the automation path's only age
   bound; the stale window serves the display and is deliberately *not* applied here (it
   would cap the hold at 10 min and defeat the 15-min contract).

5. **Event classification** (`ClaudeHeartbeatEvent.indicatesWorkInProgress`), distinct from
   the display's `isActiveEvent`:
   - **Hold:** `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `SubagentStart`,
     `SubagentStop`, and **unknown/future** events.
   - **No hold:** `Stop`, `SessionEnd`, `Notification`, `SessionStart`.
   - `SubagentStart`/`SubagentStop` are now recognised. Per the current Claude Code hooks
     reference, **`SubagentStop` fires when one subagent finishes and returns control to the
     parent turn, which keeps running** — so it must **never** trigger a global release
     (a false-release bug). It holds (within the cap), as does an unknown/future event, so an
     unrecognised subagent/tool event can never cause a false release.
   - **`Notification`** is classified conservatively as **not** work. Claude Code
     `Notification`s are permission/idle/attention prompts — i.e. *waiting for the user*,
     which SPEC §5.1 says should let the Mac sleep. Manual keep-awake still covers
     "hold while I stepped away from a prompt." (Documented per the task's rule 6.)

6. **Wiring.** `ClaudeActivityProvider` computes the intent each ~2s tick alongside the
   display state and emits it on its own first-then-on-change stream; `ClaudeActivityModel`
   republishes it (`automationIntent` + `onAutomationChange`); the app feeds it to
   `PowerAssertionModel.updateClaudeAutomation(_:)`. The bounded cap is enforced by this
   **periodic re-evaluation** (the existing detection tick), not a one-shot timer — so the
   whole decision stays pure and there is no timer lifecycle to leak. Provider teardown
   (`stop()`) cancels the only timer; model `cleanup()` releases the assertion.

**Invariants preserved.** Automation only ever sets `automationRequested`; it **never**
mutates `manualRequested`. `effectiveKeepAwake == manualRequested || automationRequested`,
so **manual keep-awake always wins** and an automation release can never turn the user's
manual switch off. No network, no telemetry, no privileged helper, no clamshell work.

## Consequences

- The Mac no longer sleeps during long silent Claude phases (build/test, long tool call,
  subagent/Task run) up to 15 minutes of silence, while still releasing promptly on a real
  finish — the v0.1 false-release bug is fixed.
- **The display may read "Idle" while sleep prevention is still held** during a quiet hold.
  This is intentional and documented (README/FAQ/PRODUCT): the UI reflects "Claude isn't
  visibly emitting events," while automation reflects "work is probably still in flight,
  bounded by the cap."
- **Known limit:** a genuinely silent phase longer than the 15-minute cap (e.g. a >15-min
  single build with no intervening hook) will release at the cap. That is the deliberate
  hung-session backstop; users with such jobs should flip **manual** keep-awake, which always
  wins. Wiring `SubagentStart`/`SubagentStop` (and any future intermediate events) into the
  hook keeps the heartbeat fresh and pushes the cap out for real ongoing work.
- The heartbeat hook sample (`settings-snippet.json`) and its README now also wire
  `SubagentStart`/`SubagentStop` so subagent phases refresh the hold. Users who don't add
  them still benefit — an unknown/older active event holds within the cap — they just get a
  shorter effective hold across subagent gaps.

## Alternatives considered

- **Simple 180s grace only (no cap, no explicit distinction).** Rejected by the product
  owner: a flat grace either releases too early for multi-minute tool phases or, if widened,
  holds a hung session indefinitely. It also still collapses finished vs. quiet.
- **Just widen the 120s L2 active window.** Rejected (as in 0008): no single window
  separates "still working silently" from "finished," and widening it makes genuine
  finishes release late.
- **A new display state (`.quietHold`) folded into `evaluate`.** Rejected: it would change
  display semantics and the many `.waiting` display tests, and conflate the display with the
  automation decision. A separate pure `automationIntent` keeps the two concerns — and their
  tests — cleanly apart.
- **A one-shot release timer in `PowerAssertionModel`.** Rejected: the existing ~2s
  detection tick already re-evaluates continuously, so a pure `now`-parameterised function
  enforces the cap with no timer to schedule, cancel, or leak. Simpler and fully unit-testable.
- **Treat `SubagentStop` as a finish.** Rejected: it is per-subagent; the parent turn
  continues, so it would cause exactly the false release this ADR fixes.
