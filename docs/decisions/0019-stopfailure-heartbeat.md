# 0019 — Recognise the `StopFailure` hook event as a finish (Claude, opt-in)

- **Status:** Accepted — code, sample config, docs, and tests landed. The `StopFailure` lifecycle
  is verified against the official Claude Code hooks reference and by unit tests; it has **not** yet
  been observed live on a real API-error turn (see *Verification*).
- **Date:** 2026-07-16
- **Deciders:** Kirill Chistov (product owner, directed this scoped fix). Implemented by Claude Code.
- **Builds on / relates to:** [`0008`](0008-claude-heartbeat-detection.md) (the VibeMenu-owned hook
  heartbeat, L2), [`0010`](0010-quiet-work-hold.md) (`automationIntent` + the bounded quiet-work
  hold), [`0011`](0011-session-radar.md) / [`0015`](0015-radar-state-and-timer.md) (per-session
  display state — `.done` vs. `.quietWorking`), [`0018`](0018-needs-approval.md) (the last event we
  added to the recognised set, same mechanism). AGENTS.md §6/§8 (only the safe heartbeat fields; no
  transcript/tool/error content; no network).

## Context

A finished Claude session was observed **stuck showing "Quiet"** (`.quietWorking`) instead of
"Done". Tracing the state machine (`ClaudeSessionState.derive`,
[`ClaudeSession.swift`](../../Sources/VibeMenuCore/ClaudeSession.swift)):

- A row reads **Done** only when the session's newest heartbeat event is a *finish* — one that is
  **not** `indicatesWorkInProgress` (`Stop`, `Notification`, `SessionStart`, `SessionEnd`).
