# 0001 — Rename from OneTab to VibeMenu

- **Status:** Accepted
- **Date:** 2026-07-02
- **Deciders:** Kirill Chistov (product owner), recorded during repo bootstrap.

## Context

The project was drafted under the internal codename **OneTab**. That name was always a
temporary codename: it very likely collides with an existing browser-extension
trademark ("OneTab"), so it could never survive to a public launch. The source spec
explicitly flagged naming as deferred and the codename as internal-only.

The product owner has now chosen a public name — **VibeMenu** — and directed that the
repository be created under it from the start, rather than carrying the codename forward
and renaming later.

## Decision

- The app is named **VibeMenu**.
- All new repo files, product copy, module names, and code symbols use **VibeMenu**
  (e.g. `VibeMenuCore`, `VibeMenuApp`, `VibeMenuCoreTests`).
- The name **OneTab** is retired. It survives only where historically necessary — e.g.
  in this ADR explaining the rename, and when quoting the original spec.

## Consequences

- No `OneTab*` symbols, targets, or product copy exist in the repo.
- The original specification document (external to this repo) still says "OneTab"; when
  referenced, treat "OneTab" there as the old codename for VibeMenu.
- A public-name decision does **not** by itself resolve trademark clearance. Before any
  public release, VibeMenu's availability (USPTO/EU trademark, domain, GitHub/Homebrew)
  should be checked. That clearance is tracked as future work, not settled here.
- Brand assets (name, logo) are handled separately from the source license — see
  [`0003-license.md`](0003-license.md).

## Alternatives considered

- **Keep "OneTab" as an internal codename and rename before launch.** Rejected: the
  owner has chosen the name now, and starting under the codename would guarantee a later
  churny rename across code and docs.
