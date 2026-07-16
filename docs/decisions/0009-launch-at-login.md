# 0009 — Launch at Login via `SMAppService.mainApp`

- **Status:** Accepted
- **Date:** 2026-07-03
- **Deciders:** Kirill Chistov (product owner); implemented by Claude Code.

## Context

A menu-bar utility like VibeMenu is only useful if it is running, so "start automatically
at login" is table-stakes. It belongs in Settings, not onboarding. The question is *how* to
register a login item without violating the project's hard invariants — public APIs only, no
root, no privileged helper, no new dependency, no network/telemetry (AGENTS.md §6–9,
[`../SECURITY.md`](../SECURITY.md)).

macOS offers three historical paths: the deprecated `LSSharedFileList`; a bundled helper
app toggled via the old `SMLoginItemSetEnabled`; and, on macOS 13+, `SMAppService`. VibeMenu's
baseline is macOS 15 ([`0002-macos-baseline.md`](0002-macos-baseline.md)), so the modern API
is available.

## Decision

Use **`SMAppService.mainApp`** (`register()` / `unregister()` / `.status`) from the
`ServiceManagement` system framework to register **the main app itself** as a login item.

- **No helper app.** `SMAppService.mainApp` registers the main bundle directly, so we do not
  ship or maintain a separate login-helper target. (`SMAppService.loginItem(identifier:)` and
  `SMAppService.daemon`/`agent` exist for helpers/daemons; none are needed here.)
- **No root, no private APIs, no new dependency.** `ServiceManagement` is a public,
  documented, sandbox-tolerable system framework — not a third-party package. No `SMJobBless`,
  no privileged helper, no `pmset`/IOKit privilege. This keeps VibeMenu App-Store-shape and
  fits direct distribution ([`0004-direct-distribution.md`](0004-direct-distribution.md))
  equally.
- **Actual status is the single source of truth.** We do **not** persist a duplicate
  "launch at login" bool in `UserDefaults`. The toggle reads `SMAppService.mainApp.status`
  and treats **only** `.enabled` as ON; every other status (`.notRegistered`, `.notFound`,
  `.requiresApproval`, and any future case) reads as OFF. This is the one honest source: the
  OS, and the user, can change it in **System Settings → General → Login Items** independently
  of VibeMenu, so a stored bool would inevitably drift.
- **Reflect reality, never the attempt.** The toggle displays the status *after* the
  operation, not the requested state. A failed or partial `register()`/`unregister()` — common
  in unsigned/ad-hoc Debug builds — re-reads `.status` and self-corrects instead of showing a
  false ON/OFF. `SettingsView.onAppear` refreshes, so external System-Settings changes appear.

### Core/adapter split (same shape as the thermal / power / Claude slices)

- **Core (`VibeMenuCore/LoginItem.swift`, testable, framework-free):**
  - `LoginItemControlling` — a tiny protocol seam: `var isEnabled: Bool`, `register() throws`,
    `unregister() throws`.
  - `LoginItemModel` (`@MainActor @Observable`) — republishes the controller's *actual*
    `isEnabled`. `setEnabled(_:)` calls register/unregister, **catches any throw (no crash)**,
    and always re-reads `isEnabled`; `refresh()` re-reads on demand. Holds no persisted state.
- **App (`VibeMenuApp`, non-testable system edge):**
  - `SMAppServiceLoginItemController` — the real `LoginItemControlling` over
    `SMAppService.mainApp`. This is the only place `ServiceManagement` is imported; it keeps
    `SMAppService` out of `VibeMenuCore`.

Fake-controller unit tests cover enable / disable / failed-register / failed-unregister /
external-drift / idempotency, so all the decision logic is verified without ever touching the
real `SMAppService`.

## Consequences

- Users get a first-class **Settings → General → Launch VibeMenu at login** toggle with no
  helper app, no elevated privilege, and no new dependency.
- The toggle cannot lie: it mirrors the real system status and self-heals after a failed op or
  an external change.
- **Honest caveat:** in unsigned / ad-hoc **Debug** builds, `register()`/`unregister()` may
  throw or behave inconsistently (Launch Services trusts the registered bundle path, which is a
  transient DerivedData path, and macOS gates login items on code signature/notarization).
  Full runtime behavior is only trustworthy in a **signed/notarized** build; that verification
  is deferred with signing/notarization ([`../ROADMAP.md`](../ROADMAP.md)). The manual fallback
  (System Settings → General → Login Items → add VibeMenu) always works.
- No privacy/security posture change: no network, no telemetry, no elevated privileges, no
  transcript access. `SECURITY.md`'s "no privileged helper in v0.1" still holds — `SMAppService`
  is not a privileged helper.

## Alternatives considered

- **Bundled login-helper app + `SMLoginItemSetEnabled`.** Rejected: `SMLoginItemSetEnabled`
  is deprecated on modern macOS, and a helper app is a second target to build, sign, and
  maintain for zero benefit over `SMAppService.mainApp`.
- **`LSSharedFileList`.** Rejected: long-deprecated, clunky, and discouraged.
- **Persist a `launchAtLogin` bool in `UserDefaults` and reconcile.** Rejected: guarantees
  drift against the OS (which owns login-item state and lets the user change it directly), and
  a reconcile loop is strictly more complexity than just reading `.status` as the source of
  truth.
- **Auto-enable on first launch / add to onboarding.** Rejected: out of scope and presumptuous
  — the user opts in from Settings.
