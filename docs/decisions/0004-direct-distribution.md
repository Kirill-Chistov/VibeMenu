# 0004 — Direct distribution first (not the Mac App Store)

- **Status:** Accepted; **amended 2026-07-15** (see [Amendment 1](#amendment-1-2026-07-15--stay-unsigned-for-the-current-validation-phase)).
- **Date:** 2026-07-02
- **Deciders:** Kirill Chistov (product owner).

> **Read the amendment first.** The core decision — distribute directly, not via the Mac App
> Store — stands. The *means* described below (Developer ID signing, notarization, DMG, Sparkle,
> Homebrew) have **not** been adopted for the project's current phase: VibeMenu ships unsigned
> and has no updater.

## Context

VibeMenu's trajectory includes capabilities that are **ineligible for the Mac App
Store**: the deferred guarded clamshell mode needs root / a privileged helper
(`pmset disablesleep`), and any optional GPU/power readouts would need private IOReport.
Even though v0.1 itself is public-API-only and could in principle be sandboxed, splitting
into a separate App Store build would fork the product and add maintenance for a weaker
subset. Sparkle-based auto-update and Homebrew distribution fit the developer audience.

## Decision

- **Distribute directly**, not via the Mac App Store: Developer ID signing +
  notarization + stapling, delivered as a DMG on GitHub Releases and a Homebrew cask, with
  **Sparkle** for auto-updates.
- **Sparkle is the one anticipated third-party dependency** and the one permitted network
  egress (an EdDSA-signed appcast over HTTPS). Its actual addition is future work with its
  own review; it is **not** present in v0.0.

## Consequences

- The distribution path is compatible with the deferred root/private-API features without
  a second build.
- Updates flow through Sparkle; this is the sole network capability VibeMenu will have,
  and it must be signed and pinned (see [`../SECURITY.md`](../SECURITY.md)).
- No App Store review constraints on the roadmap's differentiated features.
- Signing, notarization, and Sparkle are explicitly out of scope for the current bootstrap
  and are gated by [`../RELEASE_CHECKLIST.md`](../RELEASE_CHECKLIST.md).

## Alternatives considered

- **Mac App Store first.** Rejected: incompatible with the differentiated clamshell/GPU
  roadmap; sandbox + review friction; would force a maintenance fork.
- **A stripped "assertions-only" App Store lite build in parallel.** Rejected for now: a
  weaker, different product and a maintenance fork; revisit only if there is clear demand,
  via a new ADR.

---

## Amendment 1 (2026-07-15) — stay unsigned for the current validation phase

- **Status:** Accepted; supersedes the signing/notarization/DMG/Sparkle/Homebrew parts above for
  as long as the project remains in its current low-cost validation phase.
- **Deciders:** Kirill Chistov (product owner).

### Context

The original decision assumed Developer ID signing, notarization, a DMG, Sparkle auto-update,
and a Homebrew cask as the eventual distribution path. Signing and notarization are gated on an
Apple Developer Program membership, which is a **recurring annual cost**. VibeMenu is a free,
open-source, single-maintainer utility with no revenue and, by design, no telemetry to justify
the spend. Two releases (v0.1.0, v0.1.1) have shipped unsigned; the "Open Anyway" step has not
been the thing holding the project back.

Meanwhile the docs kept promising signing "on the roadmap" — a promise the project had no
current plan to keep, which is worse than an honest limitation.

The project's active milestone is finding out whether anyone actually wants VibeMenu. Paying a
recurring fee to smooth the install of a product with unproven demand is the wrong order of
operations.

### Decision

- **VibeMenu ships unsigned and un-notarized for now.** This is a declined cost for the current
  phase, not deferred work with a due date. Docs must state it plainly and stop describing
  signing as planned — while also not claiming it is ruled out forever.
- **Build-from-source is a first-class, documented alternative**, and the honest answer for
  anyone who'd rather not trust a binary built and uploaded by someone else. It does not produce
  a signed app, and docs must not imply it does.
- **No DMG, no Sparkle, no Homebrew cask, no update check** — each for its own reason, and *not*
  because signing is technically a prerequisite:
  - A **DMG** is packaging polish; the zip already does the job. Unsigned apps can ship in a DMG.
  - A **Homebrew cask** would work with an unsigned app, but it is ongoing maintenance the
    project doesn't want at this size.
  - An **updater** is ruled out by the no-network invariant, independent of signing — and an
    unsigned, unpinned update channel would be irresponsible regardless.
- The **no-network invariant tightens accordingly**: the update-check carve-out in
  `AGENTS.md` §8 stays as a hypothetical, but nothing may be built on it without a new ADR.
- **Revisiting is expected, not forbidden.** If adoption or funding justifies a Developer ID,
  the owner can reverse this with a further amendment — but it must be an explicit amendment,
  not a silent drift back to promising signing.

### Consequences

- Users see a Gatekeeper warning on first launch for as long as this stands. `INSTALL.md`
  documents the one-time approval; `SECURITY.md` states plainly what an unsigned build does and
  doesn't guarantee.
- **Launch at Login stays unreliable** on unsigned builds (`SMAppService` registration is
  inconsistent without a signature). The manual Login Items fallback is the documented answer.
- Some users will decline to run an unsigned binary. That is an accepted, known cost of this
  decision; build-from-source is their path, with the same caveat that it too is unsigned.
- Supply-chain and lookalike-distribution risk are **not** mitigated by notarization here, and
  `SECURITY.md`'s threat model says so rather than implying otherwise.
- No auto-update means users must return to the Releases page (or rebuild) for new versions.
- Adoption evidence is what would change this. That evidence is exactly what the current
  milestone is trying to gather, so the decision is deliberately revisitable.
