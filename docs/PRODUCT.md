# VibeMenu — Product

> Condensed product truth. The canonical, longer reasoning lives in the source
> specification; this file is the "why" any agent or contributor should read first.
> When product direction changes, update this file **and** add a `decisions/` entry.

## Target user

**Primary — "the agent-heavy indie dev."** A solo developer or small-team engineer who
runs Claude Code and/or Codex Desktop daily on an Apple Silicon MacBook. They frequently
start a long agent task (refactor, migration, test generation, research), then switch to
Slack, a meeting, or walk away. They value open source, transparency, low resource use,
and privacy, and are comfortable granting a permission when the reason is clearly
explained.

**Secondary.** Small dev teams/agencies running agents on laptops; developers running
any long local job (builds, model downloads, data pipelines) who want activity-driven
keep-awake; "vibe coders" who orchestrate agents heavily and don't want to think about
`pmset` or `caffeinate`.

**Non-target.** People who want detailed temperature/fan telemetry (→ Stats, TG Pro);
people who want an exhaustive cross-provider usage dashboard (→ CodexBar); anyone
wanting a Dock replacement or launcher.

## Problem

Existing keep-awake tools don't know whether an agent is still working, so they can't
start and stop sleep prevention automatically. Developers are forced to babysit the
machine, leave a blunt keep-awake tool on all day (wasting battery/heat), or risk the
Mac sleeping mid-run. There is no tool that keeps the Mac awake **exactly as long as an
agent is actually working** and no longer.

## Positioning

**One sentence:** *VibeMenu is the local power-and-attention layer for Mac-based coding
agents — it keeps your Mac awake exactly as long as an agent is working, and tells you
when one is blocked waiting on you.*

It should answer three questions at a glance:

1. **Is this run protected from sleep?** — and who is holding the assertion.
2. **Does any agent genuinely need me?** — approval prompts surface as their own row.
3. **Is it safe for the Mac to keep running?** — thermal state as decision context.

The sharpest wedge is the **automation loop between agent activity and power
management**, now extended to **attention** — not system monitoring and not usage
tracking, both of which are saturated, mostly-free, mostly-open-source spaces (Stats,
CodexBar, etc.). VibeMenu surfaces just enough thermal/activity context to *drive and
explain* the automation, and deliberately does not try to out-breadth a system monitor or
a usage tracker.

Staying small, native, local-first, cross-agent where the evidence supports it, and **not
reading transcript message content** is the product, not a constraint on it. (The one
ADR-approved exception is a session's *title* record, so a row can be named — see
[`PRIVACY.md`](PRIVACY.md).)

- **vs keep-awake tools** (Amphetamine, Caffeine, `caffeinate`): those toggle on a
  manual switch, timer, or crude "while app X runs" trigger and never auto-release.
  VibeMenu's trigger *is* the agent, and release is automatic.
- **vs system monitors** (iStat Menus, Stats, Hot, TG Pro): VibeMenu is not competing on
  sensor breadth or exact temperatures; it shows thermal *state* only as decision
  context.
- **vs usage trackers** (CodexBar, ClaudeBar): those tell you how much quota is left;
  VibeMenu tells you whether the agent is still working, whether it needs you, and manages
  sleep accordingly. VibeMenu *does* show real usage limits, but as a small opt-in readout
  for planning — not as a competing cross-provider quota dashboard.

## What is built (source at v0.2)

The thesis is wired end-to-end:

1. **Sleep-prevention loop** — a public power assertion held while an agent works and
   released when it finishes. **For Claude**, a silent tool/subagent phase is held through a
   **bounded quiet-work hold** (default 15-minute cap) rather than released the instant Claude
   looks idle, so long runs don't stall; a genuine finish (`Stop` / session end / process
   gone) releases promptly. Manual keep-awake always wins
   (see [`decisions/0010-quiet-work-hold.md`](decisions/0010-quiet-work-hold.md)).
