# 0017 — Codex Desktop session detection + usage limits (opt-in, local-only)

- **Status:** Accepted — v0.3 feature. Codex **session detection** shipped; Codex **usage limits**
  **now also shipped** (opt-in) — see the **2026-07-10 Amendment** below, which reverses the original
  "no usage limits" decision after a live re-investigation found a safe source and a live debugging
  pass fixed session detection in the running app. **Amendment 3** (same day) further reverses the
  original "display-only for sleep" stance: an active Codex **session** now feeds the shared keep-awake
  decision alongside Claude, and Codex rows became hideable. Codex **usage limits** remain display-only.
- **Date:** 2026-07-10 (amended same day)
- **Deciders:** Kirill Chistov (product owner; requested a fresh Codex redo from the stable v0.2 baseline,
  authorised reading Codex's local session files under strict privacy limits, and — after the
  investigation below — chose to keep digging on usage limits while proceeding with the session +
  AI-Agent redesign). Investigated & implemented by Claude Code under the owner's authorization.
- **Builds on / relates to:** [`0011`](0011-session-radar.md) (per-session display layer),
  [`0012`](0012-session-name-from-cwd.md) (folder-name-only naming), [`0014`](0014-enhanced-desktop-titles.md)
  (opt-in, default-off reading of another app's best-effort local data with a whitelist),
  [`0016`](0016-claude-usage-limits.md) (local-only, real-or-nothing usage stance),
  [`0006`](0006-lightweight-resource-budget.md) (lightweight budget), AGENTS.md §6/§8 (no
  transcript-content reading; no network).

## Amendment — 2026-07-10 (live debugging + Codex Limits reversal)

A live-testing pass found the first cut of this feature **did not work in the running app**, and the
"no usage limits" conclusion below was **wrong**. Both were corrected:

**1. Session detection live-failure — root causes & fixes.** The pure `CodexSessionReader`/parser were
correct all along (verified in-process against live `~/.codex`: it returns the right sessions). The
failure was in the app layer:
  - *Feature was off / stale key.* The running build read a different `UserDefaults` key than the
    Settings toggle wrote, and the persisted defaults only held the **old** `usage-codex` build's keys
    (`showCodexSessionDetection`, `showCodexLimits`, `codexLimitsSectionExpanded`) — so detection was
    never actually enabled. Fixed by shipping/relaunching the current build (key `showCodexSessions`)
    and cleaning the orphaned key.
  - *Budget starvation.* `codexBudget = max(0, 4 − claudeRowCount)` gave Codex **zero** rows whenever
    Claude filled the shared 4-row list — exactly when testing VibeMenu while running Claude. Replaced
    by `AgentSessionRadar`, which **interleaves** Claude + Codex by activity within the same shared cap
    (product choice: keep one budget, fix ordering).
  - *Subagent rollouts.* Codex's internal subagent runs (`session_meta.source.subagent`) carry
    `originator == "Codex Desktop"` and passed the gate; now dropped so they never phantom a row. The
    originator gate is also case-insensitive now.

**2. Codex usage limits ARE achievable — the original "no safe source" finding was a measurement
error.** A live re-check found the rollout `event_msg`/`token_count` payload **does** carry a clean,
structured `rate_limits` object — present in **100% of `token_count` events across all rollouts**
(389 events, Jul 2–10), not "gone". Shape:
`rate_limits.{primary,secondary}.{used_percent, window_minutes, resets_at}` — `primary` = 5-hour
(`window_minutes` 300), `secondary` = weekly (`window_minutes` 10080). The whole `token_count` payload
is exactly `{type, info, rate_limits}`; `info` is all numbers; the only strings anywhere are
`"token_count"`, `limit_id:"codex"`, `plan_type:"<tier>"`. **No prompts/responses/tool output/auth/
account.** (The earlier ADR text — "no `rate_limits`; only in `logs_2.sqlite`" — was simply wrong;
`logs_2.sqlite` remains unsafe and is *not* used.)

**Decision (amended):** **ship Codex usage limits, opt-in.** `CodexRateLimitRollout` parses only the
numeric `used_percent`/`resets_at` of the two windows, behind a `"rate_limits"`/`"originator"`
substring pre-check so conversation lines are never JSON-parsed (the same guard that made the old
attempt safe — and why it "worked live"). `CodexUsageLimitReader` → `CodexUsageLimitProvider` →
`CodexUsageLimitModel` → `CodexLimitsView` mirror the Claude Limits plumbing but with **separate
storage** (`showCodexLimits`, `codexLimitsHiddenIDs`), default **off**, fail-closed to *unavailable*,
staleness-labelled, and only the two real windows (never per-model / invented rows). Menu order:
Claude Limits → Codex Limits → AI Agent sessions → Thermal, with the same divider rules
(`MenuVisibility` extended + tested).

**Why the original measurement was wrong:** unverified; most likely the earlier probe queried the
wrong field path or event type. The lesson: the shipped readers are now verified **in-process against
live data**, not just against fixtures.

## Amendment 2 — 2026-07-10 (redo: remove the status row; safe session titles)

A follow-up redo pass changed two user-facing things and confirmed a third. This **supersedes**
Decision point 2 below (the "unified AI Agent status row").

**1. No textual "AI Agent" status row.** The `AI Agent: Active/Idle/Not detected` line is removed
entirely, and with it the `AgentStatus` / `AgentPresence` type (it fed only that text). The AI Agent
section now shows **session rows directly**, most-active/recent first; when there are no eligible
sessions it shows a single minimal, muted **"No active sessions"** line (never "AI Agent: Idle"). The
section is still one `MenuVisibility` section gated by `showClaudeStatus`, so the divider rules are
unchanged and remain fully tested; the empty-state line keeps the section from ever being an empty box.
`AgentStatusSection` was renamed `AgentSessionsSection`. **Sleep prevention is unchanged** — it was
never driven by `AgentStatus`; it stays driven solely by Claude activity through `AutomationPolicy`,
whose `PolicyInput` has no Codex field, so Codex remains strictly display-only.

**2. Better, safe session titles.** Folder-name-only labels were weak. Codex Desktop keeps a curated
short title per thread in `~/.codex/session_index.jsonl` (lines of `{id, thread_name, updated_at}`).
VibeMenu now joins that to the rollout session by `id` and shows `thread_name` — reading **only** those
two fields (`CodexSessionIndexParser`) and passing every title through `CodexTitleSanitizer`, which
rejects anything empty/generic, multi-line, URL- or git-remote-like, or path-like (and length-caps the
rest). Fallback order: **safe title → folder basename → generic "Codex session".** We deliberately did
**not** use `state_5.sqlite` `threads.title`: on real machines ~1 in 8 user threads had `title` set to
the **raw first user message** (multi-line prompt text, URLs, thousands of chars — it equals the
`first_user_message`/`preview` columns), and it would add a libsqlite3 dependency. `session_index.jsonl`
is a plain JSONL file (reuses the existing parsing posture), already excludes subagents, and its
`thread_name` is the curated title.

**3. Codex Limits confirmed rollout-only.** No change: usage limits still come solely from the rollout
`token_count.rate_limits` numeric fields (Amendment 1); `logs_2.sqlite` is never read.

---

## Amendment 3 — 2026-07-10 (Codex sessions feed sleep prevention; hideable Codex rows)

Two fixes from manual smoke testing. This **reverses** the original "Codex is strictly display-only for
sleep" stance (Decision point 1, and Amendment 2 point 1's closing sentence) and extends the hide
gesture to Codex rows.

**1. Codex session activity now prevents sleep (shared agent-activity decision).** Previously only
Claude activity could hold VibeMenu's keep-awake assertion; a running Codex task did not, so
`pmset -g assertions` showed nothing. Now Claude **and** Codex feed one shared decision:

- A provider-neutral hold set lives in `PowerAssertionModel` (`holdingSources: Set<AgentKeepAwakeSource>`,
  `.claude`/`.codex`). Each agent independently holds/releases via `updateClaudeAutomation` /
  `updateCodexAutomation`; the effective automation request is simply "any source holding". The single
  IOKit assertion (`kIOPMAssertPreventUserIdleSystemSleep`, name **"VibeMenu Keep Awake"**) is held while
  either agent is working and dropped only when **all** release. Manual keep-awake still wins over all of
  it; `manualRequested` is never mutated by automation. Claude's path is byte-for-byte unchanged — it is
  now just one possible source. This deliberately does **not** touch `AutomationPolicy` (the older,
  Claude-independent lid-open policy core), which keeps its no-Codex `PolicyInput`.
- Codex's hold is computed by the pure `CodexSessionActivity.automationIntent(_:)`: **only** a session
  VibeMenu currently reads as `.active` holds; `.idle`/`.done`/`.stale`/`.unknown` release. Because
  `.active` requires *very recent* rollout activity (≤ `activeWindow`, 60 s) and the reader re-derives
  state every tick, the hold has a natural bounded lifetime and drops on its own once a session goes
  quiet — no separate cap, and no risk of keeping the Mac awake forever.
- Gating: when `showCodexSessions` is off the provider publishes `[]` (it self-gates before any file
  access), so the intent is `.release` and Codex cannot affect sleep at all. Stale/missing/unavailable
  data is likewise `[]` ⇒ `.release`. Only session *activity* feeds this — never Codex **usage limits**
  (which stay strictly display-only) and never usage-limit refresh timestamps.
- The keep-awake decision reads the **raw** session list (`CodexSessionModel.sessions` via
  `onSessionsChange`), not the user-hidden view, so hiding a row from the menu never changes whether an
  active Codex session prevents sleep.

**2. Codex rows are hideable by swipe (Fix 2).** `CodexSessionRow` gained the same drag-right /
right-click "Hide from VibeMenu" gesture as Claude's `SessionRow`, backed by a `DismissedCodexRegistry`
(the Option-2 watermark logic, mirroring Claude, keyed on the **stable opaque session id** so a title
change never un-hides a row). `CodexSessionModel` now exposes `visibleSessions` (raw minus dismissed);
the menu interleaves/caps the **visible** lists, so hidden rows are filtered *before* the shared cap and
can never be forced back by overflow/interleave. When the user hides every row, the app folds the AI
Agent section's effective visibility to `false` (`agentSessionsHasContent`, mirroring the Limits
sections), so the section and its dividers collapse cleanly instead of showing a misleading "No active
sessions" — that line now appears only when there are genuinely no sessions.

