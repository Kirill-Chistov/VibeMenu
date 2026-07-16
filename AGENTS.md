# AGENTS.md — Rules for all AI coding agents

This is the universal contract for **every** AI coding agent working in this repo
(Claude Code, Codex, Sonnet, and any other). Claude-specific workflow notes are in
[`CLAUDE.md`](CLAUDE.md); read this file first.

## Ownership

1. **The human owns product decisions.** Kirill Chistov is the product owner and the sole final
   decision-maker. You are **not** the product owner. When a choice is architectural,
   product-shaping, or ambiguous, **stop and ask** rather than deciding silently.

## Scope discipline

2. **Small diffs only.** One logical change per task/PR. Prefer additive, reversible
   changes.
3. **Do not overbuild.** Build the shape the task asks for, not the full future behavior.
   Prefer `TODO`s and protocols/stubs over implementing deferred features early.
4. **No broad rewrites without approval.** Refactors that touch many files or cross module
   boundaries require explicit sign-off *before* you start.
5. **No new dependencies without approval.** Default to system frameworks. Propose any
   dependency in the PR with a justification and an ADR in `docs/decisions/`.

## Product/architecture workflow

For **non-trivial product or architecture changes**, do not immediately implement. First
produce a proposal with options and tradeoffs, then wait for product approval.

**Non-trivial** means anything touching:

- power assertions
- automation policy
- Claude hook/heartbeat behavior
- privacy/security
- app lifecycle/background monitoring
- settings/onboarding
- release/distribution
- new user-visible features

Small fixes may still be implemented directly:

- typo/comment cleanup
- tests for an already-approved behavior
- obvious bugfix with no product tradeoff

Required proposal format:

```md
## Problem
## Constraints
## Options
## Recommendation
## Risks
## Testing plan
## Waiting for product approval
```

## Hard product/privacy invariants (never violate without an ADR + human approval)

6. **No transcript-content reading.** Read process presence and file *metadata* (mtime) for
   detection — never the contents of prompts, responses, tool calls, `lastPrompt`, or any
   message body. **One narrow, ADR-approved exception:** the Session Radar may open the matching
   transcript to read *only* its session-title record (`custom-title` / `ai-title`) for the row
   name (docs/decisions/0013). No other transcript field is ever read, stored, or logged. Any
   further widening needs its own ADR + human approval.
7. **No telemetry. No analytics.** None, not even opt-in, without explicit approval.
8. **No network calls.** No backend, no account, no update check. The invariant reserves one
   hypothetical exception (a signed update channel, `docs/decisions/0004`) that is **not built
   and not planned** — do not add networking code on the strength of that carve-out.
9. **No clamshell / root / private-API work without approval.** Anything needing root, a
   privileged helper, `pmset disablesleep`, or a private Apple API is out of scope and
   requires its own ADR + human sign-off. Keep such code quarantined outside
   `VibeMenuCore`.
10. **Respect the lightweight resource budget.** No busy polling loops; prefer
    event-driven observation. No local database, no transcript copying, no heavy
    monitoring dashboard. See
    [`docs/decisions/0006-lightweight-resource-budget.md`](docs/decisions/0006-lightweight-resource-budget.md).

## Verification (this is non-negotiable)

11. **Run real checks.** When your change is relevant, actually run `swift build` and the
    tests (`scripts/test.sh`).
12. **Paste real command output.** The build/test output you show must be the real output
    of a command you actually ran.
13. **Never fake build/test/launch results.** Do not claim something builds, tests, or
    launches unless you ran it and can show the output. If you did not run it, say so
    plainly. The `.app` wrapper builds and runs as a menu-bar app today, but that is not a
    licence to claim *your* change runs — building the package is not launching the app, and
    launching it is not exercising your code path.

## Communication

14. **Summarize changed files** at the end of every task: path + one line on what changed
    and why.
15. **Explain macOS API assumptions.** For any system / IOKit / `pmset` / hook call,
    state: public or private? entitlements or root needed? sandbox-compatible? does it
    vary by chip generation or OS version? Cite where you verified it.
16. **Mark uncertainty clearly.** Flag anything you are guessing, anything version-fragile
    (e.g. the Claude Code JSONL format), and anything you could not test on this hardware.
17. **Write decisions down.** Any non-trivial design choice → an ADR in `docs/decisions/` with
    context, options, decision, and consequences.

## Second-model review

18. For anything risky — `AutomationPolicy`, IOKit adapters, a future privileged helper,
    or the no-network invariant — the implementing model and the reviewing model must be
    **different** models. No single model both proposes and ratifies its own risky change.

## Development log

19. **Update `docs/DEVELOPMENT_LOG.md` after each implementation task.** Append a short new
    entry with the date, what changed, the commands run and their validation results, any
    errors and how they were fixed, what you verified vs. did not verify, and the
    recommended next step. (`docs/decisions/` records *why*; `docs/DEVELOPMENT_LOG.md` records
    *what happened*.)
