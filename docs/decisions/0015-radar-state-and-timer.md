# 0015 — Session Radar: finished ≠ "Waiting", timer only while live, separator alignment

- **Status:** Accepted — refines [`0011`](0011-session-radar.md) (Session Radar) after manual testing.
- **Date:** 2026-07-06
- **Deciders:** Kirill Chistov (product owner, directed the change); implemented by Claude Code.
- **Builds on:** [`0011`](0011-session-radar.md) (per-session state), [`0008`](0008-claude-heartbeat-detection.md)
  (hook heartbeat), [`0010`](0010-quiet-work-hold.md) (`automationIntent`).

## Context

Session Radar shipped, and manual testing surfaced three issues:

1. **Separator dot misaligned.** In a row (`● Waiting · <title> · <timer>`) the "·" between the
   state word and the title looked awkwardly placed.
2. **Timer semantics confusing.** The elapsed timer was shown on *every* row, including finished
   ones, so a "Done" session kept a running clock — meaningless once the turn is over.
3. **"Waiting" was far too broad.** `derive` mapped `Stop`/`Notification`/`SessionStart` to
   `.waitingForInput` ("Waiting"), which sorted **above** working (priority 1 vs 2). But *almost
   every* Claude session finishes a turn and then waits for the next prompt; users move on and
   start new sessions, so these low-value "Waiting" rows piled up and pushed the sessions that were
   actually working out of the visible list — the opposite of the radar's job.

### Is real approval detection available? — No.

The only *actionable* waiting state is "Claude is blocked on a real approval / Allow–Deny
decision." Detecting that reliably needs the `Notification` hook's `notification_type`
(`permission_prompt`). VibeMenu's hook (`Support/ClaudeHeartbeat/vibemenu-claude-hook.sh`) records
only `{schemaVersion, updatedAt, event, sessionID, project}` — the **event name, not the subtype** —
and `0011` already documented that `notification_type` fires unreliably and the programmatic
Allow/Deny hook is unverified in our environment. So there is **no safe, verified approval signal
today**, and we will not fabricate one from ordinary events.

## Decision

Treat "finished and waiting for the next prompt" as ordinary **`.done`**, reserve the high-priority
lane for a *real* approval prompt, and only show the timer while a session is live.

1. **Remove the `.waitingForInput` state from `ClaudeSessionState`.** Its meaning folds into
   `.done`. `derive` now returns `.done` for `Stop`/`Notification`/`SessionStart` with a live
   process (rule 5) and for the no-process fresh-grace case (rule 2, then `.stale`). `SessionEnd`
   stays `.done`; working/quiet/stale/unknown are unchanged. Result: **no ordinary hook event ever
   produces a high-priority row** (a unit test asserts `derive` never yields a `needsAttention`
   state).

2. **`permissionRequested` becomes the reserved "Needs approval" lane** — relabelled from
   "Permission" to **"Needs approval"**, still sorted first (priority 0, above working) and styled
   for attention (orange dot + semibold). It remains **never produced** (the existing test still
   proves this) until an opt-in hook change records the `Notification` subtype. This is the
   documented future placeholder; approval detection is **not implemented**.

3. **Sort order** is now `permissionRequested → working → quietWorking → done → stale → unknown`.
   `.done` sits *below* the working states, so finished sessions can never outrank or crowd out an
   actively-working one — that guarantee comes from the sort order plus the `maxVisibleRows` cap,
   not from a done sub-cap. `doneVisibilityHorizon` (5 min) still drops stale finished rows so they
   don't accumulate.

   > **Follow-up (manual testing, 2026-07-06):** the original `maxDoneRows = 2` sub-cap, written
   > when `.done` was a rare terminal state, became wrong once this ADR made `.done` the *normal*
   > idle state: a list of 3–4 idle sessions was trimmed to 2 primary rows, the rest pushed into
   > overflow. Fix: `maxDoneRows` is now tied to `maxVisibleRows`, so done may fill the whole
   > visible list (up to 4). Actives still sort ahead of done, so no working row is ever hidden by
   > a finished one.

4. **Timer only while live.** New pure `ClaudeSessionState.showsElapsedTimer` — `true` for
   `working`/`quietWorking`/`permissionRequested`, `false` for `done`/`stale`/`unknown`. The row
   renders the elapsed label only when it's `true`, so a finished row shows **no** timer. Timer
   *semantics* are unchanged (elapsed since VibeMenu first observed the session — `0011`); only its
   *visibility* is gated. The compact `25s` / `1m 24s` / `1h 5m` format (`shortDuration`) is
   unchanged.

5. **Home-folder noise.** Because a finished untitled `$HOME` session is now `.done` (was
   `.waitingForInput`), the existing "hide untitled home-folder done/stale ghosts" rule now also
   hides finished untitled home-directory scratch launches — the direct fix for the "kirill 1/2"
   pile-up. Titled, real-project, and actively-working home-dir sessions still always show.

6. **Row layout (Issue 1).** The state-coloured dot, the state word, and the "·" separator are
   grouped into one fixed-width leading column (`.fixedSize()` + `minWidth`). Grouping makes the
   separator hug the word with a constant gap instead of drifting when a short word left-aligns in
   a wide frame, and reserves a stable column so titles line up while a long label ("Needs
   approval") can still grow rather than clip. Default `.center` alignment keeps both dots
   vertically centred with the text. Row height is unchanged.

**Invariants preserved.** No transcript-content reads, no network, no telemetry, no new data
source, no schema change, no title-resolver change. The keep-awake decision is **untouched**:
`ClaudeSessionState` is display-only, and `working`/`quietWorking` (the sole `holdsSleepPrevention`
states) are unchanged, so the `sessionsKeepAwakeIntent == automationIntent` equivalence test still
passes byte-for-byte. The separate `AgentActivityState.waitingForInput` (policy input, unrelated
enum) is not touched.

## Consequences

- The radar now leads with **working** sessions; finished ones are quiet, capped, timer-less
  context — matching how the tool is actually used.
- **"Needs approval" is aspirational until a hook change lands.** Users blocked on a permission
  prompt currently see `.done`, not a highlighted row. Enabling it needs an opt-in hook that
  records `notification_type` (a schema-3 add), plus tests — a separate, ADR-gated future slice.
  This is the honest trade: no fake "Waiting", rather than a misleading one.
- Losing the distinct blue "Waiting" style leaves `ClaudeSessionDisplayStyle.waiting` unused (kept
  for now; harmless, removable later).

## Non-goals (unchanged from 0011)

Real Allow/Deny detection, terminal/window jump, notch/pill UI, multi-agent, Accessibility,
AppleScript, UI scraping, network, notifications, hook-script/schema changes.
