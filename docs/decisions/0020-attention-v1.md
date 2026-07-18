# 0020 — Attention v1: local notifications, reusable-turn timers, and provider activation

- **Status:** Accepted — implemented with focused tests; live notification/activation smoke testing is
  reported separately in the development log.
- **Date:** 2026-07-17
- **Deciders:** Kirill Chistov (product owner, approved the scoped option-1 implementation).
- **Builds on / relates to:** [`0011`](0011-session-radar.md) (shared rows and dismissal),
  [`0015`](0015-radar-state-and-timer.md) (state/timer rules), [`0017`](0017-codex-session-support.md)
  (Codex Desktop metadata), [`0018`](0018-needs-approval.md) (Claude approval state), and the
  privacy/resource invariants in AGENTS.md §§6–10.

## Context

The Session Radar already exposed Claude **Needs approval**, Claude **Done**, and Codex **Done**, but
the app had no opt-in alert path, reused sessions kept their prior visible timer, and row clicks did
not bring the owning desktop app forward. The useful Attention v1 slice is deliberately limited to
one notification toggle, meaningful state transitions, reusable-turn timer resets, and provider-level
activation.

## Decision

Keep transition logic pure in `VibeMenuCore` and keep macOS side effects in `VibeMenuApp`.

- `AttentionTransitionTracker` establishes a silent per-provider baseline on the first snapshot and
  emits only a target state backed by a new safe activity generation: Claude compares `lastEventAt`
  plus its normalized heartbeat event, while Codex compares `lastActivity` plus its `task_complete`
  marker. A same-timestamp Claude reclassification with the same event is silent, while a
  same-timestamp `UserPromptSubmit` → `Stop` replacement is a new completion generation; repeated
  identical markers are silent. Claude completion notifications require a genuine `Stop` or
  `StopFailure` event, so `SessionStart`, process/age-derived `.done`, and silence never notify. A
  newer completion or permission-request generation notifies even if polling observes the target state
  twice. A newly appearing target-state session is eligible after the provider baseline. The tracker
  runs while notifications are disabled, so enabling them never replays an existing state; the
  explicit Codex provider setting reset establishes a new silent baseline when re-enabled.
- Settings has one default-off **Agent notifications** toggle. `UNUserNotificationCenter` permission is
  requested only from an explicit enable action, with `.alert` and `.sound`. A denied or unresolved
  request leaves the toggle off. Notification text is limited to the provider, the existing safe display
  name, and `needs approval` or `finished`; identifiers are random and `userInfo` contains only the
  provider. Each delivered request sets `content.sound = .default`, and foreground presentation
  requests `.banner` and `.sound`. Actual playback remains controlled by the Mac's notification,
  Focus, volume, and sound settings. There is no separate sound toggle, custom sound file, sound
  selection, badge, grouping, history, session id, path, prompt, response, error, tool, or repository
  data.
- Session-row tap and drag are composed as mutually exclusive gestures. A rightward drag hides the
  row without also activating Claude Desktop or ChatGPT; the right-click hide menu remains separate.
- Claude keeps its existing request-relative Needs approval timer. A newer `PermissionRequest` after
  a completed/stale/unknown turn establishes the reusable-turn start at the request timestamp; the
  same start is preserved when work resumes after approval. A request during an already-running turn
  preserves that turn's original start. A newer work heartbeat after a completed/stale/unknown state
  starts a fresh turn, and same-event/timestamp refreshes never reset the timer. Done remains
  timer-less.
- `ClaudeSessionState` treats `Stop` and `StopFailure` as explicit finish evidence before process or
  age checks. The next normal provider refresh therefore publishes Done, removes the timer, and
  releases Claude automation without waiting for the active window, quiet-hold cap, or process
  disappearance. Same-second per-session heartbeat replacement prefers the finish/approval event over
  an older work/lifecycle classification.