---

## Amendment 4 — 2026-07-12 (schema-driven Codex usage limits; confirmed `rate_limits` schema)

Amendment 1 shipped Codex usage limits under a **fixed two-window assumption**: `rate_limits.primary`
was hard-coded to the 5-hour row and `rate_limits.secondary` to the weekly row, labels came from that
slot **position**, and `window_minutes` was ignored. A fresh investigation of the approved local
rollout data proved that assumption **wrong**, so the reader/parser/model are now **schema-driven**:
they show exactly the windows the newest reading exposes and label each from its own duration.

**Confirmed `rate_limits` schema (68 rollout files, 1226 `token_count` events over ~11 days; only
`rate_limits` structure + `session_meta.originator` were read — no message content).**

- Each `token_count` `event_msg` carries `rate_limits`. Its **window** children are keyed `primary`
  and/or `secondary`; every window object carries exactly `{ used_percent, window_minutes, resets_at }`
  (100% of windows). `window_minutes` values seen: **300** (5-hour) and **10080** (weekly = 7 days).
- The window set is **not fixed**: observed latest-reading shapes were `[primary, secondary]` (60
  files), `[primary]` **only** (2 files), and readings also carrying a sibling `credits` object (6
  files). Empty `rate_limits` (`{}`) also occurs transiently.
