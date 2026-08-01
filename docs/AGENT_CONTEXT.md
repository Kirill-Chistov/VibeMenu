# VibeMenu — Agent Context

Canonical, concise handoff for this repo. Keep this current-state focused.
Use [`DEVELOPMENT_LOG.md`](DEVELOPMENT_LOG.md) for chronology and [`decisions/`](decisions/)
for design decisions.

> **This is the public open-source source repository.** Treat every commit, comment, and
> document as public: no personal absolute paths, private data, or internal-only shorthand.
> Tagged releases correspond to their attached binaries; `master` may later move ahead of the most recent tag.

## Product summary

VibeMenu is a lightweight, local-only macOS 15+ Apple Silicon menu-bar app. It keeps the
Mac awake while Claude Code or an active Codex Desktop session is working, releases the
power assertion when work finishes, and — **for Claude only** — uses a bounded quiet-work hold
(15 minutes by default) to cover silent builds, tools, or subagents. Codex has no heartbeat, so
it holds only while it looks active (~60s window) and gets no quiet-hold. It also provides a compact Session
Radar, coarse thermal status, optional Launch at Login, and opt-in, default-off usage-limit
previews. It is Apache-2.0 licensed; the name, logo, and brand assets are separate.

## Repository boundaries and rules

- **This public repo (`Kirill-Chistov/VibeMenu`) is the source of truth.** Source, tests,
  support scripts, product docs, ADRs, and release packaging all live here. Work relative to
  the repo root; never write an absolute personal path into a tracked file.
- A separate release/marketing wrapper repo exists (`Kirill-Chistov/VibeMenu-Public`). It is
  **out of scope**: do not edit it. Its future is the owner's decision.
- Do not commit or push unless the product owner explicitly requests it. Never rewrite history
  or discard existing user changes.
- Preserve `CLAUDE.md`'s workflow rules; correct it only where an explicitly scoped task or a
  factual error requires it (see git safety rule 4). Read `AGENTS.md` first; the human product
  owner owns product, architecture, privacy, and release decisions.
- Keep changes small and scoped. Any non-trivial product, architecture, privacy, or release
  change needs a proposal/approval and an ADR where appropriate.
- **Everything here is public.** Assume any file you touch will be read by strangers evaluating
  whether to trust the app with their machine. Describe repository and release state factually: a tag
  names the exact source that produced its attached binary, and `master` may sit ahead of the latest tag.

## Current feature set

- Menu-bar-only SwiftUI app (`MenuBarExtra`, `LSUIElement`); no Dock icon and no main window,
  but there is a Settings scene/window (`VibeMenuApp.swift`).
- Manual keep-awake override and one automatic public power assertion driven by Claude activity and
  active ChatGPT desktop sessions; manual mode wins. The menu shows the actual assertion state and its
  current owners in the order Manual → Claude → Codex → ChatGPT Work, including acquisition failure.
  The app's two modes are **independent** owners, so one finishing never releases a hold the other
  still needs. The manual switch always remains interactive and changes only manual ownership.
  Usage-limit refreshes never affect sleep prevention.
- Claude detection from process/file metadata, with an optional user-installed Claude
  heartbeat hook for reliable working/waiting states. The hook is never installed
  automatically. When no session's newest heartbeat record is still inside the 600s stale window
  (never installed, or the hook stopped writing — stale leftover files do **not** count), automatic
  Claude keep-awake degrades to a bounded L1 fallback (visible process + `~/.claude` metadata inside
  the 10s recency window ⇒ hold; no quiet-work extension). A *recent* record — including a finish —
  keeps heartbeat state authoritative. The Session Radar stays heartbeat-only and fabricates no row
  ([ADR 0010 amendment](decisions/0010-quiet-work-hold.md)).
- Shared Session Radar for Claude and Codex Desktop: a four-row interleaved primary list plus one
  centralized bounded Recent sessions expansion (up to ten extra rows), working/quiet/waiting/
  done/stale states, elapsed time, safe titles/folder names, and per-row hide.
  Claude Desktop approval prompts surface as **Needs approval** from the opt-in
  `PermissionRequest` heartbeat event; Allow clears on the next lifecycle event, while Deny
  may linger until the next event or the 30-minute prune. Hook users also recognize Claude
  Code's documented `StopFailure` event as a finished, non-holding turn, so API-error endings
  become **Done** and release sleep prevention instead of leaving the preceding work event to
  age into **Quiet**. Codex CLI sessions and internal subagent rollouts are excluded.
