# VibeMenu — Architecture

> The technical map. Agents and contributors must not violate these boundaries
> without a `decisions/` entry and human approval.

## Guiding rules

1. **Keep the core pure and testable.** `AutomationPolicy` is a pure function of its
   inputs → desired power state. No I/O. All real correctness of the automation loop
   lives here so it can be exhaustively unit-tested and audited by a human plus a
   second model.
2. **Public Apple APIs only.** No private SMC/IOReport, no root, no privileged
   helper, no exact temperatures.
3. **Event-driven and lightweight.** Prefer notifications / FSEvents / `DispatchSource`
   over polling. No busy loops. Idle CPU effectively zero (see
   [`decisions/0006-lightweight-resource-budget.md`](decisions/0006-lightweight-resource-budget.md)).
4. **Quarantine risk.** Anything touching private APIs, root, or clamshell must live
   **outside** `VibeMenuCore`, behind a protocol, in its own module/helper, and requires
   a separate ADR + human approval. It must never leak into the core.
5. **Metadata, never content.** The agent monitor reads process presence and file
   *modification times* only — never transcript contents (see [`PRIVACY.md`](PRIVACY.md)).

## App ↔ core separation

The project is a Swift Package with clearly separated targets:

- **`VibeMenuApp`** (SwiftUI shell)
  - App lifecycle and the menu-bar shell (`MenuBarExtra`, `LSUIElement = true`).
  - A dedicated SwiftUI `Settings` scene (`SettingsView`) with a **General** section
    (**Launch at login**) above a **Menu bar** section (the row-visibility toggles), opened
    from the in-menu **Settings…** item (which activates the app first so the window comes to
    front under `LSUIElement`). Row-visibility preferences persist via `@AppStorage`; Launch
    at Login does **not** — its source of truth is the live `SMAppService.mainApp.status`.
  - `SMAppServiceLoginItemController` — the real `LoginItemControlling` backend over the
    public `SMAppService.mainApp` (`register`/`unregister`/`.status`). Kept **here**, not in
    the core, so `VibeMenuCore` stays free of `ServiceManagement`
    ([`decisions/0009-launch-at-login.md`](decisions/0009-launch-at-login.md)).
  - Owns all UI and system side effects; depends on `VibeMenuCore`.
  - **Current status:** builds as an SPM executable (`swift build`) *and* as the launchable
    menu-bar `.app` (`App/VibeMenu.xcodeproj`, target `VibeMenu`) that reuses this source and
    links `VibeMenuCore`. The production menu includes the shared Session Radar, assertion
    ownership, thermal state, optional limits, settings, Attention v1 notifications, and the
    reactive normal/orange menu-bar label.

- **`VibeMenuCore`** (pure library)
  - `AutomationPolicy` — the pure decision core.
  - `AgentMonitor` — agent activity observation (protocol + stub today).
  - `PowerAssertionManager` — sleep-prevention wrapper (protocol + stub today).
  - `SystemStatus` — thermal/CPU/memory/battery via public APIs (protocol + stub today).
  - `MenuVisibility` — pure decision for which main-menu status rows (Claude, Thermal) and
    their divider are shown, from the two persisted visibility preferences. No defaults or
    SwiftUI access; the `@AppStorage` read/write stays in `VibeMenuApp`.
  - `LoginItem` — `LoginItemControlling` (protocol seam) + `LoginItemModel`
    (`@MainActor @Observable`) for Launch at Login. The model reflects the controller's
    *actual* `isEnabled` after every `refresh()`/`setEnabled(_:)`, swallows register/unregister
    errors (never crashes), and holds no persisted bool. The real `SMAppService` adapter lives
    in `VibeMenuApp` ([`decisions/0009-launch-at-login.md`](decisions/0009-launch-at-login.md)).
  - Shared value models: `AgentActivityState`, `ThermalPressureState`,
    `PowerAssertionState`, `SystemSnapshot`, `PolicyInput`, `PolicyDecision`.
  - No SwiftUI, no AppKit, no I/O in the decision logic.

- **`VibeMenuCoreTests`**
  - Unit tests for the pure decision logic and lightweight state models.

The intended data flow once wired:

```
AgentMonitor ─┐
SystemStatus ─┼─▶ PolicyInput ─▶ AutomationPolicy.decide ─▶ PolicyDecision
              │                                                   │
   (user mode)┘                                                   ▼
                                              PowerAssertionManager (prevent / allow)
                                              MenuBarExtra UI (state + "why it's awake")
```

## Planned modules

### `AutomationPolicy` — pure decision core

