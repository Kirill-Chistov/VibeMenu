# VibeMenu — Agent Context

Canonical, concise handoff for this repo. Keep this current-state focused.
Use [`DEVELOPMENT_LOG.md`](DEVELOPMENT_LOG.md) for chronology and [`decisions/`](decisions/)
for design decisions.

> **This repo is being prepared to become the public open-source source repo. It is not public
> yet** — making it public is a pending owner step (`RELEASE_CHECKLIST.md` Part A §6). Write
> every commit, comment, and doc as if a stranger will read it, because one soon will. No
> personal absolute paths, no private data, no internal-only shorthand.

## Product summary

VibeMenu is a lightweight, local-only macOS 15+ Apple Silicon menu-bar app. It keeps the
Mac awake while Claude Code or an active Codex Desktop session is working, releases the
power assertion when work finishes, and — **for Claude only** — uses a bounded quiet-work hold
(15 minutes by default) to cover silent builds, tools, or subagents. Codex has no heartbeat, so
it holds only while it looks active (~60s window) and gets no quiet-hold. It also provides a compact Session
Radar, coarse thermal status, optional Launch at Login, and opt-in experimental usage-limit
previews. It is Apache-2.0 licensed; the name, logo, and brand assets are separate.

## Repository boundaries and rules

- **This repo (`Kirill-Chistov/VibeMenu`) is the source repo, currently private and being
  readied to go public.** Source, tests, support scripts, product docs, ADRs, and release
  packaging all live here. Work relative to the repo root; never write an absolute personal path
  into a tracked file.
- A separate release/marketing wrapper repo exists (`Kirill-Chistov/VibeMenu-Public`). It is
  **out of scope**: do not edit it. Its future is the owner's decision.
- Do not commit or push unless the product owner explicitly requests it. Never rewrite history
  or discard existing user changes.
- Preserve `CLAUDE.md`'s workflow rules; correct it only where an explicitly scoped task or a
  factual error requires it (see git safety rule 4). Read `AGENTS.md` first; the human product
  owner owns product, architecture, privacy, and release decisions.
- Keep changes small and scoped. Any non-trivial product, architecture, privacy, or release
  change needs a proposal/approval and an ADR where appropriate.
- **Everything here is about to be public.** Assume any file you touch will be read by strangers
  evaluating whether to trust the app with their machine. Note that publishing has not happened
  yet, so nothing may be described as already public.

## Current feature set

- Menu-bar-only SwiftUI app (`MenuBarExtra`, `LSUIElement`); no Dock icon and no main window,
  but there is a Settings scene/window (`VibeMenuApp.swift`).
- Manual keep-awake override and automatic public power assertions driven by Claude activity
  and active Codex Desktop sessions; manual mode wins. The menu now shows the actual assertion
  state and its current Manual/Claude/Codex owners, including acquisition failure. The manual
  switch always remains interactive and changes only manual ownership. Codex usage-limit refreshes
  never affect sleep prevention.
- Claude detection from process/file metadata, with an optional user-installed Claude
  heartbeat hook for reliable working/waiting states. The hook is never installed
  automatically.
- Shared Session Radar for Claude and Codex Desktop: bounded recent rows, working/quiet/
  waiting/done/stale states, elapsed time, safe titles/folder names, and per-row hide.
  Claude Desktop approval prompts surface as **Needs approval** from the opt-in
  `PermissionRequest` heartbeat event; Allow clears on the next lifecycle event, while Deny
  may linger until the next event or the 30-minute prune. Codex CLI sessions and internal
  subagent rollouts are excluded.
  Claude Code `StopFailure` heartbeats are recognized as finished, non-holding turns so API-error
  completions become **Done** and release automatic sleep prevention. The installed hook registration
  and sanitized payload path were validated; a genuine API-error event remains unobserved end-to-end.
- Coarse macOS thermal state (Nominal/Fair/Serious/Critical), row visibility preferences,
  Launch at Login through public `SMAppService`, and compact Settings with Claude/Codex
  disclosures.
- Opt-in Claude limits: real 5-hour/weekly data from the Claude Desktop cache or a
  Claude Code `statusLine` capture; Desktop may also provide per-model weekly rows.