- Coarse macOS thermal state (Nominal/Fair/Serious/Critical), row visibility preferences,
  Launch at Login through public `SMAppService`, and compact Settings with Claude/Codex
  disclosures.
- Opt-in Claude limits: real 5-hour/weekly data from the Claude Desktop cache or a
  Claude Code `statusLine` capture; Desktop may also provide per-model weekly rows.
- Opt-in ChatGPT limits: real `rate_limits` data from the ChatGPT desktop app's rollouts, schema-driven
  rather than a fixed 5-hour/weekly pair — each row derives its label from the window's own reported
  duration and disappears when the app no longer exposes that window. Both usage features are
  display-only, fail closed, and off by default.
- **Unified ChatGPT app (verified 2026-07-28, ADR 0017 Amendment 6).** The one app's **Work** and
  **Codex** modes both write to the already-approved rollout tree and session index, and both pass the
  existing Desktop-originator gate (`codex_work_desktop` / `Codex Desktop`). Sessions surface as
  independent rows with a derived **ChatGPT Work**/**Codex** pill — the raw originator never reaches
  the UI — and the two modes share **one** `ChatGPT limits` section, since they report the same
  server-side allowance. A new limits reading is written only by a real Work or Codex turn; opening the
  app or its usage screen writes none. The user-visible provider is named **ChatGPT** (Settings group,
  `Track ChatGPT sessions`, `ChatGPT limits`), while every storage key, internal type name, and data
  source is unchanged; notification titles still use `AttentionProvider.displayName` (`OpenAI`).
  For sleep prevention the two modes are **separate owners** (`AgentKeepAwakeSource.codex` /
  `.chatGPTWork`), derived per mode from the same raw list, so one mode finishing cannot release the
  shared assertion while the other is still working.
- **No `Experimental` badge on either limits section.** Claude limits and ChatGPT limits stay opt-in
  and default-off, and keep every honest explanation (local-only source, best-effort/version-fragile
  framing, "as of" staleness, no-network limitation, shared allowance, honest unavailable state) —
  only the visible classification chip was removed.

## Privacy boundaries

- Local-only: no backend, account, telemetry, analytics, cookies, Keychain, API keys,
  auth tokens, or network requests. Only public macOS APIs are used for the current product.
- Never read, store, log, or upload prompt text, responses, reasoning, tool input/output,
  `lastPrompt`, message bodies, project files, or full working-directory paths.
- The only transcript exception is the matching Claude session title record (`custom-title`
  or `ai-title`). Claude Desktop title lookup is opt-in and allowlisted; Codex titles come
  only from the safe `thread_name` index field after sanitization. Titles stay in memory.
- The optional Claude hook stores only schema/event/timestamp/session id plus the final
  project folder name. It never stores the full `cwd`.
- New data access is not implied by an existing parser. Widening any allowlist requires
  human approval and an ADR.

## Local data sources used

- Public process inspection (process name only), thermal/system status, and file metadata.
- Claude: existence/mtime under `~/.claude` (including projects/history metadata); the
  matching transcript only for its title record; optional own heartbeat files under
  `~/Library/Application Support/VibeMenu/ClaudeHeartbeat/sessions/`.
- Claude titles, only when enabled: `~/Library/Application Support/Claude/claude-code-sessions/`
  `local_*.json` files, using whitelisted title/id/activity/archive fields.
- Claude usage: read-only recent entries under
  `~/Library/Application Support/Claude/Cache/Cache_Data/`, or VibeMenu's own
  `~/Library/Application Support/VibeMenu/ClaudeUsage/usage.json` written by the opt-in
  status-line shim. Explicit setup may modify `~/.claude/settings.json` after preview and
  backup; the heartbeat hook remains manual and is never installed by VibeMenu.
- Codex Desktop: recent `~/.codex/sessions/**/rollout-*.jsonl` data from allowlisted
  fields only, plus `~/.codex/session_index.jsonl` `id`/safe `thread_name` for titles.

## Forbidden data sources

- Claude or Codex transcript/message content, prompt/response/tool/reasoning fields, raw
  `cwd`, git metadata, URLs, or account data.
- Codex `~/.codex/logs_2.sqlite`, `~/.codex/state_5.sqlite` for titles, and
  `~/.codex/auth.json`; all browser cookies, Keychain data, and credential stores.
- Direct Claude/OpenAI network endpoints, web scraping, token estimation, or any new local
  database/cache source not explicitly approved. `logs_2.sqlite` is especially forbidden
  because it can mix prompts and authentication-related data.

## Build and test commands

Run from the repo root:

```sh
swift build
scripts/test.sh
xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build
```

For a release candidate, also run the Release build and
`scripts/package-github-release.sh <version>`. Prefer `scripts/test.sh` to plain
`swift test`; it handles Command Line Tools-only Swift Testing paths. Never claim a build,
test, or launch that was not actually run. Append implementation validation to
`DEVELOPMENT_LOG.md`.

## Current ChatGPT / Claude / Codex workflow

- **ChatGPT planning/review chat:** product decisions, prioritization, research, compact KERNEL
  prompts, result review, and handoff maintenance. This chat does **not** implement features or
  fix bugs; a separate implementation chat performs repo changes and verification.
- **Claude Code:** primary scoped implementation agent in this repo; follows
  `AGENTS.md` and `CLAUDE.md`, runs real checks, and records the result in the development log.
- **Codex:** independent implementation or review pass on a separate branch/worktree when
  useful, especially for risky power, privacy, parser, or no-network changes. The reviewer
  must be a different model from the implementer.
- Every agent hands off the diff, commands/results, verified vs. unverified behavior, and
  next step. Product approval remains with the human.

## Prompting standard

Use a compact KERNEL-style structure for future Claude/Codex prompts:

- **Goal:** one concrete outcome per prompt.
- **Context:** only task-relevant facts; rely on `AGENTS.md`, `CLAUDE.md`, this handoff, and live repo inspection for the rest.
- **Constraints:** state the important do-not rules, privacy boundaries, and allowed edit scope explicitly.
- **Verify:** give a small set of objective pass/fail checks or commands.
- **Report:** request blockers first, then optional follow-ups, plus final diff/status.

Chain complex work as separate research → implementation → review → commit prompts. Prove uncertain
runtime signals with a thin live experiment before broad implementation, hardening, or documentation.
Avoid repeating the full project history, combining unrelated goals, or writing long procedural scripts
when the agent can determine routine steps safely from the repo.

## Master state and important milestones

- Latest committed and pushed milestone (2026-07-18): `3234e3a` (`Add menu bar attention
  indicator`) is on both `master` and `origin/master`. It adds the reactive raw-Claude approval
  indicator: the existing adaptive template icon is used normally, while a separate original-color
  orange asset is selected for genuine **Needs approval** state. The asset variants were normalized
  to the normal icon's optical bounds; the owner verified the real transition and matching size.
- The preceding Attention v1 and Recent sessions work is also committed on `master`: local Claude
  **Needs approval**/**Done** notifications with default sound and best-effort provider activation;
  completion latching that ignores trailing subagent events; and one provider-neutral overflow for
  the interleaved four-row radar, revealing up to ten additional Claude/Codex rows.
- Previous committed milestone (2026-07-14): Claude Desktop **Needs approval** from the opt-in
  `PermissionRequest` heartbeat event, including request-relative timing, attention-first sorting,
  the documented Deny limitation, tests, and ADR 0018. The preceding Trust the Run milestone remains
  `5feb643` (2026-07-12).
- v0.1.1 established Claude-aware keep-awake and the bounded quiet-work hold (2026-07-04).
- Session Radar, title resolution, dismissal, and state/timer refinements landed July 6–8.
- Claude usage previews, the `v0.2` tag, Codex Desktop session/usage support, and conservative
  Codex keep-awake integration landed July 9–10.
- The reviewed Trust the Run work, committed in `5feb643`, adds truthful assertion status and
  Manual/Claude/Codex/ChatGPT Work ownership below the Sleep prevention switch. The switch remains usable during
  automation and changes only manual ownership; builds/tests passed and the owner verified the UI.
- **Public-source state:** the repository is public, and the latest published binary release is
  **v0.3**, cut directly from this repo via `scripts/package-github-release.sh`. Each tag corresponds
  to its attached binary; `master` may later move ahead of the latest tag. Trust current code, the
  latest ADRs, and the tail of `DEVELOPMENT_LOG.md` over older release-facing prose.
- **Attention v1 and centralized Recent sessions are committed current behavior.** The hook latches
  genuine `Stop`/`StopFailure` completion against trailing subagent events; notifications cover
  Claude **Needs approval** and **Done**; the menu-bar icon turns orange for raw Claude approval
  state; and one bounded provider-neutral expansion serves the shared Claude/Codex radar.
- **Known stale:** `docs/assets/vibemenu-menu.png` is the v0.1.x menu and is deliberately not
  shown in the README until a current capture replaces it. A few source comments still describe a
  `"Claude" row` / pre-wrapper state (e.g. `ClaudeActivityModel.swift`, `Package.swift`); they are
  cosmetic and were left for a separate code-comment pass.

## Common git safety rules

1. Confirm `git status --short --branch` before and after work.
2. Work only in this repo; do not edit the wrapper repo or another worktree.
3. Preserve unrelated user changes; do not use destructive reset/checkout commands.
4. Keep one logical change per diff and inspect `git diff`/`git diff --check`. **Do not modify
   `CLAUDE.md` incidentally** — leave it untouched unless the task explicitly scopes a change to
   it, or a statement in it has become factually wrong (e.g. it describes a capability the app
   no longer lacks). In those cases correct the specific claim, keep the edit minimal, and call
   it out in the handoff. Never rewrite its workflow rules to suit a task.
5. No commit, push, merge, tag, or release publication without explicit owner direction.

## Release rules

- This repo is the source of truth. The wrapper repo is not a source mirror and is touched only
  in a separate, explicit publication task, if at all.
- Current direct-release packaging is an unsigned, not-notarized macOS arm64 zip produced by
  `scripts/package-github-release.sh`; do not claim signing, notarization, DMG, or an updater.
- **Signing/notarization are not planned for the current validation phase** (a recurring cost
  that unproven demand doesn't justify yet) — a revisitable decision, not a permanent position.
  Keep the unsigned Gatekeeper/Open Anyway caveat in release notes, and present
  build-from-source as an alternative that avoids trusting the published binary but is still
  unsigned. Do not claim DMG or Homebrew technically require signing. Reversing this needs ADR
  0004 amended again.
- A release requires human sign-off, a clean/intended source commit, matching bundle/package
  version, passing build/tests, the manual smoke checklist, and a privacy/secrets scan.
- **Release state (v0.3):** this source repository is public and the latest published binary release
  is **v0.3**, packaged unsigned/not-notarized from this repo. Tagged releases correspond to their
  attached binaries; `master` may later move ahead of the latest tag. The separate wrapper repo
  remains out of scope and must not be edited without an explicit task.

## Known product direction

Approved 2026-07-12: evolve VibeMenu into the **local power-and-attention layer for Mac-based
coding agents**. It should answer three questions: is an agent run protected from sleep, does
any agent genuinely need the user, and is it safe for the Mac to keep running? Keep VibeMenu
small, native, local-first, cross-agent where evidence supports it, and free of transcript
message content (the one ADR-approved exception is the Claude session title record — see
`AGENTS.md` §6).

**Current posture: v0.3 shipped; active feature development paused.** Attention v1 and centralized
Recent sessions are complete and committed, and the focused standalone power-and-attention release has
shipped as **v0.3**. VibeMenu will not compete as a broad agent dashboard; agent tracking remains the
bounded sensing layer for power protection, release, completion, and attention. The project is now in
maintenance/feedback mode: bug fixes and any future work depend on actual user demand. Safe headless
lid-closed operation was investigated but is **not built and not shipped** — it is out of scope for
v0.3 and would need its own ADR, security review, and explicit approval before any code lands
([ADR 0021](decisions/0021-power-guardian-direction.md)).

Two owner-run 15-second tests on the current Apple Silicon Mac produced maximum
execution gaps of 1s and 2s with `SleepDisabled=1`, and both ended with `SleepDisabled=0`. This proved
basic CPU continuity on that machine only and remains a historical data point. Networking, real-agent
progress, long-duration safety, helper crash/reboot recovery, global-state ownership,
signing/notarization, and cross-model behavior were never resolved; no headless implementation exists
and none is scheduled.

`PRODUCT.md`, `ROADMAP.md`, `FAQ.md`, `INSTALL.md`, `PRIVACY.md`, `SECURITY.md`,
`ARCHITECTURE.md`, and `RELEASE_CHECKLIST.md` were synchronized on 2026-07-19 with committed
Attention v1, centralized Recent sessions, the orange attention icon, and the power-guardian
direction, and again for the **v0.3** release (2026-07-24) to the shipped-and-paused posture. ADR 0020
records the bounded attention behavior; ADR 0021 records the product direction.

Sequence to date:

1. **Trust the Run — implemented and verified:** the menu now shows whether VibeMenu actually
   holds the assertion, its Manual/Claude/Codex/ChatGPT Work owners, and acquisition failure. The manual switch
   always remains available and changes only manual ownership. Reliable quiet-hold remaining time
   is still deferred because the current model does not expose it. Signing/notarization is now a
   declined cost for this phase, not a prerequisite — build-from-source is the documented
   alternative (which avoids trusting the published binary, but is still unsigned).
2. **Needs approval — implemented and verified for Claude Desktop:** the opt-in heartbeat
   records Claude Code's documented `PermissionRequest` event and surfaces the matching Session
   Radar row as **Needs approval**, sorted first with a request-relative timer. Allow clears on
   the next lifecycle event. Claude Desktop emits no hook event on Deny, so a denied row may
   remain until the session's next event or the 30-minute prune. No prompt, tool, or conversation
   content is read.
3. **Attention v1 — committed and owner-verified:** opt-in local notifications for **Needs
   approval** and **Done**. Authorization requests `.alert` and `.sound`; delivered content uses
   `.default`; foreground presentation requests `.banner` and `.sound`. Actual playback remains
   controlled by the Mac's notification, Focus, volume, and sound settings. There is no separate
   sound toggle or custom sound selection. The safe heartbeat behavior is verified; exact live
   row/notification activation remains an owner UI smoke check because this menu-bar-only
   environment did not expose the popover to accessibility inspection. The custom menu-bar label
   selects the baked-orange asset for a genuine Claude **Needs approval** state and otherwise keeps
   the existing template asset's normal adaptive system appearance. Exact thread/window selection
   remains best-effort and evidence-gated.
4. **Centralized Recent sessions expansion — committed and owner-verified:** one shared,
   provider-neutral expansion reveals up to ten eligible Claude/Codex rows in the same ordering as the
   four-row primary list, with one combined hidden count and older remainder. This remains a bounded
   display affordance, not a history screen or persistent queue.
5. **Headless closed-lid / Safe Unattended Runs — investigated, not built:** the smallest
   signed/admin-approved helper architecture (authenticated expiring lease, AC/battery and thermal
   policy, crash/reboot/uninstall cleanup, global-state ownership, and a real networking +
   agent-progress physical test) was scoped but never implemented. No helper code is approved, v0.3
   ships without it, and it is revisited only if real user demand justifies it.

A persistent Attention Queue and stuck detection remain out of scope. **Limited native
notifications and completion/approval alerts are approved only as Attention v1 above**; this does
not approve a persistent queue or broad notification system. Additional providers and headless
clamshell/lid-closed support remain evidence- or feasibility-gated. Usage limits remain optional
planning context, not a broad quota-dashboard strategy.

Do not add agent orchestration, worktree management, transcript summaries/search, code review,
approval actions, automatic retries, team analytics, cloud relay, fan control, a broad system
monitor, or a general provider dashboard. Any privileged clamshell helper still requires its
own ADR, security review, guardrails, and explicit human approval. Codex Desktop support is
current master behavior even where older docs call it deferred.

## What to read first

1. [`AGENTS.md`](../AGENTS.md), then [`CLAUDE.md`](../CLAUDE.md) (preserve it).
2. This file, [`PRODUCT.md`](PRODUCT.md), [`ARCHITECTURE.md`](ARCHITECTURE.md), and
   [`PRIVACY.md`](PRIVACY.md).
3. ADRs [`0016`](decisions/0016-claude-usage-limits.md) and [`0017`](decisions/0017-codex-session-support.md),
   then the latest `DEVELOPMENT_LOG.md` entry.
4. For implementation, inspect `Sources/VibeMenuApp/VibeMenuApp.swift`, the relevant
   `Sources/VibeMenuCore/` reader/model, and its tests before changing behavior.