- **`primary`/`secondary` are NOT stable in meaning.** In 17 events the lone `primary` window had
  `window_minutes == 10080` — i.e. `primary` was the **weekly** window. So a positional label is a
  latent falsehood. (Confirmed live: at implementation time the newest real reading was a single
  `primary` window with `window_minutes 10080`; the old code would have mislabeled it "5-hour limit",
  the new code correctly shows "Weekly".)
- `credits` is `{ balance, has_credits, unlimited }` — **not** a usage window (no `used_percent`,
  no `window_minutes`). It must be excluded.
- Within a single file, a window present in an earlier `token_count` was **never** dropped by a later
  one (within-file window-drop count: 0) — but the requirement is to honour a drop if it ever happens.
- Originators present: **`Codex Desktop`** (64 files) **and `codex_work_desktop`** (4 files). The
  committed exact-match gate (`isDesktopOriginator == "Codex Desktop"`) therefore **rejected legitimate
  Desktop rollouts** (their sessions *and* usage limits), so the gate is widened (below).
- Opening Codex's in-app usage view is a read; it does not append a `token_count` turn, so it does not
  change the local rollout data (reasoned from the schema — a viewing action is not an assistant turn;
  not independently driven).

**Decision (amended): make Codex usage limits schema-driven.**

- **Model.** `CodexUsageLimitKind` (the fixed `fiveHour`/`weekly` enum) is removed. A `CodexUsageLimit`
  is now `{ windowMinutes: Int?, slot: String, usedPercent, resetsAt }`. Identity, label, and order all
  derive from `windowMinutes` — never from the slot. `label(windowMinutes:)`: 300 → "5-hour limit",
  10080 → "Weekly", other exact durations → truthful "N-hour/day limit", and a duration-less window →
  the **neutral** "Usage limit" (never a fabricated duration). `visibilityID` keeps the legacy
  `fiveHour`/`weekly` ids for the two known durations (so existing hide choices survive), else `win-<m>`
  / `slot-<key>`. Rows sort shortest-window-first, ties by slot then id.
