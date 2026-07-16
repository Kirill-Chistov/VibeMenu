# 0018 — "Needs approval" via the `PermissionRequest` hook event (Claude Desktop, opt-in)

- **Status:** Accepted — implemented and proven live in the Claude Desktop **Code** tab.
- **Date:** 2026-07-14
- **Deciders:** Product owner (directed the approach after an earlier Accessibility-based
  investigation was set aside; authorised restoring the committed heartbeat integration in the
  local Claude settings and temporarily registering `PermissionRequest` for a live smoke test).
  Implemented by Claude Code under the owner's authorization.
- **Builds on / relates to:** [`0008`](0008-claude-heartbeat-detection.md) (the VibeMenu-owned
  hook heartbeat, L2), [`0011`](0011-session-radar.md) (per-session display layer),
  [`0015`](0015-radar-state-and-timer.md) (state/timer; it reserved `permissionRequested` as a
  not-yet-produced placeholder — this ADR supersedes that "reserved" stance), AGENTS.md §6/§8
  (only the safe heartbeat fields; no transcript/tool/conversation content; no network).

## Context

The Session Radar already modelled a high-priority `ClaudeSessionState.permissionRequested`
("Needs approval", sorted first, attention style, timer) but **never produced it**: earlier
detection layers only recorded the hook *event name*, and no event distinguished a pending
Allow/Deny prompt. An abandoned attempt to infer it from a `Notification` subtype (a Claude Code
hook change) was reverted. A separate Accessibility-API investigation found that Claude Desktop
approvals are web-view elements with no native modal/sheet signal, and that reading them would
require enabling and walking the Chromium AX tree — heavy, fragile when the window is backgrounded,
and a privacy-surface expansion. That approach was set aside.

## Decision

Detect a pending approval from Claude Code's **documented `PermissionRequest` hook event**, using
the existing VibeMenu heartbeat mechanism — no Accessibility, UI scraping, CLI sessions, private
APIs, databases, logs, or network.

- Register `PermissionRequest` (matcher `"*"`) alongside the other events in the opt-in hook
  (`settings-snippet.json`). The hook records it exactly like any other event: only
  `{schemaVersion, updatedAt, event, sessionID, project}` — never the tool, its input/output, or
  any conversation text.
- Map the event name `"PermissionRequest"` → `ClaudeHeartbeatEvent.permissionRequested`.
- `ClaudeSessionState.derive`: a `PermissionRequest` heartbeat with a live `claude` process →
  `.permissionRequested`, at any age (a real approval can wait a long time; the 30-min prune
  horizon still bounds it). It never holds sleep prevention — the *user*, not Claude, is the
  blocker (`indicatesWorkInProgress == false`, like `Notification`; SPEC §5.1).
- **Timer from the request:** the row's timer measures `now − lastEventAt` (the `PermissionRequest`
  write time), not the session's first-observed `startedAt`, so it reads the *wait* time.
- **Clears on the next lifecycle event:** the hook overwrites the per-session heartbeat file on
  every event, so after the user responds the following `PostToolUse`/`Stop` replaces
  `PermissionRequest` and the state leaves `.permissionRequested`. Ordinary completion (no approval)
  never sets it and stays `Done`.

## Live proof (Claude Desktop Code tab, 2026-07-14)

Observed only via VibeMenu's own heartbeat files (`{event, sessionID, project}`):
- **Approve path** (session `2ebd49ef`): `UserPromptSubmit → PermissionRequest` (dialog shown; the
  row appeared as **Needs approval**, sorted first, with a timer — confirmed visually in the running
  Debug menu-bar app) `→ PostToolUse → Stop` (cleared to Working→Done after Allow).
- **Ordinary completion**: an auto-allowed `echo` and a plain prompt both ran
  `UserPromptSubmit → PostToolUse → Stop` with **no** `PermissionRequest` — stayed `Done`.

## Known limitation — the Deny path has no signal on Desktop

**Claude Desktop's Code tab emits no hook event when the user Denies a prompt.** Verified live
across a 90-minute window and multiple deny attempts (including a fresh session that *did* have the
CLI's `PermissionDenied` hook registered): a Deny produces **no** `PermissionDenied`, **no** `Stop`,
**no** `PostToolUse` — the turn silently cancels. (`PermissionRequest` *does* fire on Desktop, which
is why the Allow path works.) With Accessibility/UI-scraping off-limits, there is therefore no way to
detect a Deny immediately. So a **denied** session keeps showing "Needs approval" until its next
event (`SessionEnd` when the user closes it, or a new prompt) or the 30-minute prune (observed:
sessions `17ee1bec`/`3e41fb73`/`2bda2396` all held `PermissionRequest` after a Deny). The **Allow**
path clears cleanly via the following `PostToolUse`/`Stop`.

Registering the CLI's `PermissionDenied` event was tried and reverted: it never fires on the Desktop
surface, so it would have been dead code. If a future Claude Desktop build starts emitting a Deny
hook event, mapping it to a finished state (`.done`) would clear the row immediately.

## Alternatives considered

- **Accessibility / window metadata** — set aside (see Context): web-view approvals, no native
  signal, heavy + backgrounded-blind + privacy-surface expansion.
- **`Notification` subtype (`notification_type`)** — the abandoned approach; needs a bespoke hook
  change and is emitted unreliably.