- Codex carries the existing completion marker into `CodexSession`. `CodexSessionTurnStore` resets
  `timerStartedAt` only when newer allowlisted activity follows a completed marker and the new marker
  is not completion. Done remains timer-less, and timer state never participates in sleep prevention.
- Both row types and notification clicks call the same provider activation adapter. It resolves the
  known public bundle identifier, activates a running app or opens it with public `NSWorkspace` APIs,
  and fails quietly if the app cannot be found. It never selects a conversation, thread, project, or
  window and never uses Accessibility, window titles, private APIs, root, or extra data sources.

## Consequences

- A reused Claude or Codex session can produce another Done notification after a newer safe completion
  generation, including when polling misses the intermediate working state.
- Notifications are transition-only and in-memory; there is no notification history or catch-up after
  the feature was disabled.
- Codex has no explicit turn-start event, so its reset boundary is the existing completion marker plus
  newer non-completion activity. Exact conversation/window navigation remains intentionally out of scope.
- Bundle identifiers are current local provider targets (`com.anthropic.claudefordesktop` and
  `com.openai.codex`); an unavailable or changed app is ignored safely until the mapping is updated.
- The notification and activation adapters use public macOS APIs checked against the local macOS SDK
  headers. They need no root, Accessibility permission, private API, or special power entitlement; they
  do not change the existing public IOKit sleep-prevention path. Actual notification delivery, provider
  activation, drag/context-menu behavior, and a naturally emitted Claude finish heartbeat remain
  manual smoke checks. Pure generation, timer, state-derivation, sleep-intent, ordering, dismissal,
  and overflow behavior are covered by unit tests.

## Alternatives considered

- **Provider-side notification effects.** Rejected: it would duplicate transition rules and make the
  launch/provider baselines harder to test.
- **Persist notification state/history.** Rejected: it violates the requested 20/80 scope and the
  lightweight local-resource budget.
- **Exact thread/window selection.** Rejected: it would require unsupported or privacy-sensitive
  mechanisms; provider-level activation is the reliable public-API boundary for v1.

## Follow-up — Claude completion latch (2026-07-18)

### Confirmed root cause

The safe-field capture of a real Claude Code subagent turn showed:

`UserPromptSubmit → PreToolUse → SubagentStart → SubagentStop → PostToolUse → Stop → SubagentStop`

The final `SubagentStop` arrived after the genuine `Stop`. `SubagentStop` is deliberately treated as
work for the bounded sleep hold, but it is not a display-active event. When the hook replaced the
completed `Stop` heartbeat with that late event, the existing session store interpreted it as a new
reused-session turn: the row became **Quiet**, its timer restarted, and Claude automation could hold
again. Only the normalized event and `updatedAt` fields were inspected; no session content was read.

### Decision

Keep the correction at the earliest reliable layer: the VibeMenu-owned hook reads only the previous
safe heartbeat's `event` field as an in-memory-on-disk completion latch. After `Stop` or `StopFailure`,
it ignores repeated or trailing events from that completed turn. It accepts only `UserPromptSubmit`,
`PermissionRequest`, or `SessionEnd` as the next boundary. The accepted boundary replaces the
heartbeat normally; no schema field or consumer behavior changes. Therefore a two-second polling
tick cannot miss the boundary and manufacture a new turn from a late event.

### Verified consequence

The temporary-directory hook tests cover `PostToolUse`, `SubagentStop`, `StopFailure`, same-second
events, repeated finishes, both new-turn boundaries, SessionEnd, timer/sleep intent, and notification
deduplication. With the patched local VibeMenu hook copy, a second real subagent turn produced
`UserPromptSubmit → PreToolUse → SubagentStart → SubagentStop → PostToolUse → Stop`; no later safe
heartbeat replacement appeared during the capture window, and the final safe event remained `Stop`.
The Debug app was built and launched from the requested derived-data path. The menu-bar-only row click,
notification delivery, and provider activation could not be manually observed because the local UI
accessibility surface exposed no VibeMenu menu window; those remain covered by the existing pure tests
and explicitly unverified live behaviors.