- **Parser (`CodexRateLimitRollout`).** `parseWindows(_:)` treats **any** `rate_limits` child with a
  numeric `used_percent` as a window (reading only `used_percent` + numeric `window_minutes` +
  `resets_at`, plus the structural slot key). This excludes `credits` (no `used_percent`), copes with
  one/two/N windows, and is positional-agnostic. `parseLatest` takes the windows **verbatim from the
  single newest *authoritative* `token_count` — it never merges or carries a window forward**, so a
  window Codex stops exposing simply disappears (no resurrection). (This **replaces** Amendment 1's
  carry-forward behaviour.)
- **Authoritative-empty semantics (corrected 2026-07-12).** A `token_count` whose `rate_limits` is a
  valid JSON **object** is authoritative *even when it yields zero qualifying windows* (empty `{}`, or
  only non-window siblings like `credits`): it truthfully reports "Codex exposes these windows now" —
  possibly none — so it **clears** previously-shown rows, and a newer authoritative-empty reading
  **wins over** an older rollout that still had windows. Only a **missing** `rate_limits`, a non-object
  `rate_limits`, or a malformed line is **ignored** (it can neither add nor clear rows); a rollout with
  no valid `rate_limits` object at all yields **no** reading (`parseLatest` returns `nil`), so it can't
  masquerade as an authoritative-empty reading and wrongly clear rows. (This **corrects** the earlier
  cut of Amendment 4, which wrongly skipped empty/credits-only readings and preserved stale rows. The
  reader no longer gates candidates on "has ≥1 window".) `hasLimits == false` is now a *valid*
  authoritative state (empty), not "no reading".
- **Row identity vs visibility identity.** A snapshot can hold two distinct windows of the **same**
  duration (different slots), which would collide on the duration-derived id. So the SwiftUI-`Identifiable`
  `id` is now `"<visibilityID>#<slot>"` (slots are unique `rate_limits` keys), while `visibilityID`
  stays duration-derived so hide/show preferences remain stable across sessions. The app uses
  `visibilityID` for persistence and `id` only for `ForEach`.
- **Originator gate.** `isDesktopOriginator` now accepts the canonical `"Codex Desktop"` **and** the
  anchored underscore family `codex_<segment…>_desktop` (e.g. `codex_work_desktop`). It stays a **narrow
  allowlist** anchored at both ends — `codex_cli_rs` and anything merely containing "desktop" are still
  rejected. Because this gate is shared with session detection, `codex_work_desktop` **sessions** now
  also become eligible (correctly — they are real Desktop sessions), which can feed the shared keep-awake
  decision; Codex **usage limits** remain display-only.
- **Unchanged & preserved.** The two-layer privacy boundary (substring pre-check + numeric allowlist)
  holds — `window_minutes` is the only newly-read field and it is numeric; `plan_type`/`limit_id`/
  `credits`/`info`/message bodies are never read. Fail-closed to `.unavailable`, staleness labelling,
  bounded head+tail reads, opt-in + default-off, separate storage, and display-only (no sleep path) are
  all unchanged. The app UI needed **no** logic change — `CodexLimitsView` already iterates
  `snapshot.limits`.

