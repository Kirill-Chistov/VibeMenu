# VibeMenu — Roadmap

Kept live. Ship the smallest thing that keeps a Mac awake exactly as long as an agent is
working, and that tells you when an agent needs you — prove that loop is reliable and
trustworthy before earning the right to anything riskier.

Nothing below is a dated commitment. Items past the current milestone are **evidence-gated**:
they ship if real use pulls for them, and not otherwise.

## Where it is now

**Shipped (source at v0.2):**

- Claude Code detection (process + file metadata, plus the optional heartbeat hook) driving a
  public power assertion, with a bounded quiet-work hold (15-minute default cap). The quiet-work
  hold is **Claude-only** — it depends on Claude's lifecycle events.
- Codex Desktop session detection, opt-in and metadata-only; an **active** Codex session feeds
  the same shared keep-awake decision (ADR 0017 Amendment 3). Codex has no per-session
  heartbeat, so it holds only while it looks active and gets **no** quiet-work hold.
- Shared **Session Radar** for both agents — four interleaved priority rows plus one centralized,
  provider-neutral **Recent sessions** expansion for up to ten more, with elapsed time, safe titles,
  provider pills, and per-row hide.
- **Trust the Run** — the menu shows the real assertion state, its Manual/Claude/Codex owners,
  and acquisition failure. The manual switch stays interactive and owns only manual state.
- **Attention v1** — Claude **Needs approval** and **Done** notifications with the system default
  sound, best-effort provider activation, and an orange menu-bar glyph while any raw Claude session
  needs approval (ADRs 0018 and 0020).
- Opt-in, off-by-default **usage limits** for Claude (Desktop cache or Claude Code status line)
  and Codex (rollout `rate_limits`), display-only and fail-closed.
- Coarse thermal state, Launch at Login (`SMAppService`), menu-bar-only `.app` with an icon.

## Current milestone — Final standalone release

VibeMenu will finish one focused power-and-safety milestone, publish a strong current-source
release, then pause major standalone development and measure real interest.

See [`decisions/0021-power-guardian-direction.md`](decisions/0021-power-guardian-direction.md).

- Keep agent tracking only as the sensing layer for power, completion, and attention.
- Do not chase conversation previews, in-app approvals, dozens of providers, remote agents,
  rich terminal navigation, orchestration, or a notch interface.
- Investigate the smallest safe **headless closed-lid** architecture. Basic CPU continuity with
  `SleepDisabled=1` has been owner-verified twice on the current Mac; networking, sustained agent
  progress, thermal behavior, crash recovery, and cross-model support remain unverified.
- Require a bounded lease/watchdog, AC/battery and thermal guardrails, narrow privilege boundary,
  signing/notarization decision, ADR, and independent security review before implementation.
- Publish a release centered on agent-aware sleep prevention, safe unattended runs, basic
  notifications/attention, strict local-only privacy, and—only if the safety case passes—headless
  operation.
- Then listen. Issues, discussions, and stars are the feedback channel; there is no telemetry.

**Exit criteria:** a developer who has never seen the repo can understand what VibeMenu does,
build or install it, and correctly predict what it will and won't read from their machine.

## Distribution

1. **Now — GitHub zip release.** An **unsigned, not-notarized** `VibeMenu.app`, zipped and
   attached to a GitHub Release (`scripts/package-github-release.sh`). Users approve it once via
   **System Settings → Privacy & Security → Open Anyway**.
2. **Also now — build from source.** `swift build` + `xcodebuild`, fully supported and documented
   in the README. This is the answer for anyone who'd rather not trust a binary someone else
   built — though the result is still an unsigned app.

**Signing and notarization are not planned for the current phase.** A Developer ID is a
recurring cost, and while the project is validating whether anyone wants it, that cost isn't
justified; the honest workaround (Open Anyway, or build it yourself) is documented instead. This
is a phase decision, not a permanent position — if adoption or funding justifies the spend, the
owner can revisit it by amending
[`decisions/0004`](decisions/0004-direct-distribution.md).

A DMG, an auto-updater, and a Homebrew cask are also out, but for their own reasons — not
because signing is technically required for any of them. A DMG is packaging polish that a zip
already covers. A Homebrew cask would work with an unsigned app, but is maintenance the project
doesn't want at this size. An updater is ruled out by the no-network invariant, and would need a
signed, pinned channel to be responsible at all. Each is its own decision if it ever comes up.

The practical cost of staying unsigned is real and accepted: Gatekeeper friction on first
launch, and Launch at Login being unreliable on unsigned builds
([FAQ](FAQ.md#why-does-launch-at-login-not-work-in-debugunsigned-builds)).

## Next — evidence-gated, not committed

Considered only if real use pulls for them; each needs its own decision, and the risky ones need
an ADR before any code lands.

- **Safe Unattended Runs** — battery/thermal guardrails on automatic keep-awake, with visible
  reasons and explicit manual-override semantics. Needs a product decision on the policy.
- **Quiet-hold remaining time** — deferred: the current model doesn't expose a reliable number,
  and a fabricated countdown is worse than none.
- **Deny handling for Needs approval** — blocked upstream: Claude Desktop emits no hook event on
  deny (ADR 0018). Revisit only if a future build starts emitting one.
- **Guarded lid-closed / headless mode** — active architecture/security investigation. The
  underlying `SleepDisabled` mechanism passed two short owner-run CPU-continuity tests on the
  current Mac, but production feasibility remains gated on networking and real-agent tests,
  global-state ownership, a signed/admin-approved minimal helper, battery/thermal cutoffs,
  auto-expiring leases, crash/reboot cleanup, its own ADR, and independent security review.
- **Generalized "keep awake while X runs"** — same assertion engine, different trigger.
- **Additional agents** — only where a privacy-safe local signal genuinely exists.

## Explicitly not on the roadmap

A persistent attention queue, broad notification system, stuck detection, agent orchestration,
worktree management, transcript summaries or search, code review, in-UI approval actions,
automatic retries, team analytics, a cloud relay, fan control, a broad system monitor, a notch
interface, or a general cross-provider quota dashboard. Usage limits stay a small opt-in readout, not a
strategy.

These are not "later" — they are what VibeMenu is choosing not to be. See
[`PRODUCT.md`](PRODUCT.md) for the reasoning and
[`decisions/0006-lightweight-resource-budget.md`](decisions/0006-lightweight-resource-budget.md)
for the resource budget that rules most of them out.