2. **Agent activity** — Claude Code from process presence and session-file **metadata**
   (mtime), optionally sharpened by the opt-in heartbeat hook; Codex Desktop from
   allowlisted local rollout metadata (opt-in). An **active** Codex session feeds the same
   shared keep-awake decision — but Codex exposes no per-session heartbeat, so it gets **no
   quiet-work hold**: it holds only while it looks active and releases once it goes quiet,
   rather than guessing at a silence VibeMenu can't interpret.
3. **Trust the Run** — the menu shows the *actual* assertion state, its Manual/Claude/Codex
   owners, and acquisition failure, rather than echoing the switch back at you.
4. **Session Radar** — a per-session list for both agents (working / quiet / waiting / done
   / stale), elapsed time, a safe name, and per-row hide.
5. **Needs approval** — a Claude session blocked on a permission prompt sorts to the top with
   a request-relative timer, from the opt-in `PermissionRequest` hook event
   ([`decisions/0018`](decisions/0018-needs-approval.md)).
6. **Thermal pressure / status** — `ProcessInfo.thermalState` glance
   (nominal/fair/serious/critical). Public API; no exact temperatures.
7. **Optional usage limits** — real, local, display-only, off by default, for both agents.

All local, all on public Apple APIs, no root, no private APIs, no transcript message content.

## Non-goals (do not build)

- A general-purpose system monitor competing with Stats/iStat Menus.
- A many-provider usage/quota dashboard competing with CodexBar.
- Exact CPU/GPU temperatures or fan RPM as a feature surface.
- **Fan control** — a hard, indefinite no (root, safety risk, the OS thermal governor
  overrides it). Only the human owner may reverse this.
- A Dock replacement or app switcher.
- Any cloud sync, account system, backend, analytics, or telemetry-by-default.

## Why Session Radar exists

Product research found the strongest, best-evidenced pain for agent-heavy developers is
**agent handoff blindness** — not knowing which session is working, waiting, done, or stuck,
especially across parallel sessions — a pain keep-awake alone does not address and that
competitors chase mostly in the (hardware-gated) notch. So VibeMenu became a **lightweight,
local, menu-bar agent status center**, with keep-awake as one feature rather than the whole
product. The wedge stays the same — local-only, no network/telemetry, native, disciplined
scope — and it is **menu-bar-first**, which reaches every Mac (no notch required).

The radar is a **display layer over data VibeMenu already had** — the opt-in hook heartbeat and
allowlisted Codex metadata. It reads nothing extra and does not change the keep-awake loop
([`decisions/0011`](decisions/0011-session-radar.md), [`0017`](decisions/0017-codex-session-support.md)).
The pure session model is deliberately presentation-agnostic, so a future surface can reuse it
without reshaping the core.

## Deferred features (only if pulled by evidence)

- **Guarded lid-closed / clamshell operation** — the most differentiated behavior, but it
  needs root/a privileged helper and carries thermal + battery risk; it ships only after
  the lid-open loop is proven and all guardrails exist, behind its own ADR + human
  approval.
- **Safe unattended runs** — battery/thermal guardrails on automatic keep-awake, pending a
  product decision on the policy.
- **Generalized "keep awake while X runs"** — same assertion engine, different trigger.
- **Additional agents** — only where a privacy-safe local signal genuinely exists.

Deliberately **not** on the list: in-UI permission Allow/Deny, terminal jump, a notch/floating
layer, a cost dashboard, or a persistent attention queue — each would be its own decision, and
none is committed. See [`ROADMAP.md`](ROADMAP.md).

## Lightweight principle

VibeMenu must stay small *by design*. Idle CPU effectively zero; active overhead
negligible; event-driven observation (no busy polling loops); no local database unless
later justified; no transcript copying; no network; no resource-heavy monitoring
dashboard. If a feature would violate this budget, it is the wrong feature or needs a
`decisions/` entry justifying the cost. See
[`decisions/0006-lightweight-resource-budget.md`](decisions/0006-lightweight-resource-budget.md).