**Testing (added/updated).** Sanitized fixtures only. New/rewritten coverage: one exposed limit;
multiple limits; a `primary`-slot window that is really weekly (positional independence); changed/
unknown/absent `window_minutes` (truthful vs neutral labels); `credits` excluded; **authoritative
empty** — a latest empty/credits-only reading clears rows, and a newer authoritative-empty rollout
beats an older one with limits — while a **missing/malformed** later `rate_limits` does **not** clear a
valid earlier reading; two same-duration slots get **unique row ids**; **no within-file resurrection**
and **no cross-file resurrection** of a dropped window; malformed/non-numeric data; CLI + subagent rollouts
ignored; the `codex_work_desktop` originator accepted while `codex_cli_rs`/look-alikes rejected;
provider enable/disable gating (disabled ⇒ no file I/O) and model auto-refresh (including collapsing to
empty when windows vanish); and the existing strict privacy proof extended to the `credits` object.

**Verification.** `swift build` clean; `scripts/test.sh` **562 tests in 89 suites** passed; `xcodebuild
… -configuration Debug build` → `** BUILD SUCCEEDED **`; `git diff --check` clean. An in-session
four-lens adversarial review found and fixed two issues before finalizing — a **fail-closed crash**
(`Int(Double)` trapping on an out-of-range `window_minutes`, now range-guarded ⇒ neutral label) and a
`window_minutes ≤ 0` inconsistency (now normalized to a duration-less window). The shipped
`CodexUsageLimitReader` was run **in-process against the real `~/.codex`** and rendered exactly one
truthful row — "Weekly · 0% · Resets Sun 10:06 PM" from `slot=primary window_minutes=10080` — proving
the positional fix on live data. The freshly-built Debug `.app` launched cleanly (no crash). See the
matching `docs/DEVELOPMENT_LOG.md` entry.

**Still open.** A different-model (Codex) review per AGENTS.md §18 is recommended before the owner
signs off (this pass was implemented by Claude Code with an in-session adversarial review). The
"opening the usage UI doesn't change local data" point is reasoned from the schema, not driven live.

---

## Context

We want to (a) show **Codex Desktop** coding sessions beside Claude sessions, and (b) — if a reliable,
privacy-safe local source exists — show Codex usage limits. A prior attempt (not on this branch) was
unreliable: its Codex usage numbers were wrong live, and its session detection was untrustworthy. This
ADR records a **fresh** investigation and implementation from the stable v0.2 tag, reusing none of the
prior code.