- A row reads **Quiet** (`.quietWorking`) when the newest event **is** work-in-progress
  (`PreToolUse`/`PostToolUse`/subagent/**unknown**), has aged past the 120s display window, and is
  within the 15-minute quiet-hold cap — the intentional "long silent tool/subagent phase" state
  (0010). Past the cap it becomes `.stale` and is hidden.

So a session finishes but stays "Quiet" **iff its turn ended without a `Stop`** (or other finish)
ever overwriting the last work event. That is exactly what happens on an **API error**: per the
Claude Code hooks reference, a turn that ends because the request errored out fires **`StopFailure`,
and `Stop` does *not* fire** on that path. VibeMenu did not recognise `StopFailure`, so
`ClaudeHeartbeatEvent(hookEventName: "StopFailure")` fell to `.unknown` — and `.unknown`
`indicatesWorkInProgress` (0010 deliberately holds for unknown/future events so a silent gap never
causes a false release). The result was a **double bug** for an errored-out session:

1. **Display:** it kept reading **Quiet** (`.quietWorking`) for up to ~15 minutes, then vanished as
   `.stale` — never "Done".
2. **Keep-awake:** because `.unknown` holds, automatic sleep prevention stayed **held** after the
   turn had already ended, until the quiet-hold cap elapsed.

Normal completions were never affected: they fire `Stop`, which the sample hook already wires and
`derive` already maps to `.done`. This is a gap in the *recognised finish set*, not a timing problem
— so the fix is to recognise the missing finish event, **not** to infer "done" from silence or
shorten the quiet timeout (which would regress the 0010 quiet-work hold that the constraints
protect).

## Decision

Recognise `StopFailure` as a **finish**, using the existing opt-in heartbeat mechanism — no new data,
no transcript/error content, no network, no timing heuristic.

- **Sample hook (`settings-snippet.json`):** wire `StopFailure` alongside the other events, with
  **no matcher** (the hooks reference documents `"*"` / `""` / omitted as "match all", so a
  matcher-less block fires on every error type — `rate_limit`, `overloaded`, `server_error`,
  auth/billing, and any future type). The hook records it like any other event: only
  `{schemaVersion, updatedAt, event, sessionID, project}` — never the error type, message, tool, or
  any conversation text. This is a **manual, opt-in** settings change, exactly like every other
  heartbeat event (0008); VibeMenu still never edits `~/.claude/settings.json`.
- **Event (`ClaudeHeartbeat.swift`):** add `ClaudeHeartbeatEvent.stopFailure`; map the top-level
  `hook_event_name` `"StopFailure"` → it. Classify it **exactly like `Stop`**: a finished turn
  awaiting the user — `isWaitingEvent == true`, `indicatesWorkInProgress == false`,
  `isSessionEnd == false` (the *turn* ended, not the *session*; the user can retry, and the next
  event overwrites the heartbeat).
- **No new state.** Because `stopFailure` is classified as a non-work finish, the three existing pure
  functions produce the right answers with no special-casing: `derive` → `.done` (releases the hold),
  `automationIntent` → `.release`, and the display `evaluate` aggregate → `.waiting` (same as `Stop`).
  A still-working sibling session still wins (`.hold`), so an errored-out session never forces a
  global release (0010 rule 5).

`.unknown`'s "hold within the cap" semantics are **deliberately left unchanged** — that safety net
still protects genuinely unrecognised / future events from causing a false release. `StopFailure` is
simply promoted out of `.unknown` into an explicit, recognised finish.

## Consequences

- An errored-out Claude session now reads **Done** promptly and **releases** automatic sleep
  prevention — instead of lingering on **Quiet** (holding the assertion) for up to the 15-minute cap.
- **Existing installations must add the `StopFailure` block** to their `~/.claude/settings.json` for
  the fix to take effect — the code recognises the event, but the hook must emit it. Users who do not
  add it are no worse off than before (an errored turn still ages out via the quiet-hold cap); they
  just do not get the prompt "Done" + release. Same opt-in posture as `SubagentStart`/`SubagentStop`
  (0010) and `PermissionRequest` (0018). The manual addition is documented in
  [`Support/ClaudeHeartbeat/README.md`](../../Support/ClaudeHeartbeat/README.md).
- Privacy contract is unchanged and re-proven for this payload shape: a `StopFailure` payload carries
  the error detail the event is *about*, and a subprocess test asserts none of it (type, message)
  reaches the heartbeat file — only the safe `{event, session id, folder}`.
- The Session Radar ⇔ keep-awake equivalence invariant (0011) still holds: `stopFailure` is a
  non-holding finish in both the radar aggregate and the wired `automationIntent`, pinned by the
  drift-guard test across a `StopFailure` timeline.

## Verification and the smallest next experiment

- **Mechanism** — verified against the current source (the `derive` / `automationIntent` / `evaluate`
  paths above) and by focused unit tests: event mapping + classification, `derive` → `.done`,
  `automationIntent` → `.release`, display → `.waiting`, on-disk decode → recognised event, the
  radar/automation equivalence, and the subprocess privacy test. `swift build`, `scripts/test.sh`
  (570 tests), and the Debug `.app` build all pass.
- **External fact** — that `StopFailure` is the exact top-level `hook_event_name`, that it fires when
  a turn ends on an API error, and that **`Stop` does not fire** on that path — verified against the
  official Claude Code hooks reference (`code.claude.com/docs/en/hooks.md`).
- **Not yet observed live.** A real API-error turn was not reproduced on this machine, so the
  end-to-end path (Claude writes a `StopFailure` heartbeat → row flips to Done → assertion releases)
  is **unverified live**. **Smallest next experiment:** with the `StopFailure` block installed, watch
  `~/Library/Application Support/VibeMenu/ClaudeHeartbeat/sessions/*.json` while triggering an
  API-error finish (e.g. a rate-limit/overload during a turn), and confirm the file's `event` becomes
  `StopFailure`, the Session Radar row reads **Done**, and `pmset -g assertions` shows VibeMenu's
  `PreventUserIdleSystemSleep` released — mirroring the 0018 live-proof method.

## Alternatives considered

- **Infer "Done" from silence / shorten the quiet-hold cap.** Rejected (and forbidden by the task
  constraints): it would regress the 0010 quiet-work hold, which exists precisely so a long silent
  tool/subagent/build phase (no hook for minutes) keeps holding. The bug is a missing *event*, not a
  mis-tuned timeout.
- **Treat `.unknown` as a finish.** Rejected: 0010 holds for unknown/future events on purpose, so an
  unrecognised subagent/tool event can never cause a false release. Promoting `StopFailure` to an
  explicit case keeps that safety net intact while fixing the one event we now know is a finish.
- **Wire per-error-type matchers.** Rejected: VibeMenu doesn't care *why* the turn errored, only that
  it ended. A matcher-less block matches every type (including future ones) and records no error
  detail, staying within the privacy contract.
