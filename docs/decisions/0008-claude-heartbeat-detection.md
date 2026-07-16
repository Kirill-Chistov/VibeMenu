# 0008 — Claude heartbeat detection (L2), observation-only

- **Status:** Accepted
- **Date:** 2026-07-03
- **Deciders:** Kirill Chistov (product owner); implemented by Claude Code.

## Context

Claude detection L1 (ADR 0005 item 2, ARCHITECTURE.md "AgentMonitor") reads only
**process presence** + session-file **mtime** under `~/.claude`. That is enough to guess
"present / recently active" but it **cannot distinguish "working" from "waiting for
input"**: when Claude finishes replying it is still a live `claude` process and its last
write leaves the session mtime briefly fresh, so L1 can only *age out* of `active` after a
short window. The finished-reply latency work (DEVELOPMENT_LOG, 10s window) mitigated but
could not fix this — it is a fundamental limit of metadata-only detection.

A hook experiment was run in the product owner's real desktop local-agent environment. It
confirmed Claude Code fires local lifecycle hooks reliably — `SessionStart`,
`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `SessionEnd` (and `Notification`)
— and, critically, that `UserPromptSubmit` fires when the user sends a prompt, `PreToolUse`
/`PostToolUse` bracket tool calls, and **`Stop` fires promptly when Claude finishes and
waits**. Product verdict: hooks are reliable enough to base a real working/waiting signal
on.

The constraint set is unchanged and strict: still **observation only** (no wiring to sleep
prevention / Keep-Awake / power assertions), still **metadata only** (no transcript reads,
no JSONL parsing, no prompt/response/tool/path logging), no network/telemetry/deps, no
auto-editing of `~/.claude/settings.json`, no clobbering existing hooks, no new permissions
(Accessibility / Full Disk / root / privileged helper).

## Decision

Add **Claude detection L2**: a VibeMenu-owned hook heartbeat that supersedes mtime-guessing
as the primary active/waiting signal, with L1 retained as the fallback. Keep the same
pure-core / thin-adapter / observable-model shape as the thermal, power, and L1 slices.

1. **Heartbeat files (VibeMenu-owned, privacy-constrained).** An **opt-in**, user-installed
   Claude Code hook script (`Support/ClaudeHeartbeat/vibemenu-claude-hook.sh`) writes one
   file per session at
   `~/Library/Application Support/VibeMenu/ClaudeHeartbeat/sessions/<session_id>.json`
   containing **only** `{schemaVersion, updatedAt, event, sessionID}`. The script reads the
   hook JSON on stdin, extracts **only** `hook_event_name` + `session_id`, ignores
   everything else, sanitizes the session id before using it as a filename, writes
   atomically (temp + rename), and always exits 0. No `jq`/dependencies. A missing
   `session_id` is written to a shared `unknown-session.json` (documented behavior).

2. **Manual setup, never automatic.** VibeMenu does **not** install the hook and does
   **not** edit `~/.claude/settings.json`. `Support/ClaudeHeartbeat/README.md` documents
   backup → merge → verify → remove, and `settings-snippet.json` is a sample block wiring
   `SessionStart` / `UserPromptSubmit` / `PreToolUse "*"` / `PostToolUse "*"` /
   `Notification` / `Stop` / `SessionEnd`. Existing user hooks are composed with, not
   replaced.

3. **Pure L2 decision.** `ClaudeActivityState.evaluate(heartbeats:signals:now:…)`:
   - active event (`UserPromptSubmit`/`PreToolUse`/`PostToolUse`) within the active
     window ⇒ `.active`;
   - `Stop`/`Notification` (or an active event aged past the active window, or
     `SessionStart`/unknown) ⇒ `.waiting`;
   - `SessionEnd` sessions are excluded; records past a several-minute **stale** window are
     ignored;
   - across sessions **any active wins, else any waiting**;
   - **process cross-check**: a heartbeat is not proof of a live process, so `.active` is
     never reported without a visible `claude` process (a fresh heartbeat downgrades to
     `.waiting`, an aged one falls back to L1) — no stale/crashed `Active` sticks;
   - **no fresh heartbeat records ⇒ fall back to L1 `evaluate(signals:)` exactly.**

   A new `.waiting` case (label "Waiting") is added to `ClaudeActivityState`; it is only
   reachable via L2. Defaults: active window **120s**, stale window **600s**, L1 recency
   **10s** (unchanged).

4. **Reader in the adapter.** `ClaudeActivityProvider` reads its own heartbeat files each
   ~2s tick (malformed-safe pure decoder `ClaudeHeartbeatRecord.decode(from:)`), gathers
   process presence + L1 mtime, and maps them via the pure L2 function. It reads **its own**
   files only — never Claude transcripts.

5. **DEBUG diagnostics, path-free and id-free.** `ClaudeActivityDiagnostics` gains
   heartbeat fields; `summary` reads e.g. `process=true, heartbeat=Active age=1s
   sessions=1, newestAge=none, threshold=10s, result=Active` (a session *count*, never
   ids/paths). DEBUG-only menu row + `os.Logger`; compiled out of Release.

This is recorded as an ADR (not just an ARCHITECTURE.md note like the thermal/power slices)
because it introduces a **new detection architecture** — a VibeMenu-owned local IPC surface
(the heartbeat files), a new externally-facing artifact (the hook script the user installs
into Claude Code), and a new state (`.waiting`) — that should be preserved and reasoned
about as a unit.

## Consequences

- VibeMenu can finally distinguish **Active** (working) from **Waiting** (finished, awaiting
  input) reliably, for users who opt in — the signal L1 metadata could never provide.
- The heartbeat is a tiny, auditable, **local** IPC: append-free per-session JSON files with
  four safe fields, read by our own code. No transcript exposure; privacy invariants
  (AGENTS.md §6, PRIVACY.md) hold — verified by unit tests and a subprocess test of the
  script.
- Detection **degrades gracefully**: no hook installed ⇒ no heartbeat files ⇒ automatic L1
  fallback, so nothing regresses for users who don't opt in.
- Still **observation only** — no `AutomationPolicy`, Keep-Awake, or power-assertion wiring.
  L2 remains a *separate* seam from `AgentActivityState`.
- The ~2s coarse timer persists (now also doing a small heartbeat read). Moving the
  heartbeat directory to FSEvents (idle CPU → zero) is the remaining TODO; the opt-in hook
  heartbeat that ARCHITECTURE.md's AgentMonitor anticipated is now implemented.
- The hook is **manual to install** by deliberate choice; a future guided/one-click
  installer (with its own explainer and an uninstall path) is possible but out of scope and
  would need its own decision.

## Alternatives considered

- **Keep tuning the L1 mtime window.** Rejected: no window can separate "still writing while
  working" from "just finished and waiting" — the last reply's write is indistinguishable
  from ongoing work. Only an explicit lifecycle signal (Stop) resolves it.
- **Auto-install the hook / edit `settings.json` for the user.** Rejected for v0.1: silently
  editing the user's Claude config (and risking clobbering their hooks) violates the
  ownership/consent posture (AGENTS.md). Manual, reversible setup first; a guided installer
  can come later.
- **Parse Claude's own transcript/JSONL for turn boundaries.** Rejected hard: forbidden by
  the privacy invariants (transcript-content reading) and version-fragile.
- **A socket / long-running local server the hook pings.** Rejected: heavier, adds a
  lifecycle/port surface, and violates the lightweight budget (ADR 0006). Per-session
  files are the minimal, crash-safe, inspectable IPC.
- **Record L2 as an ARCHITECTURE.md note only** (as with thermal/power). Rejected: this
  slice adds a new external artifact and IPC surface worth preserving as a decision.