Hard constraints (unchanged from the app's invariants): **local files only**, **no network / cookies /
API keys / auth extraction**, **no prompt/response/tool-output reading**, **no fabricated data**, and
Codex detection must be **display-only** (it must never influence sleep prevention — a false "active"
must not keep the Mac awake).

### Investigation (redacted diagnostics only; no real data retained)

Paths inspected: `~/.codex/sessions/**/rollout-*.jsonl` (30 files, all `originator == "Codex Desktop"`);
`~/.codex/.codex-global-state.json`, `session_index.jsonl`, `config.toml`, `state_5.sqlite`,
`logs_2.sqlite` (schema only); `~/Library/Application Support/Codex/` (Chromium profile — Local State,
Local Storage / IndexedDB leveldb); `~/Library/Caches/com.openai.codex/` (Cache.db + wal + fsCachedData);
`~/Library/Preferences/com.openai.codex.plist`.

**Usage limits — no safe source.**
- The rollout `event_msg`/`token_count` `info` carries **only** `total_token_usage`, `last_token_usage`,
  `model_context_window` — **no `rate_limits`** (structured `rate_limits` key count across all rollouts:
  0). Deriving 5-hour/weekly percentages from token counts is fabrication — the prior bug.
- No rate-limit data in `global-state.json` (only a `rate-limit-reset-…-dismissal` boolean), the
  session index, `config.toml`, the Chromium profile (Local Storage/IndexedDB), or the HTTP caches.
- The **only** place real `rate_limits`/`used_percent`/`window_minutes` appear on disk is
  `logs_2.sqlite` `logs.feedback_log_body` — a raw debug/HTTP log (28k+ rows) that intermixes prompts,
  responses, tool output, `x-codex-*` headers, auth, and account ids. It is **not allowlisted-safe**,
  is **ephemeral** (rotating `logs_N`), and reading it would violate AGENTS.md §6/§8.

**Session detection — reliable, safe source exists.** Each rollout is newline-delimited JSON with a
`{timestamp, type, payload}` envelope. `session_meta.payload` provides safe metadata — `session_id`/`id`,
`originator` (`"Codex Desktop"` distinguishes the Desktop app from the shared CLI), `cwd` (basename
only), and a start `timestamp` — every line carries an ISO `timestamp` (reliable last-activity), and a
`task_complete` `event_msg` (present in 29/30 files) is a reliable completion marker.

## Decision

1. **Ship Codex Desktop session detection** — opt-in (`showCodexSessions`, default off), **display-only**.
   A pure `CodexRolloutParser` reads a strict allowlist (`session_id`/`originator`/`cwd`→basename/
   timestamps + `event_msg` *category* to spot `task_complete`) and nothing else. `CodexSessionReader`
   walks `~/.codex/sessions`, mtime-filters to recent files, reads under a byte cap, **gates on
   `originator == "Codex Desktop"`** (CLI ignored), dedupes, sorts, caps. `CodexSessionState.derive`
   is conservative — `.active` only on very recent non-completed activity, `.done` only on the
   `task_complete` marker, else `.idle`/`.stale`; **no fake "working".** It has **no** keep-awake hook.

2. **Replace the Claude-only status row with a unified "AI Agent" row.** *(Superseded by Amendment 2 —
   the textual status row and `AgentStatus` are removed; the section shows session rows directly with a
   minimal empty-state line.)* `AgentStatus.evaluate` folded each enabled provider's presence into one
   status; `AgentStatusSection` rendered the row, then Claude `SessionRow`s (unchanged, with dismiss +
   overflow), then Codex `CodexSessionRow`s with a clear "Codex" pill, sharing one compact 4-row budget.

3. **Do not ship Codex usage limits.** *(Superseded by Amendment 1 — a safe rollout source was found;
   usage limits shipped, opt-in.)* The original stance was "real-or-nothing" from ADR 0016: show **no**
   Codex Limits section rather than a fabricated or debug-log-derived one.

Preferences are kept **fully separate** from Claude (`showCodexSessions`); nothing Codex is persisted.

## Consequences

- Codex sessions appear in the menu only when the user opts in; off ⇒ zero file I/O.
- The status row is now agent-agnostic; existing `MenuVisibility` section/divider logic is unchanged
  (the AI Agent area is still one section gated by `showClaudeStatus`).
- No Codex usage feature. If OpenAI later persists rate limits to a safe local file, an additive reader
  can slot behind the same provider/model plumbing without reopening this decision.
- Reads another app's local files whose format may change; on any change VibeMenu simply shows no Codex
  rows (fails closed).
- Version-fragile like the Desktop-title source (0014); flagged in Settings as Desktop-only and
  experimental.

## Alternatives considered

- **Derive Codex limits from `token_count`** — rejected: fabrication (no `rate_limits` present).
- **Read `logs_2.sqlite` for real limits** — rejected: privacy-hostile (prompts/responses/auth) and
  ephemeral/unreliable.
- **Read `state_5.sqlite` `threads` table for sessions** — viable and structured, but its `title`/
  `preview`/`first_user_message` columns are prompt-derived, and it is the Desktop app's internal DB.
  The rollout `session_meta` path is the documented artifact the task pointed at, is trivial to gate by
  originator, and exposes only folder-name-safe metadata — so it was chosen.
- **Keep a "Codex Limits — unavailable" placeholder** — rejected as clutter for a section that can
  never show data.

## Privacy

Local files only; no network, cookies, API keys, or auth (`~/.codex/auth.json` is never touched). Only
allowlisted metadata is read: session id (never shown), originator (gate), folder **name** (basename of
`cwd`, never a path), activity timestamps, and the `task_complete` category. Never read/surfaced:
prompts, responses, reasoning, tool input/output, command text, full paths, repo URLs (`git.*`),
`base_instructions`, account ids, tokens. Since Amendment 3, an **active** Codex session may hold the
keep-awake power assertion (shared with Claude) — a purely local, metadata-derived decision that reads no
additional data; Codex **usage limits** remain display-only. See [`../PRIVACY.md`](../PRIVACY.md).

## Testing

Pure, fixture-driven (synthetic rollouts + a synthetic `session_index.jsonl` — no real `~/.codex`
data): parser allowlist + a privacy test that feeds a rollout (and an index) deliberately stuffed with
prompts/responses/tool/reasoning/git/account/auth and asserts none surfaces; CLI-ignored gate; folder-
name fallback; the `CodexTitleSanitizer` (drops multi-line / URL / git-remote / path / generic titles,
length-caps) and title→folder→generic resolution joined by id; malformed/large/missing-file safety;
`derive` active/idle/done/stale heuristics; the interleave presenter across none/Claude/Codex/both with
an empty-presentation case (drives the "No active sessions" fallback — there is no status row); the shared
budget/caps/disambiguation. Existing Claude Session Radar and Claude Limits tests remain green.

Amendment 3 adds: `CodexSessionActivity.automationIntent` (active holds; idle/done/stale/empty release);
`PowerAssertionModel` shared-source tests (Claude-only unchanged, Codex-only holds, Codex disabled/release
does not hold, Claude+Codex held until both release, manual wins, cleanup clears all, and an invariant
documenting that Codex *usage limits* have no path to the sleep loop); `DismissedCodexRegistry` (hide/
un-hide, stable-id-across-title-change, hide-all); and `CodexSessionModel` hide tests (hide-all leaves no
visible rows while the raw power-loop list is untouched, hidden filtered before the cap, revive on newer
activity). Codex is still **not** an `AutomationPolicy` input — the shared decision lives in
`PowerAssertionModel`, and `AutomationPolicy.PolicyInput` keeps no Codex field.

## Amendment 5 — 2026-07-18 (centralized bounded Recent sessions expansion)

The shared presenter already interleaved Claude and Codex for the four-row primary list, but the
menu still exposed Claude's bounded overflow separately from a provider-specific Codex count. That
made the same shared list behave differently depending on which provider overflowed.

### Decision

- `AgentSessionRadar.Presentation` owns one provider-neutral shape: `items`, `overflowItems`,
  `hiddenCount`, and `olderHiddenCount`.
- The primary `items` list remains the existing shared four-row prefix and uses the existing
  cross-provider bucket/recency comparison unchanged.
- The presenter builds the hidden Claude stream from rows bumped by the shared cap plus Claude's
  already-eligible bounded overflow, and the hidden Codex stream from the reader-provided,
  provider-filtered, user-visible session list. It merges those streams with the same comparison and
  reveals at most `SessionRadar.maxOverflowRows` (10) rows.
- `hiddenCount` is the total eligible remainder from both providers. `olderHiddenCount` is the
  provider-neutral remainder after the ten-row expansion bound; it is shown only when expanded.
- The SwiftUI section renders one collapsed `+N more recent session(s)` control and, when expanded,
  one `Recent sessions` list. Each item still selects the existing Claude or Codex row view, so
  provider pills, activation, drag-right hiding, context-menu hiding, and provider-specific naming
  remain intact. The local expansion state still resets when the menu content is recreated.

This is a single centralized, bounded recent-session expansion. It is a display affordance, not a
session-history screen, persistent queue, search surface, or new provider setting.

### Consequences

Claude's age, home-noise, unknown, Done, and Stale eligibility rules remain in `SessionRadar`; Codex
reader recency and provider filtering remain in `CodexSessionReader`; user-hidden sessions remain
filtered before presentation. There are no provider-specific overflow counters in the shared model
or menu. The bounded input supplied by Claude's presenter is sufficient for the first ten shared
overflow positions; any older eligible remainder is counted but not materialised.

### Testing

Pure `AgentSessionRadar` tests cover Claude-only and Codex-only expansion, mixed ordering, active
Codex versus Done Claude ranking, higher-priority hidden Claude rows, the four/ten row caps, combined
and older counts, singular/plural count values, no-overflow behavior, and the fact that filtered
hidden rows cannot reappear.