The heart of the product. Given `(mode × agent activity × thermal)` it returns a
`PolicyDecision` (`desiredAssertion`, `reason`, `thermalWarning`). Manual overrides
(`forceAwake` / `forceOff`) win over activity-driven behavior. It never performs I/O and
never silently ignores high thermal pressure — it flags it (the exact response to
serious/critical is a deferred product decision, marked `TODO(ADR)`).

**Implemented today** as a real, tested type. This is the one piece with genuine
behavior in v0.0.

### `AgentMonitor`

Eventually observes whether a watched agent is working, using, in order of stability:

1. **Process presence** — a running `claude` process (e.g. `proc_listpids`); coarse.
2. **Session-file liveness** — mtime/append activity on the current session file under
   `~/.claude/…`, watched via FSEvents/`DispatchSource` (not polling). Recent appends ⇒
   working; quiet for N seconds ⇒ idle.
3. **Hook heartbeat (opt-in, most robust)** — an optional Claude Code hook script that
   pings VibeMenu locally with minimal working/waiting state. **Implemented as L2** (see
   below).

**Hard rule:** depend only on file *existence, mtime, and append events*, VibeMenu's own
heartbeat files, and documented hook interfaces — **never** on parsing Claude transcript
message content (the JSONL format is internal and version-fragile). Distinguishing
"working" from "waiting for input" is solved by L2 (the hook heartbeat); L1 metadata alone
cannot.

**Today — Claude detection L1:** a real first detection layer is live. It combines two
metadata-only signals — process presence (a `claude`-named process via public `libproc`
inspection) and session-file *mtime* under `~/.claude` (`projects/`, `history.jsonl`) —
mapped by a pure, unit-tested decision function into a `ClaudeActivityState`
(`notDetected` / `running` / `active` / `idle` / `unknown`) that drives the menu's
**Claude** row and the built-in automatic keep-awake loop. Layering mirrors the
thermal/power slices:

- `ClaudeActivityState.evaluate(signals:now:recencyThreshold:)` — the pure, I/O-free L1
  decision (recency window default **10s**); fully unit-tested with synthetic signals.
  `active` requires a session-file mtime within the window, so a still-running `claude`
  process whose files have gone quiet (Claude finished replying and is waiting for input)
  ages out to `idle` within ~10s + one refresh tick rather than lingering "active".
