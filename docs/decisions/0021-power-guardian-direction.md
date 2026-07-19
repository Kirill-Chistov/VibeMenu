# ADR 0021 — Focus VibeMenu on agent-aware power and safety

- **Status:** Accepted
- **Date:** 2026-07-19

## Context

VibeMenu was compared directly with broader agent dashboards such as Vibe Island. Those products
already compete on richer navigation, conversation-oriented workflows, many integrations, remote
agents, and visually ambitious control-center surfaces. Chasing that breadth would turn VibeMenu
into a smaller copy while weakening the product's clearest differentiated value.

VibeMenu already has a stronger, narrower thesis: local agent signals drive truthful sleep
prevention, release, completion, and attention behavior without a backend, telemetry, or transcript
message access.

Attention v1 and the bounded shared Recent sessions presentation are complete. The remaining major
standalone opportunity is safe headless lid-closed operation. Two short owner-run tests on one Apple
Silicon Mac showed a process continuing to execute with `SleepDisabled=1`, with normal sleep restored
to `0` afterward. This is feasibility evidence only; it does not approve a production helper or prove
networking, real-agent progress, long-duration safety, crash recovery, or broad compatibility.

## Decision

VibeMenu will become the **open-source power guardian for local coding agents**, not a broad agent
dashboard or control center.

- Keep Claude and Codex session tracking only as the bounded sensing layer needed to determine:
  - whether an agent is genuinely working;
  - whether sleep prevention should remain active;
  - whether the user needs attention;
  - when protection should release.
- Do not pursue conversation previews, in-app approval actions, remote agents, orchestration,
  worktree management, dozens of providers, rich terminal navigation, a notch interface, or a
  general usage/system-monitor dashboard.
- Investigate safe headless lid-closed operation as the final major standalone feature.
- Apply the 20/80 rule: prefer one conservative, reliable policy over a configurable
  power-management platform.
- Any privileged helper remains separately gated by architecture research, a dedicated ADR,
  signing/notarization and installation decisions, explicit human approval, and an independent
  security review.
- After the focused power-and-safety release, pause major standalone development and measure real
  interest through public feedback. Continue the niche if users value it; otherwise move the
  project to maintenance mode.
- A later contribution of the power/sleep-prevention layer to another open-source project remains a
  possible path, not part of the current milestone.

## Consequences

### Positive

- Gives the product a clear and defensible identity.
- Keeps the UI and agent integrations bounded.
- Aligns future work with VibeMenu's privacy and local-first strengths.
- Makes headless safety, rather than dashboard breadth, the criterion for the final milestone.

### Costs and constraints

- VibeMenu will intentionally offer fewer agent-management features than broad dashboards.
- Headless operation may require signing, notarization, administrator approval, and a narrowly
  privileged helper, changing the current distribution and trust posture if approved later.
- The project may enter maintenance mode after the next release if demand is weak.

## Non-decision

This ADR does **not** approve a privileged helper, `pmset` integration, a safety policy, signing
spend, or production closed-lid support. Those require the separate research, physical verification,
security review, and implementation ADRs described above.
