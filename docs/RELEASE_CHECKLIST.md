# VibeMenu — Release Checklist

Two-part checklist:

- **Part A — GitHub release (the live process).** The gate for the **unsigned, not-notarized**
  zip shipped directly via GitHub Releases. **This is how VibeMenu ships, every time.**
- **Part B — Signed/notarized release (dormant).** Retained as the gate that *would* apply if
  signing were adopted. It is **not planned for the current phase** — see
  [`decisions/0004` Amendment 1](decisions/0004-direct-distribution.md#amendment-1-2026-07-15--stay-unsigned-for-the-current-validation-phase).
  Nothing in Part B blocks a release today.

The human product owner (Kirill Chistov) has final sign-off. A green checklist is necessary but not
sufficient.

---

## Part A — GitHub release (unsigned)

### 1. Clean working tree

- [ ] `git status` is clean (no uncommitted changes); you're on the intended commit.
- [ ] Decide the version, e.g. `0.2`.
- [ ] **Bundle version matches.** `App/Info.plist` `CFBundleShortVersionString` equals the
      version you're releasing (e.g. `0.2`) and `CFBundleVersion` is set (e.g. `1`). These
      are hand-maintained (`GENERATE_INFOPLIST_FILE = NO`), so bump them when the version
      changes — the packaging script only *names* the zip; it does not rewrite the plist.
      It will warn if the built bundle version does not match the requested version.

### 2. Build & test

- [ ] `swift build` passes cleanly.
- [ ] `scripts/test.sh` passes (all `AutomationPolicy` / heartbeat tests green).
- [ ] `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Release build`
      succeeds.

### 3. Package the zip

- [ ] `scripts/package-github-release.sh <version>` produces
      `dist/VibeMenu-v<version>-macos-arm64.zip` with no errors, and prints **no** bundle-version
      mismatch warning.

### 4. Launch smoke test

- [ ] Unzip the produced zip into `/Applications` (a *fresh* copy, not your build output) and
      open it via **System Settings → Privacy & Security → Open Anyway** — confirm it launches past Gatekeeper and the **VibeMenu
      menu-bar icon** appears in the menu bar (no Dock icon).

### 5. Manual smoke checklist

- [ ] **App icon in Finder** — in `/Applications` (and Get Info / Spotlight results),
      VibeMenu shows the proper VibeMenu app icon, not a generic/default icon.
- [ ] **Menu-bar icon appearance** — the menu-bar glyph is the VibeMenu mark, crisp and
      readable at small size, large enough (not tiny), shows no black background box, and
      tints correctly (template) in both light and dark menu-bar appearances.
- [ ] **Manual sleep prevention** — turn the **Sleep prevention** switch on; confirm a real
      assertion appears: `pmset -g assertions` lists a `PreventUserIdleSystemSleep` assertion
      owned by VibeMenu. Turn it off; confirm the assertion is released.
- [ ] **Claude active → auto assertion** — with a `claude` session active (heartbeat hook
      recommended for a reliable signal), confirm its session row reads **Working** and an
      assertion is held automatically.
- [ ] **Claude finishes → releases assertion** — when Claude finishes its turn (`Stop`),
      confirm the row reads **Done** and the auto assertion is released shortly after (unless
      the manual switch is on).
- [ ] **Quiet-work hold (Claude only)** — during a long silent Claude phase (a multi-minute
      build/test or a subagent/Task), confirm the row may read **Quiet** but the assertion
      **stays held** (verify with `pmset -g assertions`), up to the 15-minute cap. See
      [Support/ClaudeHeartbeat/README.md](../Support/ClaudeHeartbeat/README.md#verifying-the-quiet-work-hold-v011).
      Codex has no equivalent hold — do not expect this behavior from a Codex row.
- [ ] **Assertion status truthfulness** — confirm the status line under the switch matches
      reality: the owners shown (Manual / Claude / Codex) agree with `pmset -g assertions`, and
      the manual switch stays interactive while automation holds the assertion.
- [ ] **Needs approval** *(hook with `PermissionRequest` registered)* — trigger a permission
      prompt; confirm the row reads **Needs approval**, sorts to the top, and times from the
      request. Approve it; confirm the row clears once the session's **next** lifecycle event
      lands (it is not expected to clear on the click itself). *(Deny is a known upstream gap —
      ADR 0018.)*
- [ ] **Attention icon** — while the approval is pending, confirm the menu-bar glyph switches to
      the baked-orange attention asset at the same optical size as the normal icon; hiding the row
      must not clear it. Confirm it returns to the normal adaptive template icon afterward.
- [ ] **Agent notifications** *(opt-in)* — grant notification permission, trigger **Needs approval**
      and **Done**, and confirm one local banner per meaningful transition with the system default
      sound subject to macOS Focus/volume settings. Confirm no prompt, command, tool, or approval
      details appear. Verify click activation only as best-effort provider foregrounding.
- [ ] **Centralized Recent sessions** — with more than four eligible mixed Claude/Codex sessions,
      confirm there is one provider-neutral expansion control, shared priority/recency ordering,
      no duplicate provider-specific overflow, a maximum of ten expanded rows, and one combined
      older remainder count.
- [ ] **Codex sessions** *(opt-in)* — with the setting **off**, confirm no Codex rows. Turn it
      on with a Codex Desktop session active; confirm the row appears with a **Codex** pill, no
      CLI sessions appear, and an actively-working session holds the assertion.
- [ ] **Usage limits** *(opt-in)* — with both off, confirm no Limits sections. Turn each on and
      confirm real numbers or an honest no-data line — never a fabricated bar.
- [ ] **Settings row visibility** — open **Settings…**; toggle hiding the session and
      **Thermal** rows and confirm the menu reflects the choice and it persists.
- [ ] **Launch at Login toggle** — toggle **Launch VibeMenu at login**; confirm it does not
      crash. *Verify register/unregister against `SMAppService.mainApp.status` / System
      Settings → Login Items if possible* — note that reliable behavior needs a signed build,
      which is [not planned](decisions/0004-direct-distribution.md#amendment-1-2026-07-15--stay-unsigned-for-the-current-validation-phase);
      the Login Items fallback is the documented answer.

### 6. Public repository & community features

The repository is already public. Before publishing each release:

- [ ] **Re-confirm public-repo safety** — no secrets, certs, provisioning profiles, private data,
      personal absolute paths, or real runtime fixtures; `build/` and `dist/` remain gitignored and
      untracked.
- [ ] **Enable Issues** (Settings → General → Features → Issues). The bug/feature templates
      in `.github/ISSUE_TEMPLATE/` take effect once Issues is on.
- [ ] **(Optional) Enable Discussions** (Settings → General → Features → Discussions) for
      questions and ideas. The Issues "Questions & ideas" contact link points here.
- [ ] **Verify the README install flow** reads correctly on the public repo page — download →
      unzip → move to /Applications → open → Privacy & Security → **Open Anyway**.

### 7. Create the GitHub Release

- [ ] Create the release + tag (`gh release create v<version> …` or via the GitHub UI).
- [ ] **Attach** `dist/VibeMenu-v<version>-macos-arm64.zip` and **verify the asset actually shows
      on the published release** (not just uploaded locally).
- [ ] Fill in the release notes (template below).
- [ ] **Keep the caveat visible:** this build is **unsigned / not notarized**; first launch
      needs **System Settings → Privacy & Security → Open Anyway** (point the notes at
      `docs/INSTALL.md`, and mention build-from-source as the alternative).

### Release-notes template

```md
## VibeMenu v<version>

Keeps your Mac awake while a coding agent is working, and tells you when one needs you.
Supports Claude Code and (opt-in) Codex Desktop. Local-only: no network, no telemetry,
never reads your prompts.

**⚠️ Unsigned / not notarized build.** On first launch, macOS will warn that it
can't verify the app — approve it once via **System Settings → Privacy & Security →
Open Anyway** (see docs/INSTALL.md). Signing isn't planned for now; you can also build
it from source (README) — same app, two commands, still unsigned.

### Install
1. Download `VibeMenu-v<version>-macos-arm64.zip` below.
2. Unzip, move `VibeMenu.app` to /Applications.
3. Open it; when blocked, go to **System Settings → Privacy & Security → Open Anyway**.
   Look for the VibeMenu icon in the menu bar.

### Requirements
- macOS 15+, Apple Silicon.

### Known caveats
- Unsigned and not notarized (Gatekeeper warning on first open) — a deliberate cost
  decision for now, not an oversight.
- Does not prevent display sleep. Headless lid-closed support is not shipped; the privileged,
  watchdogged architecture remains under safety/security investigation.
- Launch at Login may be unreliable on an unsigned build; the System Settings →
  Login Items fallback works.
- "Needs approval" is Claude-only and needs the optional hook. It clears on the
  session's next lifecycle event, so a *denied* row can linger — Claude Desktop
  fires no hook event on deny.
- Codex support is Desktop-only (CLI sessions are ignored) and off by default, and
  Codex gets no quiet-work hold — use the manual switch for long silent Codex runs.

Full docs: docs/INSTALL.md · docs/FAQ.md · docs/PRIVACY.md
```

### 8. Privacy & security gate (every release)

These are not optional and do not depend on signing.

- [ ] **Privacy copy reviewed against code** — [PRIVACY.md](PRIVACY.md), the README privacy
      section, and the Settings disclosures accurately describe what *this* build reads. Every
      new or changed parser field is reflected there.
- [ ] **No transcript content is read or logged** — verified against the metadata-only design,
      not assumed. The privacy tests (payloads stuffed with prompts/tokens/secret paths) pass.
- [ ] **No new network code.** `swift build` output and the diff contain no networking; the
      no-network invariant holds.
- [ ] **No secrets in the repo or app bundle** (no keys, certs, credentials); `build/` and
      `dist/` are gitignored and untracked.
- [ ] **No personal absolute paths or private data** in tracked files or release notes.
- [ ] **Opt-in features are still off by default** in a fresh install (Codex sessions, both
      usage limits, Desktop titles).

---

## Part B — Signed/notarized release (dormant)

**This part is dormant.** VibeMenu ships unsigned by decision for its current phase
([`decisions/0004` Amendment 1](decisions/0004-direct-distribution.md#amendment-1-2026-07-15--stay-unsigned-for-the-current-validation-phase)),
so nothing below gates a release today. It is retained so the bar is already written down if the
owner revisits that decision — which would need a further amendment first. Do not claim any of it
is done, and do not treat it as pending work in the meantime.

### App packaging & distribution

- [ ] The Release `.app` (`LSUIElement = true`, no Dock icon) **actually launches** as a
      menu-bar agent (verified manually). *(This one does apply today — it's in Part A §4.)*
- [ ] App is **signed** with a Developer ID certificate.
- [ ] App is **notarized** by Apple.
- [ ] App is **stapled**, and a fresh download opens with no Gatekeeper warning.
- [ ] Hardened runtime enabled; App Sandbox decisions documented.

### Release hygiene

- [ ] Version number consistent across the app, tag, and the appcast.
- [ ] Homebrew cask bumped (only if Homebrew distribution ever exists). Note that a cask does
      **not** require signing — it's listed here only because it was part of the original 0004
      distribution plan, and it remains its own separate decision.

### Updates (only if an updater is ever added)

- [ ] Appcast is **EdDSA-signed**, served over HTTPS with a pinned public key.
- [ ] An update from the previous version was tested end-to-end (vN → vN+1).

### Clamshell (only if it is ever built)

- [ ] Crash-safe watchdog test passes — `disablesleep` restored to 0 on quit/crash/restart.

---

Gate authority: the human product owner (Kirill Chistov) approves the release.