- `ClaudeActivityProvider` (`ClaudeActivityObserving`) — a thin adapter that gathers the
  signals (process table + a bounded, stat-only two-level walk of `~/.claude/projects`)
  and maps them via the pure function. **Metadata only** for detection: process *name* and
  file *mtime*; never message contents, never transcript copying. (The Session Radar title
  resolver is the one component that opens a transcript, for the title record only — see
  [Session Radar](#session-radar-claude) below.)
- `ClaudeActivityModel` (`@MainActor @Observable`) — republishes the state to the
  `MenuBarExtra`.

**Today — Claude detection L2 (hook heartbeat, opt-in):** L2 layers a
reliable working/waiting signal on top of L1 without weakening any invariant (see
[`decisions/0008-claude-heartbeat-detection.md`](decisions/0008-claude-heartbeat-detection.md)).
The user *optionally* installs a small VibeMenu-owned Claude Code hook
([`Support/ClaudeHeartbeat/vibemenu-claude-hook.sh`](../Support/ClaudeHeartbeat/)) that, on
each lifecycle hook, writes a tiny per-session JSON file under
`~/Library/Application Support/VibeMenu/ClaudeHeartbeat/sessions/<session_id>.json`
carrying **only** `{schemaVersion, updatedAt, event, sessionID, project}` (schema 2) — where
`project` is the **folder name only** (final path component of `cwd`, e.g. `VibeMenu`), never
the full path, and never prompt/response/tool/transcript contents
(docs/decisions/0012-session-name-from-cwd.md). VibeMenu **never** installs the hook or edits
`~/.claude/settings.json`; setup is a documented manual step.

- `ClaudeHeartbeatEvent` / `ClaudeHeartbeatRecord` + the malformed-safe pure decoder
  (`ClaudeHeartbeatRecord.decode(from:)`) model one heartbeat. `ClaudeActivityProvider`
  reads *its own* heartbeat files (not Claude transcripts) each tick.
- `ClaudeActivityState.evaluate(heartbeats:signals:now:…)` — the pure L2 decision: an
  active event (`UserPromptSubmit`/`PreToolUse`/`PostToolUse`) within the active window ⇒
  `.active`; a `Stop`/`Notification` (or an aged/`SessionStart`/unknown live event) ⇒
  `.waiting`; `SessionEnd` sessions are excluded; across sessions **any active wins, else
  any waiting**. A **process cross-check** never lets a heartbeat claim `.active` with no
  visible `claude` process (a fresh one downgrades to `.waiting`), and records past a
  several-minute **stale** window are ignored — so no stale/crashed `Active` sticks. With
  **no fresh heartbeat records it falls back to L1** `evaluate(signals:)` exactly.
- `ClaudeActivityState.diagnostics(heartbeats:signals:now:…)` — a pure, privacy-safe
  companion returning a `ClaudeActivityDiagnostics` (process flag; heartbeat aggregate
  state + newest *age in seconds* + live-session *count*; L1 mtime age; threshold; result)
  whose `summary` reads e.g. `process=true, heartbeat=Active age=1s sessions=1,
  newestAge=none, threshold=10s, result=Active`. Metadata only — **no paths, no session
  ids, no contents**. In **DEBUG builds only** it is mirrored to `os.Logger` (subsystem
  `com.kirillchistov.VibeMenu`, category `claude-detect`); compiled out of Release. It is
  no longer shown as a menu row.

**Scope & honesty:** L1+L2 feed automation through a **separate pure keep-awake decision**,
`ClaudeActivityState.automationIntent(heartbeats:signals:now:quietHoldCap:)`, that is
deliberately **decoupled from the Active/Waiting/Idle display state**
(docs/decisions/0010-quiet-work-hold.md). It returns `.hold` or `.release`, which the app
feeds to `PowerAssertionModel.updateClaudeAutomation(_:)`. The key behavior it fixes: an
active heartbeat that ages past the 120s display window while the `claude` process is still
present and no finish event has arrived is treated as **quiet-but-still-running** and keeps
holding sleep prevention **up to a bounded 15-minute cap**, instead of releasing the moment
the display falls back to Idle. A genuine finish (`Stop`/`SessionEnd`/process gone) releases
promptly; past the cap it releases so a hung session can't hold forever. `SubagentStop` and
unknown/future events are treated as "still working" so a subagent gap never causes a false
release; `Notification` is classified conservatively as waiting-for-user (release). L1 alone
cannot tell "working" from "waiting for input" (and will have false positives/negatives, e.g.
a `node`-hosted CLI is missed); L2's opt-in hook is what supplies the reliable internal
`Active`/`Waiting` distinction. `Active`/`Waiting` are *internal* detection states, not UI
labels: there is no aggregate `Claude: …` row any more (see
[Session Radar](#session-radar-claude)). The session row displays **Quiet** once an active
heartbeat ages past the 120s display window, which is why a row can read **Quiet** while sleep
prevention stays on for the rest of the 15-minute hold. (The simpler state-only entry
`updateClaudeActivity(_:)` — `.active` ⇒ hold, else release — is retained for tests but is no
longer what the app wires.)

**Temporary polling (documented exception to decisions/0006):** rather than wire
FSEvents across the `~/.claude/projects` tree *and* the heartbeat sessions directory, the
provider uses a single **coarse `DispatchSourceTimer`** (~2s, 0.5s leeway) — a coalesced
scheduled wakeup doing negligible work per tick (a bounded stat walk, a small
heartbeat-file read, one process-table read), *not* a busy loop. This is an explicit,
temporary measure. **TODO:** replace it with FSEvents/`DispatchSource` append events on the
heartbeat directory + process-lifecycle observation so idle CPU returns to truly zero (the
opt-in hook heartbeat itself is now implemented — see L2 above).

**Still stubbed (for future generalized agents):** `AgentMonitoring` + `StubAgentMonitor`
(reports `.unknown`, no-op) and `AgentActivityState` remain as the older agent-agnostic
seam. The v0.1 Claude loop is wired directly from `ClaudeActivityModel` into
`PowerAssertionModel` so it does not invent new detection logic.

### Session Radar (Claude)

`ClaudeSession.swift` adds a **pure, display-only** per-session layer over the same L2
heartbeat records, so the menu can show *which* Claude Code session is working / waiting /
done rather than one collapsed status (docs/decisions/0011-session-radar.md,
docs/decisions/0012-session-name-from-cwd.md, docs/decisions/0013-session-title-and-dismiss.md).
It derives state/order from VibeMenu's own `{schemaVersion, updatedAt, event, sessionID,
project}` files, process presence, and `now`, and **does not touch the keep-awake decision**
(`automationIntent` is unchanged). The row **name** now prefers Claude Code's own session
**title**, read narrowly from the transcript (title record only; see below), over the folder name.

- `ClaudeSessionState` (`working`/`quietWorking`/`permissionRequested`/`done`/`stale`/`unknown`;
  terse `label`s Working/Quiet/Needs approval/Done) + `ClaudeSession` (id,
  state, event, `startedAt` = first observed, `lastEventAt`, `agent = "Claude"`, `projectName`
  = the hook's folder name, `title` = Claude Code's session title when readable, `displayName`
  = `title ?? projectName ?? "Claude session"`, and documented-`nil` `terminal`/`currentActivity`
  placeholders). The opaque session id is kept off the row.
- **Session title (docs/decisions/0013).** `ClaudeSessionTitle` is a **pure** parser that pulls a
  session's human-readable title from transcript bytes, reading **only** `custom-title` /
  `ai-title` records (last custom wins, else last ai) and only their title field — a substring
  pre-filter means prompt/response/`lastPrompt`/tool lines are never parsed. `TranscriptTitleResolver`
  (the sole component that opens a transcript) locates `~/.claude/projects/*/<session_id>.jsonl` by
  session id (validated against `[A-Za-z0-9._-]` to block traversal), reads it, and **caches the
  title per session keyed by mtime** so an unchanged transcript costs one `stat`. The provider
  attaches the resolved title to each session *after* the pure store builds it, outside the store's
  lock; a `nil` resolver (tests) leaves titles unset. No title/path/id is ever logged.
- **Opt-in Claude Desktop titles (docs/decisions/0014).** Claude Code often doesn't write its
  visible title into the transcript, so an **off-by-default** setting adds a higher-priority source:
  the Claude **Desktop** app's local session index. `ClaudeDesktopTitleIndex` is a **pure** parser
  that decodes one `local_<uuid>.json` file to a whitelisted `DesktopSessionRecord`
  (`cliSessionId`/`title`/`titleSource`/`lastActivityAt`/`isArchived` only — the `Decodable` DTO has
  no property for `promptSuggestion`/`cwd`/messages, so they're never decoded) and reduces a set to a
  `cliSessionID → title` map (non-archived beats archived; latest `lastActivityAt` wins).
  `DesktopTitleResolver` (adapter) is gated by an injected `isEnabled` closure checked **before any
  file access**, globs `~/Library/Application Support/Claude/claude-code-sessions/*/*/local_*.json`
  (both UUID levels enumerated), and caches the map keyed by a file signature (paths+mtimes+sizes) so
  an unchanged index costs stats, not reads; a missing directory fails closed to an empty map.
  `CompositeTitleResolver` chains resolvers (first non-`nil` wins); the app wires
  `[DesktopTitleResolver(isEnabled: UserDefaults "useDesktopTitles"), TranscriptTitleResolver()]`, so
  when the toggle is off the Desktop resolver returns `nil` and behavior is exactly the transcript
  path. `displayName` fallback is now: Desktop title → transcript title → folder name →
  `"Claude session"`.
- **Manual dismiss (docs/decisions/0013).** `DismissedSessionRegistry` is a **pure** hide-only
  registry: dismissing records a session's `lastEventAt`, and the row stays hidden until a *newer*
  event arrives, then reappears (Option 2). `ClaudeActivityModel` owns one instance and exposes
  `visibleSessions` (= `sessions` minus hidden rows) to the UI; `dismiss(_:)` is a main-actor UI
  action. It hides the row **only** — no Claude data is touched, no session is stopped, no file is
  written. In the UI, `SessionRow` dismisses via a native SwiftUI `DragGesture` (swipe right, with
  a `.move(edge:.trailing)` removal transition) or a `contextMenu` "Hide from VibeMenu" fallback.
- `SessionRadar.present([ClaudeSession], now:)` — the pure **visibility + naming** projection of
  the store's attention-first list: at most `maxVisibleRows` (4) rows, up to `maxDoneRows`
  (= `maxVisibleRows`) `done`, hide `done` older than 5 min and `stale` older than 2 min, drop
  `unknown`, a bounded "+N more recent sessions" overflow (up to `maxOverflowRows` = 10), and a
  stable numeric suffix when two visible rows share a folder name. No SwiftUI, fully unit-tested.
- `ClaudeSessionState.derive(event:age:processPresent:)` — the pure per-session decision, using
  the **same** active window (120s) and quiet-hold cap (900s) as the automation path, so a
  session `holdsSleepPrevention` (`working ∨ quietWorking`) **iff** `automationIntent` would
  hold it. `sessionsKeepAwakeIntent([ClaudeSession])` therefore equals the wired
  `automationIntent` — a unit test pins this equivalence across the automation timelines, so
  the radar can never drift from the power decision. `permissionRequested` (label **Needs
  approval**, sorted first, timer from the request) is derived from Claude Code's documented
  `PermissionRequest` hook event — recorded as the session's heartbeat `event` and proven live in
  the Claude Desktop Code tab — and clears when the next lifecycle event overwrites the heartbeat
  after the user responds (docs/decisions/0018).
- `ClaudeSessionStore` — a stateful value type (`mutating update`) that tracks `startedAt`
  across ticks, **prunes** sessions whose newest event is older than 30 min (the hook never
  deletes files, so they accumulate — a live machine had 105), and sorts **attention-first**.
- Wiring: `ClaudeActivityProvider` owns one store + the title resolver, folds the store each ~2s
  tick behind its lock, attaches titles, and emits `[ClaudeSession]` on a **first-then-on-change
  `onSessions` stream**; `ClaudeActivityModel` republishes it as `sessions` and derives
  `visibleSessions` (dismissals applied); `SessionRadarView` renders the compact rows from
  `visibleSessions` and falls back to the pre-radar `Claude: …` label when there are no visible
  sessions (including "hook not installed" and "all rows dismissed"). The `MenuBarExtra` icon and the keep-awake loop are
  unchanged. Notch/floating presentation is deliberately deferred; the pure `ClaudeSession`
  model is presentation-agnostic so a future layer can reuse it.

### Claude usage limits (opt-in, experimental — Desktop cache + Claude Code)

A compact **Claude Limits** section shows the user's **real** 5-hour and weekly Claude usage (and
per-model weekly rows) — the same server-side percentages the in-app `/usage` view shows — read
**locally** with no network, from either of two sources the user picks in Settings. Source and
rationale: [`decisions/0016-claude-usage-limits.md`](decisions/0016-claude-usage-limits.md).

- **Normalised model (pure, tested):** `ClaudeUsageLimit` (kind, clamped percent, reset, optional model
  `group`, `displayLabel`/`id`/`sortKey`) / `ClaudeUsageLimitKind` / `ClaudeUsageLimitSnapshot` /
  `ClaudeUsageLimitStatus` / `ClaudeUsageLimitSource` / `ClaudeUsageLimitSourceMode` model the rows +
  fresh/stale/unavailable state with deterministic percent/reset formatting. Source-independent, so a
  future provider is additive.
- **Source A — Claude Desktop cache:** `ClaudeDesktopUsageCacheReader` scans
  `~/Library/Application Support/Claude/Cache/Cache_Data` **read-only** (small, recently-modified
  entries first; throttled), recognises the org `…/usage` entry by byte-scanning its key, decodes the
  zstd body, and parses only the whitelisted fields (`ClaudeDesktopUsageParser` — both the `limits[]` and
  top-level-window shapes). The real `limits[]` kinds are `session` (→ 5-hour), `weekly_all` and
  `weekly_scoped` (→ weekly); `is_active` is read but not used as a filter (Claude marks only the
  currently-binding row true), and a per-model row's name comes from `scope.model.display_name`, not the
  generic `group` bucket — so the all-models row shows plain "Weekly", never "Weekly · Weekly". zstd is a
  vendored decompress-only decoder (`Sources/CZstd`, BSD-3-Clause) behind a safe streaming wrapper with
  an output cap (`Zstd.swift`) — macOS ships no zstd.
- **Source B — Claude Code status line (mirrors the ADR 0008 hook pattern):** an opt-in statusLine shim
  (`Support/ClaudeUsage/vibemenu-usage-statusline.sh`, embedded as `ClaudeUsageStatusLineShim.source`)
  extracts **only** the whitelisted `rate_limits` fields via the system `/usr/bin/python3` and writes a
  VibeMenu-owned file (`…/VibeMenu/ClaudeUsage/usage.json`) atomically, wrapping any existing status
  line. `ClaudeUsageLimitFile.parse` is the malformed-safe whitelist decode.
- **Selection & persistence:** `CompositeClaudeUsageLimitReader` applies the source mode (Auto / Desktop
  / Claude Code); Auto prefers a fresh Desktop snapshot, else fresh Claude Code, else the newer stale
  one. Because Desktop's cache body is intermittent (200 → empty 304), the last good Desktop decode is
  persisted (normalised rows only — no org UUID/raw payload) by `ClaudeUsageLimitSnapshotStore` and shown
  aged/stale when the cache empties.
- **Wiring:** `ClaudeUsageLimitProvider` (a coarse ~5 s poll, self-gated on the default-off
  `showClaudeLimits` preference so off ⇒ zero I/O) feeds `ClaudeUsageLimitModel`, which the menu's
  `ClaudeLimitsView` renders as thin severity-tinted bars; `ClaudeUsageInstallModel` (app adapter)
  performs the preview-gated, backed-up, reversible `~/.claude/settings.json` write for the Claude Code
  source; `StatusLineInstaller` is the pure compose/wrap/uninstall logic. The Session Radar row design
  and the keep-awake loop are unchanged.

### AI Agent sessions + Codex Desktop sessions (opt-in)

The old Claude-only "Claude: …" status row is **gone**: there is **no textual status line at all**.
The menu's shared session section shows the Claude Code and (opt-in) Codex Desktop **session rows
directly**, most-active/recent first; when there are no eligible visible sessions, the section and its
dividers collapse completely rather than reserving an empty/status row. See
docs/decisions/0017-codex-session-support.md. Codex support is a **fresh** implementation from the
v0.2 baseline (the earlier attempt was unreliable and is not reused).

Since ADR 0017 **Amendment 3**, an **active** Codex session also feeds sleep prevention: Claude and
Codex activity flow into one shared keep-awake decision in `PowerAssertionModel` (a provider-neutral
`holdingSources` set), so either working agent holds the single "VibeMenu Keep Awake" IOKit assertion
and only *all* releasing drops it. Codex's contribution is the pure, conservative
`CodexSessionActivity.automationIntent` (only `.active` holds; it ages out on its own). This is separate
from `AutomationPolicy` — that older lid-open policy core still has **no** Codex field. Codex **usage
limits** remain display-only and never touch the loop.

- **No aggregate status type.** There is no `AgentStatus`/`AgentPresence` — the section renders rows,
  not a folded "Active/Idle/Not detected" word. The shared keep-awake decision (Claude + Codex session
  activity) lives in `PowerAssertionModel`; `AutomationPolicy`'s `PolicyInput` still has no Codex field.
- **Hideable rows (both providers).** Claude and Codex rows can be dragged right / right-clicked to
  hide; hidden rows are filtered *before* the shared cap/interleave, and hiding every row collapses the
  whole section (and its dividers) rather than forcing rows back or showing a misleading empty state.
  Hiding is display-only — it never changes whether an active session prevents sleep (the keep-awake
  decision reads the raw, un-hidden list).
- **Codex model (pure, tested):** `CodexSessionState` (`active`/`idle`/`done`/`stale`/`unknown`) +
  `CodexSession` (opaque `id`, state, `folderName` = basename of `cwd` only, safe `title`, real
  `startedAt`/`lastActivity`, `agent = "Codex"`). `CodexSessionState.derive(age:endedWithCompletion:)`
  is the conservative heuristic: `.active` only on very recent, non-completed activity; `.done` only on
  the reliable `task_complete` marker; otherwise it ages down to `.idle`/`.stale` — **no fake "working".**
- **Allowlist parser (pure, tested):** `CodexRolloutParser.parse(text:)` reads a strict allowlist of
  metadata from a rollout — `session_meta.{session_id/id, originator, cwd→basename, timestamp}`, per-line
  `timestamp`, and the *category* of `event_msg` lines (only to spot `task_complete`). It never reads any
  message/reasoning/tool body, the full path, `git.*`, `base_instructions`, account ids, or auth; the
  `CodexRolloutSummary`/`CodexSession` types structurally cannot hold that content. Malformed lines are
  skipped; a non-Desktop or meta-less file yields `nil`.
- **Safe titles (pure + adapter, tested):** a session's display name is a curated Codex title when one
  is safely available, else the project folder name, else a generic label. The title comes from
  `~/.codex/session_index.jsonl` — a small index whose lines are `{id, thread_name, updated_at}`.
  `CodexSessionIndexParser` reads **only** `id` + `thread_name` (allowlist), and every `thread_name`
  passes `CodexTitleSanitizer`, which drops anything empty/generic, multi-line, URL/git-remote-like, or
  path-like and length-caps the rest. This deliberately avoids `state_5.sqlite.threads.title`, which on
  real machines sometimes holds the **raw first user message** (multi-line prompt text/URLs), and needs
  no SQLite dependency. `CodexSessionIndexReader` does the bounded file read; `CodexSessionReader` joins
  titles to sessions by id.
- **Reader (adapter):** `CodexSessionReader` walks `~/.codex/sessions/**/rollout-*.jsonl`, opens only
  files whose mtime is within a 60-min horizon (a cheap stat), reads each under a byte cap (whole file, or
  head+tail for a pathological one), **gates on `originator == "Codex Desktop"`** (CLI ignored), dedupes by
  session id (newest activity wins), sorts most-active-first, caps, and attaches each safe title.
- **Presentation (pure, tested):** the menu merges Claude and Codex rows through
  `AgentSessionRadar.present(claude:codex:)`, which **interleaves** the two by activity within one
  shared compact 4-row budget (a stable two-way merge — most-active-first, never re-ordering a
  provider's rows among themselves). This replaced the earlier "all Claude first, then Codex fills the
  remainder" split, which starved Codex to zero rows whenever Claude filled the list. With Codex
  off/empty it reduces exactly to the previous Claude-only list. `CodexSessionRadar.disambiguate`
  still names/indexes Codex rows.
- **Wiring:** `CodexSessionProvider` (a coarse ~5 s poll, self-gated on the default-off
  `showCodexSessions` preference so off ⇒ zero I/O) feeds `CodexSessionModel`; the menu's
  `AgentSessionsSection` renders the interleaved Claude `SessionRow`s + Codex `CodexSessionRow`s (clear
  "Codex" pill), or the minimal empty-state line. Internal **subagent** rollouts (`source.subagent`) are
  dropped so they never phantom a row, and the Desktop-`originator` gate is case-insensitive. The
  keep-awake loop is untouched.
- **Codex usage limits (opt-in, shipped):** the real 5-hour + weekly `rate_limits` Codex writes to its
  rollout `token_count` events **is** a reliable, privacy-safe local source (present in every
  `token_count` event; a live re-investigation corrected the earlier claim that it was gone).
  `CodexRateLimitRollout` extracts ONLY the numeric `primary`/`secondary` `used_percent` + `resets_at`
  behind a `"rate_limits"`/`"originator"` substring pre-check (conversation lines are never parsed);
  `CodexUsageLimitReader` → `CodexUsageLimitModel` feed a `CodexLimitsView` mirroring Claude Limits.
  Default off, fail-closed to *unavailable*, staleness-labelled, storage/visibility separate from
  Claude. The internal debug/HTTP log (`logs_2.sqlite`, which does intermix prompts/auth) is **not**
  read. See docs/decisions/0017.

### `PowerAssertionManager`

Wraps public sleep-prevention APIs: `IOPMAssertionCreateWithName` with
`kIOPMAssertPreventUserIdleSystemSleep`, released with `IOPMAssertionRelease`.
Held while sleep prevention should be on, released otherwise. Surfaces active assertions
honestly (mirroring `pmset -g assertions`).

**Public, documented, no privileged helper, sandbox-tolerable.** Lid-closed
`disablesleep` is explicitly **not** here — see clamshell quarantine below.

**Today:** the manual and Claude/Codex-automation slice is real. A small three-layer seam in
`PowerAssertionManager.swift`, mirroring the thermal slice's shape:

- `PowerAssertionCreating` — a minimal syscall seam (`create`/`release`) with a real
  `IOKitPowerAssertion` backend and a spy double for tests, so the manager's logic is
  unit-tested without creating a real system assertion.
- `SystemPowerAssertionManager` (`PowerAsserting`) — holds **at most one** assertion;
  `preventIdleSleep()`/`allowSleep()` are idempotent, a failed creation stays safely
  `.acquisitionFailed` (no crash; logged via `os.Logger`), and `deinit` releases any held
  assertion.
- `PowerAssertionModel` — a `@MainActor @Observable` surface the `MenuBarExtra` binds to.
  It keeps `manualRequested` (the user's long-term switch preference) separate from
  `automationRequested` (temporary Claude/Codex ownership) and applies only
  `manualRequested || automationRequested` to the manager. Automation is driven by the
  keep-awake **intent** (`updateClaudeAutomation(_:)` / `updateCodexAutomation(_:)`): `.hold`
  records that agent as an owner, `.release` drops it — and it **never** mutates
  `manualRequested`, so manual keep-awake always wins (docs/decisions/0010). The single
  compact **Sleep prevention** row displays only the manual preference and remains interactive
  while automation is holding;
  Quit calls `cleanup()` to release before exit.

### `SystemStatus`

Eventually exposes thermal state, CPU, memory, and battery via public APIs:
`ProcessInfo.processInfo.thermalState` (+ `thermalStateDidChangeNotification`),
`host_statistics64` for CPU/memory, `IOPowerSources` for battery. GPU/package power
would require private IOReport and is therefore **out of the core** (optional,
direct-build-only, behind a flag, if ever).

**Today:** the **thermal** slice is real. A focused `ThermalStatusObserving` protocol
with a `SystemThermalStatusProvider` implementation reads
`ProcessInfo.processInfo.thermalState` and observes `thermalStateDidChangeNotification`
(public API, event-driven, no polling). A pure, failable
`ThermalPressureState.init?(_: ProcessInfo.ThermalState)` is the single mapping bridge
(unmappable future cases → `nil` → "Unknown" in the UI), and a main-actor `@Observable`
`ThermalStatusModel` republishes the value for the `MenuBarExtra`. CPU/memory/battery
remain deferred: `SystemStatusProviding` + `StubSystemStatus` (nominal) still stand as
the seam for the broader snapshot and can later consume the thermal provider.

## Public-API preference

VibeMenu uses only public, documented, sandbox-tolerable, non-root APIs. Any use of a
private API or root access:

- must be justified in a `decisions/` ADR,
- must be quarantined outside `VibeMenuCore` behind a protocol,
- forces direct distribution (App-Store-ineligible) — a known trade-off, see
  [`decisions/0004-direct-distribution.md`](decisions/0004-direct-distribution.md),
- requires explicit human approval.

## Codex support (status)

Codex **Desktop session detection** is now implemented as an opt-in layer beside the Claude monitor
(see *AI Agent sessions + Codex Desktop sessions* above, docs/decisions/0017). It reads only allowlisted
metadata from `~/.codex/sessions` rollout files. Since ADR 0017 Amendment 3, an **active** Codex session
feeds the shared keep-awake decision in `PowerAssertionModel` (alongside Claude) — but `AutomationPolicy`
itself stays Codex-free (its `PolicyInput` has no Codex field); the shared decision is a separate,
provider-neutral hold set. Codex **usage/rate limits** are also **shipped** (opt-in, experimental): a
live re-investigation found the rollout `token_count` events *do* carry a clean, structured `rate_limits`
object (5-hour + weekly `used_percent`/`resets_at`) — present in every such event, in the same files
session detection already reads — so VibeMenu extracts only those numeric fields behind a substring
pre-check and shows the two real windows. It never reads the `logs_2.sqlite` debug log (which intermixes
prompts/auth). Codex usage limits remain strictly **display-only** (they never affect sleep); both Codex
features are default-off, fail-closed, and version-fragile (framed Experimental).

## Headless closed-lid helper quarantine

Headless closed-lid operation is **out of scope for v0.3 and is not built** — no privileged helper
and no headless setting ship, and closing the lid may still sleep the Mac. Active feature development
is paused; whether it is ever pursued depends on real user demand, and it would be a separate, gated
effort under the rules below. Two short owner-run tests on the current Apple Silicon Mac showed
uninterrupted one-second logging while `SleepDisabled=1`, followed by confirmed restoration to `0` —
a historical, one-machine data point that establishes basic CPU continuity only; networking,
real-agent progress, long-duration thermal behavior, crash/reboot recovery, and cross-model support
were never verified.

Any production implementation would still need **root** to control the global kernel
`SleepDisabled` behavior and therefore must obey these rules:

- Live in a **separate, minimal, auditable helper module**, never in `VibeMenuCore`.
- Expose only a narrow authenticated, expiring lease API—no arbitrary commands, paths, scripts,
  or argument passthrough.
- Keep all agent interpretation and product policy unprivileged; the helper only enforces a
  bounded lease and safe cleanup.
- Require its own ADR, signing/notarization and installation decision, dedicated independent
  security review, and explicit human approval before code lands.
- Enforce hard guardrails: AC/battery policy, battery floor, thermal cutoff, maximum duration,
  app/helper crash handling, boot/uninstall reconciliation, and a watchdog that restores
  `disablesleep 0` when no valid lease exists.
- Resolve global-state ownership and coexistence with other sleep-management tools before go.

Until those gates pass, VibeMenu continues to hold lid-open assertions only.

## Testing strategy

- **Heavy unit coverage on `AutomationPolicy`** — truth tables over
  `mode × agent × thermal` (and later × battery). This is the correctness heart.
- **Future:** a fake-agent fixture (a script that appends to a temp JSONL and spawns a
  fake `claude` process) to verify activity detection without a real agent.
- **Future:** a no-network invariant test asserting no egress except the update check.

## Stack

Swift 6 (strict concurrency), SwiftUI-first with AppKit where needed, `MenuBarExtra` for
the menu bar, `LSUIElement = true` (in the `App/VibeMenu.xcodeproj` `.app` wrapper). SPM
modules for testability. macOS 15+, Apple Silicon first
([`decisions/0002-macos-baseline.md`](decisions/0002-macos-baseline.md)).

**Dependencies: none.** No SPM package dependencies at all. The only third-party code is a
vendored zstd **decompressor** (`Sources/CZstd/` — the official decode-only amalgamation, BSD,
© Meta), needed to read Claude Desktop's compressed local cache: macOS ships no zstd, and the
project rules forbid shelling out to a `zstd` binary or fetching one. Every future
dependency needs an ADR. There is no updater — ruled out by the no-network invariant — so there
is no Sparkle dependency and none is planned
([`decisions/0004`](decisions/0004-direct-distribution.md#amendment-1-2026-07-15--stay-unsigned-for-the-current-validation-phase)).