- Opt-in Codex limits: real `rate_limits` data from Codex Desktop rollouts, schema-driven rather than
  a fixed 5-hour/weekly pair — each row derives its label from the window's own reported duration and
  disappears when Codex no longer exposes that window. Both usage features are display-only, fail
  closed, and off by default.

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
xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug build
```

For a release candidate, also run the Release build and
`scripts/package-github-release.sh <version>`. Prefer `scripts/test.sh` to plain
`swift test`; it handles Command Line Tools-only Swift Testing paths. Never claim a build,
test, or launch that was not actually run. Append implementation validation to
`DEVELOPMENT_LOG.md`.

## Current ChatGPT / Claude / Codex workflow

- **ChatGPT:** product-facing planning, synthesis, research, and handoff preparation. It
  records approved direction in product docs/ADRs and does not make silent product decisions.
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

- Latest committed milestone (2026-07-14): Claude Desktop **Needs approval** from the opt-in
  `PermissionRequest` heartbeat event, including request-relative timing, attention-first sorting,
  the documented Deny limitation, tests, and ADR 0018. The preceding Trust the Run milestone remains
  `5feb643` (2026-07-12).
- v0.1.1 established Claude-aware keep-awake and the bounded quiet-work hold (2026-07-04).
- Session Radar, title resolution, dismissal, and state/timer refinements landed July 6–8.
- Claude usage previews, the `v0.2` tag, Codex Desktop session/usage support, and conservative
  Codex keep-awake integration landed July 9–10.
- The reviewed Trust the Run work, committed in `5feb643`, adds truthful assertion status and
  Manual/Claude/Codex ownership below the Sleep prevention switch. The switch remains usable during
  automation and changes only manual ownership; builds/tests passed and the owner verified the UI.
- **Docs currentization (2026-07-15, uncommitted):** README/ROADMAP/PRODUCT/FAQ/INSTALL/PRIVACY/
  SECURITY and the contract files were rewritten ahead of making the repo public — v0.2 and both
  agents, ownership corrected to Kirill Chistov, signing reframed as a declined cost for the
  current validation phase (revisitable, ADR 0004 Amendment 1), the Claude-only scope of the
  quiet-work hold made explicit, and the stale "Claude: Active/Idle/Not detected" aggregate-row
  wording removed (that row no longer exists; the menu shows session rows directly). For current
  master behavior, still trust the code, latest ADRs, and the tail of `DEVELOPMENT_LOG.md` over
  any prose.
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
- **Release state (2026-07-15):** source is at v0.2, but this repo's published releases stop at
  **v0.1.1**; the v0.2 zip was published on the wrapper repo. Publishing a matching v0.2 release
  here is an open owner task — do not describe one as existing until it does.

## Known product direction

Approved 2026-07-12: evolve VibeMenu into the **local power-and-attention layer for Mac-based
coding agents**. It should answer three questions: is an agent run protected from sleep, does
any agent genuinely need the user, and is it safe for the Mac to keep running? Keep VibeMenu
small, native, local-first, cross-agent where evidence supports it, and free of transcript
message content (the one ADR-approved exception is the Claude session title record — see
`AGENTS.md` §6).

**Active milestone: Open Source Readiness / Prove the Pull — not new features.** The goal is to
make the project legible to strangers and learn whether anyone actually wants it: accurate public
docs, a clean repo, a current screenshot, making the repo public, a release matching the v0.2
source, then listen via issues/discussions/stars (there is no telemetry and will be none). Do not
start new feature work without the owner redirecting the milestone.

Sequence to date:

1. **Trust the Run — implemented and verified:** the menu now shows whether VibeMenu actually
   holds the assertion, its Manual/Claude/Codex owners, and acquisition failure. The manual switch
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
3. **Safe Unattended Runs (not started, gated):** after a separate product decision, add
   battery/thermal keep-awake
   guardrails with visible reasons and explicit manual-override semantics.

A persistent Attention Queue, native notifications, completion alerts, stuck detection,
additional providers, and clamshell/lid-closed support are **not approved roadmap commitments**.
They remain evidence- or feasibility-gated follow-ons. Usage limits remain optional planning
context, not a broad quota-dashboard strategy.

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
