# 0003 — License: Apache-2.0 for source; brand assets reserved

- **Status:** Accepted
- **Date:** 2026-07-02
- **Deciders:** Kirill Chistov (product owner).

## Context

VibeMenu's audience is privacy- and open-source-sensitive developers, and its adjacent
peers (Stats, CodexBar) are free/open. Trust and adoption are the scarce resources for a
first native app, not near-term revenue. An open, permissive license maximizes trust and
verifiability of the privacy claims. At the same time, the product name and logo are
brand identity that should not be freely reusable just because the code is open.

## Decision

- **Source code is licensed under Apache-2.0** (see [`../../LICENSE`](../../LICENSE)).
- **The VibeMenu name, logo, and other brand assets are NOT licensed for reuse.** They
  are expressly excluded from the Apache-2.0 grant. Using the code is fine; shipping a
  fork under the VibeMenu name/brand is not.

## Consequences

- Anyone may use, modify, and redistribute the source under Apache-2.0 terms (including
  its patent grant), which supports the "verifiable privacy" stance.
- Forks/derivatives must use their own name and branding, not "VibeMenu" or its logo.
- Apache-2.0 (vs MIT) adds an explicit patent grant and is a widely trusted permissive
  choice; it does not preclude a future open-core arrangement, but any monetization
  boundary is deferred until value is validated (not decided here).
- The README and this ADR both state the brand-asset carve-out explicitly.

## Alternatives considered

- **MIT.** Rejected in favor of Apache-2.0's explicit patent grant and trademark clarity.
- **A source-available / non-open license to protect future monetization.** Rejected for
  now: it would undercut the trust/adoption goal that matters most for a first release.
  Monetization boundaries can be revisited later via a new ADR without relicensing already
  published code.
