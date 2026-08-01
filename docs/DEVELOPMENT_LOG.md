# VibeMenu — Development Log

A chronological engineering log of VibeMenu development sessions. It records **what
happened during implementation**: files touched, commands run, validation results,
errors and their fixes, what was and was not verified, and the recommended next step.

> **How this differs from `decisions/`.** The [`decisions/`](decisions/) ADRs explain
> **why** important product/architecture choices were made. This log explains **what
> happened** while implementing them. When a session makes a non-trivial design choice,
> record the *what* here and the *why* in a new ADR.

**Convention:** append a new entry at the **bottom** for each implementation task. Keep
entries factual and short. Never paste faked results — only outputs of commands actually
run (AGENTS.md §11–13).

---

## 2026-07-02 — v0.0 repo bootstrap

**Task/session:** `v0.0 repo bootstrap`.

**Summary:** Created the initial VibeMenu repository foundation — docs, decision records,
license, and a buildable Swift package (pure, tested core + a compile-only menu-bar app
shell). No real monitoring, power assertions, or thermal reads.

**Files/categories added:**
- Documentation files (`README.md`, `PRODUCT.md`, `ARCHITECTURE.md`, `PRIVACY.md`,
  `SECURITY.md`, `ROADMAP.md`, `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`,
  `RELEASE_CHECKLIST.md`).
- ADRs under `decisions/` (`0001`–`0006`).
- Apache-2.0 `LICENSE`.
- `.gitignore`.
- Swift package (`Package.swift`).
- `VibeMenuCore` — pure, testable decision core + lightweight state models.
- `VibeMenuApp` — compile-only SwiftUI menu-bar shell.
- `VibeMenuCoreTests` — `AutomationPolicy` truth-table tests.
- `scripts/test.sh` — Swift Testing wrapper.

**Commands / procedures:**
- `swift build`
- `scripts/test.sh`

**Validation results:**
- `swift build` succeeded.
- `scripts/test.sh` passed **8/8** tests.

**Errors encountered & fixes:**
- The environment had **Command Line Tools only**, no full Xcode.
- **XCTest was not available** with Command Line Tools only.
- Swift Testing required extra `Testing.framework` / interop-dylib search paths, so plain
  `swift test` failed to build/load the tests.
- **Fix:** use `scripts/test.sh`, which detects Command Line Tools and adds the `-F` /
  `-rpath` paths (and just runs `swift test` under full Xcode).

**Verified:**
- The Swift package and the app executable **compiled**.
- Policy truth-table tests **passed**.

**Not verified:**
- Launchable `.app` (none existed yet).
- Menu-bar appearance.
- No-Dock-icon behavior.
- Quit behavior.
- `LSUIElement = true` behavior.
- Signing / notarization.

**Environment notes:**
- Command Line Tools only; no full Xcode; the menu-bar `.app` wrapper was not created yet.
- Full Xcode was installed *after* this session, for the next one.

**Recommended next step:** Create the Xcode `.app` wrapper and verify the app launches as
a real menu-bar app.

---

## 2026-07-02 — v0.0 macOS `.app` wrapper

**Task/session:** Create the real macOS `.app` wrapper around the existing Swift package
and verify it launches as a menu-bar-only app. (No v0.1 features; no real detection,
assertions, thermal, Codex, clamshell, Sparkle, or signing/notarization.)

**Summary:** Added a minimal Xcode app project that wraps the existing package. The app
target `VibeMenu` compiles the **existing, shared** SwiftUI shell
(`Sources/VibeMenuApp/VibeMenuApp.swift`) and **links** the `VibeMenuCore` package
library (no core logic duplicated). `LSUIElement = true` makes it a menu-bar-only agent
with no Dock icon. Also added this `DEVELOPMENT_LOG.md` and a minimal "update the log"
rule to `AGENTS.md` / `CLAUDE.md`.

**Files added:**
- `App/VibeMenu.xcodeproj/` — hand-authored minimal Xcode project (`project.pbxproj`,
  `project.xcworkspace/contents.xcworkspacedata`, shared scheme `VibeMenu`).
- `App/Info.plist` — app-bundle Info.plist: `LSUIElement = true`, bundle id
  `com.kirillchistov.VibeMenu`, `LSMinimumSystemVersion = $(MACOSX_DEPLOYMENT_TARGET)`.
- `DEVELOPMENT_LOG.md` — this log (with the v0.0 bootstrap entry above).
- `decisions/0007-app-wrapper-structure.md` — records the wrapper's project structure.

**Files changed:**
- `AGENTS.md`, `CLAUDE.md` — added the "update `DEVELOPMENT_LOG.md` after each task" rule.
- `README.md` — updated build/run instructions and the "next step" section.
- `ARCHITECTURE.md` — refreshed the now-stale "not yet a launchable `.app`" status lines.

**Design choices (project structure):**
- The Xcode project lives in `App/` and references the **root Swift package** via a local
  package reference (`relativePath = ..`), linking only the `VibeMenuCore` product.
- The app target **reuses the existing shell source file** rather than copying it, so
  there is a single source of truth. `swift build` still builds the package's
  `VibeMenuApp` executable; Xcode builds the launchable `.app` from the same file. See
  `decisions/0007-app-wrapper-structure.md`.
- Deployment target `macOS 15.0`; `SWIFT_VERSION = 6.0`; ad-hoc "Sign to Run Locally"
  (`CODE_SIGN_IDENTITY = -`) — no Developer-ID signing/notarization yet (deferred).

**Commands run:**
- `xcode-select -p` → `/Applications/Xcode.app/Contents/Developer` (full Xcode now present)
- `xcodebuild -version` → `Xcode 26.6 (17F113)`
- `swift build`
- `scripts/test.sh`
- `xcodebuild -list -project App/VibeMenu.xcodeproj`
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug -derivedDataPath <scratch> CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" build`
- `open <built VibeMenu.app>` + `lsappinfo` + `osascript … to quit` (runtime checks)

**Validation results:**
- `swift build` — **Build complete** (package unchanged; still builds).
- `scripts/test.sh` — **8/8** tests passed (Swift Testing, via full Xcode).
- `xcodebuild … build` — **BUILD SUCCEEDED**; produced an ad-hoc-signed `VibeMenu.app`.
- Package graph resolved the local package: `VibeMenu: <repo> @ local`.

**Errors encountered & fixes:**
- `request_access` (computer-use) could not resolve `VibeMenu` / `Dock` by name — a
  DerivedData-built app is not in the automation app registry — so UI could not be driven
  by the tool. **Fix/workaround:** verified runtime behavior via LaunchServices
  (`lsappinfo`) and a standard Quit Apple event instead of simulated clicks (see below).
- No build errors: the hand-authored `project.pbxproj` built on the first `xcodebuild`
  run after `xcodebuild -list` confirmed it parsed and the local package resolved.
- **Adversarial review pass** (3 lenses — Xcode-project correctness, spec completeness,
  repo invariants — each finding independently verified) surfaced one confirmed *minor*
  doc-consistency defect: the file-level comment in `Sources/VibeMenuApp/VibeMenuApp.swift`
  still said the app was "not …launched" and `LSUIElement` "unverified". **Fix:** updated
  that comment to match the wrapper reality (comment-only; re-ran `swift build` and
  `xcodebuild` green afterward). No project/invariant defects were found.

**Verified (how):**
- **Builds to a real bundle** — `xcodebuild … build` → `BUILD SUCCEEDED`; bundle at
  `…/Build/Products/Debug/VibeMenu.app`.
- **Correct bundle metadata** — read the *built* `Contents/Info.plist`:
  `CFBundleIdentifier = com.kirillchistov.VibeMenu`, `LSUIElement = true`,
  `LSMinimumSystemVersion = 15.0`, `CFBundleName = VibeMenu`.
- **Core linked, not duplicated** — no embedded `Contents/Frameworks`; `VibeMenuCore`
  links statically from the package (single source of the decision logic).
- **Launches & runs** — `open …VibeMenu.app`; `pgrep -x VibeMenu` found the process.
- **No Dock icon (LSUIElement effective)** — `lsappinfo` reported
  `ApplicationType = "UIElement"`, macOS's authoritative "menu-bar accessory, no Dock
  icon, no app-switcher entry" classification.
- **Quits cleanly** — a standard Quit Apple event (`osascript … to quit`, the same
  `NSApplication.terminate` path the in-app "Quit VibeMenu" button invokes) exited the
  process; `pgrep` then found nothing.

**Not verified (needs a human at the machine):**
- The literal rendering of the bolt status item in the menu bar.
- The dropdown opening on click and showing the placeholder rows
  (VibeMenu / Status / Thermal / Sleep prevention / Quit).
- A literal click on the "Quit VibeMenu" button (the *terminate path* it calls was
  verified; the button press itself was not clicked).
  These could not be automated because the DerivedData app is not grantable to
  computer-use; drive them with one manual launch + click.

**Recommended next step:** Do a human smoke test — launch the built `VibeMenu.app`, click
the menu-bar bolt to confirm the placeholder dropdown and the Quit button — then begin
v0.1 by wiring a real `PowerAssertionManager` (public `IOPMAssertionCreateWithName` /
`ProcessInfo.beginActivity`) behind the existing `PowerAsserting` protocol.

---

## 2026-07-02 — v0.1 thermal pressure status

**Task/session:** `v0.1 thermal pressure status`. Replace the placeholder Thermal row
with a real, lightweight thermal *pressure* reading from Apple's public API. No exact
temperatures, no fan RPM, no SMC/IOReport, no polling. Agent detection, power assertions,
sleep prevention, Codex, and clamshell explicitly **not** touched.

**Summary:** Wired the first real v0.1 signal. `ProcessInfo.processInfo.thermalState`
(current value) plus `ProcessInfo.thermalStateDidChangeNotification` (live updates) now
drive the menu's Thermal row through a small, testable seam. The pure mapping and the
observable model are unit-tested with a fake provider, so nothing requires forcing the
real Mac into a thermal state.

**Files added:**
- `Sources/VibeMenuCore/ThermalStatusProvider.swift` — `ThermalStatusObserving` protocol +
  real `SystemThermalStatusProvider` (public API, single NotificationCenter subscription,
  main-queue callbacks, no timer/polling).
- `Sources/VibeMenuCore/ThermalStatusModel.swift` — `@MainActor @Observable`
  `ThermalStatusModel`; takes a provider via DI, exposes `pressure` + `displayLabel`.
- `Tests/VibeMenuCoreTests/ThermalStatusTests.swift` — mapping tests
  (`.nominal/.fair/.serious/.critical`), display-label tests, and model state-update tests
  driven by a `FakeThermalProvider`.

**Files changed:**
- `Sources/VibeMenuCore/ThermalPressureState.swift` — added pure failable
  `init?(_: ProcessInfo.ThermalState)` (unmappable future case → `nil` → "Unknown") and a
  `displayName`. The 4-case `Comparable` model itself is unchanged (preserved).
- `Sources/VibeMenuCore/Monitoring.swift` — comment note pointing the deferred
  `SystemStatusProviding` snapshot seam at the new real thermal provider.
- `Sources/VibeMenuApp/VibeMenuApp.swift` — App owns a `ThermalStatusModel` (`@State`),
  starts it `.onAppear`; Thermal row now shows `thermal.displayLabel` instead of
  "Placeholder". Status and Sleep-prevention rows unchanged.
- `README.md`, `ARCHITECTURE.md` — status/feature notes for the live thermal slice.

**Design choice (no ADR):** used a focused `ThermalStatusObserving`/`SystemThermalStatusProvider`
seam rather than fleshing out `SystemStatusProviding`, because this slice is thermal-only
and DI keeps mapping + state updates testable. This is a straightforward implementation of
the already-decided thermal feature (decisions/0005), so per CLAUDE.md it gets an
ARCHITECTURE.md note, not a new ADR. `.unknown` was deliberately **not** added to
`ThermalPressureState`, to keep `AutomationPolicy`'s ordered comparisons total; "Unknown" is
the optional/`nil` path instead.

**Commands run:**
- `git status` (clean at start)
- `swift build` → **Build complete!**
- `scripts/test.sh` → **16 tests in 4 suites passed** (8 prior + 8 new).
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug build`
  → **BUILD SUCCEEDED**.
- Runtime: `open …/VibeMenu.app`, `pgrep -x VibeMenu`, `lsappinfo … ApplicationType`,
  `pmset -g therm`, `osascript … to quit`.

**Validation results:**
- `swift build` — clean.
- `scripts/test.sh` — 16/16 passed.
- `xcodebuild … build` — BUILD SUCCEEDED (ad-hoc-signed `VibeMenu.app`).

**Errors encountered & fixes:** None. Code compiled and tests passed on the first run
after the edits; no Swift 6 concurrency diagnostics (`@MainActor` model + `@Sendable`
main-queue callback path compiled cleanly).

**Verified (how):**
- Builds — all three commands green (output pasted in session).
- Unit correctness — mapping (each `ProcessInfo.ThermalState` → matching
  `ThermalPressureState`), labels (Nominal/Fair/Serious/Critical), and model updates
  (initial value, change emission, `nil` → "Unknown") all pass via the fake provider.
- Launches & menu-bar-only — `pgrep -x VibeMenu` found the process; `lsappinfo` reported
  `ApplicationType = "UIElement"` (no Dock icon).
- Quits cleanly — Quit Apple event (same `NSApplication.terminate` path as the button)
  exited the process; `pgrep` then found nothing.
- Current machine thermal state — `pmset -g therm`: "No thermal warning level has been
  recorded" (i.e. nominal), so the Thermal row should read **Nominal** right now.

**Not verified (needs a human at the machine):**
- The literal dropdown rendering — that the Thermal row visibly shows "Thermal: Nominal"
  (or the current state) and re-renders on a real thermal change. The DerivedData app is
  not grantable to computer-use, so the click/rendering could not be automated.
- Live update under actual thermal load (would require stressing the Mac); the update path
  is covered by the model unit test with a fake, not by a real hardware transition.

**Recommended next step:** Human smoke test — launch the built `VibeMenu.app`, open the
menu, and confirm the Thermal row shows the real state (expected "Nominal" now). Then wire
the real `PowerAssertionManager` (public `IOPMAssertionCreateWithName` /
`ProcessInfo.beginActivity`) behind the existing `PowerAsserting` protocol.

---

## 2026-07-02 — v0.1 manual sleep prevention

**Task/session:** `v0.1 manual sleep prevention`. Add a manual menu-bar "Keep Awake"
control that holds/releases a real public macOS power assertion (idle *system* sleep,
lid open). Explicitly **not** touched: Claude/agent detection, activity-driven automatic
sleep prevention, Codex, clamshell/lid-closed, `pmset disablesleep`, `caffeinate`,
privileged helper/root, SMC/IOReport/private APIs, exact temperatures, polling loops,
dependencies, network/telemetry.

**Summary:** Wired the third v0.1 signal. A three-layer seam (mirroring the thermal
slice) turns the former no-op `StubPowerAssertionManager` into a real assertion:
`IOKitPowerAssertion` calls `IOPMAssertionCreateWithName`
(`kIOPMAssertionTypePreventUserIdleSystemSleep`) / `IOPMAssertionRelease`;
`SystemPowerAssertionManager` owns idempotency + state + error handling behind the
`PowerAsserting` protocol; `PowerAssertionModel` (`@MainActor @Observable`) republishes
Active/Inactive to the menu. The menu gained a "Start/Stop Keep Awake" button and the
Sleep-prevention row is now live; Quit releases any held assertion first.

**Files added:**
- `Sources/VibeMenuCore/PowerAssertionManager.swift` — `PowerAssertionCreating` seam +
  real `IOKitPowerAssertion`, `PowerAsserting` + `SystemPowerAssertionManager` (idempotent,
  at-most-one assertion, failure-safe, `deinit` releases), and the `@MainActor @Observable`
  `PowerAssertionModel`.
- `Tests/VibeMenuCoreTests/PowerAssertionTests.swift` — 12 tests over a spy backend (no
  real system assertion): initial inactive, one assertion on enable, idempotent
  enable/disable, release on disable, disable-when-never-enabled, failed-creation stays
  inactive, retry-after-failure, `deinit` releases, plus model toggle/cleanup/label.

**Files changed:**
- `Sources/VibeMenuCore/Monitoring.swift` — removed the power-assertions protocol+stub
  (moved to the real implementation file); left a pointer note.
- `Sources/VibeMenuApp/VibeMenuApp.swift` — app owns a `PowerAssertionModel`; menu shows
  `Sleep prevention: Active/Inactive`, adds the Start/Stop Keep Awake button, and Quit
  calls `cleanup()` before `terminate`. Removed the unused placeholder snapshot.
- `README.md`, `ARCHITECTURE.md` — status/feature notes for the live manual-keep-awake slice.

**Design choice (no ADR):** reused the thermal slice's DI shape (low-level syscall seam +
manager + observable model) rather than inventing a new pattern. This is a straightforward
implementation of the already-decided sleep-prevention feature (decisions/0005), so per
CLAUDE.md it gets an ARCHITECTURE.md note, not a new ADR. Chose
`IOPMAssertionCreateWithName` over `ProcessInfo.beginActivity` because it exposes a named
assertion and explicit release, matching the "surface assertions honestly" goal and giving
`pmset -g assertions` a clear `VibeMenu Keep Awake` entry.

**Commands run:**
- `git status` (clean at start)
- `swift build` → **Build complete!**
- `scripts/test.sh` → **28 tests in 6 suites passed** (16 prior + 12 new).
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug build`
  → **BUILD SUCCEEDED** (ad-hoc-signed `VibeMenu.app`).
- Runtime: `open …/VibeMenu.app`, `pgrep -x VibeMenu`, `lsappinfo … ApplicationType`,
  `pmset -g assertions`, `osascript … quit`. Plus a runtime harness compiled from the
  **real** `PowerAssertionManager.swift` + `PowerAssertionState.swift` (`swiftc … -framework
  IOKit`) that drives `SystemPowerAssertionManager` and snapshots `pmset` before/during/after.

**Validation results:**
- `swift build` — clean.
- `scripts/test.sh` — 28/28 passed.
- `xcodebuild … build` — BUILD SUCCEEDED.

**Errors encountered & fixes:**
- Harness first failed to link (`library 'VibeMenuCore' not found` — SwiftPM emits no
  static lib) and then `expressions are not allowed at the top level`. **Fix:** compiled the
  real core sources directly alongside the harness and renamed it `main.swift`.
- A leftover `VibeMenu` process from a *previous* session's DerivedData lingered after the
  quit event; confirmed via `ps` it was a different bundle path and cleared it. My own
  launched instance quit cleanly.

**Verified (how):**
- Builds — all three commands green (output pasted in session).
- Unit correctness — 12 tests over a spy backend: idempotent enable/disable, at-most-one
  assertion, disable/`deinit`/`cleanup` release, failed-creation stays inactive, retry works.
- **Real assertion effective** — the harness (running the exact `SystemPowerAssertionManager`
  / `IOKitPowerAssertion` source) produced, while held:
  `pid …(keepawake_harness): … PreventUserIdleSystemSleep named: "VibeMenu Keep Awake"` in
  `pmset -g assertions`; state went inactive → preventingIdleSleep → (idempotent) → inactive;
  the named assertion was **absent** before and **gone** after release.
- App launches menu-bar-only — `pgrep -x VibeMenu` found it; `lsappinfo` reported
  `ApplicationType = "UIElement"` (no Dock icon). At startup no `VibeMenu Keep Awake`
  assertion is held (correct initial Inactive). (A transient `runningboardd` foreground
  assertion tagged with the bundle id appears at launch — that is macOS's own launch
  assertion, **not** VibeMenu's `Keep Awake` assertion.)
- Quits cleanly — Quit Apple event exited the process.

**Not verified (needs a human at the machine):**
- The literal in-app menu: that clicking **Start Keep Awake** flips the row to
  `Sleep prevention: Active` and back on **Stop**, as rendered in the dropdown. The
  DerivedData `.app` is not grantable to computer-use, so the click/render could not be
  automated; the button → model → manager wiring is covered by unit tests and the real-API
  harness, but the literal click was not performed.
- Real hardware idle-sleep being blocked over a long idle window (would require waiting out
  the system idle timer); the assertion's presence in `pmset` is the public evidence.

**Recommended next step:** Human smoke test — launch the built `VibeMenu.app`, click
**Start Keep Awake**, confirm the row shows `Sleep prevention: Active` and that
`pmset -g assertions` lists `VibeMenu Keep Awake`, then **Stop** and confirm both clear.
Also, per AGENTS.md §18, have a **different** model (e.g. Codex) review the IOKit adapter
before final human sign-off.

---

## 2026-07-02 — v0.1 Keep Awake control: Start/Stop button → native Toggle

**Task/session:** UI-only fix for manual sleep prevention. Human feedback: the menu had
no usable visible control; it must be a **native toggle** (macOS switch), labelled
**"Keep Awake"**, lightweight and minimal — not a Start/Stop button. Backend was **not**
approved to change beyond what a clean toggle binding needs. Explicitly **not** touched:
the `PowerAssertionManager` core/IOKit adapter, agent detection, automatic sleep
prevention, thermal slice, Codex, clamshell, or any new settings/animation/onboarding.

**Summary:** Replaced the `Button("Start/Stop Keep Awake")` in the menu with a native
SwiftUI `Toggle("Keep Awake", …)` using `.toggleStyle(.switch)`. The toggle binds to the
**existing** `PowerAssertionModel`: `isOn` reads `keepAwake.isActive`; ON calls
`keepAwake.enable()`, OFF calls `keepAwake.disable()`. No backend change — the model
already exposed `isActive`/`enable()`/`disable()`, so this is a pure UI swap. The
`Sleep prevention: Active/Inactive` row, Quit → `cleanup()`, and all other rows are
unchanged. The now-unused `PowerAssertionModel.toggle()` was kept (still covered by
`PowerAssertionModelTests`); no tests changed.

**Files changed:**
- `Sources/VibeMenuApp/VibeMenuApp.swift` — swapped the Start/Stop `Button` for a native
  `Toggle("Keep Awake", isOn:)` (`.switch` style) bound via a `Binding` to
  `keepAwake.isActive` / `enable()` / `disable()`.
- `README.md` — "Start/Stop Keep Awake control" → "Keep Awake toggle" (one line).
- `ARCHITECTURE.md` — control description updated to the native `Toggle` (`.switch`).

**Commands run:**
- `git status`
- `swift build` → **Build complete!**
- `scripts/test.sh` → **28 tests in 6 suites passed** (unchanged; UI-only change).
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug build`
  → **BUILD SUCCEEDED**.
- Runtime: `open …/VibeMenu.app`, `pgrep -x VibeMenu`, `lsappinfo … ApplicationType`,
  `pmset -g assertions`, `osascript … quit`. Plus a real-API harness (`swiftc` over the
  **real** `PowerAssertionManager.swift` + `PowerAssertionState.swift`, `-framework IOKit`)
  driving `SystemPowerAssertionManager.preventIdleSleep()`/`allowSleep()` — the exact
  methods the toggle's binding calls — and snapshotting `pmset` before/ON/OFF.

**Validation results:**
- `swift build` — clean.
- `scripts/test.sh` — 28/28 passed (no test edits needed).
- `xcodebuild … build` — BUILD SUCCEEDED (ad-hoc-signed `VibeMenu.app`).

**Errors encountered & fixes:** None. Compiled and tested green on the first run after
the edit.

**Verified (how):**
- Builds — all three commands green (output pasted in session).
- App launches menu-bar-only — `pgrep -x VibeMenu` found the process; `lsappinfo`
  reported `ApplicationType = "UIElement"` (no Dock icon).
- Correct initial state — at launch `pmset -g assertions` has **no** `VibeMenu Keep Awake`
  entry (matches the toggle's initial OFF / `Sleep prevention: Inactive`).
- **ON/OFF drives the real assertion** — the harness (running the exact
  `enable()`→`preventIdleSleep()` / `disable()`→`allowSleep()` path the toggle binds to):
  `BEFORE` none → `ON` `PreventUserIdleSystemSleep named: "VibeMenu Keep Awake"` present in
  `pmset` (state `preventingIdleSleep`) → `OFF` gone (state `inactive`).
- Quits cleanly, no leaked assertion — Quit Apple event (same `NSApplication.terminate`
  path as the Quit button, which first calls `cleanup()`) exited the process; `pmset`
  showed no lingering `VibeMenu Keep Awake` assertion after.

**Not verified (needs a human at the machine):**
- The **literal rendering and click of the `Keep Awake` toggle** in the dropdown: that the
  native switch is visibly present, and that flipping it ON shows `Sleep prevention:
  Active` (+ `VibeMenu Keep Awake` in `pmset`) and OFF returns to `Inactive`. The
  DerivedData `.app` is not grantable to computer-use, so the click/render could not be
  automated; the ON/OFF→assertion path is covered by unit tests and the real-API harness,
  but the toggle press itself was not clicked.
- Real hardware idle-sleep being blocked over a long idle window (the assertion's presence
  in `pmset` is the public evidence).

**Recommended next step:** Human smoke test — launch the built `VibeMenu.app`, open the
menu, confirm a native **Keep Awake** switch is visible; flip it ON and confirm the row
reads `Sleep prevention: Active` and `pmset -g assertions` lists `VibeMenu Keep Awake`,
then OFF and confirm both clear. If approved, proceed to wiring the real
`AgentMonitor` (process presence + session-file mtime) for automatic sleep prevention.

---

## 2026-07-02 — v0.1 sleep-prevention UI simplification

**Task/session:** `v0.1 sleep-prevention UI simplification`. UI-only. Human feedback: the
two separate rows (`Sleep prevention: Active/Inactive` text **and** a `Keep Awake` toggle)
were not approved. Collapse them into one compact row: `Sleep prevention` label on the
left, a native switch on the right. Backend **not** to change unless absolutely necessary.
Explicitly **not** touched: the `PowerAssertionManager` core/IOKit adapter, agent
detection, automatic sleep prevention, thermal slice, Codex, clamshell, private APIs,
dependencies, or any new settings/icons/colors/animations/onboarding.

**Summary:** Replaced the two-row layout (a `Text("Sleep prevention: …")` status row plus a
labelled `Toggle("Keep Awake", …)`) with a single `HStack`: `Text("Sleep prevention")` +
`Spacer()` + `Toggle("", …).labelsHidden().toggleStyle(.switch)`. The switch binds to the
**existing** `PowerAssertionModel` exactly as before — `isOn` reads `keepAwake.isActive`, ON
calls `keepAwake.enable()`, OFF calls `keepAwake.disable()`. No backend change: the model
already exposed `isActive`/`enable()`/`disable()`, so `displayLabel` is simply no longer
rendered in the menu (kept on the model; still unit-tested). No tests changed.

**Files changed:**
- `Sources/VibeMenuApp/VibeMenuApp.swift` — removed the `Sleep prevention: Active/Inactive`
  text row and the labelled `Keep Awake` toggle; added one `HStack` row with the label and a
  label-hidden `.switch` toggle bound to the same `PowerAssertionModel`. Updated the
  file-level comment to describe the single-row control.
- `README.md` — status blurb and app-run section: two-row / "Keep Awake toggle" → single
  compact **Sleep prevention** row with a native switch.
- `ARCHITECTURE.md` — `PowerAssertionModel` control description updated to the single-row
  layout (label + label-hidden `.switch` toggle bound to `isActive`).

**Commands run:**
- `git status` (clean at start)
- `swift build` → **Build complete!**
- `scripts/test.sh` → **28 tests in 6 suites passed** (unchanged; UI-only change).
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug build`
  → **BUILD SUCCEEDED**.
- Runtime: `open …/VibeMenu.app`, `pgrep -x VibeMenu`, `lsappinfo … ApplicationType`,
  `pmset -g assertions`, `osascript … quit`.

**Validation results:**
- `swift build` — clean.
- `scripts/test.sh` — 28/28 passed (no test edits needed).
- `xcodebuild … build` — BUILD SUCCEEDED (ad-hoc-signed `VibeMenu.app`).

**Errors encountered & fixes:** None. Compiled and tested green on the first run after the
edit.

**Verified (how):**
- Builds — all three commands green (output pasted in session).
- App launches menu-bar-only — `pgrep -x VibeMenu` found the process; `lsappinfo` reported
  `ApplicationType = "UIElement"` (no Dock icon).
- Correct initial state — at launch `pmset -g assertions` has **no** `VibeMenu Keep Awake`
  entry (matches the switch's initial OFF).
- Quits cleanly — Quit Apple event (same `NSApplication.terminate` path as the Quit button,
  which first calls `cleanup()`) exited the process.
- The ON/OFF → real-assertion binding path (`enable()`→`preventIdleSleep()` /
  `disable()`→`allowSleep()`) is unchanged from the prior session and remains covered by the
  12 `PowerAssertion`/`PowerAssertionModel` unit tests and the earlier real-API `pmset`
  harness; only the surrounding SwiftUI layout changed.

**Not verified (needs a human at the machine):**
- The literal dropdown rendering: that the menu now shows a **single** `Sleep prevention`
  row with the switch on the right, with **no** separate `Sleep prevention: Active/Inactive`
  text row and **no** separate `Keep Awake` row; and that flipping the switch ON lists
  `VibeMenu Keep Awake` in `pmset -g assertions` and OFF clears it. The DerivedData `.app`
  is not grantable to computer-use, so the click/render could not be automated.

**Recommended next step:** Human visual smoke test — launch the built `VibeMenu.app`, open
the menu, confirm the single `Sleep prevention` row + right-side switch (no old rows), and
flip it ON/OFF while watching `pmset -g assertions`. If approved, proceed to wiring the real
`AgentMonitor` for automatic sleep prevention.

---

## 2026-07-02 — v0.1 sleep-prevention: Codex-review cleanup

**Task/session:** Apply the *minor changes* from Codex's review of the manual
sleep-prevention (IOKit power assertion) slice. Codex verdict was **"approve with minor
changes"**, no blockers. No new product features: no Claude/agent detection, no automatic
sleep prevention, no Codex support, no clamshell/lid-closed, no new dependencies.

**Summary:** Small correctness/clarity fixes only. Corrected stale docs, adopted the newer
SDK constant spelling, made assertion *release* report success/failure (only clearing the
held id on success + logging on failure), added a termination-time cleanup hook so
Apple-event quits also release the assertion, and added a light concurrency note. One new
unit test covers the release-failure path.

**Codex findings addressed:**
1. **Stale docs in `PowerAssertionState.swift`** — the header said real assertions were
   "not wired yet" and referenced `ProcessInfo.beginActivity(options:)`. Rewritten to state
   that manual real assertions **are** wired via public IOKit
   (`IOPMAssertionCreateWithName` / `IOPMAssertionRelease`,
   `kIOPMAssertPreventUserIdleSystemSleep`) and that **no clamshell/lid-close** behavior is
   implemented.
2. **Newer SDK spelling** — switched `kIOPMAssertionTypePreventUserIdleSystemSleep` →
   `kIOPMAssertPreventUserIdleSystemSleep` in `IOKitPowerAssertion.create` (and matching
   comments in `PowerAssertionManager.swift` / `VibeMenuApp.swift` / `ARCHITECTURE.md` /
   `README.md`). Verified in the installed SDK's `IOPMLib.h` that the old constant is just a
   `#define` alias of the new one, so both compile; the app-target build confirms it builds.
3. **Release failure handling** — the low-level `PowerAssertionCreating.release` seam now
   returns `Bool` (`IOPMAssertionRelease(id) == kIOReturnSuccess`; `@discardableResult`).
   `SystemPowerAssertionManager.allowSleep()` clears `assertionID` **only** on a successful
   release; on failure it keeps the id (state stays `.preventingIdleSleep`, so the UI does
   not falsely show "off") and logs locally (no transcript content / paths). `deinit`
   remains best-effort. New test `failedReleaseKeepsAssertionHeld` asserts the id is kept on
   a simulated failed release and freed on a later successful retry.
4. **App termination cleanup hook** — added a minimal `@MainActor AppDelegate`
   (`NSApplicationDelegateAdaptor`) that **owns** the `PowerAssertionModel` and calls
   `keepAwake.cleanup()` in `applicationWillTerminate`, so Apple-event / app-driven quits
   also explicitly release the assertion (complements the in-menu Quit button's `cleanup()`
   and the manager `deinit`). No other lifecycle machinery added.
5. **Concurrency note** — added a short doc comment on `SystemPowerAssertionManager`: it is
   not internally synchronized, is intended to be driven through the `@MainActor`
   `PowerAssertionModel`, and a future off-main automation caller must serialize access or
   actor-isolate it. Deliberately **not** refactored to an actor now.

**Files changed:**
- `Sources/VibeMenuCore/PowerAssertionState.swift` — corrected the stale header doc
  (real assertions wired; public IOKit; no clamshell).
- `Sources/VibeMenuCore/PowerAssertionManager.swift` — newer SDK constant; `release` seam
  returns `Bool`; `allowSleep()` clears id only on success + logs failure; concurrency note.
- `Sources/VibeMenuApp/VibeMenuApp.swift` — added `AppDelegate` termination cleanup hook
  (owns the model); Quit-button comment + constant name updated.
- `Tests/VibeMenuCoreTests/PowerAssertionTests.swift` — spy `release` returns `Bool` with a
  `shouldFailRelease` flag; new `failedReleaseKeepsAssertionHeld` test.
- `README.md`, `ARCHITECTURE.md` — constant name updated for consistency (one symbol each).

**Commands run:**
- `git status` (clean at start)
- `swift build` → **Build complete!**
- `scripts/test.sh` → **29 tests in 6 suites passed** (28 prior + 1 new release-failure test).
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug … build`
  → **BUILD SUCCEEDED** (ad-hoc-signed `VibeMenu.app`).
- Runtime: `open …/VibeMenu.app`, `pgrep -x VibeMenu`, `lsappinfo … ApplicationType`,
  `pmset -g assertions`, `osascript … to quit`.

**Validation results:**
- `swift build` — clean.
- `scripts/test.sh` — 29/29 passed.
- `xcodebuild … build` — BUILD SUCCEEDED.

**Errors encountered & fixes:** None. Compiled and tested green on the first run after the
edits (the `Bool`-returning `release` and the `@MainActor AppDelegate` produced no Swift 6
concurrency diagnostics).

**Verified (how):**
- Builds — all three commands green (output pasted in session).
- Unit correctness — 29 tests pass, including the new `failedReleaseKeepsAssertionHeld`
  (id kept + state stays active on a failed release; freed on successful retry).
- SDK constant — confirmed in `…/MacOSX.sdk/…/IOPMLib.h` that
  `kIOPMAssertionTypePreventUserIdleSystemSleep` is `#define`d as
  `kIOPMAssertPreventUserIdleSystemSleep`; both compile.
- App launches menu-bar-only — `pgrep -x VibeMenu` found the process; `lsappinfo` reported
  `ApplicationType = "UIElement"` (no Dock icon).
- Correct initial state — at launch `pmset -g assertions` has **no** `VibeMenu Keep Awake`
  entry.
- Clean quit — an Apple-event quit (`osascript … to quit`, which drives
  `NSApplication.terminate` → `applicationWillTerminate`) exited the process with **no**
  lingering `VibeMenu Keep Awake` assertion.

**Not verified (needs a human at the machine):**
- The new `applicationWillTerminate` hook releasing an **actively held** assertion: it fires
  on the Apple-event quit path, but I could not first flip the toggle ON (the DerivedData
  `.app` is not grantable to computer-use), so at quit time no assertion was held. The
  `cleanup()` it calls is unit-tested (`cleanupReleasesActiveAssertion`); the
  will-terminate→cleanup wiring itself was exercised only with an inactive assertion.
- The literal dropdown render / toggle click (unchanged from prior sessions; still a manual
  smoke-test step).

**Recommended next step:** Human smoke test — launch the built `VibeMenu.app`, flip
**Sleep prevention** ON, confirm `pmset -g assertions` lists `VibeMenu Keep Awake`, then
quit via ⌘Q / an Apple event **without** first toggling OFF and confirm the assertion is
gone (exercises the new `applicationWillTerminate` cleanup with a held assertion). If
approved, proceed to wiring the real `AgentMonitor` for automatic sleep prevention.

---

## 2026-07-02 — v0.1 Claude detection L1

**Task/session:** `v0.1 Claude detection L1`. Add the first Claude Code detection layer
and show it as a simple **Claude** status row. **OBSERVATION ONLY** — explicitly **not**
touched: automatic/activity-driven sleep prevention, wiring detection to the Keep-Awake
toggle or any power assertion, Codex, Claude hooks, clamshell, network/telemetry,
Keychain/cookies, Accessibility/Full-Disk permissions, transcript-content reading or
JSONL parsing, new dependencies.

**Summary:** Wired a metadata-only L1 detector behind the same DI shape as the
thermal/power slices. Two conservative signals — process presence (a `claude`-named
process via public `libproc`) and session-file *mtime* under `~/.claude` — feed a pure,
unit-tested decision function that yields a `ClaudeActivityState`
(`notDetected`/`running`/`active`/`idle`/`unknown`). A thin provider gathers the signals
on a coarse temporary timer; an `@Observable` model republishes to the menu's new
**Claude** row. Never reads file contents.

**Detection design (decision table, recency default 90s):**
- process + recent session mtime → `.active`
- process + stale session mtime → `.idle`
- process + no session files → `.running`
- no process + recent session mtime → `.idle` (conservative — a short-lived/`node`-hosted
  CLI can be missed by the name check; fresh files ⇒ recently active, but we don't claim a
  running process)
- no process + stale/no files → `.notDetected`
- `.unknown` = pre-observation state owned by the model (never returned by `evaluate`).

**Honesty / limitations (documented in code + ARCHITECTURE.md):** L1 will have false
positives/negatives; the process check matches the process *name* `claude` exactly
(case-sensitive — so it correctly ignores the capital-`C` "Claude" desktop app, but
*misses* a CLI hosted by a `node` process). It cannot tell "working" from "waiting for
input" and deliberately does not model a waiting state. Kept a **separate** model from
`AgentActivityState` (the future automation-loop input), which stays stubbed.

**Files added:**
- `Sources/VibeMenuCore/ClaudeActivityState.swift` — the `ClaudeActivityState` enum +
  `displayName`, the `ClaudeActivitySignals` value type, and the pure
  `evaluate(signals:now:recencyThreshold:)` decision function.
- `Sources/VibeMenuCore/ClaudeActivityProvider.swift` — `ClaudeActivityObserving`
  protocol + real `ClaudeActivityProvider` (thin adapter: `libproc` process check +
  bounded stat-only two-level walk of `~/.claude/projects` and `history.jsonl`; coarse
  `DispatchSourceTimer` refresh, main-queue delivery). Metadata only; logs no paths.
- `Sources/VibeMenuCore/ClaudeActivityModel.swift` — `@MainActor @Observable`
  `ClaudeActivityModel`, mirrors `ThermalStatusModel`.
- `Tests/VibeMenuCoreTests/ClaudeActivityTests.swift` — 12 tests: the 5 required cases +
  extras (no-process/stale → notDetected, threshold boundary, future-mtime clock skew,
  metadata-only structural check), display labels, and model state-update via a fake
  provider.

**Files changed:**
- `Sources/VibeMenuApp/VibeMenuApp.swift` — app owns a `ClaudeActivityModel` (`@State`),
  starts it `.onAppear`; menu gained `Text("Claude: \(claude.displayLabel)")` between
  Status and Thermal. File-level doc updated (three real signals; L1 observation-only).
- `README.md`, `ARCHITECTURE.md`, `PRIVACY.md` — status/feature/privacy notes for the L1
  slice (metadata-only, observation-only, temporary poll).

**Design choice (no ADR; flagged for the human):** followed the precedent of the thermal
and power slices — an ARCHITECTURE.md note rather than a new ADR — since Claude detection
is an already-decided v0.1 feature (decisions/0005 item 2). The one novel wrinkle is the
**temporary coarse timer**, which is a documented *exception* to the event-driven mandate
in decisions/0006 / ARCHITECTURE.md. The task explicitly sanctioned a conservative 5–10s
L1 poll as temporary, so it is documented in code + ARCHITECTURE.md + here with a
`TODO(L2)` to move to FSEvents. If the product owner prefers this recorded as a formal
ADR, that is a one-file follow-up.

**Commands run:**
- `git status` (clean at start)
- `swift build` → **Build complete!** (clean after fixing one `String(cString:)`
  deprecation warning by switching to the pointer overload)
- `scripts/test.sh` → **41 tests in 9 suites passed** (29 prior + 12 new).
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug build`
  → **BUILD SUCCEEDED** (ad-hoc-signed `VibeMenu.app`).
- Real-adapter harness: `swiftc -O` over the **real** `ClaudeActivityState.swift` +
  `ClaudeActivityProvider.swift` + a `main.swift` that runs `gatherSignals()` +
  `evaluate()` on this machine.
- Runtime: `open …/VibeMenu.app`, `pgrep -x VibeMenu`, `lsappinfo … ApplicationType`,
  `osascript … to quit`. Plus `ps -Ac`, `ls -ld ~/.claude*`, `find ~/.claude/projects`
  for ground truth.

**Validation results:**
- `swift build` — clean, no warnings.
- `scripts/test.sh` — 41/41 passed.
- `xcodebuild … build` — BUILD SUCCEEDED.

**Errors encountered & fixes:**
- `String(cString: [CChar])` array overload is deprecated → switched to the
  (non-deprecated) `String(cString: UnsafePointer<CChar>)` pointer overload inside
  `withUnsafeMutableBytes`. Rebuilt clean.

**Verified (how):**
- Builds — all three commands green (output pasted in session).
- Unit correctness — 12 tests cover the full decision table, boundary, clock-skew, labels,
  and model updates via a fake provider (no real process/`~/.claude` needed).
- **Real adapter works end-to-end on this machine** — the harness (running the exact
  `ClaudeActivityProvider.gatherSignals()` + `evaluate()`) reported `processPresent = true`
  (correctly matched the lowercase `claude` CLI at pids 28640/30704, *not* the capital-`C`
  "Claude" desktop app), most-recent session mtime age ≈ 3s, ⇒ `ClaudeActivityState.active`
  / label "Active" — matching ground truth (`ps -Ac` + `find ~/.claude/projects` showed a
  session file modified seconds earlier). `~/.claude/history.jsonl` was absent and handled
  as `nil` (no crash).
- App launches menu-bar-only — `pgrep -x VibeMenu` found it; `lsappinfo` reported
  `ApplicationType = "UIElement"` (no Dock icon). Quit cleanly via Apple event.

**Not verified (needs a human at the machine):**
- The literal dropdown rendering — that the **Claude** row visibly shows "Claude: Active"
  (current machine state) between Status and Thermal, and re-renders as detection changes.
  The DerivedData `.app` is not grantable to computer-use, so the click/render could not be
  automated; the state→label path is unit-tested and the real detection is harness-verified,
  but the on-screen row was not visually confirmed.
- Live `active → idle → notDetected` transitions over time in the running app (would require
  quitting the real `claude` CLI and waiting out the 90s window); the transitions are covered
  by unit tests and the pure evaluator, not by a timed in-app observation.

**Recommended next step:** Human smoke test — launch the built `VibeMenu.app`, open the
menu, and confirm the **Claude** row shows the real state (expected **Active** now, while a
`claude` CLI is running with recent session activity); then quit the `claude` CLI, wait
~90s, and confirm the row falls back to **Idle**/**Not detected**. Do **not** wire L1 into
the automation loop until the human approves the detection's reliability.

---

## 2026-07-02 — v0.1 Claude detection responsiveness + menu cleanup

**Task/session:** `v0.1 Claude detection responsiveness + menu cleanup`. Two changes on
human feedback: (1) remove the now-unnecessary `Status: Not monitoring yet` menu row; (2)
make Claude L1 detection feel more responsive while staying lightweight. Explicitly **not**
touched: automatic/activity-driven sleep prevention, wiring L1 to the Keep-Awake toggle or
any power assertion, Codex, Claude hooks, FSEvents, clamshell, transcript-content reading
or JSONL parsing, network/telemetry, dependencies. No new UI beyond the row removal.

**Summary:** UI cleanup plus a pure-constant retune. The placeholder Status row is gone;
the menu now shows only live rows (VibeMenu / Claude / Thermal / Sleep prevention / Quit).
Detection was sped up by tightening three named defaults — no algorithm change, no new
signals, still the same coarse coalesced timer (not a busy loop) and metadata-only walk:
- `ClaudeActivityProvider.refreshInterval` 8s → **2s**
- timer leeway 2s → **0.5s** (now a named `ClaudeActivityProvider.refreshLeeway` constant,
  no longer an inline `.seconds(2)` magic number)
- `ClaudeActivityState.defaultRecencyThreshold` 90s → **20s**

Net effect: a finished session now falls from `active` toward `idle`/`notDetected` within
~20s + a ~2s tick instead of ~90s + an ~8s tick.

**Files changed:**
- `Sources/VibeMenuApp/VibeMenuApp.swift` — removed the `Text("Status: Not monitoring yet")`
  row (no replacement text); updated the file-level and view doc comments that referenced a
  placeholder Status row.
- `Sources/VibeMenuCore/ClaudeActivityProvider.swift` — `refreshInterval` 8→2s; added the
  named `refreshLeeway` (0.5s) constant and used it in `timer.schedule(leeway:)` instead of
  the inline `.seconds(2)`; refreshed the type/tick doc comments (dropped the stale
  "5–10s"/"8s"/"2s leeway" wording).
- `Sources/VibeMenuCore/ClaudeActivityState.swift` — `defaultRecencyThreshold` 90→20s with
  an updated rationale comment.
- `Tests/VibeMenuCoreTests/ClaudeActivityTests.swift` — updated the `recent()`/`stale()`
  comments (90s → 20s); added `defaultRecencyThresholdIsTwentySeconds` (pins the constant)
  and `justPastThresholdCountsAsStale` (process+just-stale ⇒ `.idle`; no-process+just-stale
  ⇒ `.notDetected`) to make the faster fall-off explicit. The existing five required cases,
  the `≤`-threshold boundary, and the label tests are unchanged and still pass.
- `README.md` — dropped the "Status row remains a placeholder" lines; menu now described as
  live rows only.
- `ARCHITECTURE.md` — recency window 90s → 20s; timer described as `~2s, 0.5s leeway`.

**Commands run:**
- `git status` (clean at start)
- `swift build` → **Build complete!**
- `scripts/test.sh` → **43 tests in 9 suites passed** (41 prior + 2 new).
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug … build`
  → **BUILD SUCCEEDED** (ad-hoc-signed `VibeMenu.app`).
- Runtime: `open …/VibeMenu.app`, `pgrep -x VibeMenu`, `lsappinfo … ApplicationType`,
  `osascript … to quit`.

**Validation results:**
- `swift build` — clean, no warnings.
- `scripts/test.sh` — 43/43 passed.
- `xcodebuild … build` — BUILD SUCCEEDED.

**Errors encountered & fixes:** None. Compiled and tested green on the first run after the
edits.

**Verified (how):**
- Builds — all three commands green (output pasted in session).
- Unit correctness — the new constant is pinned at 20s; the just-past-threshold rows
  confirm the faster active→idle/notDetected fall-off; the five required cases and labels
  are unchanged and pass.
- App launches menu-bar-only — `open`ed the freshly built `.app`; `pgrep -x VibeMenu` found
  it and `lsappinfo` reported `ApplicationType = "UIElement"` (no Dock icon). Quit cleanly
  via Apple event (a lingering `VibeMenu` from a *previous* session at a different
  DerivedData bundle path remained; my launched `$TMPDIR` instance exited).

**Not verified (needs a human at the machine):**
- The literal dropdown rendering — that the menu now shows **no** `Status: Not monitoring
  yet` row and only the VibeMenu / Claude / Thermal / Sleep prevention / Quit rows. The
  DerivedData `.app` is not grantable to computer-use, so the click/render could not be
  automated; the row removal is a source edit and the app builds/launches, but the on-screen
  menu was not visually confirmed.
- The *felt* responsiveness of active ⇄ idle transitions in the running app — the timing is
  a constant change covered by unit tests over the pure evaluator, not by a timed in-app
  observation. Human check: with a `claude` CLI running, confirm **Active**, then quit it and
  confirm the row reaches **Idle**/**Not detected** within roughly 20–25s (vs. ~90s before).

**Recommended next step:** Human visual smoke test — launch the built `VibeMenu.app`, open
the menu, confirm the Status row is gone and the four live rows + Quit remain, and eyeball
the faster Claude fall-off (~20s). If the responsiveness feels right, the natural next slice
is replacing the temporary L1 timer with the event-driven FSEvents/process-lifecycle
observer (TODO(L2)) so idle CPU returns to truly zero — still observation-only until the
human approves wiring L1 into the automation loop.

---

## 2026-07-02 — v0.1 Claude detection finished-reply latency diagnostics

**Task/session:** `v0.1 Claude detection finished-reply latency diagnostics`. Bugfix +
diagnostics pass on two issues from human testing of Claude detection L1: (1) after Claude
finishes replying and waits for input, the **Claude** row stayed **Active** for ~a minute;
(2) the menu still showed `Status: Not monitoring yet` even after launching "the newest
build". Explicitly **not** touched (hard constraints honored): no wiring of Claude
detection to sleep prevention / Keep-Awake / any power assertion, no automatic keep-awake,
no Codex, no clamshell, no transcript-content reading / JSONL parsing, no full-path
logging, no network/telemetry/analytics/deps, no heavyweight polling, no settings screen.

**Root cause / diagnosis:**
- *Issue 1 (stays Active ~1 min):* L1's `active` rule is `process present + session mtime
  within the recency window`. When Claude finishes replying it is **still a live `claude`
  process** (waiting for input), and its final write left the session mtime fresh — so the
  row reads `active` until that mtime ages past the window. With the historical 90s window
  (and even the interim 20s) that is a long, misleading "Active" tail. Process presence
  alone must not mean Active; only *recent* mtime should. Fix = shrink the window so the
  row *ages out* to `idle` fast. This is a fundamental L1 limit: metadata cannot tell
  "working" from "waiting"; reliable state needs an L2 hook/status-line heartbeat.
- *Issue 2 (Status row still visible):* the row was **already removed from source** (the
  single UI source of truth, `Sources/VibeMenuApp/VibeMenuApp.swift`, which the `.app`
  target compiles by file reference — decisions/0007). The string now lives **only** in
  this historical log. The prior session's own log noted "a lingering `VibeMenu` from a
  *previous* session at a different DerivedData bundle path remained" — i.e. the human was
  looking at a **stale instance built before the removal**. Fix path = kill old instances,
  rebuild, relaunch the newest bundle (`pkill -x VibeMenu` → build → `open …VibeMenu.app`).

**Summary:**
- **Status row:** confirmed gone from all UI paths; single source of truth verified (the
  xcodeproj references `../Sources/VibeMenuApp/VibeMenuApp.swift`, not a copy). `grep` finds
  `Status: Not monitoring yet` only in `DEVELOPMENT_LOG.md` (history).
- **Latency:** `ClaudeActivityState.defaultRecencyThreshold` 20s → **10s** (net path
  90 → 20 → 10). Refresh interval stays ~2s, leeway ~0.5s. No algorithm/state-machine
  change: the existing `evaluate` table already yields `process + stale ⇒ idle`; the
  optional mtime-delta "short active window" idea was deliberately **not** built (kept
  simple per the task's guidance).
- **Diagnostics (new, privacy-safe):** a pure `ClaudeActivityDiagnostics` + static
  `ClaudeActivityState.diagnostics(signals:now:recencyThreshold:)` producing a path-free
  `summary` like `process=true, newestAge=7s, threshold=10s, result=Active` (age `none`
  when no session files). Surfaced **DEBUG-only**: a compact menu row and an `os.Logger`
  line each tick (subsystem `com.kirillchistov.VibeMenu`, category `claude-detect`,
  `%{public}s` — safe because the string is path-free by construction). Release builds
  compile all of it out (no per-tick main-queue hop, no row). Plumbed via a second
  `onDiagnostics` closure on `ClaudeActivityObserving.start` + a `debugSummary` on
  `ClaudeActivityModel`; the state channel keeps its emit-on-change cadence unchanged.

**Files changed:**
- `Sources/VibeMenuCore/ClaudeActivityState.swift` — `defaultRecencyThreshold` 20→**10s**
  (rationale comment now spells out the finished-reply age-out + the L1 limitation); added
  `ClaudeActivityDiagnostics` value type and the pure `diagnostics(...)` companion.
- `Sources/VibeMenuCore/ClaudeActivityProvider.swift` — `import os`; added `onDiagnostics`
  channel + DEBUG-only `os.Logger`; `refresh()` now captures a single `now`, reuses it for
  evaluate + diagnostics, and (DEBUG) logs the summary and pushes it to the model each tick.
- `Sources/VibeMenuCore/ClaudeActivityModel.swift` — new `debugSummary` published property;
  `start()` now passes both the state and diagnostics closures.
- `Sources/VibeMenuApp/VibeMenuApp.swift` — DEBUG-only diagnostics row under the Claude
  row (`DEBUG — <summary>`, `.caption2`, selectable); doc comments updated.
- `Tests/VibeMenuCoreTests/ClaudeActivityTests.swift` — threshold test 20→**10s**; added
  `processPresentActivityOlderThanTenSecondsIsIdle` (finished-reply → idle), a full
  `ClaudeActivityDiagnostics` suite (summary fields, `none`, finished-reply legibility,
  **no paths/contents**, non-default threshold), and a model test for the diagnostics
  channel; `FakeClaudeProvider` updated for the two-closure `start`.
- `ARCHITECTURE.md` / `README.md` / `PRIVACY.md` — recency window 20s→10s; documented the
  DEBUG diagnostics row + `os.Logger` and its path-free/metadata-only guarantee.

**Commands run & validation results:**
- `swift build` → **Build complete!** (Debug; `#if DEBUG` compiled).
- `swift build -c release` → **Build complete!** (Release; DEBUG paths compile out).
- `scripts/test.sh` → **50 tests in 10 suites passed** (43 prior + 7 new).
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug build`
  → **BUILD SUCCEEDED** (ad-hoc-signed `VibeMenu.app`).
- Runtime: `pkill -x VibeMenu` → rebuild → `open …/VibeMenu.app`; `pgrep -x VibeMenu`
  (running) + `lsappinfo … ApplicationType` = `"UIElement"` (menu-bar-only, no Dock icon).

**Verified (how):**
- Builds — all four commands green (output pasted in session).
- Unit correctness — 50/50 pass: threshold pinned at 10s; the finished-reply row
  (process + 15s-old files ⇒ `idle`) is explicit; the diagnostics summary carries the four
  fields and **no** `/`, `.claude`, `users`, `projects`, or `.jsonl` substrings across five
  input states.
- The launched Debug `.app` **contains** the diagnostics code: `strings` on its
  `VibeMenu.debug.dylib` shows `Claude debug: %{public}s`, `newestAge=`, `threshold=`, and
  the `com.kirillchistov.VibeMenu.claude-detect` logger — proving `#if DEBUG` compiled in.

**Not verified (needs a human at the machine):**
- The live on-screen DEBUG row and the live `os.Logger` age-out trace. Detection/logging
  start from the menu content's `.onAppear` → `claude.start()` (existing wiring, unchanged),
  i.e. **only once the menu is opened**; I could not headlessly click the `MenuBarExtra`
  item (Accessibility control not granted to this context, and the DerivedData `.app` is
  not grantable to computer-use — same limitation the prior session hit). I did **not**
  fabricate a log capture.
- The *felt* active→idle fall-off timing in the running app (a constant change covered by
  the pure evaluator's tests, not a timed in-app observation).

**Recommended next step:** Human runtime check on the freshly launched instance (PID left
running): open the menu → the DEBUG row shows `process=true, newestAge=…s, threshold=10s,
result=…` (optionally `log stream --predicate 'subsystem == "com.kirillchistov.VibeMenu"'
--level debug`). Prompt Claude → **Active**; when Claude finishes replying and waits, watch
`newestAge` climb — it should reveal whether the session mtime keeps changing or simply ages
out, and the row should reach **Idle** within ~10–15s. If confirmed, the next slice is the
event-driven FSEvents/process-lifecycle observer (TODO(L2)) and, for true working/waiting
state, an opt-in Claude hook/status-line heartbeat — still observation-only until the human
approves wiring L1 into the automation loop.

---

## 2026-07-02 — Verification: Claude detection DEBUG diagnostics

**Task/session:** Verification-only pass on the Claude-detection DEBUG diagnostics
(`process=…, newestAge=…s, threshold=10s, result=…`). **No code changes** — confirm the
diagnostics compile into the Debug app, are compiled out of Release, are privacy-safe, and
that the menu/state wiring matches spec. No new features, no wiring of L1 to sleep
prevention; transcript contents never read.

**Commands run & results:**
- `git status` → clean at start.
- `grep -rn "Not monitoring yet" Sources/` → **no matches** (the placeholder Status row is
  not rendered by any source; the string lives only in this log's history).
- `swift build` → **Build complete!**
- `swift build -c release` → **Build complete!**
- `scripts/test.sh` → **50 tests in 10 suites passed**.
- `xcodebuild … -configuration Debug build` → **BUILD SUCCEEDED**.
- `xcodebuild … -configuration Release build` → **BUILD SUCCEEDED**.
- `strings` on the built bundles (Debug `VibeMenu.debug.dylib` vs Release `VibeMenu`).
- Runtime: `pkill -x VibeMenu` → Debug build → `open …/VibeMenu.app` → `pgrep`/`lsappinfo`.
- `log stream --predicate 'subsystem == "com.kirillchistov.VibeMenu"' --level debug` (6s).

**Verified (how):**
- **DEBUG diagnostics compiled into Debug** — `strings` on the Debug dylib shows
  `Claude debug: %{public}s` (logger line), `DEBUG ` (menu row), `process=`, `newestAge=`,
  `threshold=`, `result=`, and the `com.kirillchistov.VibeMenu.claude-detect` logger.
- **Release ships no DEBUG surfacing** — the DEBUG-only markers `Claude debug` and
  `DEBUG —` are present in Debug (count 1 each) and **absent** in Release (count 0 each).
  The only two Release string hits are inert: (1) the always-compiled `DispatchQueue` label
  `com.kirillchistov.VibeMenu.claude-detect` (line 80), and (2) the `process=` literal from
  the pure public `ClaudeActivityDiagnostics.summary` formatter, which no Release code path
  invokes/displays/logs (the row and the `os.Logger` call are both `#if DEBUG`).
- **Menu structure (source review)** — VibeMenu / `Claude: <state>` / `Thermal: <state>` /
  `#if DEBUG` DEBUG row / `Sleep prevention` switch / Quit. No placeholder Status row.
  *Note:* the DEBUG row renders **beneath the Thermal row**, not between Claude and Thermal.
- **Privacy** — `summary` is built only from a Bool, an Int age in whole seconds, an Int
  threshold, and `result.displayName`; no path, project name, transcript filename, prompt/
  response text, or command args. Covered by existing unit tests (no `/`, `.claude`,
  `projects`, `.jsonl` substrings across five input states).
- **Launches menu-bar-only** — `pgrep -x VibeMenu` found it; `lsappinfo` reported
  `ApplicationType = "UIElement"`. Left running (PID at session time) for a human smoke test.

**Not verified (needs a human at the machine):**
- The live on-screen DEBUG row and the live `os.Logger` age-out trace. Detection/logging
  only start on the menu's `.onAppear` → `claude.start()` (menu must be opened first); a 6s
  `log stream` with the menu closed produced no lines, as expected. The DerivedData `.app`
  is not resolvable by computer-use (`request_access` for "VibeMenu" returned `notInstalled`,
  not shown to the user), so the menu click could not be automated. No log capture fabricated.

**Issue flagged (not a bug; product owner's call):** the DEBUG row is placed under the
Thermal row rather than directly under the Claude row it explains (the task's expected order
and the L1 log's prose both say "under the Claude row"). Cosmetic only — left unchanged per
"no code changes unless a clear bug" + "the human owns product decisions."

**Recommended next step:** Human runtime check on the running instance — open the menu,
confirm the DEBUG row reads `process=true, newestAge=<low>s, threshold=10s, result=Active`
while a `claude` CLI is active; then let Claude finish and watch `newestAge` climb and the
row fall to **Idle** within ~10–15s.

---

## 2026-07-03 — v0.1 Claude heartbeat L2

**Task/session:** `v0.1 Claude heartbeat L2`. Replace mtime-guessing as the *primary*
active/waiting signal with a VibeMenu-owned **hook heartbeat**, based on the hook
experiment that succeeded in the product owner's real local-agent environment (observed
events: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`,
`SessionEnd`; `Stop` fires promptly when Claude finishes). **OBSERVATION ONLY** — hard
constraints honored: no wiring to sleep prevention / Keep-Awake / power assertions, no
automatic keep-awake, no Codex, no clamshell, no transcript reads / JSONL parsing, no
prompt/response/tool/path/cwd logging, no auto-editing of `~/.claude/settings.json`, no
clobbering existing hooks, no Accessibility/Full-Disk/root/helper, no
network/telemetry/analytics/deps. See `decisions/0008-claude-heartbeat-detection.md`.

**Summary:** Added Claude detection **L2** on top of L1 (kept as fallback), same
pure-core / thin-adapter / observable-model shape as the thermal/power/L1 slices. An
**opt-in, user-installed** Claude Code hook writes a tiny per-session JSON file
(`{schemaVersion, updatedAt, event, sessionID}`) under
`~/Library/Application Support/VibeMenu/ClaudeHeartbeat/sessions/`; VibeMenu reads *its
own* files (never transcripts) and maps them via a pure decision to `Active` / `Waiting`
/ fallback-to-L1. Added a new `.waiting` state (label "Waiting"). VibeMenu never installs
the hook and never edits `settings.json` — setup is a documented manual step.

**Files added:**
- `Support/ClaudeHeartbeat/vibemenu-claude-hook.sh` — production hook (POSIX sh, no deps;
  extracts only `hook_event_name` + `session_id`; sanitizes the session id to a safe
  filename; atomic temp+rename; missing id → `unknown-session.json`; always exits 0;
  `VIBEMENU_HEARTBEAT_DIR` override for tests).
- `Support/ClaudeHeartbeat/settings-snippet.json` — sample hook block for all seven events
  (`SessionStart`/`UserPromptSubmit`/`PreToolUse "*"`/`PostToolUse "*"`/`Notification`/
  `Stop`/`SessionEnd`).
- `Support/ClaudeHeartbeat/README.md` — manual setup (backup → merge → verify → remove),
  privacy note.
- `Sources/VibeMenuCore/ClaudeHeartbeat.swift` — `ClaudeHeartbeatEvent`,
  `ClaudeHeartbeatRecord` + malformed-safe pure decoder, the L2
  `evaluate(heartbeats:signals:now:…)` (active/stale thresholds 120s/600s), and the L2
  `diagnostics(...)`.
- `Tests/VibeMenuCoreTests/ClaudeHeartbeatTests.swift` — 28 tests: event mapping, the full
  L2 decision table (rules 1–11), decoder/reader malformed-safety, L2 diagnostics
  (heartbeat state/age/count, no paths/ids), and **subprocess tests of the real hook
  script** (writes only allowed fields; ignores sensitive fields; unknown-session; garbage
  → exit 0; path-traversal sanitized).

**Files changed:**
- `Sources/VibeMenuCore/ClaudeActivityState.swift` — added `.waiting` case + label;
  extended `ClaudeActivityDiagnostics` with heartbeat fields + new `summary` format;
  removed the old L1-only `diagnostics` (superseded by the L2 one).
- `Sources/VibeMenuCore/ClaudeActivityProvider.swift` — reads heartbeat files first
  (`readHeartbeatRecords(in:)`, `defaultHeartbeatDirectory`), then process, then L1 mtime;
  `refresh()` uses the L2 evaluate + L2 diagnostics; init gains heartbeat thresholds + an
  injectable directory (for tests).
- `Sources/VibeMenuApp/VibeMenuApp.swift` — doc/comment updates only (L2 + new DEBUG-row
  fields); the menu structure is unchanged and already matches the expected order
  (VibeMenu / Claude / Thermal / DEBUG / Sleep prevention / Quit).
- `Tests/VibeMenuCoreTests/ClaudeActivityTests.swift` — `.waiting` label assertion;
  diagnostics tests updated to the new signature (`heartbeats: []`) + new summary format.
- `README.md`, `ARCHITECTURE.md`, `PRIVACY.md`, `SECURITY.md` — L2 heartbeat + Waiting +
  opt-in hook + new DEBUG-row format documented.
- `decisions/0008-claude-heartbeat-detection.md` — new ADR.

**Detection design (L2, defaults active=120s, stale=600s, L1 recency=10s):**
- active event (`UserPromptSubmit`/`PreToolUse`/`PostToolUse`) within active window ⇒
  `Active`; `Stop`/`Notification` (or aged-active, `SessionStart`, unknown) ⇒ `Waiting`.
- `SessionEnd` sessions excluded; records past the stale window ignored.
- multiple sessions: any Active wins, else any Waiting.
- process cross-check: never report `Active` with no visible `claude` process (fresh ⇒
  `Waiting`, aged ⇒ L1) — no stale/crashed Active sticks.
- no fresh heartbeat records ⇒ fall back to L1 `evaluate(signals:)` exactly.

**Commands run & validation results:**
- `git status` (clean at start).
- `swift build` → **Build complete!**
- `swift build -c release` → **Build complete!**
- `scripts/test.sh` → **78 tests in 15 suites passed** (50 prior + 28 new).
- `xcodebuild … -configuration Debug build` → **BUILD SUCCEEDED**.
- `xcodebuild … -configuration Release build` → **BUILD SUCCEEDED**.

**Verified (how):**
- Builds — all commands green (output pasted in session).
- Unit correctness — 78/78, including the full L2 decision table, malformed-JSON safety,
  and the real-script subprocess tests (privacy contract enforced end-to-end).
- **Release ships no DEBUG surfacing (test #16)** — `strings` on the built bundles: the
  Debug `VibeMenu.debug.dylib` contains `Claude debug`, `heartbeat=`, `newestAge=`, and the
  `DEBUG ` row; the Release `VibeMenu` binary contains **none** of them (even the
  `process=`/`heartbeat=` summary formatter is dead-code-eliminated). Only inert Release hit
  is the always-compiled `claude-detect` dispatch-queue/logger label.
- **Real pipeline works end-to-end on this machine** — a harness compiled from the *real*
  core (`swiftc -O`) drove the production script → `readHeartbeatRecords(in:)` →
  `evaluate(heartbeats:signals:)`: `UserPromptSubmit`/`PreToolUse`/`PostToolUse` + process
  ⇒ **Active**; `Stop`/`Notification` ⇒ **Waiting**; `SessionEnd` (no proc/files) ⇒ **Not
  detected** (L1 fallback); `PreToolUse` + **no process** ⇒ **Waiting** (cross-check);
  stale active (700s) + process ⇒ **Running** (dropped → L1, not Active). Diagnostics summary
  matched the spec format `process=true, heartbeat=Active age=1s sessions=1, newestAge=none,
  threshold=10s, result=Active` with no session id / path.
- **Hook script privacy** — feeding a payload with `prompt`/`transcript_path`/`cwd`/
  `tool_input`/`tool_response` produced a file containing only the four safe fields and
  **none** of the sensitive substrings; path-traversal `../../etc/evil` stayed inside the
  dir (sanitized to `....etcevil.json`).

**Not verified (needs a human at the machine):**
- The **live on-screen menu**: that the Claude row visibly shows **Waiting** after Claude
  stops (vs **Active** while working) and that the DEBUG row shows the heartbeat fields.
  The detection start is on the menu's `.onAppear` and the DerivedData `.app` is not
  grantable to computer-use, so the menu click could not be automated — the state→label
  path is unit-tested and the file→reader→evaluator pipeline is harness-verified with the
  real script, but the on-screen row was not visually confirmed. No capture fabricated.
- A **live end-to-end hook run** (installing the hook into the real `~/.claude/settings.json`
  and watching VibeMenu flip Active⇄Waiting): not performed, because auto-installing/editing
  the user's Claude settings is explicitly forbidden by the task. Verification used the
  production script writing to a temp dir + the real reader/evaluator instead.
- Sleep prevention untouched and still manual (all 12 power tests unchanged and passing).

**Recommended next step:** Human opt-in smoke test — follow
`Support/ClaudeHeartbeat/README.md` to back up `~/.claude/settings.json`, merge the snippet
(absolute script path), restart Claude Code, and confirm the VibeMenu **Claude** row reads
**Active** while Claude works and **Waiting** shortly after it stops (DEBUG row:
`heartbeat=… sessions=…`). Per AGENTS.md §18, have a **different** model (e.g. Codex) review
the L2 decision + the hook script before the heartbeat is ever wired into the automation
loop — which stays deferred until the human approves L2's reliability.

---

## 2026-07-03 — proposal-first workflow docs

**Task/session:** Update agent workflow docs for non-trivial product/architecture changes.

**Summary:** Documented that Claude must produce a proposal with options/tradeoffs and wait
for product approval before implementing non-trivial product or architecture changes.

**Files changed:**
- `AGENTS.md` — added the universal proposal-first workflow, non-trivial scope list, direct
  small-fix exceptions, and required proposal format.
- `CLAUDE.md` — added Claude-specific instructions to follow the proposal-first workflow
  before implementation.
- `DEVELOPMENT_LOG.md` — recorded this documentation-only update.

**Commands run & validation results:**
- `sed -n '1,220p' AGENTS.md` — inspected existing universal rules.
- `sed -n '1,260p' CLAUDE.md` — inspected existing Claude workflow.
- `tail -n 80 DEVELOPMENT_LOG.md` — inspected the latest log entry.
- `head -n 60 DEVELOPMENT_LOG.md` — inspected log conventions.
- `date +%F` — confirmed today's date as `2026-07-03`.

**Verified:**
- Documentation changes are narrow and additive.

**Not verified:**
- No build or test suite was run; this was a docs-only workflow update.

**Recommended next step:** Follow the new proposal format before starting any future
non-trivial product or architecture change.

---

## 2026-07-03 — v0.1 Codex review cleanup — hook parser and launch observation

**Task/session:** Address Codex's "request changes before automation" review of the L2
Claude-detection slice. Fix the three highest findings; leave manual/automatic power
assertion ownership (and all automation wiring) for a later slice. Still observation-only.

**Summary:**
- **HIGH — hook parser could read nested JSON fields.** The production hook script extracted
  `hook_event_name`/`session_id` with a `sed` regex over the *flattened* payload, so a
  same-named key nested inside `tool_input`/`tool_response` could override the top-level
  event or the output filename. Rewrote the extractor to parse the JSON **structurally** with
  the system `python3` and read **only the top-level** two fields (nested keys ignored).
  Preserved every existing behavior: atomic temp+rename write, session-id filename
  sanitization (`[A-Za-z0-9._-]`), the documented `unknown`/`unknown-session` fallbacks,
  manual/opt-in setup, and **always exit 0**. Invalid JSON or a missing `python3` degrades to
  a safe `unknown` record rather than an unsafe parse. No `jq`, no third-party dependency
  (python3 is a macOS system interpreter), no payload ever logged.
- **MEDIUM — detection started from menu `.onAppear`.** Moved Claude observation to
  **app-launch** time: `AppDelegate` now owns the `ClaudeActivityModel` and calls
  `claude.start()` in `applicationDidFinishLaunching` and `claude.stop()` in
  `applicationWillTerminate`. Opening the menu now only *displays* state. Made
  `ClaudeActivityModel.start()` truly **idempotent** (an `isObserving` guard) so repeated
  calls never spin up a duplicate provider timer.
- **LOW — stale L1-era comments.** Refreshed doc comments in `ClaudeActivityState`,
  `ClaudeActivityModel`, `ClaudeActivityProvider`, and `VibeMenuApp` to say L2 heartbeat is
  implemented, L1 mtime/process remains the fallback, detection is observation-only, and
  automation is not wired yet. Also aligned PRIVACY/SECURITY/README wording to
  "top-level-only, structural parse".

**Files changed:**
- `Support/ClaudeHeartbeat/vibemenu-claude-hook.sh` — structural top-level-only JSON parse
  via system `python3`; replaces the nested-vulnerable regex. Behavior otherwise unchanged.
- `Sources/VibeMenuCore/ClaudeActivityModel.swift` — `isObserving` idempotency guard;
  refreshed docs.
- `Sources/VibeMenuApp/VibeMenuApp.swift` — `AppDelegate` owns `claude`; start at launch,
  stop at terminate; menu `.onAppear` no longer starts Claude observation.
- `Sources/VibeMenuCore/ClaudeActivityState.swift`, `ClaudeActivityProvider.swift` — stale
  comment refresh (L1+L2, observation-only).
- `Tests/VibeMenuCoreTests/ClaudeHeartbeatTests.swift` — `nestedFieldsCannotOverrideTopLevel`
  (the regression guard for the HIGH finding) + `missingEventWritesUnknownEvent`.
- `Tests/VibeMenuCoreTests/ClaudeActivityTests.swift` — fake provider start/stop counters +
  `startIsIdempotent` / `startAfterStopResubscribes`.
- `PRIVACY.md`, `SECURITY.md`, `Support/ClaudeHeartbeat/README.md` — clarified top-level-only
  structural parsing and the `python3` (system interpreter, not a dependency) requirement.

**Commands run & validation results:**
- `swift build` → **Build complete.**
- `swift build -c release` → **Build complete.**
- `scripts/test.sh` → **82 tests in 15 suites passed** (was 78; +4 new).
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug build`
  → **BUILD SUCCEEDED.**
- Script smoke test (temp `VIBEMENU_HEARTBEAT_DIR`): the nested-override payload
  (`hook_event_name=Stop`, `session_id=real-session`, with nested `PreToolUse`/`NESTEDSECRET`
  + secrets) wrote only `real-session.json` with `event=Stop`; no `NESTEDSECRET*` file and no
  nested secret string present. Normal, missing-session, missing-event, garbage, empty, and
  path-traversal payloads all still exit 0 with the documented output.

**Verified:**
- Nested `tool_input`/`tool_response` fields can no longer steer the event or filename (unit
  test + subprocess smoke test).
- Claude observation starts at launch and `start()` is idempotent (unit tests via a
  start-counting fake provider).
- All four build/test commands pass on this machine (full Xcode).

**Not verified:**
- The `.app` was built but not launched this session; the app-launch/terminate lifecycle
  hooks (`applicationDidFinishLaunching`/`WillTerminate`) were reasoned about and unit-tested
  at the model level, but not observed end-to-end in a running menu-bar app.
- The behavior on a machine with **no** `python3` was reasoned about (safe `unknown`
  degrade) but not exercised here, since macOS provides `/usr/bin/python3`.

**Recommended next step:** Per AGENTS.md §18, have a **different** model (Codex) confirm the
three findings are resolved. Then proceed to the deferred slice — manual/automatic power
assertion ownership — still without wiring detection to sleep prevention until the human
approves.

---

## 2026-07-03 — Codex cleanup: hook uses only `/usr/bin/python3`

**Change.** In `Support/ClaudeHeartbeat/vibemenu-claude-hook.sh`, removed the
`command -v python3` PATH fallback. The script now resolves the interpreter **only** from
the fixed path `/usr/bin/python3` (checked with `[ -x ]`). If it is missing or not
executable, `PYTHON` stays empty and the script degrades to the existing SAFE no-parse mode
(event from `$1` if present, else `unknown`; session `unknown-session`) and still exits `0`.
Rationale: a third-party `python3` on `PATH` would be an unvetted dependency (AGENTS.md §5)
and could be shadowed by an attacker-controlled `PATH`.

**Docs updated to match behavior.** Header comment in the script, `Support/ClaudeHeartbeat/
README.md` (the "Requires" note now says `/usr/bin/python3` only, never other `PATH`
interpreters), and `SECURITY.md` (fixed-path, exclusive-use wording).

**Commands run (all from repo root):**
- `swift build` → Build complete.
- `swift build -c release` → Build complete.
- `scripts/test.sh` → Test run with **82 tests in 15 suites passed** (incl. all
  `vibemenu-claude-hook.sh` suite cases).
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug build`
  → **BUILD SUCCEEDED**.

**Hook smoke tests (manual, temp `VIBEMENU_HEARTBEAT_DIR`):**
- Valid payload `{"hook_event_name":"PreToolUse","session_id":"abc-123"}` → exit 0, wrote
  `abc-123.json` with event `PreToolUse`.
- Nested duplicate payload (nested `hook_event_name`/`session_id` inside `tool_input`) →
  exit 0, top-level values won (`Stop` / `top-session`), no `../escape` file created.
- Malformed payload (`this is not json {{{`) → exit 0, wrote `unknown-session.json` with
  event `unknown`.
- Simulated missing `/usr/bin/python3` (patched copy) → exit 0, degraded to event from `$1`
  and `unknown-session`, confirming safe no-parse fallback.

**Verified vs. unverified.** Builds, full test suite, and the four hook smoke cases were
run and observed. The `.app` was built but **not launched**; menu-bar/runtime behavior
unchanged and unverified this session. No automation wired; no power-assertion behavior
touched. Not committed, per request.

**Recommended next step.** Optional independent (Codex) confirmation that the doc wording
still matches the script, then commit if the human approves.

---

## 2026-07-03 — v0.1 automatic Claude keep-awake

**Task/session:** Implement automatic keep-awake while Claude is Active, simplify the menu,
and keep the manual Sleep prevention toggle as the user's long-term preference.

**Summary:**
- Added separate ownership in `PowerAssertionModel`: `manualRequested`,
  `automationRequested`, `automationReleasePending`, and effective assertion state
  `manualRequested || automationRequested`.
- Wired `ClaudeActivityModel` state changes at app launch into the power model. Only
  internal `.active` requests automation immediately; `.waiting`, `.running`, `.idle`,
  `.notDetected`, and `.unknown` schedule release after a 30-second grace period.
- Simplified the visible Claude menu label to **Active / Idle / Not detected**, removed the
  visible DEBUG row, and disabled the manual Sleep prevention switch while automation is
  holding or grace-active. The switch still displays only the manual preference.

**Files changed:**
- `Sources/VibeMenuCore/PowerAssertionManager.swift` — added manual-vs-automation ownership,
  30-second automation release grace, cancellation on renewed Active, effective assertion
  application, and cleanup release.
- `Sources/VibeMenuCore/ClaudeActivityModel.swift` — added an app-lifetime state-change hook
  and simplified `displayLabel` to the menu vocabulary.
- `Sources/VibeMenuCore/ClaudeActivityState.swift` — added pure `menuDisplayName` mapping
  and refreshed comments for the now-wired automation behavior.
- `Sources/VibeMenuCore/ClaudeActivityProvider.swift`, `ClaudeHeartbeat.swift` — refreshed
  stale observation-only / DEBUG-row comments.
- `Sources/VibeMenuApp/VibeMenuApp.swift` — wired Claude state to keep-awake at launch,
  removed the DEBUG row, bound the switch to manual preference, and disabled it during
  automation hold/grace.
- `Tests/VibeMenuCoreTests/PowerAssertionTests.swift` — added ownership, grace, cancellation,
  idempotency, disabled-toggle, manual-preservation, and cleanup tests.
- `Tests/VibeMenuCoreTests/ClaudeActivityTests.swift` — added simplified menu-label tests and
  state-change hook coverage.
- `README.md`, `ARCHITECTURE.md`, `PRIVACY.md` — documented built-in Claude keep-awake, the
  manual preference model, system-idle-sleep-only behavior, and the simplified Claude row.

**Commands run & validation results:**
- Baseline before edits:
  - `git status && swift build` → clean working tree; `Build complete! (0.12s)`.
  - `swift build -c release` → `Build complete! (0.10s)`.
  - `scripts/test.sh` → `Test run with 82 tests in 15 suites passed`.
  - `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug build`
    → `** BUILD SUCCEEDED **`.
- During implementation:
  - `swift build` initially failed because Swift disallows `Self.defaultAutomationReleaseGrace`
    in that default argument; changed it to `PowerAssertionModel.defaultAutomationReleaseGrace`.
  - `swift build` after the fix → `Build complete! (0.98s)`.
  - `scripts/test.sh` after test additions → `Test run with 93 tests in 15 suites passed`.
- Final validation:
  - `swift build` → `Build complete! (1.16s)`.
  - `swift build -c release` → `Build complete! (1.89s)`.
  - `scripts/test.sh` → `Test run with 93 tests in 15 suites passed after 0.247 seconds`.
  - `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug build`
    → `** BUILD SUCCEEDED **`.

**Runtime verification:**
- Ran:
  - `pkill -x VibeMenu || true`
  - `open "$APP_PATH"` for
    `<DerivedData>/VibeMenu-<hash>/Build/Products/Debug/VibeMenu.app`
- First `open` attempt returned LaunchServices error `-600`; a second
  `/usr/bin/open -n "$APP_PATH"` succeeded. `ps` showed:
  - `78337 ... <DerivedData>/VibeMenu-<hash>/Build/Products/Debug/VibeMenu.app/Contents/MacOS/VibeMenu`

**Verified:**
- Package debug/release builds pass.
- Xcode Debug `.app` build passes.
- Unit tests cover manual off/on with Claude Active, release after grace, manual state not
  mutated by automation, Active canceling pending release, disabled-toggle state,
  simplified Claude labels, repeated updates, and cleanup release.
- The newest Debug app was launched after killing old instances on this machine.

**Not verified:**
- Live menu visuals and `pmset -g assertions` behavior while driving a real Claude session
  still need human smoke testing from the menu bar.
- Display sleep behavior was not manually observed; implementation continues to use only
  `kIOPMAssertPreventUserIdleSystemSleep`, so display sleep is not intentionally prevented.

**Recommended next step:** Human smoke test the running Debug app: confirm no DEBUG row,
Claude only shows Active/Idle/Not detected, the Sleep prevention switch is disabled during
automation hold/grace while preserving its manual visual state, and `pmset -g assertions |
grep -i "VibeMenu"` appears only while manual or Claude automation effectively requests it.

---

## 2026-07-03 — Remove automatic keep-awake grace period

**Task/session:** Remove the automatic release grace period now that Claude heartbeat
detection is instant and reliable.

**Summary:**
- Removed `PowerAssertionModel`'s delayed automation release task/state. Claude `.active`
  sets `automationRequested = true`; every non-active Claude state sets it to `false`
  immediately.
- Kept the user's manual preference separate from automation ownership. Effective sleep
  prevention remains `manualRequested || automationRequested`.
- Updated the Sleep prevention switch behavior so it is disabled only while
  `automationRequested` is true, and becomes usable immediately when Claude leaves Active.
- Updated tests and current docs/comments to stop describing the old 30-second grace
  behavior.

**Files changed:**
- `Sources/VibeMenuCore/PowerAssertionManager.swift` — removed automation release grace
  constant, pending task, `automationReleasePending`, and delayed-release helpers.
- `Sources/VibeMenuCore/ClaudeActivityState.swift` — updated automation comments to say
  non-active states release immediately.
- `Sources/VibeMenuApp/VibeMenuApp.swift` — updated the menu switch comment for the new
  disabled-only-while-active behavior.
- `Tests/VibeMenuCoreTests/PowerAssertionTests.swift` — replaced grace/cancellation tests
  with immediate-release, immediate-toggle-enable, manual-preservation, and idempotency
  coverage.
- `README.md`, `ARCHITECTURE.md`, `PRIVACY.md`, `PRODUCT.md`, `ROADMAP.md`,
  `decisions/0005-v0-1-scope.md` — updated current behavior docs to remove the automatic
  grace-period description.
- `DEVELOPMENT_LOG.md` — recorded this implementation session.

**Commands run & validation results:**
- Baseline before edits:
  - `swift build` → `Build complete! (0.11s)`.
- Final validation:
  - `swift build` → `Build complete! (1.04s)`.
  - `swift build -c release` → waited for the SwiftPM build lock from the parallel debug
    build, then `Build complete! (1.67s)`.
  - `scripts/test.sh` → `Test run with 93 tests in 15 suites passed after 0.268 seconds`.
  - `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug build`
    → `** BUILD SUCCEEDED **`.

**Verified:**
- Package debug/release builds pass.
- Unit tests now cover manual off + Claude Active, manual off + Claude Idle immediate
  release, manual on + Claude Idle staying active via manual, immediate manual-toggle
  re-enable after Active → Idle, automation not mutating manual preference, repeated state
  update idempotency, and cleanup.
- Xcode Debug `.app` build passes.

**Not verified:**
- Did not launch the app or observe live menu/`pmset -g assertions` behavior in a real
  Claude session during this task.
- Display sleep behavior was not manually observed. The code still uses only the public
  `kIOPMAssertPreventUserIdleSystemSleep` assertion, so it does not intentionally prevent
  display sleep.

**macOS API assumptions:**
- No new macOS APIs were added. Existing sleep prevention still uses public documented
  IOKit `IOPMAssertionCreateWithName` / `IOPMAssertionRelease` with
  `kIOPMAssertPreventUserIdleSystemSleep`; no root, private APIs, privileged helper,
  network, telemetry, or new dependencies were introduced.

**Recommended next step:** Human runtime smoke test the built Debug app: Claude Active
should show the VibeMenu assertion, Claude Idle should remove it immediately when manual is
off, the toggle should become usable immediately on Idle, and manual-on should keep the
assertion after Claude becomes Idle.

## 2026-07-03 — v0.1 settings window and menu visibility preferences

**Task/session:** Slice 1 — minimal Settings window + main-menu row-visibility
preferences (product-approved scope).

**Summary:**
- Added a pure `MenuVisibility` value type in `VibeMenuCore` that turns the two
  visibility preferences (`showClaudeStatus`, `showThermalStatus`) into three display
  decisions: is the Claude row visible, is the Thermal row visible, is the status divider
  visible (shown iff at least one status row is visible). No defaults/SwiftUI access.
- Added a dedicated SwiftUI `Settings` scene + small `SettingsView` with two toggles under
  a "Menu bar" section ("Show Claude status", "Show Thermal status"). No tabs, footer,
  reset, DEBUG, or explanatory rows.
- Added a top-level **Settings…** item to the main menu (⌘,), kept **Quit VibeMenu** and
  **Sleep prevention** top-level. Because the app is LSUIElement, the opener calls
  `NSApp.activate(ignoringOtherApps:)` before `openSettings()` so the window comes to
  front.
- Menu now conditionally renders the Claude/Thermal rows and the status divider from
  `MenuVisibility`; hiding both rows also hides the divider (no empty/doubled separator).
- Persisted both booleans via `@AppStorage` (defaults: both true). No Launch at Login,
  no ServiceManagement, no placeholder LaL row in this slice.
- Added `MenuVisibilityTests` (default both visible; hide Claude keeps Thermal; hide
  Thermal keeps Claude; hide both hides both; divider visible if ≥1 row; divider hidden if
  none; determinism/purity). Existing Claude/power-assertion tests unchanged.

**Commands run / validation:**
- `swift build` → `Build complete! (1.08s)`.
- `swift build -c release` → `Build complete! (1.87s)`.
- `scripts/test.sh` → `Test run with 102 tests in 18 suites passed after 0.221 seconds`.
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug build`
  → `** BUILD SUCCEEDED **`.

**Verified:**
- Package debug/release builds and the Xcode Debug `.app` build all pass.
- New `MenuVisibility` unit tests pass; full suite (102 tests) green.

**Not verified:**
- Did not launch the app this session; the Settings-window front-most behavior under
  LSUIElement, live row hiding, and `@AppStorage` persistence across relaunch were not
  observed at runtime — left as manual smoke-test steps.

**macOS API assumptions:**
- `@AppStorage` (UserDefaults-backed) and the SwiftUI `Settings` scene + `openSettings`
  environment action are public, sandbox-compatible, macOS 14+ (baseline is macOS 15).
  `NSApp.activate(ignoringOtherApps:)` is public AppKit. No root, private APIs, network,
  telemetry, or new dependencies.

**Recommended next step:** Human runtime smoke test the built Debug app: open Settings…,
toggle each row off/on and confirm the menu updates and the status divider disappears when
both rows are hidden; relaunch to confirm the preferences persist.

## 2026-07-03 — Settings/menu UI polish (footer row + Settings material)

Changed `MenuContentView` footer to a single horizontal `HStack`: `Settings…` (left) and
`Quit VibeMenu` (right) separated by a `Spacer`, replacing the two stacked button rows.
Keyboard shortcuts (⌘, and ⌘Q) and both actions' bodies are unchanged. Added native-glass
polish to `SettingsView` via `.scrollContentBackground(.hidden)` + `.background(.regularMaterial)`.
No settings contents, Claude detection, or power-assertion behavior touched.

Validation: `swift build`, `swift build -c release`, `scripts/test.sh` (102 tests, 18 suites
passed), and `xcodebuild … VibeMenu Debug` all succeeded. UI-only change — no new tests.
App compiled and Debug .app built but not launched; menu layout and Settings material appearance
are unverified on-screen (manual smoke test pending). Not committed per request.

**Recommended next step:** Human runtime smoke test: open the menu and confirm Settings…/Quit
sit side-by-side (left/right) and both still work; open Settings and eyeball the material.

## 2026-07-03 — Thermal row color coding (static, native semantic colors)

Added static color/weight to the Thermal row. Core gains a framework-free
`ThermalDisplayStyle` enum plus `ThermalPressureState.displayStyle` and
`ThermalStatusModel.displayStyle` (nil pressure → `.unknown`), keeping the mapping pure
and testable with no SwiftUI in core. `VibeMenuApp.MenuContentView` translates the style to
SwiftUI: nominal → `.green`, fair → `.orange`, serious/critical → `.red`, unknown →
`.primary`; critical also gets `.semibold`. System semantic colors only (no RGB), no
animation. Thermal detection, Claude detection, power-assertion, and Settings behavior all
untouched; no new settings, no DEBUG row.

Added two Swift Testing cases in `ThermalStatusTests.swift` for the pure style mapping
(pressure→style and model unknown-fallback). SwiftUI Color mapping in the app is left
untested by design.

Validation: `swift build`, `swift build -c release`, `scripts/test.sh` (104 tests, 19 suites
passed), and `xcodebuild … VibeMenu Debug` all succeeded. App compiled and Debug .app built
but not launched; on-screen colors are unverified (manual smoke test pending). Not committed
per request.

**Recommended next step:** Human runtime smoke test: open the menu and confirm the Thermal
row shows green under Nominal; other states are hard to force manually.

---

UI correction to the Thermal row: renamed the label from `Thermal:` to
`Thermal pressure:` and stopped coloring the whole row. The row is now composed text
(`Text("Thermal pressure: ") + Text(value)…`) so only the pressure *value* carries the
thermal color (`foregroundColor`) and weight; the label stays default color like every
other menu row. No detection, settings, or style-mapping changes; the row visibility
toggle still hides/shows the whole row. `swift build`, `scripts/test.sh` (104 tests),
and `xcodebuild … VibeMenu Debug` all succeeded; on-screen colors unverified (not
launched). Not committed per request.

---

## 2026-07-03 — v0.1 launch at login

Added a **Launch at Login** setting and shrank the main-menu **Sleep prevention** switch.

**Launch at Login.** New core file `VibeMenuCore/LoginItem.swift`: a `LoginItemControlling`
protocol seam + a `@MainActor @Observable` `LoginItemModel`. The model reflects the
controller's *actual* `isEnabled` after every `refresh()`/`setEnabled(_:)`, swallows any
register/unregister throw (no crash), and persists no duplicate bool — the source of truth is
the live system status. The real adapter, `SMAppServiceLoginItemController` (public
`SMAppService.mainApp.register()`/`unregister()`/`.status`, `.enabled` → ON), lives in
`VibeMenuApp`, keeping `ServiceManagement` out of the core. `SettingsView` gained a **General**
section (**Launch VibeMenu at login**) above **Menu bar**, bound to the model, refreshing
actual status on `.onAppear`. Owned for the app lifetime by `AppDelegate`. No helper app, no
root/private APIs, no new dependency, no network/telemetry, no onboarding, no extra pane. See
[`decisions/0009-launch-at-login.md`](decisions/0009-launch-at-login.md).

**Sleep-prevention switch sizing.** The main-menu switch now uses `.controlSize(.small)` +
`.scaleEffect(0.7, anchor: .trailing)` (~30% smaller), applied to the switch only — the
"Sleep prevention" label and every other row is untouched, and Settings toggles stay
full-size. All existing power/automation behavior (manual toggle, Claude auto keep-awake,
disabled-while-automation) is unchanged.

**Tests.** New `Tests/VibeMenuCoreTests/LoginItemTests.swift` (8 cases) over a fake controller:
initial enabled/disabled reflect, toggle-on registers, toggle-off unregisters, failed register
doesn't falsely enable, failed unregister doesn't falsely disable, external drift reflected on
refresh, and repeated ops are idempotent/no-crash. No SwiftUI scale/controlSize tests (by
design).

**Validation (all real, all passed):**
- `swift build` — Build complete.
- `swift build -c release` — Build complete.
- `scripts/test.sh` — 112 tests in 20 suites passed.
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug build` —
  BUILD SUCCEEDED (ad-hoc "Sign to Run Locally").

**Runtime verification (partial, honest).** The Debug `.app` was launched and confirmed
running (`pgrep -x VibeMenu`). `pmset -g assertions` showed a real `"VibeMenu Keep Awake"`
`PreventUserIdleSystemSleep` assertion held while a `claude` process was present — confirming
the automatic Claude keep-awake / IOKit power-assertion path is live end-to-end in the built
app. **Not verified on-screen:** the General section layout, the Launch-at-Login toggle
register/unregister at runtime, and the visually-smaller switch — the `LSUIElement`
DerivedData bundle is not resolvable by the computer-use allowlist and this session is
non-interactive, so the menu-bar UI could not be driven with clicks. Launch at Login is also
subject to the unsigned/ad-hoc caveat: `SMAppService` register/unregister may throw or behave
inconsistently until a signed/notarized build. Not committed per request.

**Recommended next step:** Human runtime smoke test — open Settings, confirm **General**
appears above **Menu bar**, toggle **Launch VibeMenu at login** and check
`SMAppService.mainApp.status` / System Settings → Login Items, and eyeball the smaller Sleep
prevention switch. For trustworthy Launch-at-Login behavior, verify on a signed/notarized build.

---

## 2026-07-03 — v0.1 GitHub dogfood release surface

Built the GitHub-facing release surface for a v0.1 **unsigned, not-notarized** dogfood build.
Docs/tooling only — no product logic, power/automation, or app-source changes.

**Changed / added files:**
- `README.md` — rewritten for GitHub users: one-line pitch, features, "Why VibeMenu?",
  Install (Releases zip + right-click→Open unsigned warning), How it works (public power
  assertion, opt-in Claude heartbeat, `ProcessInfo` thermal, no temps/fans/private APIs),
  Privacy, Limitations (no display sleep, no clamshell, detection caveat, unsigned
  Launch-at-Login caveat), Develop, License. Static shields.io badges (status/platform/
  license) only — **no fake CI badges**. Screenshot paths added as commented-out
  placeholders (`docs/assets/menu-screenshot.png`, `docs/assets/settings-screenshot.png`);
  no image assets created.
- `docs/INSTALL.md` — download/unzip/move-to-Applications, right-click→Open workaround,
  enable Launch at Login, optional heartbeat pointer (existing docs, no invented automation),
  uninstall (quit, disable login item, remove app, optional
  `~/Library/Application Support/VibeMenu`).
- `docs/FAQ.md` — nine short answers (Gatekeeper warning, display sleep, clamshell, reading
  transcripts, network, Claude "Not detected", Launch-at-Login on unsigned builds, full
  uninstall, fans/temps).
- `RELEASE_CHECKLIST.md` — restructured into **Part A (GitHub dogfood, unsigned)** with clean
  tree / build+test / package / launch smoke / manual smoke checklist / create release +
  attach zip + notes template + unsigned caveat, and **Part B (future signed/notarized)**.
- `scripts/package-github-release.sh` — new `set -euo pipefail` bash script: xcodebuild
  Release into `build/DerivedData`, locate `.app`, `ditto -c -k --keepParent` into
  `dist/VibeMenu-v<VERSION>-macos-arm64.zip` (VERSION arg/env, default `0.1.0`), print next
  steps. No sign/notarize/DMG/creds.
- `ROADMAP.md` — added a "Distribution plan" section: GitHub zip first → Developer ID +
  notarization later → DMG/updater/Homebrew later.
- `.gitignore` — ignore `build/` and `dist/` (packaging output).

**Validation (all real, all passed):**
- `bash -n scripts/package-github-release.sh` — syntax OK.
- `swift build` — Build complete.
- `scripts/test.sh` — 112 tests in 20 suites passed.
- `xcodebuild … -configuration Release build` — BUILD SUCCEEDED (ad-hoc; unsigned).
- `scripts/package-github-release.sh 0.1.0` — created
  `dist/VibeMenu-v0.1.0-macos-arm64.zip` (~244K).

**Verified vs. not:** verified the script builds, locates, and zips the Release `.app`
end-to-end and the zip exists. **Not verified:** the zip was not unzipped and launched from
`/Applications`. The build is genuinely unsigned/not-notarized, so the Gatekeeper/unsigned
copy is honest. No screenshots exist (placeholders only). Not committed per request.

**Recommended next step:** Human runs the Part A manual smoke checklist against a freshly
unzipped `/Applications/VibeMenu.app`, then creates the GitHub Release and attaches the zip.

---

## Align app bundle version with GitHub release version (0.1.0)

**Context:** The dogfood zip was named `v0.1.0` but `App/Info.plist` still had
`CFBundleShortVersionString = 0.0`, so the built app reported the wrong marketing version.

**Change (source of truth = `App/Info.plist`):** the Xcode project uses
`GENERATE_INFOPLIST_FILE = NO` / `INFOPLIST_FILE = Info.plist` and defines no
`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`, so the plist literals are authoritative.
- `App/Info.plist` — `CFBundleShortVersionString` `0.0` → `0.1.0`. `CFBundleVersion` left at
  `1` (already the existing convention).
- `scripts/package-github-release.sh` — after locating the built `.app`, PlistBuddy-print
  its `CFBundleShortVersionString` / `CFBundleVersion` and **warn** (non-fatal) if the short
  version ≠ the requested package `$VERSION`.
- `RELEASE_CHECKLIST.md` — Part A §1 now includes verifying the bundle version matches before
  packaging (plist is hand-maintained; the script only names the zip).

No auto-versioning infrastructure, no notarize, no DMG.

**Validation (all real, all passed):**
- `xcodebuild … -configuration Release build` — BUILD SUCCEEDED.
- Built app `Contents/Info.plist`: `CFBundleShortVersionString = 0.1.0`, `CFBundleVersion = 1`
  (via PlistBuddy).
- `scripts/package-github-release.sh 0.1.0` — printed `Bundle version:
  CFBundleShortVersionString=0.1.0 CFBundleVersion=1`, no warning, created
  `dist/VibeMenu-v0.1.0-macos-arm64.zip` (~244K).
- Ran with mismatched `0.9.9` to confirm the warning path fires; removed the throwaway zip.

**Verified vs. not:** verified the Release build embeds `0.1.0` / `1` and the script's
version check both passes (match) and warns (mismatch). Not launched from `/Applications`;
still unsigned/not-notarized. Not committed per request.

**Recommended next step:** Human runs the Part A manual smoke checklist, then creates the
GitHub Release and attaches the zip.

---

## v0.1 app icon, menu-bar icon, and compact settings window

**Context:** Pre-release polish for the GitHub v0.1.0 dogfood build. Remaining work was
app-identity (a real app icon + a matching menu-bar glyph, replacing the placeholder
`bolt.fill` SF Symbol and the generic app icon) and a compact Settings window.

**Icon source & derivation (local, no downloads, no dependencies):** the reference art
(terminal-prompt chevron `>` + heartbeat/pulse waveform) was reproduced as vector geometry
and rasterized locally with a small AppKit/CoreGraphics script (`scripts/render-icons.swift`:
`NSBezierPath` strokes, `NSBitmapImageRep` → PNG). No SVG rasterizer / Pillow / cairosvg was
available; AppKit was. The script authors the chevron + pulse in a 1024 reference grid and
renders every size, so the assets are reproducible (`swift scripts/render-icons.swift
App/Assets.xcassets`).

**Added — asset catalog `App/Assets.xcassets`:**
- `AppIcon.appiconset` — dark rounded-square (native macOS content-square proportions) with
  green neon chevron + pulse and a soft glow; full macOS size set (16→1024, 1x/2x).
- `MenuBarIcon.imageset` — flat monochrome (black + alpha) chevron + pulse at 18/36/54 px,
  `template-rendering-intent = template` so macOS tints it for light/dark menu bars.

**Wiring:**
- `App/VibeMenu.xcodeproj/project.pbxproj` — added the `Assets.xcassets` file reference, the
  Resources build-phase entry, the App group entry, and `ASSETCATALOG_COMPILER_APPICON_NAME
  = AppIcon` in both Debug and Release target configs.
- `App/Info.plist` — added `CFBundleIconName = AppIcon` (needed because
  `GENERATE_INFOPLIST_FILE = NO`, so Xcode does not inject it) so Finder/LaunchServices
  resolve the compiled icon.
- `Sources/VibeMenuApp/VibeMenuApp.swift` — `MenuBarExtra` now uses
  `image: "MenuBarIcon"` instead of `systemImage: "bolt.fill"`. The asset lives only in the
  `.app` target; the string name compiles fine under plain `swift build`.

**Settings window (compact):** dropped the `.regularMaterial` / `.scrollContentBackground(.hidden)`
glass (it made the excess height read as a translucent void) and constrained the grouped
`Form` with `.frame(width: 360)` + `.fixedSize(horizontal: false, vertical: true)` so the
window hugs the two sections (General → Launch at login; Menu bar → Show Claude / Show
Thermal) instead of stretching to a tall default with an empty bottom. No rows added or
removed; all existing behavior (login item, visibility toggles) unchanged.

**Docs:** `README.md` (status line + "menu bar" bullet now describe the chevron + pulse icon
instead of "no app icon yet" / "bolt icon"); `RELEASE_CHECKLIST.md` (launch smoke test
mentions the new menu-bar icon; two new manual checks — app icon in Finder, menu-bar icon
appearance/tint).

**Validation (all real, all passed):**
- `swift build` — Build complete.
- `scripts/test.sh` — 112 tests in 20 suites passed.
- `xcodebuild … -configuration Release build` — BUILD SUCCEEDED. Verified the built bundle:
  `Contents/Resources/AppIcon.icns` present, `CFBundleIconName = AppIcon`, and
  `assetutil --info Assets.car` shows `AppIcon` renditions (16→1024) plus `MenuBarIcon` with
  `Template Mode = template`.
- `scripts/package-github-release.sh 0.1.0` — created
  `dist/VibeMenu-v0.1.0-macos-arm64.zip` (~345K); zip contains `AppIcon.icns` + `Assets.car`.

**Verified vs. not:** verified the icons compile into the bundle and the Release build/zip
succeed; verified the rendered PNGs visually (app icon + menu-bar template) match the
reference motif. NOT launched from `/Applications` — actual menu-bar appearance/tint, Finder
icon, Spotlight icon, and the on-screen Settings window height are unverified on-device and
need the human manual checks. Still unsigned / not notarized. Not committed per request.

**Recommended next step:** Human runs the Part A manual smoke checklist (esp. the two new
icon checks + Settings window height), then creates the GitHub Release and attaches the zip.

---

## Menu-bar icon sizing fix (pre-release) — glyph too small

**Problem:** The `MenuBarIcon` template rendered correctly and tinted in the menu bar, but
the chevron+pulse glyph looked tiny. Root cause: the shared 1024 reference geometry places
the glyph in a small central region — combined stroked bbox ≈ x202–818 (60% width) / y312–680
(**36% height**) — and the menu-bar canvas is square, so on an 18pt status item the visible
mark was only ~11×6.5pt.

**Fix (asset regeneration only, no behavior change):** Added a template-only zoom in
`scripts/render-icons.swift` (`fitTemplate` + `bbox`, `TEMPLATE_MARGIN = 0.05`). It scales the
glyph points **and** stroke widths about the glyph center so the wider dimension fills ~90% of
the canvas (k ≈ 1.5), preserving the exact design. Applied ONLY when `template == true`; the
app-icon branch keeps the original unzoomed geometry, so `AppIcon` is byte-for-byte the same
motif. Regenerated `menubar_{18,36,54}.png`. `MenuBarExtra(image:)` and Contents.json unchanged
(least-fragile native path — no custom label view needed).

**Measured fill (opaque bbox / canvas):** 18px → w88% h55%, 54px → w92% h55% (was ~60%/36%).
Height is capped by the inherently wide chevron+pulse aspect — native for horizontal glyphs
(cf. Wi-Fi/battery), and the status item stays a normal width.

**Validation (all real, all passed):**
- `swift build` — Build complete.
- `scripts/test.sh` — 112 tests in 20 suites passed.
- `xcodebuild … -configuration Release build` — BUILD SUCCEEDED.
- `scripts/package-github-release.sh 0.1.0` — created `dist/VibeMenu-v0.1.0-macos-arm64.zip` (~348K).

**Verified vs. not:** verified the regenerated PNGs, larger fill ratios, and that build/test/
package all succeed. NOT launched on-device — actual menu-bar size/crispness/tint and item
width need human eyes. Still unsigned / not notarized. Not committed per request.

**Recommended next step:** Human verifies the menu-bar icon on-device (larger, crisp, tints,
not too wide, menu opens), then proceeds with the release.

---

## v0.1 replace app and menu-bar icons

**Change:** Replaced the procedurally-drawn chevron/pulse icon with two shipped source
artworks. Added `App/IconSources/` holding `big_app_logo.jpg` (app icon source, 1024²,
black field + white `>-<` glyph) and `minilogo_for_bar.png` (menu-bar source, 1024²,
white glyph on transparent). Rewrote `scripts/render-icons.swift`: it no longer draws
vector geometry — it resamples the two sources into every asset-catalog size (AppKit /
CoreGraphics only, no deps).

**App icon:** source is placed on Apple's macOS icon grid — a centered rounded-rect body
(inset ≈8.6% of canvas, corner radius ≈22.37% of body) with transparent margins/corners,
matching the previous icon's footprint so it sits natively next to other Dock/Finder
icons. Drawn 1:1 (both square) → no distortion. Regenerated `icon_{16,32,64,128,256,512,
1024}.png`.

**Menu-bar template:** auto-cropped the source to its alpha bbox (179,269 666×486 in the
1024 grid), scaled to fill ~88% of the square canvas (`TEMPLATE_MARGIN = 0.06`), and
re-rendered as **black masked by the source alpha** — canonical template form, so macOS
tints it for light/dark and there is no black background box. Regenerated `menubar_{18,
36,54}.png`. `Contents.json` (`template-rendering-intent = template`) and
`MenuBarExtra(image: "MenuBarIcon")` unchanged.

**Settings window:** unchanged — already compact (`Form(.grouped)` +
`.fixedSize(vertical: true)`, no material), with General → Launch at login and Menu bar →
Show Claude/Thermal. Verified it still builds; no edits needed.

**Docs:** dropped stale "chevron + pulse" / "bolt icon" wording in `README.md` and
`RELEASE_CHECKLIST.md`; the checklist now also calls out "large enough" and "no black box"
for the menu-bar icon.

**Validation (all real, all passed):**
- `swift build` — Build complete.
- `scripts/test.sh` — 112 tests in 20 suites passed.
- `xcodebuild … -configuration Release build` — BUILD SUCCEEDED; `assetutil` confirms
  `AppIcon` + `MenuBarIcon` compiled into `Assets.car`, `CFBundleIconName = AppIcon`.
- `scripts/package-github-release.sh 0.1.0` — created
  `dist/VibeMenu-v0.1.0-macos-arm64.zip` (~312K).

**Verified vs. not:** verified the regenerated PNGs (rendered previews: app icon rounded
tile + centered glyph; menu-bar template tints black-on-light / white-on-dark with no box),
asset compilation, and that build/test/package all succeed. NOT launched on-device —
Finder/Spotlight app-icon appearance and live menu-bar size/tint need human eyes. Still
unsigned / not notarized. Not committed per request.

**Recommended next step:** Human verifies on-device (app icon in Finder/Applications/
Spotlight; menu-bar icon large, crisp, no black box, tints in light/dark; Settings still
compact), then proceeds with the release.

## App icon fix — remove extra rounded-tile container (full-bleed source)

**Problem:** The app icon in Applications/Finder/Spotlight looked like a *smaller* logo
sitting inside another dark icon tile. The menu-bar icon was already correct.

**Cause:** `renderAppIcon` in `scripts/render-icons.swift` treated `big_app_logo.jpg` as
raw art needing macOS-grid framing — it re-inset the source (~8.6% of canvas) and clipped
it to a rounded "squircle" body with transparent margins. But the source is *already* a
finished, full-bleed icon (black field + centered glyph, artist's own margins baked in).
The extra inset + rounded container shrank the complete artwork into a small dark tile
floating in transparent margins, so the glyph read tiny and the icon looked double-boxed.

**Fix:** `renderAppIcon` now resamples the source 1:1 to fill the entire canvas — no
inset, no rounded clip (both source and target are 1:1, so no distortion). The app icon
now matches the provided artwork directly. Removed the now-unused `APPICON_INSET` /
`APPICON_RADIUS_FRAC` constants. Regenerated `icon_{16,32,64,128,256,512,1024}.png`.

**Menu-bar pipeline: unchanged.** `renderMenuTemplate` and its constants are untouched;
re-running the generator produced byte-identical `menubar_{18,36,54}.png` (they don't even
appear in `git status`). `MenuBarIcon.imageset` and `MenuBarExtra(image:)` wiring
unchanged. Settings window and all app behavior untouched.

**Validation (all real, all passed):**
- `swift build` — Build complete.
- `scripts/test.sh` — 112 tests in 20 suites passed.
- `xcodebuild … -configuration Release build` — BUILD SUCCEEDED; `assetutil` now reports
  `AppIcon` `"Opaque": true` (full-bleed, no transparent margins) in `Assets.car`.
- `scripts/package-github-release.sh 0.1.0` — regenerated
  `dist/VibeMenu-v0.1.0-macos-arm64.zip` (~308K); packaged bundle's `AppIcon` also opaque.

**Verified vs. not:** verified the regenerated PNG previews (app icon now full-bleed,
glyph at source proportions, no inner tile/padding; menu-bar preview unchanged), that the
compiled/ packaged icon is opaque, and that build/test/package all succeed. NOT launched
on-device — Finder/Spotlight/Dock appearance needs human eyes (and the icon cache may need
a refresh). Still unsigned / not notarized. Not committed per request.

**Recommended next step:** Human verifies the app icon in Finder/Applications/Spotlight
fills the tile and matches the source; if the old icon lingers, refresh LaunchServices /
the icon cache or re-login.

---

## 2026-07-03 — App icon: swap in new squircle-tile source

**Task/session:** Fix the Finder/Applications/Spotlight app icon using a newly supplied
app-logo image. Menu-bar icon must stay byte-for-byte identical.

**Summary:** The previous app-icon source (`big_app_logo.jpg`) was a flat, full-bleed
black **square** with a small centered glyph — so macOS (which does not auto-round Mac app
icons) showed a plain square, not a proper squircle app tile. The new supplied image is
already the finished macOS app-icon tile (rounded squircle + drop shadow + larger glyph).
Replaced the source with it and re-rendered. The render pipeline already did full-canvas
1:1 resampling (no inset/clip/framing) from an earlier fix, so no icon-generation logic
changed — only the source art and its path/extension.

**Files touched:**
- `App/IconSources/big_app_logo.png` (new) — the supplied 1254×1254 opaque tile art; the
  new source of truth. Kept as lossless PNG for crisp glyph edges.
- `App/IconSources/big_app_logo.jpg` (deleted) — old flat-square source.
- `scripts/render-icons.swift` — `appSource` and comments now point at `big_app_logo.png`.
  App-icon rendering itself unchanged (still full-canvas, no padding/rounding).
- `App/Assets.xcassets/AppIcon.appiconset/icon_{16,32,64,128,256,512,1024}.png` —
  regenerated from the new source.

**Menu-bar icon unchanged (verified):** re-running the script also rewrites the
`MenuBarIcon.imageset` PNGs from the untouched `minilogo_for_bar.png`; their SHA-1 hashes
are identical before/after and `git status` shows no change to `MenuBarIcon.imageset/`.

**Commands / validation (all passed):**
- `swift scripts/render-icons.swift App/Assets.xcassets App/IconSources` — wrote 7 app +
  3 menu-bar PNGs; menu-bar hashes unchanged.
- `swift build` — Build complete.
- `scripts/test.sh` — 112 tests / 20 suites passed.
- `xcodebuild … -configuration Release build` — BUILD SUCCEEDED; built app has
  `CFBundleIconName=AppIcon`, AppIcon renditions present in `Assets.car`.
- `scripts/package-github-release.sh 0.1.0` — rebuilt Release and produced
  `dist/VibeMenu-v0.1.0-macos-arm64.zip` (1.8M); zipped bundle carries the 11 AppIcon
  renditions, `CFBundleIconName=AppIcon`, `CFBundleShortVersionString=0.1.0`.

**Verified vs. not:** verified the regenerated 1024 preview matches the supplied art
(full-canvas squircle, no inner tile/padding/shrink), menu-bar bytes unchanged, icon
wiring in both the Xcode-built and packaged bundles, and that build/test/package succeed.
NOT launched on-device — Finder/Dock/Spotlight appearance and any icon-cache staleness
need human eyes. Still unsigned / not notarized. Not committed per request.

**Recommended next step:** Human confirms the icon in Finder/Applications/Spotlight; if the
old icon lingers, refresh LaunchServices / the icon cache or re-login.

---

## 2026-07-03 — Pre-release GitHub polish (public-repo readiness)

**Summary:** Documentation/repo-hygiene pass to make the repo safe and friendly to open to
the public alongside the v0.1.0 dogfood release. No code or app behavior changed. Shortened
the README, corrected the Gatekeeper story for the app's macOS-15 baseline (Apple removed the
Control-click → Open bypass for un-notarized apps on Sequoia, so **System Settings → Privacy &
Security → Open Anyway** is now the reliable first-launch path), added GitHub issue/discussion
guidance, and extended the release checklist with a "make repo public / enable Issues &
Discussions" gate. Ran a public-repo safety scan — clean.

**Files touched:**
- `README.md` — rewritten shorter (~156 → ~110 lines): one-line pitch, What it does, Install
  (download → unzip → move to /Applications → open → Privacy & Security → Open Anyway),
  Privacy, Limitations, **Feedback** (Issues for bugs/features, Discussions for questions),
  Develop, License. Longer detail delegated to docs/ and the existing longform docs.
- `docs/INSTALL.md` — first-launch step now leads with Privacy & Security → Open Anyway
  (right-click → Open noted as a secondary path); clarified the zip is only the download
  package and that you launch from /Applications afterward; Launch-at-Login note kept.
- `RELEASE_CHECKLIST.md` — new section 6 "Make the repo public & enable community features"
  (public visibility + safety re-scan, enable Issues, optional Discussions, verify README
  install flow); create-release step now verifies the asset shows on the published release;
  Gatekeeper caveat + release-notes template updated to Open Anyway wording.
- `.github/ISSUE_TEMPLATE/bug_report.md`, `feature_request.md`, `config.yml` (new) —
  lightweight templates; config disables blank issues and points questions at Discussions.

**Public-repo safety scan (clean):**
- No secrets/tokens/keys/passwords, private certs, provisioning profiles, or `.env` tracked.
  `git grep` "secret"-style hits are all **synthetic test fixtures** in
  `Tests/…/ClaudeHeartbeatTests.swift` that assert VibeMenu does *not* leak such data.
- `build/` and `dist/` are gitignored and untracked; `.DS_Store` untracked; no DerivedData
  or dist zip tracked by git.
- No personal emails in tracked files. Bundle id `com.kirillchistov.VibeMenu` is intentional
  (permanent reverse-domain id), `DEVELOPMENT_TEAM` empty, ad-hoc signing (`-`).
- Minor: `DEVELOPMENT_LOG.md` previously contained local build paths under
  `<local user>/…/DerivedData` (exposed the macOS short username). Cosmetic, not a secret —
  since scrubbed to generic `<DerivedData>/…` placeholders for the public release.

**Commands / validation (all passed):**
- `git status` — only README.md, RELEASE_CHECKLIST.md, docs/INSTALL.md modified; `.github/`
  untracked. Working tree otherwise clean.
- `swift build` — Build complete.
- `scripts/test.sh` — 112 tests / 20 suites passed.
- `scripts/package-github-release.sh 0.1.0` — BUILD SUCCEEDED; produced
  `dist/VibeMenu-v0.1.0-macos-arm64.zip` (1.8M); `CFBundleShortVersionString=0.1.0`.

**Verified vs. not:** verified docs render/link sanity by inspection and that build/test/
package succeed. NOT launched; menu-bar behavior unverified this pass. Still unsigned / not
notarized. Not committed per request.

**Recommended next step:** Human makes the repo public, enables Issues (and optionally
Discussions), then runs the RELEASE_CHECKLIST manual smoke tests and publishes the v0.1.0
release with the zip attached.

---

## 2026-07-04 — v0.1.1 automation reliability: bounded quiet-work hold

**Task/session:** `v0.1.1 automation reliability fix` — stop VibeMenu releasing sleep
prevention during long *silent* Claude work (a long build/test, one long tool call, or a
subagent/Task), while still releasing promptly on a genuine finish. Product decision:
implement the "revised **D + C**" approach (explicit state distinction **and** a bounded
cap), not the simple 180s-grace idea. Recorded as [ADR-0010](decisions/0010-quiet-work-hold.md).

**Root cause.** v0.1 wired automation as `automationRequested = (state == .active)`. An
active heartbeat aging past the 120s L2 display window surfaces as `.waiting` — the *same*
display state a genuine `Stop` produces — so `updateClaudeActivity` released the assertion
mid-run during any silent phase where no hook fired for >120s. Display state alone cannot
tell "finished" from "quietly still working."

**Change (small, pure-core + thin wiring).**
- New pure evaluator `ClaudeActivityState.automationIntent(heartbeats:signals:now:quietHoldCap:)`
  → `ClaudeAutomationIntent{.hold,.release}`, **decoupled from the display state**. Process
  gone ⇒ release; per live session (newest wins) a *work-in-progress* newest event within the
  **15-minute cap** ⇒ hold; any one holding session wins; `Stop`/`SessionEnd`/past-cap ⇒
  release. The cap — not the 600s display "stale" window — is the automation bound (applying
  the 600s window would have capped the hold at 10 min; caught by a failing test and fixed).
- New `ClaudeHeartbeatEvent` cases `subagentStart`/`subagentStop` + `indicatesWorkInProgress`
  classification (broader than display `isActiveEvent`): subagent events **and** unknown/
  future events hold (a subagent finishing or an unrecognised event must never force a global
  release — verified `SubagentStop` is per-subagent via the current Claude Code hooks docs);
  `Notification` classified conservatively as waiting-for-user (release), documented.
- The bounded cap is enforced by the existing ~2s detection re-evaluation, **not** a one-shot
  timer, so the whole decision stays pure. Provider computes the intent each tick and emits it
  on its own first-then-on-change stream (`onAutomation`); `ClaudeActivityModel` republishes
  (`automationIntent` + `onAutomationChange`); app feeds `PowerAssertionModel.updateClaudeAutomation(_:)`.
- Invariants preserved: automation only sets `automationRequested`, never `manualRequested`;
  `effective == manual || automation`; manual keep-awake still wins. No network/telemetry/helper.
- Hook sample (`settings-snippet.json`) + Support README now also wire `SubagentStart`/
  `SubagentStop`; README gains a `pmset`-based quiet-hold verification procedure. Version
  bumped to **0.1.1** (`App/Info.plist`).

**Files changed:** `Sources/VibeMenuCore/ClaudeHeartbeat.swift` (intent enum, cap constant,
`automationIntent`, subagent cases, `indicatesWorkInProgress`), `ClaudeActivityProvider.swift`
(compute/emit intent + DEBUG intent log), `ClaudeActivityModel.swift` (republish intent),
`PowerAssertionManager.swift` (`updateClaudeAutomation`), `Sources/VibeMenuApp/VibeMenuApp.swift`
(wire intent), tests (`ClaudeHeartbeatTests`, `PowerAssertionTests`, `ClaudeActivityTests`),
`docs/decisions/0010-quiet-work-hold.md` (new), `App/Info.plist` (0.1.1), and wording in
`README.md` / `docs/FAQ.md` / `docs/PRODUCT.md` / `docs/ARCHITECTURE.md` / `docs/ROADMAP.md` /
`docs/PRIVACY.md` / `docs/RELEASE_CHECKLIST.md` / `Support/ClaudeHeartbeat/{README.md,settings-snippet.json}`.

**Commands / validation (all passed):**
- `swift build` — Build complete.
- `scripts/test.sh` — **137 tests / 21 suites passed** (was 112/20; +25 automation tests,
  incl. the 12 required cases). One intermediate failure — the 600s stale window shortening
  the cap — was caught by `quietHoldReleasesAfterCap` and fixed by making the cap the sole
  automation bound.
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug build` —
  **BUILD SUCCEEDED**.
- `scripts/package-github-release.sh 0.1.1` — produced `dist/VibeMenu-v0.1.1-macos-arm64.zip`
  (1.8M); packaged bundle `CFBundleShortVersionString=0.1.1` (no version-drift warning).

**Empirical findings.** Confirmed `pmset -g assertions` reports VibeMenu's assertion under
the exact name `"VibeMenu Keep Awake"` (matches `SystemPowerAssertionManager.defaultAssertionName`),
so the documented quiet-hold verification command is correct. Note: a *previously-installed*
VibeMenu (pid 36592, the old build) was observed holding that assertion for ~11.7h at the time
— consistent with either manual keep-awake on or the pre-fix behavior; left untouched. The
new build was **not** launched this session.

**Verified vs. not:** verified via the pure unit tests (the automation evaluator is exhaustively
tested over synthetic heartbeat timelines) and by building all three targets + packaging.
**Not verified:** a live end-to-end run against a real multi-minute Claude Task/subagent with
the new build launched — documented as a manual procedure in
`Support/ClaudeHeartbeat/README.md` and `RELEASE_CHECKLIST.md`. Still unsigned / not notarized.
Not committed (per request).

**Recommended next step:** launch the new 0.1.1 build and run the documented quiet-hold manual
test (long `Bash`/Task → watch heartbeat JSON, the **Claude=Idle / Sleep prevention=Active**
menu split, and `pmset` holding through the silent phase then releasing after `Stop`), then a
second-model review of `automationIntent` before the human approves the release.

## 2026-07-05 — Session Radar (v0.2): per-session Claude state in the menu

**What changed.** Added **Session Radar** — the single `Claude: Active/Idle` menu row becomes a
compact per-session list (working / quiet-working / waiting-for-input / done / stale + elapsed +
a `Claude` tag + a short session-id fragment). It is a **pure, display-only** layer over the
existing L2 heartbeat records: it reads **nothing new** (only the `{schemaVersion, updatedAt,
event, sessionID}` files, process presence, and `now`) and **leaves the keep-awake path
untouched** (`automationIntent` still feeds power). Per-session state is *defined* to be
identical to the automation decision, so `sessionsKeepAwakeIntent(...) == automationIntent(...)`
— pinned by a test — meaning the radar can never drift from the power decision. Researched first
(competitors Vibe Island / Open Island / Ping Island / MioIsland / Vibe Notch / AgentNotch, and
Adrafinil for the power lifecycle; Claude hook capabilities) and captured in
`docs/decisions/0011-session-radar.md`. `permissionRequested` is a reserved placeholder that
`derive` never produces (needs the `Notification` `notification_type`, an opt-in future hook
change) — so the UI never fabricates a permission prompt.

**Files changed.**
- `Sources/VibeMenuCore/ClaudeSession.swift` (**new**) — `ClaudeSessionState`, `ClaudeSession`,
  `ClaudeSessionStore` (pure `update` with startedAt tracking, 30-min prune, attention-first
  sort), `ClaudeSessionState.derive`, `sessionsKeepAwakeIntent`, `shortDuration` formatter.
- `Sources/VibeMenuCore/ClaudeActivityProvider.swift` — `onSessions` on the observing protocol;
  the real provider owns one `ClaudeSessionStore`, folds it each ~2s tick under the lock, and
  emits the list first-then-on-change.
- `Sources/VibeMenuCore/ClaudeActivityModel.swift` — republishes `sessions`.
- `Sources/VibeMenuApp/VibeMenuApp.swift` — `SessionRadarView` + `SessionRow` (state-coloured
  dot, elapsed via `TimelineView`, `Claude` tag, short id), fallback to the pre-radar label when
  empty; popover widened 240 → 300.
- `Tests/VibeMenuCoreTests/ClaudeSessionTests.swift` (**new**, +31 tests) — derivation, state
  helpers, session/value helpers, store (startedAt/prune/sort/aggregate), and the
  `sessionsKeepAwakeIntent == automationIntent` equivalence battery.
- `Tests/VibeMenuCoreTests/ClaudeActivityTests.swift` — `FakeClaudeProvider` updated for
  `onSessions`; +1 model republish test.
- Docs: `docs/decisions/0011-session-radar.md` (new), `docs/ARCHITECTURE.md`, `docs/PRODUCT.md`,
  `docs/ROADMAP.md`, `docs/PRIVACY.md`.

**Commands / validation (all passed).**
- `swift build` — Build complete! (1.58s).
- `scripts/test.sh` — **169 tests / 26 suites passed** (was 137/21; +32).
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug build` —
  **BUILD SUCCEEDED**.
- **Real-data end-to-end check** (throwaway program over the live heartbeat dir, public API
  only): **105 heartbeat files → 105 decoded → 3 shown after pruning**; the live session
  (`43fef9…`, this Claude Code run) correctly derived **working**, two recent ones **done**,
  aggregate **hold**. Confirms the file schema, the pruning against real accumulation, the
  derivation, the sort, and the aggregate on real data.

**Empirical finding.** The hook never deletes heartbeat files — the live machine had **105** in
`~/Library/Application Support/VibeMenu/ClaudeHeartbeat/sessions/` (mostly days old). The radar
prunes them from the *list* (30-min horizon), but on-disk cleanup (hook-side delete on
`SessionEnd`, or a VibeMenu sweep) is **future work**, deliberately not done here (it adds a
write path).

**Verified vs. not.** Verified: all three build/test targets and the real-data pipeline dump.
**Not verified:** the SwiftUI popover's *visual* layout in a running app — the owner's real
VibeMenu (pid 93171) was running and launching a second instance would duplicate the menu-bar
item/assertion, so that remains a manual smoke-test step. Still unsigned / not notarized. **Not
committed** (per request).

**Open decisions flagged for the owner** (see ADR 0011): the short session-id fragment shown in
rows (trivially removable); enabling `permissionRequested` via an opt-in `notification_type`
hook change; and unifying the power feed onto `sessionsKeepAwakeIntent` (needs the second-model
review AGENTS.md §18 requires — the equivalence test makes it a validated target).

**Recommended next step.** Owner review of the id-fragment choice; a manual visual smoke-test of
the popover with the new build; then decide the next Session Radar increment (a notification on
"waiting for input" / long-run done, or the `notification_type` capture for
`permissionRequested`).

---

## 2026-07-05 — Session Radar identity: project folder name from cwd

**Task/session:** Improve Session Radar identity and visibility rules (`docs/decisions/0012-session-name-from-cwd.md`).

**Summary.** Replaced the human-useless session-id fragment on each radar row with the
**project folder name**, captured by the opt-in hook from the top-level `cwd` (folder name
only — never the full path). Added pure visibility rules (≤5 rows, ≤2 done, hide old
done/stale, drop unknown, "+N more"), shortened the state copy (Working / Quiet / Waiting /
Done), and hid the raw session id from the UI. Owner chose the "hook captures cwd" source over
reading `~/.claude/projects` dir names or a do-nothing fallback.

**Research finding (safe-source question).** Claude Code *does* persist a human-readable
`customTitle` (record `type: "custom-title"`) plus `lastPrompt`, `cwd`, and `gitBranch` — but
all **inside the transcript `.jsonl`**. Reading any of them means parsing transcript contents,
which violates AGENTS.md §6, so there is **no safe title field**. The only safe human-readable
identity is the project folder name from `cwd`. (Verified by inspecting record `type`s and
field *keys* only; no message text was read.)

**Files changed:**
- `Support/ClaudeHeartbeat/vibemenu-claude-hook.sh` — schema 1→2; parse top-level `cwd`,
  emit `basename(cwd)` from inside the Python parser, sanitise to `[A-Za-z0-9 ._-]` (≤64), write
  new `project` field. Full path/parents never written.
- `Sources/VibeMenuCore/ClaudeHeartbeat.swift` — `ClaudeHeartbeatRecord.project`;
  `currentSchemaVersion` 1→2; decoder reads/trims `project` (empty ⇒ nil; schema-1 ⇒ nil).
- `Sources/VibeMenuCore/ClaudeSession.swift` — `ClaudeSession.projectName` + `displayName`
  (folder name ?? "Claude session"); shortened state `label`s; store attaches `projectName`;
  new pure `SessionRadar.present` (visibility rules + `RadarRow` name disambiguation).
- `Sources/VibeMenuApp/VibeMenuApp.swift` — `SessionRadarView` uses `SessionRadar.present`;
  `SessionRow` is now single-line `state · name · elapsed`; id fragment + agent capsule removed;
  "+N more recent sessions" footer.
- `Tests/VibeMenuCoreTests/ClaudeHeartbeatTests.swift` — new `project` decode test; updated the
  two subprocess hook tests to the schema-2 contract (folder name written; full path/parents
  still never leak).
- `Tests/VibeMenuCoreTests/ClaudeSessionTests.swift` — `displayName`, `projectName` flow, and a
  full `SessionRadar.present` suite (caps, horizons, disambiguation, order).
- `docs/PRIVACY.md`, `Support/ClaudeHeartbeat/README.md` — documented cwd→folder-name capture,
  schema 2, and a Session-Radar "what is/ isn't read" table.
- `docs/decisions/0012-session-name-from-cwd.md` — new ADR.

**Commands / validation (real output):**
- Hook smoke test (synthetic payloads): `project` = `VibeMenu` for a normal cwd, `My Cool
  Project` for a spaced folder with trailing slash, `""` for missing cwd; a quote/backslash/comma
  injection in the folder name was stripped and all files stayed valid JSON; nested
  `tool_input.cwd` was ignored (top-level only).
- `swift build` → `Build complete!`.
- `scripts/test.sh` → `Test run with 181 tests in 27 suites passed`.
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug
  -derivedDataPath ./.derivedData build` → `** BUILD SUCCEEDED **`.

**Verified vs. not verified.** Verified: hook output shape/safety, decode, store wiring, the
pure visibility/naming rules, the keep-awake equivalence still holds, and all three
build/test gates. **Not verified:** the live SwiftUI popover appearance (not launched — the
owner's real VibeMenu is running; a second instance would duplicate the menu-bar item /
assertion, per 0011); and end-to-end capture against the owner's *installed* hook (their copy
is schema-1 until re-copied — existing on-disk heartbeats have no `project` and will show
`Claude session` until sessions run again under the new script).

**Recommended next step.** Owner re-copies the hook script (no settings change) and does a
manual visual smoke-test of the popover; then decide whether same-project disambiguation needs
more than the numeric suffix (e.g. an opt-in `customTitle`-via-hook path, which would need its
own privacy ADR).

## 2026-07-05 — Session Radar: Claude Code session title + manual dismiss

**Task/session:** Fix the Session Radar identity mismatch (rows named `VibeMenu 1/2` instead of
Claude Code's real session names) and add a way to hide a row
(`docs/decisions/0013-session-title-and-dismiss.md`).

**Summary.** The radar now shows **Claude Code's own session title** as each row's name, read
narrowly from the transcript, with the folder name as fallback. Also added a **manual dismiss**
(swipe-right or right-click → Hide) that only hides the row in VibeMenu.

**Part A — research (types/keys only, no message values).** Across this project's 63 transcripts:
the title lives in two one-field records — `custom-title`→`customTitle` (user rename; last wins)
and `ai-title`→`aiTitle` (auto title; what un-renamed sessions show). Claude Code shows custom
if present, else ai. Every title record's `sessionId` **equals the transcript filename stem**, so
the file is found by name (`~/.claude/projects/*/<session_id>.jsonl`) with no content parsing.
`last-prompt`/`assistant`/`user` records (prompt/response content) are never consulted. Owner
approved reading **both** title records (customTitle preferred), still no other field.

**Design.**
- Fallback order for the row name: `customTitle`/`aiTitle` → project folder name → `"Claude
  session"`. No raw session id in the main UI.
- Dismiss uses **Option 2** (hide until a newer event): dismissing records `lastEventAt`; the row
  reappears the moment a newer heartbeat arrives. In-memory, so restart also clears it. Native
  SwiftUI `DragGesture` + `contextMenu` fallback; no AppKit/Accessibility.
- Keep-awake untouched — title + dismiss are display-only, so the `sessionsKeepAwakeIntent ==
  automationIntent` equivalence test still holds.

**Changed files.**
- `Sources/VibeMenuCore/ClaudeSessionTitle.swift` (new) — pure title parser: decodes a line only
  if it's literally a title record, keeps only `customTitle`/`aiTitle` (last custom else last ai),
  trims + length-caps. Never parses prompt/response/`lastPrompt`/tool lines.
- `Sources/VibeMenuCore/TranscriptTitleResolver.swift` (new) — the sole component that opens a
  transcript; locates it by (traversal-validated) session id, reads it, hands bytes to the pure
  parser, caches title per session by mtime. No title/path/id logged.
- `Sources/VibeMenuCore/DismissedSessions.swift` (new) — pure `DismissedSessionRegistry`
  (dismiss / isHidden / reconcile: un-hide on newer event, drop vanished).
- `Sources/VibeMenuCore/ClaudeSession.swift` — `title` field; `displayName` = `title ?? projectName
  ?? "Claude session"`; `withTitle(_:)`.
- `Sources/VibeMenuCore/ClaudeActivityProvider.swift` — injected `titleResolver`
  (`TranscriptTitleResolver()` default; `nil` in tests); attaches titles after the store, outside
  the lock; updated privacy header.
- `Sources/VibeMenuCore/ClaudeActivityModel.swift` — owns `DismissedSessionRegistry`; new
  `visibleSessions` + `dismiss(_:)`.
- `Sources/VibeMenuApp/VibeMenuApp.swift` — `SessionRadarView` renders `visibleSessions`;
  `SessionRow` gets swipe-right drag (offset + `.move(edge:.trailing)` removal) and a "Hide from
  VibeMenu" context-menu fallback.
- `Tests/…/ClaudeSessionTitleTests.swift`, `DismissedSessionsTests.swift` (new) + `ClaudeSessionTests`
  updates — all synthetic/fake data.
- `docs/PRIVACY.md`, `docs/ARCHITECTURE.md`, `AGENTS.md` (§6 narrow exception),
  `docs/decisions/0013-session-title-and-dismiss.md` (new ADR).

**Commands / validation (real output).**
- `swift build` → `Build complete!`.
- `scripts/test.sh` → `Test run with 202 tests in 30 suites passed` (new suites:
  `ClaudeSessionTitle.parse`, `TranscriptTitleResolver.isSafeSessionID`,
  `DismissedSessionRegistry`).
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug
  -derivedDataPath ./.derivedData build` → `** BUILD SUCCEEDED **`.
- Real-data spot check (parser logic replicated in python over the owner's transcripts, title
  strings only): resolves to the exact Claude Code names — *Session Radar identity and visibility*,
  *VibeMenu local launch setup*, *Casual greeting and conversation*, etc.; 21/63 transcripts have a
  title, the rest fall back to `VibeMenu`.

**Verified vs. not verified.** Verified: pure parser/registry logic, resolver traversal-safety
gate, provider/model wiring compiles, keep-awake equivalence intact, all three build/test gates,
and title matching against real transcripts. **Not verified at runtime:** the live SwiftUI popover
(not launched — owner's real VibeMenu is running; a second instance would duplicate the menu-bar
item/assertion), so the swipe-to-dismiss animation and title rows are visually unverified; and the
title only appears for sessions whose transcript exists under `~/.claude/projects` (it does here).

**Recommended next step.** Owner runs the app and smoke-tests: confirm rows show Claude Code
titles, swipe-right + context-menu hide behave, and a dismissed live session reappears on its next
event. Consider a future FSEvents-based title refresh instead of the per-tick mtime `stat`.

## 2026-07-05 — Session Radar: filter home-dir "ghost" launches; make title lookup deterministic; honest title-availability finding

**Context / task.** Debug the reported Session Radar bugs from manual-test screenshots:
(1) "kirill 1 / kirill 2" ghost rows appearing when Claude is opened; (2) auto-titled sessions
("GMT time query", "Public repository audit") falling back to the project folder name instead of
their Claude Code title. Privacy-constrained investigation: heartbeat metadata + title records only
(`custom-title`/`ai-title`), no prompt/response/`lastPrompt`/message content, no network.

**Root causes (verified against live local data, privacy-safe).**
- **Ghost rows:** the Claude *desktop app* launches throwaway sessions in `$HOME`.
  The hook records `project="kirill"` (basename of home), the sessions fire only
  `SessionStart`→`SessionEnd` (no prompt/tool), leave no transcript under `~/.claude/projects/`, and
  have no title — so the radar showed `Done · kirill N`. `SessionRadar.present` had no rule to
  suppress home-folder / no-work sessions.
- **Titles falling back:** Claude Code does **not** reliably write a title record into the
  transcript. Live count: of 67 `~/.claude/projects/*/<id>.jsonl` transcripts, 9 had a `custom-title`
  and 15 an `ai-title` record; **45 had neither**. The desktop app's picker titles ("GMT time
  query", "Public repository audit") were found **nowhere** under `~/.claude` (not in transcripts as
  title records, not in `~/.claude.json`, not in `~/.claude/sessions/<pid>.json` whose `name` is a
  *derived* process name like `vibemenu-c3`). They live in the desktop app's own container, which
  VibeMenu is not scoped to read (ADR 0013). So the folder-name fallback is the **honest** behavior
  for those sessions — not a resolver bug. The resolver's location logic (scan all project dirs by
  session id) and parser (field names `customTitle`/`aiTitle`, verified against real record shapes)
  are both correct.

**Changes.**
- `Sources/VibeMenuCore/ClaudeHeartbeat.swift` — add `ClaudeHeartbeatEvent.isLifecycleOnly`
  (`SessionStart`/`SessionEnd` only): the signal that a session did no real work.
- `Sources/VibeMenuCore/ClaudeSession.swift` — add `ClaudeSession.isHomeFolderNoise(homeFolderName:)`
  (pure): hides an untitled session whose project folder name equals the home folder **and** which
  is done/stale/unknown or has only started; never hides a titled or actively-working session, and
  keeps a home-dir session that did real work (Stop/Notification/tool) even while waiting. Add
  `SessionRadar.currentHomeFolderName` (home dir's last path component only) and thread a
  `homeFolderName` param through `SessionRadar.present`, dropping noise at the eligibility stage so
  ghosts don't count toward `hiddenCount`.
- `Sources/VibeMenuApp/VibeMenuApp.swift` — pass `SessionRadar.currentHomeFolderName` into `present`.
- `Sources/VibeMenuCore/TranscriptTitleResolver.swift` — `locateTranscript` now picks the
  **most-recently-modified** match when a session id appears under several encoded project dirs
  (was: arbitrary first hit), using one `fileStat` per candidate for existence+mtime. Deterministic.
- Tests (all synthetic / fake data): `ClaudeSessionTests` — 9 home-folder-noise `present` cases;
  `ClaudeSessionTitleTests` — new `TranscriptTitleResolver transcript lookup` suite (find-by-id
  across encoded dirs, newest-of-multiple wins, no-title→nil ignoring prompt content, title-only
  extraction, unknown id→nil) using an injected temp `projects/` tree; `ClaudeHeartbeatTests` —
  `isLifecycleOnly` classification.

**Commands / validation (real output).**
- `swift build` → `Build complete! (1.55s)`.
- `scripts/test.sh` → `Test run with 217 tests in 31 suites passed`.
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug
  -derivedDataPath ./.derivedData build` → `** BUILD SUCCEEDED **`.

**Privacy impact.** None widened. New reads: the current user's home *folder name* (last path
component of the home dir — no path stored/shown) to recognise home-dir launches. The resolver still
opens only transcript title records; the deterministic-pick change is metadata-only (`stat` mtime).
No prompt/response/`lastPrompt`/message content is read or logged; nothing leaves the Mac.

**Verified vs. not verified.** Verified: root causes against live data; pure filter + resolver logic
via unit tests; all three build/test gates. **Not verified at runtime:** the live popover was not
launched (owner's real VibeMenu is running; a second instance would duplicate the menu-bar
item/assertion), so the ghost rows disappearing is confirmed only in tests, not on-screen. The
auto-titles that live off-disk ("GMT time query", "Public repository audit") **cannot** be shown
without a new (out-of-scope) data source; sessions Claude *does* title in the transcript resolve, and
late-written titles are picked up on the next tick via the mtime-keyed cache.

**Recommended next step.** Owner runs the app and confirms the "kirill" ghost rows are gone and real
project rows remain. If showing the desktop app's auto-titles becomes a requirement, it needs a new
ADR + data source (the desktop app's own store) and a privacy review — do not read it silently.

## 2026-07-06 — Session Radar: opt-in Claude Desktop session titles (enhanced title mode)

**Context / task.** Follow-through on the prior entry's deferral. Research (metadata/keys/title-
strings only, no message bodies) located the reliable source of the titles Claude Code shows in its
own UI: the **Claude Desktop app's** local session index, not the CLI transcript store —
`~/Library/Application Support/Claude/claude-code-sessions/<account>/<workspace>/local_<uuid>.json`,
one JSON object per session carrying `title`, `titleSource`, `cliSessionId` (= VibeMenu's session id),
`lastActivityAt`, `isArchived` (plus fields we never read: `promptSuggestion`, `alwaysAllowedReasons`,
`cwd`, …). All three previously-missing titles are present there and the live session's file updates in
real time. Owner requirement: surface these as an **opt-in, off-by-default** setting because it reads
another app's private, undocumented cache. See [`docs/decisions/0014-enhanced-desktop-titles.md`](decisions/0014-enhanced-desktop-titles.md).

**Changed files.**
- `Sources/VibeMenuCore/ClaudeDesktopTitleIndex.swift` (new) — **pure** parser: decodes one index
  file to a whitelisted `DesktopSessionRecord` (the `Decodable` DTO declares only the five allowed
  keys, so `promptSuggestion`/`cwd`/messages are never decoded), and `buildTitleMap` reduces records
  to `cliSessionID → title` (non-archived beats archived; latest `lastActivityAt` wins; ties keep the
  incumbent). Title trimmed + capped via `ClaudeSessionTitle.maxTitleLength`.
- `Sources/VibeMenuCore/DesktopTitleResolver.swift` (new) — `DesktopTitleResolver` adapter
  (`SessionTitleResolving`) gated by an injected `isEnabled` closure checked **before any file
  access**; globs `*/*/local_*.json` (both UUID levels enumerated, never assumed); caches the map
  keyed by a file signature (paths+mtimes+sizes) so an unchanged index costs stats not reads; missing
  dir → empty map (fail-closed). Plus `CompositeTitleResolver` — consults an ordered resolver list,
  first non-`nil` wins.
- `Sources/VibeMenuApp/VibeMenuApp.swift` — provider now takes
  `CompositeTitleResolver([DesktopTitleResolver(isEnabled: UserDefaults "useDesktopTitles"), TranscriptTitleResolver()])`,
  so flipping the setting takes effect on the next ~2s tick with no restart. Added
  `PreferenceKey.useDesktopTitles` (default off) and a **Settings → Session titles** section with the
  "Use Claude Desktop session titles" toggle and an in-UI privacy caption ("Reads Claude Desktop's
  local session index titles only. Does not read prompts or responses.").
- Tests (all synthetic / fake data): `Tests/VibeMenuCoreTests/ClaudeDesktopTitleTests.swift` (new) —
  parse valid record; **ignores non-whitelisted fields** (a fixture stuffed with
  `promptSuggestion`/`lastPrompt`/`cwd`/`model` parses to exactly the whitelisted record); missing
  id / empty title → dropped; trim + cap; malformed JSON → nil; dedup (latest activity, non-archived
  beats archived, archived-only fallback, missing-time sorts oldest); adapter resolves when enabled,
  **returns nil and reads nothing when disabled**, missing dir → nil, globs both UUID levels, honors a
  live enable-flag flip; composite first-non-nil + fall-through + full `displayName` fallback intact.
- Docs: new ADR `0014-enhanced-desktop-titles.md`; `PRIVACY.md` (promise bullet, Session Radar
  subsection, "what is/isn't read" rows); `ARCHITECTURE.md` (Session Radar title bullet); `README.md`
  (privacy blurb).

**Fallback chain (new).** Desktop title (opt-in, if found) → transcript `custom-title`/`ai-title` →
project folder name → `"Claude session"`. With the setting **off** (default), the Desktop resolver
returns `nil` without touching disk, so behavior is byte-for-byte the prior transcript-only path.

**Default.** **OFF.** It reads another app's private, undocumented cache; opt-in keeps the baseline
privacy promise intact and puts the choice with the user.

**Commands / validation (real output).**
- `swift build` → `Build complete! (1.33s)`.
- `scripts/test.sh` → `Test run with 238 tests in 35 suites passed after 0.274 seconds` (4 new
  suites: `ClaudeDesktopTitleIndex.parse`, `…buildTitleMap`, `DesktopTitleResolver`,
  `CompositeTitleResolver`).
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug
  -derivedDataPath ./.derivedData build` → `** BUILD SUCCEEDED **`.

**Privacy impact.** New capability, **off by default**, reads only when the user enables it. When on,
reads a strict whitelist (`cliSessionId`, `title`, `titleSource`, `lastActivityAt`, `isArchived`) from
the Desktop index — never `promptSuggestion`, `alwaysAllowedReasons`, `cwd`, prompts, responses, tool
output, or `lastPrompt`. Titles held in memory only, never written to disk, never logged. No network,
no writes to Claude files. Fail-closed on missing dir / format drift → transcript/folder fallback.

**Verified vs. not verified.** Verified: parser + adapter + composite logic via unit tests (temp
index tree + synthetic fixtures); the opt-in gate reads nothing when disabled; all three build/test
gates. **Not verified at runtime:** the live popover was not launched (owner's real VibeMenu runs; a
second instance would duplicate the menu-bar item/assertion), so on-screen resolution of the real
titles ("GMT time query", "Public repository audit") is confirmed only against the parsed index in
tests, not in the live menu. Best-effort against an undocumented cache: may need maintenance if Claude
Desktop changes its format.

**Recommended next step.** Owner enables *Settings → Session titles → "Use Claude Desktop session
titles"* and confirms the radar shows the Claude Code UI names for sessions that lacked a transcript
title, with no regression when the toggle is off.

---

## 2026-07-06 — Session Radar refinements: active-title timing, duration format, menu width

**Task.** Three manual-testing issues on the enhanced Desktop-title Session Radar: (1) active
sessions show the project-folder fallback while Claude works and only pick up the real title after
completion; (2) the elapsed-time format is confusing; (3) the menu is too narrow for real titles.
Scope guardrails: no privacy-scope change, no new Desktop fields (whitelist only), Desktop title
source stays opt-in, minimal changes.

**Issue 1 — investigation (root cause), no behavior change.** Cross-referenced live heartbeat
sessions against the Desktop index and transcripts (whitelisted fields only), then ran the **real**
`CompositeTitleResolver` against live data with the Desktop setting forced on:
- The Claude **Desktop index writes `cliSessionId` + `title` while a session is still active** — an
  actively-working session (last heartbeat 1 s old) resolved a Desktop title in real time; several
  other still-active sessions resolved `desk=YES, transcript=nil, composite=YES`.
- The **transcript** path (the default, setting-off source) has **no** title while active — Claude
  Code writes the `ai-title`/`custom-title` record late (often only near/after completion), so those
  same active sessions had zero title records on disk. This is the reported "fallback until done."
- The resolver/cache/provider pipeline is **correct**: `DesktopTitleResolver` rebuilds its cached map
  whenever the index file signature (paths+mtimes+sizes) changes; the provider re-resolves titles for
  every session every ~2 s tick and re-emits the radar list on **any** `ClaudeSession` change (title
  included, not just state); the model republishes and the `@Observable` UI re-renders. So when the
  Desktop title exists it is displayed within one ~2 s tick — verified end-to-end.
- **Conclusion:** titles *are* available while active via the opt-in Desktop source, and VibeMenu
  already picks them up promptly; the transcript-only default legitimately has nothing to show until
  Claude writes it. No title is faked and the project-folder fallback is kept while active. No code
  change was warranted for the pipeline; added two regression tests pinning the "title appears while
  active → reflected on the next lookup" cache-invalidation guarantee (new-file and in-place-update
  cases).

**Issue 2 — duration format.** Semantic unchanged (elapsed since VibeMenu first observed the session
— `startedAt`; the safest existing meaning, documented). Reformatted `ClaudeSession.shortDuration` to
two significant units: `7s` / `25s`; `1m 5s` / `12m 44s` (zero seconds dropped → `5m`); `1h 5m` /
`2h` (zero minutes dropped). Hours is the top unit (>24h reads e.g. `25h 3m`); dropped the old
single-unit `4m`/`1h`/`2d` collapsing.

**Issue 3 — menu width.** `MenuContentView` frame `300 → 380`; gave the title `Text` `.layoutPriority(1)`
so it claims the row's free width and only tail-truncates when genuinely too long. Row height, keep-awake
controls, and thermal row unchanged. (Title already used single-line tail truncation.)

**Changed files.**
- `Sources/VibeMenuCore/ClaudeSession.swift` — new `shortDuration` two-unit format + doc.
- `Sources/VibeMenuApp/VibeMenuApp.swift` — menu width 300→380; title `.layoutPriority(1)`.
- `Tests/VibeMenuCoreTests/ClaudeSessionTests.swift` — updated duration/elapsed-label tests to the
  new format with the task's examples.
- `Tests/VibeMenuCoreTests/ClaudeDesktopTitleTests.swift` — two new cache-invalidation tests
  (`picksUpTitleWhenIndexFileAppearsMidSession`, `picksUpTitleWhenAddedToExistingFile`).

**Commands / validation (real output).**
- `swift build` → `Build complete! (1.22s)`.
- `scripts/test.sh` → `Test run with 240 tests in 35 suites passed after 0.228 seconds`.
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug
  -derivedDataPath ./.derivedData build` → `** BUILD SUCCEEDED **`.

**Verified vs. not verified.** Verified: the live resolver returns a Desktop title for a currently
*active* session (out-of-tree probe against live data, presence-only, no title strings printed); the
new formatting and cache-invalidation logic via unit tests; all three build/test gates. **Not verified
at runtime:** the live popover was not launched (owner's real VibeMenu runs; a second instance would
duplicate the menu-bar item), so on-screen 380 px width and the ticking label were not eyeballed.

**Privacy impact.** None. No new fields read (same five-field Desktop whitelist), Desktop source stays
opt-in/off-by-default, no logging of titles, no network, no writes to Claude files. The live
investigation read only whitelisted Desktop fields and title-record *markers* (not prompt/response
content).

## 2026-07-06 — Session Radar row: timer never clipped

**Task.** Manual testing showed a long session title pushing/clipping the elapsed timer (first row's
timer barely visible) even after the menu was widened to 380 px. Fix the row layout so the elapsed
time is always fully visible; no new features / no title-resolver / privacy / keep-awake changes.

**Root cause.** In `SessionRow` the title `Text(row.name)` carried `.layoutPriority(1)`, higher than
the elapsed-time `Text` (default priority 0). In an `HStack` constrained to a fixed width, SwiftUI
satisfies the higher-priority child's ideal size first, so a long title claimed the row's width and
the lower-priority timer was compressed/clipped instead of the title truncating.

**Fix (smallest change, `Sources/VibeMenuApp/VibeMenuApp.swift`).**
- Timer is now rigid: `.fixedSize()` (never compressed/truncated) inside a reserved, right-aligned
  trailing area `.frame(minWidth: 44, alignment: .trailing)` — always fully visible.
- Title dropped `.layoutPriority(1)` + trailing `Spacer` for `.frame(maxWidth: .infinity,
  alignment: .leading)`: it takes the flexible middle and tail-truncates instead of growing into the
  timer.
- State label gained `.frame(minWidth: 58, alignment: .leading)` (kept `.fixedSize()`) so rows
  roughly align without a hard width that would clip the rare "Permission" label.
- `MenuContentView` width 380 → 420 for a little more title room; still popover-compact.
Row height unchanged; single-line; no wrapping.

**Changed files.**
- `Sources/VibeMenuApp/VibeMenuApp.swift` — `SessionRow` HStack layout + `MenuContentView` width.

**Commands / validation (real output).**
- `swift build` → `Build complete! (0.93s)`.
- `scripts/test.sh` → `Test run with 240 tests in 35 suites passed after 0.221 seconds`.
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug
  -derivedDataPath ./.derivedData build` → `** BUILD SUCCEEDED **`.

**Tests.** No new tests: the change is pure SwiftUI frame/priority wiring with no testable pure
formatter/layout helper (elapsed formatting via `shortDuration` is unchanged and already covered).

**Verified vs. not verified.** Verified: all three build/test gates. **Not verified at runtime:** the
live popover was not launched (owner's real VibeMenu runs; a second instance would duplicate the
menu-bar item), so the on-screen 420 px width and non-clipped timer were not eyeballed this session.

**Privacy impact.** None. Layout-only change; no new fields read, no logging, no network, no writes.

---

## Expandable "more recent sessions" control in Session Radar

**What & why.** The Session Radar overflow line ("+N more recent session(s)") was informational
only. Made it an expandable/collapsible control so the hidden overflow sessions can be revealed
in-place, without turning the popover into a history dashboard.

**Core change (`Sources/VibeMenuCore/ClaudeSession.swift`).**
- Added `SessionRadar.maxOverflowRows = 10` (cap on revealed hidden rows).
- `SessionRadar.Presentation` gained two fields (init defaults keep it source-compatible):
  `overflowRows: [RadarRow]` (the elided-but-eligible sessions, same layout, capped at 10) and
  `olderHiddenCount: Int` (remainder past the cap).
- `present()` now also computes overflow = eligible sessions not in the primary `visible` set, in
  the same attention-first order, disambiguated independently. `rows`/`hiddenCount` are unchanged
  (all pre-existing tests pass untouched), so collapsed behaviour is byte-identical.

**View change (`Sources/VibeMenuApp/VibeMenuApp.swift`).**
- `SessionRadarView` gained `@State private var showOverflowSessions = false` (per-popover, defaults
  collapsed).
- The overflow footer is now a `.plain` `Button`: collapsed shows
  "+N more recent session(s) ▸" (`chevron.right`); expanded flips to "Recent sessions ▾"
  (`chevron.down`) and renders `radar.overflowRows` using the same `SessionRow` (drag + right-click
  hide intact), then "+N older sessions hidden" when `olderHiddenCount > 0`.
- `.animation(.snappy, value: showOverflowSessions)` on the VStack.

**Changed files.**
- `Sources/VibeMenuCore/ClaudeSession.swift` — overflow fields + `present()` computation.
- `Sources/VibeMenuApp/VibeMenuApp.swift` — expandable control + local state.
- `Tests/VibeMenuCoreTests/ClaudeSessionTests.swift` — 6 new overflow tests.

**Commands / validation (real output).**
- `swift build` → `Build complete! (1.20s)`.
- `scripts/test.sh` → `Test run with 246 tests in 35 suites passed after 0.230 seconds` (6 new).
- `xcodebuild … -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build` →
  `** BUILD SUCCEEDED **`.

**Tests added.** primary capped at 5 with overflow disjoint/complete; overflow capped at 10 with
older-remainder; overflow excludes unknown/expired-done/expired-stale/home-ghost; overflow includes
fresh done beyond the done cap; no-overflow-when-nothing-hidden; cap constant == 10.

**Verified vs. not verified.** Verified: all three build/test gates. **Not verified at runtime:** the
live popover was not launched, so the expand/collapse animation and chevron glyphs were not eyeballed
this session.

**Scope guardrails honoured.** No new data source, no title-resolver change, no state-derivation
change, no privacy/network change, no keep-awake change, no notifications. Not committed.

## 2026-07-06 — Session Radar fixes: finished ≠ "Waiting", timer only while live, separator alignment

Manual testing of Session Radar found three bugs; fixed all three (docs/decisions/0015).

**Root causes.**
- *Separator misalignment (Issue 1):* the state word had `.frame(minWidth: 58, alignment: .leading)`,
  so a short word (e.g. "Done") left-aligned in the wide frame and the following `Text("·")` floated
  ~14pt off the word but only 8pt off the title — asymmetric whitespace, so the dot looked mis-placed.
- *Confusing timer (Issue 2):* the row rendered `elapsedLabel` **unconditionally**, so a finished
  `.done` row kept a running clock. Semantics: elapsed = *now − first-observed* (`startedAt`);
  `.done` therefore showed session age since first sight, not "working time" and not age-since-done.
- *Over-broad "Waiting" (Issue 3):* `ClaudeSessionState.derive` mapped `Stop`/`Notification`/
  `SessionStart` → `.waitingForInput` ("Waiting"), sorted **above** working. Every session finishes a
  turn and waits, so these low-value rows piled up and pushed actively-working sessions out.

**Approval detection: not available.** The hook records only the event *name*, never the
`Notification` `notification_type` (`permission_prompt`); ADR 0011 already noted that subtype fires
unreliably and the Allow/Deny hook is unverified here. So no verified approval signal exists — we do
**not** fabricate one.

**Change (`Sources/VibeMenuCore/ClaudeSession.swift`).**
- Removed `ClaudeSessionState.waitingForInput`; folded its meaning into `.done`. `derive` rule 5
  (`Stop`/`Notification`/`SessionStart`, live process) and rule 2 (no-process fresh grace) now return
  `.done`. `SessionEnd`/working/quiet/stale/unknown unchanged.
- `permissionRequested` relabelled "Permission" → **"Needs approval"**; still sorted first, styled for
  attention, and **never produced** (reserved placeholder — approval detection is a future opt-in hook
  change). New sort order: needs-approval → working → quietWorking → done → stale → unknown.
- Added pure `showsElapsedTimer` (true for working/quiet/approval; false for done/stale/unknown).
- Home-folder noise: an untitled finished `$HOME` session is now `.done` → hidden (the "kirill" ghost
  pile-up fix); titled/real-project/working home-dir sessions still always show.

**Change (`Sources/VibeMenuApp/VibeMenuApp.swift`).**
- `SessionRow`: grouped the coloured dot + state word + "·" into one fixed-width leading column
  (`.fixedSize()` + `minWidth: 104`), so the separator hugs the word and titles align; the long "Needs
  approval" label grows instead of clipping. Row height unchanged. The elapsed timer now renders only
  when `session.state.showsElapsedTimer` (no timer on `.done`).

**Changed files.**
- `Sources/VibeMenuCore/ClaudeSession.swift` — remove `waitingForInput`; `.done` reclassification;
  `showsElapsedTimer`; "Needs approval" label; sort order; home-folder + derive docs.
- `Sources/VibeMenuApp/VibeMenuApp.swift` — grouped status column (Issue 1) + state-gated timer (Issue 2).
- `Tests/VibeMenuCoreTests/ClaudeSessionTests.swift` — updated derive/store/present/home-folder tests to
  `.done`; added 6 tests (approval>working>done sort, Needs-approval/Done labels, `showsElapsedTimer`,
  `derive` never yields an attention state, Stop/SessionEnd→done, finished rows don't push out active).
- `Tests/VibeMenuCoreTests/ClaudeActivityTests.swift`, `DismissedSessionsTests.swift` — `.waitingForInput`
  → `.done` in fixtures.
- `docs/ARCHITECTURE.md` — removed the stale `waitingForInput` state from the current session-radar
  summary so the architecture doc matches the code.
- `docs/decisions/0015-radar-state-and-timer.md` — new ADR.

**Commands / validation (real output).**
- `swift build` → `Build complete! (1.88s)`.
- `scripts/test.sh` → `Test run with 252 tests in 35 suites passed after 0.283 seconds` (was 246; +6).
- `xcodebuild … -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build` →
  `** BUILD SUCCEEDED **`.

**Verified vs. not verified.** Verified: all three build/test gates; pure state/label/sort/timer logic
by unit test. **Not verified at runtime:** the live popover was not launched, so the separator
alignment and the timer-hidden-on-Done row were not eyeballed on screen this session (pure layout +
the gated `Text`, but SwiftUI spacing is a manual smoke-test step).

**Scope guardrails honoured.** No approval detection faked, no notifications, no terminal jump, no notch,
no multi-agent, no Accessibility/AppleScript/UI-scraping, no network, no title-resolver change, no
privacy-scope change, no hook-script/schema change. Keep-awake untouched (display-only enum; the
`sessionsKeepAwakeIntent == automationIntent` equivalence test still passes). Not committed.

---

## 2026-07-06 — Session Radar: narrower menu (420→380), title truncation before timer

**Change.** The prior pass fixed row alignment but left the popover at 420px, which read as bulky.
Reduced the menu frame to **380px** (`MenuContentView` `.frame(width:)`). The `SessionRow` layout was
already correct for truncation — flexible `maxWidth: .infinity` tail-truncated title, rigid
`.fixedSize()` timer with a reserved `minWidth: 44` trailing area — so no structural change was needed;
the title simply gets ~190pt before ellipsizing and the timer stays fully visible. State column
(`minWidth: 104`, `.fixedSize()`) and row height unchanged.

**Files.**
- `Sources/VibeMenuApp/VibeMenuApp.swift` — menu frame width 420 → 380 (+ comment).

**Commands / validation (real output).**
- `swift build` → `Build complete! (1.30s)`.
- `scripts/test.sh` → `Test run with 252 tests in 35 suites passed after 0.250 seconds`.
- `xcodebuild … -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build` →
  `** BUILD SUCCEEDED **`.

**Verified vs. not verified.** Verified: all three build/test gates. **Not verified at runtime:** the
live popover was not launched, so the 380px width and title-truncation-before-timer were not eyeballed
on screen (pure layout constant; SwiftUI spacing is a manual smoke-test step).

**Scope guardrails honoured.** No new features, no title-resolver/privacy/state-classification/keep-awake
change, no notifications/terminal-jump/notch/multi-agent. Done rows remain timerless; Waiting/Done
classification unchanged; prior alignment fix kept. Not committed.

---

## 2026-07-06 — Session Radar: fixed-column row layout + narrower menu (380→270)

**Task/session:** Layout/presentation fix for `SessionRow`. No logic changes.

**Root cause.** Two separate defects made the row read as unstable:
- *Separator drift.* The status column grouped `[dot + word + "·"]` in one `.fixedSize()` box inside
  `.frame(minWidth: 104, alignment: .leading)`. Because the whole group was fixed-size and left-aligned,
  the "·" hugged the *end of the word*; "Working"/"Quiet"/"Done" differ in length, so the separator
  landed at a different x on every row. `minWidth` only reserved the column's left edge, not the "·".
- *Title expands into timer space.* The timer was rendered inside `if session.state.showsElapsedTimer`.
  On timerless rows (`.done`/`.stale`) the name's `maxWidth: .infinity` claimed the freed trailing
  width, so its right edge (and truncation point) moved between rows.

**Change (`Sources/VibeMenuApp/VibeMenuApp.swift`, `SessionRow`).**
- Split the status column into a **fixed-width box** (`statusColumnWidth = 76`) holding just the dot +
  word (word `lineLimit(1)`/tail-truncates inside), with the "·" as a **separate element after it** — so
  the separator sits at a constant x regardless of state word length.
- Made the trailing timer a **always-present fixed-width column** (`timerColumnWidth = 48`): shows the
  elapsed label when `showsElapsedTimer`, else an empty string, but always holds the column open so the
  flexible name ends at the same x on every row and never expands into the timer space.
- Title stays in the flexible middle (`maxWidth: .infinity`, single-line, tail truncation) — unchanged
  behaviour, now correctly bounded on both sides.
- Outer `HStack` spacing 8 → 6 to keep the narrower row tight.
- Menu frame width **380 → 270** (~29% smaller) in `MenuContentView`.
- No changes to state classification, `showsElapsedTimer`, labels, sort, dismiss, or the drag gesture.

**Final row layout (left→right):** fixed status box (dot + word, 76pt) · separator "·" · flexible
tail-truncated name · fixed timer column (48pt, empty when no timer). Single line, row height unchanged.

**Commands / validation (real output).**
- `swift build` → `Build complete! (1.21s)`.
- `scripts/test.sh` → `Test run with 252 tests in 35 suites passed after 0.261 seconds`.
- `xcodebuild … -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build` →
  `** BUILD SUCCEEDED **`.

**Verified vs. not verified.** Verified: all three build/test gates; layout is a pure SwiftUI frame
change with no logic touched (the 252 core tests are unaffected and still pass). **Not verified at
runtime:** the live popover was not launched, so the fixed-column alignment, the 270px width, and the
timerless-`Done` row were not eyeballed on screen — SwiftUI spacing remains a manual smoke-test step.

**Scope guardrails honoured.** Presentation-only: no state/label/sort/timer-eligibility change, no
title-resolver/privacy/keep-awake/hook change, no notifications/terminal-jump/notch/multi-agent, no new
dependencies. Done rows remain timerless. Not committed. No build artifacts / `.derivedData` staged.

## 2026-07-06 — Session Radar: widen menu to 320, tighten separator

**What & why.** 270px read too narrow and the "·" separator sat too far from the status labels.
Presentation-only tweak in `SessionRow` / `MenuContentView` (`Sources/VibeMenuApp/VibeMenuApp.swift`):

- Menu frame width **270 → 320** in `MenuContentView`.
- Status column width **76 → 64** (`SessionRow.statusColumnWidth`): the fixed box is tighter, so the
  "·" (a separate element anchored to the box's trailing edge) sits nearer the label while its x stays
  constant across rows. Single-word states still read; longer labels ("Needs approval") tail-truncate
  as before. Timer column unchanged (48pt, reserved, empty on `.done`).

No change to state classification, `showsElapsedTimer`, labels, sort, dismiss/drag, title resolver,
privacy, or keep-awake.

**Commands / validation (real output).**
- `swift build` → `Build complete! (1.02s)`.
- `scripts/test.sh` → `Test run with 252 tests in 35 suites passed after 0.226 seconds`.
- `xcodebuild … -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build` →
  `** BUILD SUCCEEDED **`.

**Verified vs. not verified.** Verified: all three build/test gates. **Not verified at runtime:** the
live popover was not launched, so the 320px width, separator proximity, and "Working" fitting in the
64pt box were not eyeballed on screen — SwiftUI spacing remains a manual smoke-test step.

**Scope guardrails honoured.** Presentation-only frame/width change. Not committed.

## 2026-07-06 — Session Radar: two-line row redesign

**What & why.** Redesigned `SessionRow` from one line to **two lines** to match a supplied visual
reference. Presentation-only change in `Sources/VibeMenuApp/VibeMenuApp.swift`; no core logic touched.

New row structure (left → right): a state-coloured status **dot** in the gutter, a flexible **content
column**, then a fixed **timer column** on the far right. Inside the content column:
- **Top line:** the state word (`Working` / `Quiet` / `Done` / `Needs approval`), semibold when the
  session `needsAttention`.
- **Bottom line:** an agent **pill** (`Text(session.agent)` — always "Claude" in v0.2) in a subtle
  translucent `Capsule` (`Color.primary.opacity(0.08)`), immediately followed by the session name
  (`row.name`), single-line and tail-truncated (`maxWidth: .infinity`) so it ellipsizes before the
  trailing edge.

Timer lives in the **outer HStack trailing column** (`timerColumnWidth = 48`, always reserved) so it
stays pinned far right on the top line and the name can never expand into it; `.done` rows still show
an empty string (no running clock), but the column stays open so rows align. Removed the now-unused
`statusColumnWidth` constant and the old "·" separator. Dot nudged (`.padding(.top, 4)`) to centre on
the status line; outer `HStack(alignment: .top)`. Menu width kept at **320**.

Preserved: state/label/sort/`showsElapsedTimer` mapping, timer semantics (active shows elapsed, `.done`
none), title lookup (`row.name`), dismiss (drag + right-click "Hide"), overflow/visibility, thermal row,
sleep-prevention toggle.

**Commands / validation (real output).**
- `swift build` → `Build complete! (1.12s)`.
- `scripts/test.sh` → `Test run with 252 tests in 35 suites passed after 0.242 seconds`.
- `xcodebuild … -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build` →
  `** BUILD SUCCEEDED **`.

**Verified vs. not verified.** Verified: all three build/test gates; the 252 core tests are untouched
by a pure SwiftUI layout change and still pass. **Not verified at runtime:** the live popover was not
launched, so the two-line spacing, the dot's `.padding(.top, 4)` vertical alignment on the status line,
the pill styling, and the timer sitting on the top line were not eyeballed on screen — SwiftUI spacing
remains a manual smoke-test step.

**Scope guardrails honoured.** Presentation-only: no state/label/sort/timer-eligibility change, no
title-resolver/privacy/keep-awake/hook change, no notifications/terminal-jump/notch/multi-agent, no new
dependencies. Done rows remain timerless. Not committed. No build artifacts / `.derivedData` staged.

## 2026-07-06 — Session Radar: agent pill on the status line, primary cap 5→4

**What & why.** Two small requested tweaks on top of the two-line row: (1) move the agent **pill**
from the bottom line up beside the state word, so `state + agent` group on one glanceable line and the
session name owns the second line alone; (2) drop the primary visible cap from **5 → 4**, so a 5th
eligible session is the first to spill into the expandable "more recent sessions" control.

Row structure now (left → right): state-coloured **dot** (gutter, `.padding(.top, 4)` to centre on the
top line) → **content column** → fixed **timer column** (`timerColumnWidth = 48`, always reserved). Inside
the content column:
- **Top line:** state word (`Working` / `Quiet` / `Done` / `Needs approval`, semibold when
  `needsAttention`) + the agent **pill** (`Text(session.agent)`, always "Claude" in v0.2) in the subtle
  translucent `Capsule` (`Color.primary.opacity(0.08)`), wrapped in an `HStack(spacing: 6)` with a
  trailing `Spacer(minLength: 0)` and `.frame(maxWidth: .infinity, alignment: .leading)`.
- **Bottom line:** the session **name** (`row.name`) on its own, single-line, `.truncationMode(.tail)`,
  greedy (`maxWidth: .infinity`) so it ellipsizes before the trailing edge and aligns under the state
  word (content-column leading edge), not under the dot.

The timer stays pinned to the reserved trailing column on the top line; `.done` rows still show an empty
string (no running clock) while the column stays open so rows align. Menu width kept at **320**.

**Files changed.**
- `Sources/VibeMenuCore/ClaudeSession.swift` — `SessionRadar.maxVisibleRows` `5 → 4` (+ doc note).
- `Sources/VibeMenuApp/VibeMenuApp.swift` — moved the pill into the top line of `SessionRow`; updated the
  `SessionRow` / menu-width / "cap N rows" doc comments.
- `Tests/VibeMenuCoreTests/ClaudeSessionTests.swift` — `constantsMatchTheSpec` now expects `maxVisibleRows
  == 4`; renamed `capsAtFiveRows → capsAtFourRows` (rows 4 / hidden 4); updated `overflowRevealsHiddenBelowPrimary`
  (4/4/4), `overflowRowsCappedAtTenWithOlderRemainder` (4 primary, hidden 13, older 3),
  `overflowExcludesIneligibleSessions` (4 primary, overflow `["w4","w5"]`); **added** `fifthEligibleSessionGoesToOverflow`.
- `docs/DEVELOPMENT_LOG.md` — this entry.

Preserved: state/label/sort/`showsElapsedTimer` mapping, timer semantics, title lookup (`row.name`),
dismiss (drag + right-click "Hide"), overflow cap (`maxOverflowRows = 10`) and every visibility filter
(unknown hidden, expired done/stale hidden, home-folder ghosts hidden, dismissed hidden), thermal row,
sleep-prevention toggle.

**Commands / validation (real output).**
- `swift build` → `Build complete! (1.41s)`.
- `scripts/test.sh` → `Test run with 253 tests in 35 suites passed after 0.306 seconds` (252 + the new
  overflow test).
- `xcodebuild … -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build` →
  `** BUILD SUCCEEDED **`.

**Verified vs. not verified.** Verified: all three build/test gates. **Not verified at runtime:** the live
popover was not launched, so the pill sitting inline with the state word, the second-line name alignment
under the status text, and tail truncation were not eyeballed on screen — SwiftUI spacing remains a manual
smoke-test step.

**Scope guardrails honoured.** Presentation + one constant: no title-resolver/privacy/keep-awake/hook
change, no notifications/terminal-jump/notch/multi-agent, no new dependencies. Done rows remain timerless.
Not committed. No build artifacts / `.derivedData` staged.

## 2026-07-06 — Session Radar: show up to 4 idle sessions; separator above Thermal pressure

Manual testing after 0015 surfaced two layout issues. Both fixed; row visual design untouched.

**Issue 1 — only ~2 sessions showed in the main list (root cause: presentation logic, not SwiftUI).**
`SessionRadar.maxVisibleRows` was already `4` at runtime and `present` returns up to 4 primary rows, and
the `.window` popover has no height clip — so none of those were the cause. The real cause: 0015 folded
"finished / idle / waiting for the next prompt" into `.done`, making `.done` the *normal* resting state.
But `present` applied a **done sub-cap `maxDoneRows = 2`** *before* the 4-row cap, so a list of 3–4 idle
(now `.done`) sessions was trimmed to 2 primary rows and the rest pushed into the overflow control — exactly
the reported "only 2 visible." Fix: tie `maxDoneRows` to `maxVisibleRows` so done may fill the whole visible
list (up to 4). Actives still sort ahead of done, so no working row is ever hidden by a finished one (that
guarantee is the sort order + `maxVisibleRows`, never the done sub-cap).

**Issue 2 — Thermal pressure needed a separator above it (SwiftUI layout + one pure decision).**
Added `MenuVisibility.isClaudeThermalDividerVisible` (`isClaudeRowVisible && isThermalRowVisible`) and a
plain `Divider()` gated on it, placed between the Session Radar list and the Thermal pressure row — the same
divider style already used above Sleep prevention. Shown only when both rows are visible, so hiding either
never leaves a stray separator; the no-sessions fallback Claude line still gets a sensible divider below it.

**Files changed.**
- `Sources/VibeMenuCore/ClaudeSession.swift` — `SessionRadar.maxDoneRows` `2 → maxVisibleRows` (+ rationale).
- `Sources/VibeMenuCore/MenuVisibility.swift` — added pure `isClaudeThermalDividerVisible`.
- `Sources/VibeMenuApp/VibeMenuApp.swift` — `Divider()` between the Claude row and Thermal row gated on the
  new decision; refreshed the stale "≤2 done" doc comment in `SessionRadarView`.
- `Tests/VibeMenuCoreTests/ClaudeSessionTests.swift` — `constantsMatchTheSpec` now expects `maxDoneRows == 4`
  (== `maxVisibleRows`); replaced `capsDoneToTwo` with `doneFillsPrimaryUpToVisibleCap` (4 done → 4 rows, 0
  hidden) + added `doneBeyondVisibleCapOverflows` (6 done → 4/2); updated `overflowIncludesDoneBeyondThe…`
  (renamed …VisibleCap; 6 done → 4 primary / 2 overflow).
- `Tests/VibeMenuCoreTests/MenuVisibilityTests.swift` — added a suite for `isClaudeThermalDividerVisible` and
  extended the determinism sweep.
- `docs/decisions/0015-radar-state-and-timer.md` — point 3 follow-up note: the `maxDoneRows = 2` sub-cap was
  wrong once `.done` became the normal idle state; now tied to `maxVisibleRows`.
- `docs/DEVELOPMENT_LOG.md` — this entry.

Preserved: state classification / labels / sort / `showsElapsedTimer`, title resolver, dismiss, privacy,
keep-awake, thermal reading, overflow cap (`maxOverflowRows = 10`) and every visibility filter. Row visual
design unchanged.

**Commands / validation (real output).**
- `swift build` → `Build complete! (1.26s)`.
- `scripts/test.sh` → `Test run with 258 tests in 36 suites passed after 0.220 seconds`.
- `xcodebuild … -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build` →
  `** BUILD SUCCEEDED **`.

**Verified vs. not verified.** Verified: all three build/test gates, and the changed/added radar +
visibility tests pass individually. **Not verified at runtime:** the live popover was not launched, so the
new Thermal separator and the 4-visible-rows behaviour were not eyeballed on screen — SwiftUI spacing/divider
placement remains a manual smoke-test step.

**Scope guardrails honoured.** Presentation logic + one constant + one pure visibility decision + a SwiftUI
divider: no state-classification / title-resolver / privacy / keep-awake / hook change, no
notifications/terminal-jump/notch/multi-agent, no new dependencies, no row redesign. Not committed. No build
artifacts / `.derivedData` staged.

---

## 2026-07-09 — Claude usage limits (opt-in, experimental, CLI-native statusLine capture)

**Feature.** New opt-in **Claude Limits** menu section showing the user's **real** 5-hour + weekly Claude
usage (used-percentage + reset), matching the usage-bars design. See
[`docs/decisions/0016-claude-usage-limits.md`](decisions/0016-claude-usage-limits.md).

**Research (two multi-agent passes; metadata/field-names only, no private values read).** Mapped every
source: token estimation (forbidden), network OAuth/cookie API (forbidden), the Claude **Desktop** HTTP
cache (real data but zstd-compressed → would need a **vendored zstd dep**; Apple `Compression` can't
decode zstd and macOS 26 ships no system `libzstd`; also Desktop-only, LRU-evictable, cross-app-private),
and — chosen — **Claude Code's statusLine `rate_limits` stdin** (`five_hour`/`seven_day` →
`used_percentage` + `resets_at`; the real server value, delivered locally, zero network). Verified the
schema in the local `claude` v2.1.202 binary. Because a better CLI-native source exists, the Desktop-cache
path (and the zstd dependency) was **not** taken.

**Implementation (pure core + thin adapters, mirroring the ADR 0008 hook pattern).**
- `Sources/VibeMenuCore/ClaudeUsageLimit.swift` — `ClaudeUsageLimit(Kind/Severity)`, `…Snapshot`,
  `…Status`, `…Source`; clamped percent, deterministic reset formatting ("Resets in 2 hr 40 min",
  "Resets Sun 1:00 PM"), fresh/stale/unavailable + "as of Xm ago".
- `ClaudeUsageLimitReader.swift` — whitelist-DTO malformed-safe `parse` + read-only `FileClaudeUsageLimitReader`.
- `ClaudeUsageLimitModel.swift` — coarse ~5 s file-poll provider (self-gated on the default-off pref) + `@Observable` model.
- `StatusLineInstaller.swift` — pure compose/wrap(base64)/uninstall/detect/preview for the one-click install.
- `ClaudeUsageStatusLineShim.swift` — embedded shim source (single source of truth; sync-tested against the Support copy).
- `Support/ClaudeUsage/vibemenu-usage-statusline.sh` (+ `README.md`) — the opt-in statusLine shim (system
  `/usr/bin/python3`, whitelist-only, atomic write, always exits 0, passes through any wrapped status line).
- `MenuVisibility.swift` — extended for the new section's dividers (unchanged when off).
- `VibeMenuApp.swift` — `ClaudeLimitsView`/`UsageLimitRow`/`UsageBar`, the enable toggle + status + one-click
  install (preview-gated, backed-up, reversible) `ClaudeUsageInstallModel`, wiring in `AppDelegate`. The
  install model lives in `VibeMenuApp.swift` (not a new file) because the Xcode `.app` target compiles that
  source explicitly.
- Tests: `ClaudeUsageLimitTests`, `StatusLineInstallerTests`, `ClaudeUsageShimSyncTests`,
  `ClaudeUsageStatusLineScriptTests` (real shim → file → real reader, end-to-end + privacy), and extended
  `MenuVisibilityTests`.

**Posture change (owner-approved).** The one-click install is the first time VibeMenu writes to
`~/.claude/settings.json` — narrowed to be safe: opt-in, preview-gated, timestamped backup, wraps (never
clobbers) an existing status line, only the `statusLine` key, reversible, pure/tested compose logic. Manual
install stays documented. **Second-model review of `StatusLineInstaller` + the install adapter is advised
before public release** (CLAUDE.md).

**Commands / validation (real output).**
- `swift build` → `Build complete!`.
- `scripts/test.sh` → `Test run with 314 tests in 50 suites passed`.
- `xcodebuild … -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build` → `** BUILD SUCCEEDED **`.
- Manual shim smoke test + the subprocess test both confirm: capture writes only the six whitelisted keys
  (no cost/transcript/cwd leakage), the real reader decodes the expected snapshot, window-absent renders
  preserve last-known-good, and `--wrap` passes through.

**Verified vs. not verified.** Verified: all three build/test gates; the shim→file→reader pipeline and its
privacy contract (subprocess test). **Not verified at runtime:** the live popover was not launched (a second
instance would duplicate the owner's menu-bar item), so the bar/divider placement and the install
confirmation dialog remain a manual smoke-test step; and no live Pro/Max statusLine `rate_limits` payload was
observed end-to-end on this machine (the shim was exercised with synthetic payloads matching the verified
binary schema).

**Scope guardrails.** No zstd/other dependency added; no network/cookies/API keys/token extraction/scraping;
Session Radar row design, keep-awake loop, thermal, and heartbeat unchanged. Not committed. No build
artifacts / `.derivedData` staged.

## 2026-07-09 — Claude usage limits: add Claude Desktop cache source (vendored zstd)

Extended the (prior, statusLine-only) Claude Limits feature with a second local source — the **Claude
Desktop** app's own usage cache — since that is the owner's primary want. See the substantially revised
[`docs/decisions/0016-claude-usage-limits.md`](decisions/0016-claude-usage-limits.md).

**Research (dev-time only, on this machine, nothing committed).** Confirmed Claude Desktop caches
`GET …/api/organizations/{org}/usage` in Chromium's Simple Cache
(`~/Library/Application Support/Claude/Cache/Cache_Data/<hash>_0`), body `content-encoding: zstd`.
Confirmed macOS 26.5 has **no** zstd (no `libzstd` dylib, no `COMPRESSION_ZSTD`, no python `zstandard`).
Confirmed the payload is a `limits[]` array (`kind`/`group`/`percent`/`resets_at`/`is_active`) plus a
`spend`/cost block and the org UUID (both deliberately ignored). Learned the cache body is **intermittent**
— a full 200 body, then empty 304 revalidation stubs — which drove the last-known-good design.

**Vendored dependency (ADR decision rule 3).** Added `Sources/CZstd` — the official **decompress-only**
zstd single-file amalgamation `zstddeclib.c` (v1.5.6, commit `794ea1b0…`, generated by zstd's own
`create_single_file_decoder.sh`) + unmodified `zstd.h`/`zstd_errors.h` + module map + `LICENSE`.
**BSD-3-Clause** (zstd is dual BSD/GPLv2; we take BSD). No compressor, no network, no shelling out, no
Homebrew. `Package.swift`: new `CZstd` target; `VibeMenuCore` depends on it. Provenance in
`Sources/CZstd/README.md`.

**New source files.**
- `Zstd.swift` — safe Swift wrapper: streaming decode (stops at frame boundary; ignores Chromium's
  trailing metadata) with an 8 MiB **output cap** (decompression-bomb guard); frame-scan helper.
- `ClaudeDesktopUsageCacheReader.swift` — `ChromiumSimpleCacheEntry` (byte-scan the usage key + parse the
  HTTP `Date`), `ClaudeDesktopUsageParser` (whitelist DTO for both the `limits[]` and top-level-window
  shapes; ignores spend/cost/org-uuid; maps per-model `group` → "Weekly · Opus"), and the throttled,
  read-only directory scanner (small + recently-modified entries first; keeps last-good on empty scans).
- `ClaudeUsageLimitAutoReader.swift` — `CompositeClaudeUsageLimitReader` (Auto/Desktop/ClaudeCode source
  selection) + `ClaudeUsageLimitSnapshotStore` (persists the last good Desktop snapshot — normalised rows
  only, no org UUID/raw payload).

**Changed.**
- `ClaudeUsageLimit.swift` — added `.desktopCache` source + `ClaudeUsageLimitSourceMode`; added per-model
  `group` (+ `displayLabel`/`id`/`sortKey`, `Identifiable`) so weekly per-model rows render and sort
  deterministically. Backward-compatible (new params defaulted); existing tests unchanged.
- `VibeMenuApp.swift` — provider now uses the composite reader; Settings gains a **Source** picker
  (Auto / Claude Desktop / Claude Code) + a live **Detected** line; menu row uses `displayLabel` and a
  stable `ForEach` id; empty-state copy is source-neutral.

**Tests (all synthetic — zstd fixtures generated offline from fake data via Node's built-in zstd; no real
cache payload committed).** New `ZstdTests`, `ClaudeDesktopUsageCacheTests`,
`ClaudeUsageCompositeReaderTests`, and per-model model tests in `ClaudeUsageLimitTests` — decode/trailing/
bomb-cap; both payload shapes; forbidden fields never surface; inactive rows skipped; Chromium entry +
`Date` parse; full compressed-entry decode; empty-304 → nil; throttled scanner + last-good fallback;
source selection; store round-trip. **363 tests, all passing.**

**Commands / validation (real output).**
- `swift build` → `Build complete!`.
- `scripts/test.sh` → `Test run with 363 tests in 59 suites passed`.
- `xcodebuild … -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build` →
  `** BUILD SUCCEEDED **`; verified `CZstd`/`zstddeclib.o` compiled and the vendored decoder (163 `ZSTD_`
  symbols) + `ClaudeDesktopUsageCacheReader` are linked into `VibeMenu.debug.dylib`.

**Verified vs. not verified.** **Verified end-to-end against the real local Desktop cache** at dev time: a
throwaway harness ran the real `ClaudeDesktopUsageCacheReader` over the actual `Cache_Data` directory and
decoded the live 5-hour + weekly rows in ~27 ms across ~1,500 files (the throwaway test was then deleted;
no real data committed). **Not verified at runtime:** the live popover was not launched (a second instance
would duplicate the owner's menu-bar item), so bar/divider placement, the Source picker, and per-model row
rendering remain a manual smoke-test step; per-model weekly rows were exercised with synthetic fixtures
(this account's live payload currently returns only the two all-models rows).

**Scope guardrails.** Vendored zstd is the only dependency (decode-only, BSD-3-Clause); still no network /
cookies / API keys / token extraction / scraping / telemetry / Homebrew / shell-out. Read-only w.r.t.
Claude's data (never writes/deletes the cache). Session Radar row design, keep-awake loop, thermal, and
heartbeat unchanged. **Second-model review of the decoder wrapper, cache parser, and install adapter still
advised before public release** (CLAUDE.md). Not committed. `.derivedData` restored after the Xcode build.

## 2026-07-09 — Claude Limits: fix Desktop normalisation (5-hour + duplicate label) + menu order

**Why.** The live Claude Limits section showed a single mislabelled `Weekly · Weekly` row and no 5-hour
row. Root-cause was in the Desktop normaliser, not SwiftUI: the persisted `desktop-snapshot.json` itself
held one bad `sevenDay`/`group:"Weekly"` row. A diagnostic pass (temporary test, since deleted) that
decoded the real `/usage` body showed its true shape.

**Real payload shape (verified, sanitized in fixtures — no real data committed).** `limits[]` uses
`kind` = `session` (the 5-hour window), `weekly_all` (weekly, all models), `weekly_scoped` (per-model);
the per-model identity is under `scope.model.display_name` ("Fable"); `group` is a generic bucket
("weekly"/"session"); and `is_active` is `true` on only the currently-binding row (the base 5-hour +
weekly-all windows are `false`). Top-level `five_hour`/`seven_day` carry `utilization` + `resets_at`.

**Root causes.**
1. *Missing 5-hour (and weekly-all) row:* the parser skipped every `is_active:false` row — which in the
   real payload is exactly the live base windows — and never mapped `session` → 5-hour.
2. *`Weekly · Weekly`:* the surviving `weekly_scoped` row's generic `group:"weekly"` was prettified to
   "Weekly" and appended to the base "Weekly" label; the actual model name in `scope` was never read.

**Changed (fixes).**
- `ClaudeDesktopUsageCacheReader.swift` — `windowKind` maps `session`→`fiveHour`, `weekly_all`/
  `weekly_scoped`→`sevenDay`; **stopped filtering on `is_active`** (read but not a display filter); read
  `scope.model.display_name` (whitelisted) for the per-model name, falling back to `group`; expanded the
  generic-group sentinels (`weekly`/`session`/`weekly_all`/…) so a bucket name collapses to `nil`.
- `ClaudeUsageLimit.swift` — `sevenDay.label` "Weekly · all models" → **"Weekly"**; `displayLabel` gained
  a defensive `isRedundantWeeklyGroup` guard so a generic group can never render "Weekly · Weekly" (also
  fixes an already-persisted snapshot without re-decoding).
- `MenuVisibility.swift` — rebuilt divider logic for the new order (Limits → Claude → Thermal): a divider
  above each visible section that has one above it (`isDividerAboveClaudeRow`/`isDividerAboveThermalRow`)
  plus `isStatusDividerVisible`; removed the old pairwise `isClaude*/isLimits*DividerVisible`.
- `VibeMenuApp.swift` — moved the **Claude Limits section above** the Session Radar; rewired dividers to
  the new properties; tidied `UsageLimitRow` (label gets layout priority; reset text fills the freed
  middle; percent in a fixed trailing column). Session Radar UI unchanged.

**Tests (all synthetic; zstd fixture regenerated offline via Node's built-in `zstdCompressSync`).**
- `ClaudeDesktopUsageCacheTests` — real-shaped fixture (session/weekly_all/weekly_scoped + `scope.model`
  + secret model ids + spend). New/updated: 5-hour extracted from `session`; weekly-all row; `is_active`
  no longer filters; **no `Weekly · Weekly`**; per-model from `scope.model.display_name`
  (`Weekly · Fable`/`Weekly · Sonnet`); spend/cost **and** model ids never surface; `windowKind`/
  `normalizedGroup` variant coverage; full compressed-entry decode.
- `ClaudeUsageLimitTests` — `sevenDay.label == "Weekly"`; `displayLabel` guard for generic weekly groups;
  updated ordering expectations.
- `MenuVisibilityTests` — rewritten for the new order + dividers (all 8 toggle combinations).
- `ClaudeUsageCompositeReaderTests` — a full multi-row snapshot (5-hour + weekly + per-model) round-trips
  through the last-known-good store without dropping the 5-hour row.

**Commands / validation (real output).**
- `swift build` → `Build complete!`.
- `scripts/test.sh` → `Test run with 376 tests in 60 suites passed`.
- `xcodebuild … -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build` →
  `** BUILD SUCCEEDED **`; `.derivedData` removed afterwards.

**Verified vs. not verified.** **Verified:** the parser fixes against a decode of the **real live cache**
(temporary diagnostic, since deleted) — it now yields a 5-hour row, a plain "Weekly" row, and a
"Weekly · Fable" per-model row; unit tests cover the same on sanitized fixtures. **Not verified at
runtime:** the live popover was not launched (a second instance would duplicate the owner's menu-bar
item), so the on-screen section order, row layout, and divider placement remain a **manual smoke-test**
step. The user's existing `desktop-snapshot.json` will be overwritten with the corrected shape on the
next live Desktop scan; the `displayLabel` guard renders it correctly meanwhile.

**Scope guardrails.** No new dependency, no network/cookies/API-keys/telemetry, read-only w.r.t. Claude's
cache, privacy model unchanged (whitelist now includes only `scope.model.display_name`; the model `id` is
ignored). Session Radar design untouched. **Not committed / not pushed.**

---

## 2026-07-09 — Claude usage limits: settings UX cleanup + per-limit visibility (ADR 0016)

**Goal (this task).** Fix the messy Claude-usage-limits Settings section and add per-row show/hide.
The menu rendering and parsing were already good; only the settings UX and a new visibility filter
changed. No parsing change beyond exposing a stable id; no network; no new dependency.

**Core (pure, unit-tested).**
- `ClaudeUsageLimit.swift` — added `visibilityID`: a **stable, normalized** id used to persist per-row
  visibility (`fiveHour` / `sevenDay` / `sevenDay#<normalized model>`). Collapses case+whitespace and
  treats a generic weekly bucket as all-models, so a hide/show choice stays pinned to the row across
  relaunch and across a source re-emitting the model name with different casing. Added
  `ClaudeUsageLimitsSummary.collapsedHeader(...)` — the deterministic `On · … · …` / `Off` text for the
  collapsed settings header.
- `ClaudeUsageLimitVisibility.swift` (new) — pure value type storing the **hidden** set (absent ⇒ shown,
  so new rows show by default). Newline-joined `persisted` encoding for `@AppStorage`; `visibleLimits(in:)`
  filters a snapshot. Deliberately **not** pruned when a row disappears, so a hidden row that returns
  stays hidden. Mirrors `DismissedSessionRegistry` for the radar.

**App / UI (`VibeMenuApp.swift`).**
- Settings "Claude usage limits" is now a **collapsible** `DisclosureGroup`: collapsed shows only the
  title + a one-line status summary; expanded shows enable toggle, source picker, "Detected" status,
  **one show/hide toggle per detected row**, a short `Local only · no network · experimental` note, and
  two folded sub-areas — "Claude Code capture" (advanced install/remove + compact status) and
  "Privacy details" (the full explanation that used to sit inline). Section-expanded state persisted;
  the sub-areas default folded.
- Menu: `ClaudeLimitsView` filters hidden rows via the visibility registry; `MenuContentView` computes
  an effective `claudeLimitsHasContent` so the whole section (and its divider) disappears when every
  detected row is hidden, and still shows the setup hint when there is simply no data yet.
- New `PreferenceKey`s: `claudeLimitsHiddenIDs` (shared by menu + settings, so a toggle updates the
  popover live) and `claudeLimitsSectionExpanded`.

**Tests.** `ClaudeUsageLimitVisibilityTests.swift` (new): stable-id normalization; show-by-default;
menu filtering; hide `Weekly · Fable` while `5-hour limit`+`Weekly` stay visible; persistence round-trip;
disappearing/reappearing row keeps the preference (no crash); all-hidden ⇒ empty visible list; the
collapsed-header summary text. Existing parser/visibility suites unchanged.

**Commands / validation (real output).**
- `swift build` → `Build complete!`.
- `scripts/test.sh` → `Test run with 391 tests in 63 suites passed`.
- `xcodebuild … -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build` →
  `** BUILD SUCCEEDED **`; `.derivedData` restored afterwards.

**Verified vs. not verified.** **Verified:** all pure logic (ids, filtering, persistence, summary) by
unit tests; all three builds. **Not verified at runtime:** the live popover / Settings window were not
launched (a second instance would duplicate the menu-bar item), so the on-screen collapse behavior,
the per-row toggle layout, and live menu updates on toggle remain a **manual smoke-test** step.

**Scope guardrails.** No parsing change (only exposed a stable id), no network/cookies/API-keys/telemetry,
no new dependency, Session Radar untouched. Hidden rows are still parsed/stored — only the menu display
is filtered. **Not committed / not pushed.**

## 2026-07-10 — Codex Desktop session detection + unified "AI Agent" status (ADR 0017); no Codex usage limits

Fresh redo from the stable v0.2 tag (`24ae132`) on branch `claude-codex-redo`. The prior Codex attempt
(unreliable usage numbers, untrustworthy session detection) was **not** reused. Two outcomes: (1) Codex
**usage limits** are **not** shipped — investigation found no reliable, privacy-safe local source; (2)
Codex **session detection** is shipped, opt-in and display-only, and the Claude-only status row is now a
unified **AI Agent** row.

**Investigation (redacted diagnostics only; nothing real retained).** Inspected
`~/.codex/sessions/**/rollout-*.jsonl`, `.codex-global-state.json`, `session_index.jsonl`, `config.toml`,
`state_5.sqlite`, `logs_2.sqlite` (schema), the Chromium profile under
`~/Library/Application Support/Codex/` (Local State, Local Storage/IndexedDB), the HTTP caches under
`~/Library/Caches/com.openai.codex/`, and `com.openai.codex.plist`. Findings: rollout `token_count`
carries only token counts (**no `rate_limits`**; structured key count across all rollouts = 0); the only
place real `rate_limits`/`used_percent` appear on disk is `logs_2.sqlite`'s free-text debug/HTTP log
(prompts/responses/auth intermixed — unsafe + ephemeral). → **no Codex Limits.** Sessions: rollout
`session_meta` gives safe metadata (`session_id`, `originator == "Codex Desktop"`, `cwd`→basename,
timestamps) + a `task_complete` done marker → reliable, safe **session detection.**

**Core (new, pure/tested).**
- `CodexSession.swift` — `CodexSessionState` (active/idle/done/stale/unknown; label/displayStyle/sort/
  timer), `CodexSession` (id, state, `folderName` basename-only, real `startedAt`/`lastActivity`,
  `agent = "Codex"`), conservative `derive(age:endedWithCompletion:)` (no fake "working"), and
  `CodexSessionRadar.present(_:limit:)` (caps + name disambiguation).
- `CodexRolloutParser.swift` — strict allowlist parser: reads only `session_meta.{session_id/id,
  originator, cwd→basename, timestamp}`, per-line `timestamp`, and `event_msg` *category* (to spot
  `task_complete`). Never reads message/reasoning/tool bodies, full paths, `git.*`, `base_instructions`,
  account ids, or auth. Malformed lines skipped; non-Desktop / meta-less ⇒ `nil`.
- `AgentStatus.swift` — pure `AgentStatus.evaluate([AgentPresence])` + `.claude`/`.codex` presence
  mappers → unified Active/Idle/Not detected.
- `CodexSessionReader.swift` — I/O adapter: mtime-filtered walk of `~/.codex/sessions`, byte-capped read
  (whole file, or head+tail for a pathological one), **originator gate ("Codex Desktop")**, dedupe by id,
  sort most-active-first, cap. `CodexSessionModel.swift` — `CodexSessionProvider` (~5 s poll, self-gated
  on default-off `showCodexSessions` ⇒ off means zero I/O) + `@Observable CodexSessionModel`. **No
  keep-awake hook anywhere** (display-only).

**App / UI (`VibeMenuApp.swift`).**
- `AppDelegate` owns `codexSessions` (started/stopped with the others). New `PreferenceKey.showCodexSessions`.
- The old `SessionRadarView` (with its "Claude: …" fallback) is replaced by `AgentStatusSection`: a
  single "AI Agent: <status>" line + Claude `SessionRow`s (unchanged, dismiss + overflow) + Codex
  `CodexSessionRow`s (clear "Codex" pill), sharing one compact 4-row budget (Claude first;
  `codexBudget = max(0, SessionRadar.maxVisibleRows − claudeRowCount)`).
- Settings: new "Codex (Desktop only)" section — "Detect Codex Desktop sessions" toggle (default off),
  a short Desktop-only + display-only caption, and a folded "Privacy details" disclosure. Claude
  settings untouched; Codex prefs fully separate.

**Tests (new; sanitized fixtures only).** `CodexTestSupport.swift` (synthetic rollout builder that
stuffs forbidden fields), `CodexRolloutParserTests` (basic/robustness/**privacy** — proves no
prompt/response/tool/reasoning/git/account/auth surfaces), `CodexSessionStateTests` (activity heuristics
+ display), `CodexSessionReaderTests` (CLI-ignored, folder-name-only, malformed/large/missing safe, mtime
prefilter, dedup, sort), `AgentStatusTests` (none/Claude/Codex/both), `CodexSessionRadarTests`
(caps/disambiguation + shared budget).

**Commands / validation (real output).**
- `swift build` → `Build complete!`.
- `scripts/test.sh` → `Test run with 451 tests in 74 suites passed` (391 baseline + 60 new; existing
  Claude Session Radar + Claude Limits suites still green).
- `xcodebuild … -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build` → see below.

**Verified vs. not verified.** **Verified:** all pure Codex logic + the reader over temp-dir fixtures by
unit tests; all builds. **Not verified at runtime:** the live menu was not launched (a second instance
would duplicate the menu-bar item), so the on-screen "AI Agent" row, the Codex pill/rows, and the
shared-budget layout remain a **manual smoke-test** step. Live Codex parsing was validated only via
redacted diagnostics during investigation (deleted); the shipped reader was not run against live
`~/.codex` in-app.

**Scope guardrails.** Local-only, no network/cookies/API-keys/auth, no prompt/response/tool-output read,
no new dependency, Codex display-only (never affects sleep prevention), Claude Session Radar + Claude
Limits untouched, no real `~/.codex` data in fixtures. **Not committed / not pushed.**

## 2026-07-10 (later) — Codex live debugging: fixed session detection, shipped Codex Limits (ADR 0017 amended)

Follow-up debugging pass after live testing found the prior Codex redo broken in the running app. Same
branch `claude-codex-redo`; nothing committed/pushed.

**Root-cause: why session detection "didn't work live" (core was fine).** Verified the shipping
`CodexSessionReader`/`CodexRolloutParser` **in-process against live `~/.codex`** (a temporary, deleted
diagnostic) — they correctly return sessions. The failure was app-layer:
1. **Feature off / stale key.** Persisted `UserDefaults` held only the *old* `usage-codex` build's keys
   (`showCodexSessionDetection`, `showCodexLimits`, `codexLimitsSectionExpanded`); the current code
   reads `showCodexSessions`, which was unset → off. Plus the running menu-bar binary was stale vs the
   source. → detection was never actually enabled in what was tested.
2. **Budget starvation.** `codexBudget = max(0, 4 − claudeRowCount)` → Codex got **0** rows whenever
   Claude filled the shared 4-row list (i.e. always, while testing with Claude running).
3. **Subagent rollouts** (`session_meta.source.subagent`) carry `originator == "Codex Desktop"` and
   passed the gate.

**Fixes (session detection).**
- New pure `AgentSessionRadar.present(claude:codex:)` — a stable two-way **interleave** by activity
  within the shared 4-row cap (product choice: keep one budget, fix ordering). Codex off/empty ⇒
  identical to the old Claude-only list. `AgentStatusSection` rewired to render the merged list; Claude
  dismiss + overflow preserved (overflow now also absorbs Claude rows bumped by a busier Codex row).
- `CodexRolloutParser` now reads `session_meta.source` (category only) → `isSubagent`; the reader
  **drops** subagent rollouts and gates the originator **case-insensitively** (`isDesktopOriginator`).

**Codex usage limits — reversed "not shipped".** The DEV-LOG/ADR claim "`token_count` has no
`rate_limits` anymore" was **wrong**. Live re-check: `event_msg`/`token_count` `payload.rate_limits`
is present in **100% of `token_count` events across all 30 rollouts (389 events, Jul 2–10)**, shape
`{primary,secondary}.{used_percent, window_minutes, resets_at}` (primary=5h/300min, secondary=weekly/
10080min). Whole payload is `{type, info, rate_limits}`; `info` all-numeric; only strings are
`"token_count"`,`limit_id:"codex"`,`plan_type`. No prompts/responses/tool/auth/account. Product owner
approved shipping it.
- New: `CodexUsageLimit` (model), `CodexRateLimitRollout` + `CodexUsageLimitReader` (parse only numeric
  `used_percent`/`resets_at` behind a `"rate_limits"`/`"originator"` substring pre-check so conversation
  lines are never parsed), `CodexUsageLimitModel`/`Provider`, `CodexUsageLimitVisibility`, and menu
  `CodexLimitsView`/`CodexUsageLimitRow` (reuse `UsageBar`). Separate storage (`showCodexLimits`,
  `codexLimitsHiddenIDs`), default off, fail-closed to unavailable, staleness-labelled.
- `MenuVisibility` extended for the Codex Limits section (order: Claude Limits → Codex Limits → AI
  Agent → Thermal) with the same "divider above each visible section that has one above it" rule.
- **Not** read: `logs_2.sqlite` (intermixes prompts/auth), `info` token counts, `plan_type`/account,
  `auth.json`. `logs_2.sqlite` is unnecessary given the clean rollout field.

**Verification (real output).**
- `swift build` → Build complete.
- `scripts/test.sh` → **486 tests in 80 suites passed** (451 baseline + 35 new: AgentSessionRadar
  interleave/cap, subagent filter, case-insensitive gate, CodexUsageLimit model/parser/reader/
  visibility incl. a privacy proof that no SECRET_* / token-count field surfaces, Codex Limits divider
  rules). Existing Claude Session Radar + Claude Limits suites still green.
- `xcodebuild … -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build` → **BUILD
  SUCCEEDED**.
- **Live, in-process:** the shipping `CodexSessionReader` + `CodexUsageLimitReader` run against real
  `~/.codex` returned correct sanitized output (session `VibeMenu`; limits `5-hour 16%` / `Weekly 3%`,
  honestly labelled stale). The fixed `.app` was rebuilt, both features enabled in defaults, the stale
  `showCodexSessionDetection` key removed, and the app relaunched — it runs healthy (no crash).

**Verified vs. not verified.** Verified: all pure logic (unit tests); both readers against live data
in-process; both builds; the fixed app launches and runs without crashing. **Not verified:** the
on-screen menu **dropdown rendering** of the Codex session row + Codex Limits section — the dev `.app`
(LSUIElement, unsigned) isn't resolvable by GUI automation, so this remains a **one-click manual
smoke-test** (open the menu; the interleave + rendering follow the already-working Claude Limits/Session
Radar patterns).

**Scope guardrails.** Local-only; no network/cookies/API-keys/auth; no prompt/response/tool-output read;
no new dependency; both Codex features display-only (never affect sleep prevention); Claude features
untouched; no real `~/.codex` data in fixtures (sanitized only). A temporary live diagnostic was created
and **deleted**. **Not committed / not pushed.**

## 2026-07-10 — Codex redo fixes: remove the "AI Agent" status row; safe session titles; limits re-checked

Follow-up redo on branch `claude-codex-redo` addressing three requested fixes (plus a critical file
restore). Local-only; nothing committed/pushed/merged.

- **0. Restored `CLAUDE.md`.** It had been deleted from the working tree (tracked, unstaged deletion).
  `git restore -- CLAUDE.md` brought it back byte-identical to HEAD and the `v0.2` tag (76 lines); no
  longer in `git status`. Root cause: an accidental working-tree deletion during earlier testing (the
  file was tracked and unchanged in history).
- **1. Removed the visible `AI Agent: Active/Idle/Not detected` status row.** Deleted the display-only
  `AgentStatus`/`AgentPresence` type (`AgentStatus.swift`) and its tests — it fed **only** that text,
  not automation. The section (`AgentStatusSection` → **`AgentSessionsSection`**) now renders session
  rows directly; with no eligible sessions it shows one muted **"No active sessions"** line (never "AI
  Agent: Idle"), so the section is never an empty box and the `MenuVisibility` divider logic is
  unchanged. Settings toggle relabelled "Show AI Agent sessions" (key `showClaudeStatus` kept).
  **Sleep prevention untouched:** still driven only by `claude.onAutomationChange →
  keepAwake.updateClaudeAutomation`; `AutomationPolicy.decide` has no Codex input (pinned by a new test).
- **2. Better Codex session titles from a safe source.** New `CodexSessionTitle.swift`:
  `CodexTitleSanitizer` (rejects empty/generic/multi-line/URL/git-remote/path titles, length-caps) +
  `CodexSessionIndexParser` (reads **only** `id` + `thread_name`) + `CodexSessionIndexReader` over
  `~/.codex/session_index.jsonl`. `CodexSession` gained a safe `title`; `displayName` is now
  title→folder→generic. Investigation (schema/aggregates only, **no content surfaced**) showed
  `session_index.jsonl` `thread_name` is clean (24 entries, all ≤33 chars, single-line, no URL/path;
  subagents already excluded) whereas `state_5.sqlite` `threads.title` was the **raw first user message**
  in 3/24 user threads (and 10/10 subagent threads) — so the index is used and the SQLite title
  rejected (also avoiding a libsqlite3 dependency).
- **3. Codex Limits re-checked — unchanged.** Confirmed the reader uses **only** rollout
  `token_count.rate_limits` numeric fields; there is **no** `logs_2.sqlite` reader in `Sources/` (only
  docs mention it, as "not read"). Opt-in/default-off, separate storage, staleness-labelled — all kept.
- **Docs reconciled:** `ARCHITECTURE.md`, `PRIVACY.md`, ADR `0017` (Amendment 2 + superseded markers on
  the old Decision points), and this log.

**Verification (real output).**
- `swift build` → Build complete.
- `scripts/test.sh` → **495 tests in 82 suites passed** (removed `AgentStatusTests`; added Codex title
  sanitizer/parser/reader tests, reader title-integration incl. no-leak proofs, empty-presentation +
  single-provider interleave cases, and a Codex-display-only sleep-prevention invariant).
- `xcodebuild … -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build` → **BUILD
  SUCCEEDED**.

**Verified vs. not verified.** Verified: all pure logic + adapters (unit tests, incl. privacy proofs on
synthetic fixtures); both builds. **Not verified:** the on-screen menu **dropdown rendering** of the
status-row removal, the "No active sessions" fallback, and the new Codex titles — the dev `.app`
(LSUIElement, unsigned) isn't GUI-automatable, so this remains a **one-click manual smoke-test**.

**Scope guardrails.** Local-only; no network/cookies/API-keys/auth; no prompt/response/tool-output/
command/path/URL read or surfaced; no new dependency; Codex stays display-only (never affects sleep
prevention); Claude sleep-prevention logic unchanged; no real `~/.codex` data copied into fixtures
(sanitized synthetic only); read-only schema/aggregate inspection of `state_5.sqlite`/`session_index.jsonl`
surfaced no content. **Not committed / not pushed / not merged.**

## 2026-07-10 — Codex sessions feed sleep prevention; hideable Codex rows (ADR 0017 Amendment 3)

Two fixes from a manual smoke test on branch `claude-codex-redo`. Local-only; nothing committed/pushed/merged.

**Fix 1 — an active Codex session now prevents sleep (shared agent-activity decision).**
- *Root cause:* Codex session detection was deliberately display-only — it had no path into
  `PowerAssertionModel`, whose single `automationRequested` bit was owned solely by Claude. So a running
  Codex task never held the IOKit assertion and `pmset -g assertions` showed nothing.
- *Fix:* `PowerAssertionModel` now tracks a provider-neutral `holdingSources: Set<AgentKeepAwakeSource>`
  (`.claude`/`.codex`). `updateClaudeAutomation`/`updateCodexAutomation` insert/remove a source; the
  effective `automationRequested` is "any source holding", so the single `kIOPMAssertPreventUserIdleSystemSleep`
  assertion (**"VibeMenu Keep Awake"**) is held while either agent works and dropped only when all release.
  Claude's path is unchanged (it's now one source). New pure `CodexSessionActivity.automationIntent`:
  only `.active` holds; `.idle/.done/.stale/.unknown/[]` release. `.active` requires ≤60 s activity and is
  re-derived each tick, so the hold ages out on its own — no forever-awake, no separate cap. Wired in
  `AppDelegate` via `CodexSessionModel.onSessionsChange` over the **raw** list, and gated by
  `showCodexSessions` (off ⇒ empty list ⇒ release). Codex **usage limits** never feed this.
- *Claude preserved:* the set-based refactor keeps every existing `PowerAssertionTests` green (Claude-only
  behaviour, manual-wins, idempotency, cleanup) — Claude just became one of N sources.
- *pmset string to look for:* `VibeMenu Keep Awake` (a `PreventUserIdleSystemSleep` assertion owned by the
  `VibeMenu` pid).

**Fix 2 — every session row can be hidden by swipe.**
- *Root cause:* `CodexSessionRow` had **no** hide gesture at all (Claude rows did), so any Codex row always
  remained. There was also no per-Codex hidden-ID store, and the section always rendered "No active sessions"
  even when the user had hidden existing sessions.
- *Fix:* added the same drag-right / right-click "Hide from VibeMenu" gesture to `CodexSessionRow`, backed
  by a new `DismissedCodexRegistry` (Option-2 watermark, mirroring Claude, keyed on the **stable opaque
  session id** so a title change never un-hides). `CodexSessionModel` gained `visibleSessions` + `dismiss`;
  the menu interleaves/caps the **visible** Claude and Codex lists, so hidden rows are filtered *before* the
  shared cap and can't be forced back. When every row is hidden, `MenuContentView.agentSessionsHasContent`
  folds the AI Agent section's effective visibility to `false` (mirroring the Limits sections), collapsing
  the section and its dividers instead of showing a misleading empty state; "No active sessions" now shows
  only when there are genuinely none. Hidden IDs: Claude = existing session identity; Codex = `session.id`.

**Files changed.** Core: `AgentKeepAwake.swift` (new — `AgentKeepAwakeSource`, `CodexSessionActivity`),
`PowerAssertionManager.swift` (set-based holds + `updateAgentAutomation`/`updateCodexAutomation`),
`DismissedCodexSessions.swift` (new — `DismissedCodexRegistry`), `CodexSessionModel.swift` (`visibleSessions`,
`dismiss`, `onSessionsChange`). App: `VibeMenuApp.swift` (wire Codex keep-awake; Codex row hide gesture +
dismiss closure; `visibleSessions` before interleave; `agentSessionsHasContent` gate). Tests:
`AgentKeepAwakeTests.swift`, `CodexSessionHideTests.swift` (new); `MenuVisibilityTests.swift` (all-hidden
divider case). Docs: ADR 0017 Amendment 3, `ARCHITECTURE.md`, `PRIVACY.md`, this log.

**Verification (real output).**
- `swift build` → Build complete.
- `scripts/test.sh` → **522 tests in 86 suites passed** (was 495/82; +CodexSessionActivity, shared
  PowerAssertionModel, DismissedCodexRegistry, CodexSessionModel-hide suites).
- `xcodebuild … -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build` → **BUILD SUCCEEDED**.

**Verified vs. not verified.** Verified: all pure logic + the set-based power model + the Codex hide
registry/model (unit tests); both builds. **Not verified on-device:** the actual `pmset -g assertions`
appearing while a real Codex task runs, and the on-screen swipe-to-hide of Codex rows — the dev `.app`
(LSUIElement, unsigned) isn't GUI-automatable, so this stays a **one-click manual smoke test**.

**Scope guardrails.** Local-only; no network/cookies/API-keys/auth; no prompt/response/tool/path/URL read;
no new dependency; Codex **Limits** stay display-only (never affect sleep); only Codex **session activity**
feeds sleep, conservatively (`.active` only, no usage-limit timestamps); Claude sleep-prevention logic
unchanged; `logs_2.sqlite` never read; no real `~/.codex` data in fixtures (sanitized synthetic only);
`CLAUDE.md` present. **Not committed / not pushed / not merged.**

---

## 2026-07-10 — Fix empty vertical gap where the sessions section used to be

**Task/session:** focused UI/layout fix — a manual smoke test showed a large blank vertical band between
**Codex Limits** and **Thermal pressure** when the AI Agent sessions section had no visible rows.

**Root cause.** `MenuContentView.agentSessionsHasContent` returned `true` in the *genuinely-no-sessions*
case (its `return !hasAnySessions` branch) so `AgentSessionsSection` could render a muted "No active
sessions" placeholder. Because the section counted as "has content", the parent both instantiated it and
drew the divider above it (`isDividerAboveClaudeRow`) plus the divider above Thermal
(`isDividerAboveThermalRow`), with the top-level `VStack(spacing: 8)` adding gaps around each — a tall
empty band. The section's `TimelineView` re-evaluates the radar on its own tick (`context.date`), while
the parent evaluated `agentSessionsHasContent` once with a one-shot `Date()`; when the radar's time-based
rules aged the last row out between those two evaluations, the reserved section rendered *no* text at all —
a fully blank band. (The all-hidden case already collapsed correctly.)

**Fix.** Gate the whole section on the *final visible row count* only. Extracted the decision into a pure,
tested `AgentSessionRadar.hasVisibleContent(showSessions:claude:codex:)` (VibeMenuCore): `true` iff the
feature is on **and** ≥1 interleaved row survives the shared cap. `agentSessionsHasContent` is now a thin
wrapper over it (dismissals still applied *before* the gate via `visibleSessions`). Removed the
"No active sessions" placeholder from `AgentSessionsSection` entirely — prefer nothing over a fallback
that reserves height (per task). No `MenuVisibility` change: its divider rules already collapse cleanly
when `showClaudeStatus` folds to `false`. Shared cap/interleave for non-empty sessions untouched.

**Files touched (path + one line).**
- `Sources/VibeMenuCore/AgentSessionRadar.swift` — new pure `hasVisibleContent` section gate.
- `Sources/VibeMenuApp/VibeMenuApp.swift` — `agentSessionsHasContent` uses the gate (dropped the
  no-sessions fallback); removed the "No active sessions" placeholder; refreshed comments/doc.
- `Tests/VibeMenuCoreTests/AgentSessionRadarTests.swift` — new `hasVisibleContent` suite (feature off /
  none / all-hidden / Claude-only / Codex-only / both); updated the `noSessionsEmpty` comment.
- `Tests/VibeMenuCoreTests/MenuVisibilityTests.swift` — added the exact reported-gap scenario (both Limits
  on, sessions with no visible rows, Thermal on → tight dividers, no session band).

**Verification (real output).**
- `swift build` → **Build complete!**
- `scripts/test.sh` → **529 tests in 87 suites passed** (was 522/86; +`hasVisibleContent` suite,
  +reported-gap case).
- `xcodebuild … -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build` → **BUILD SUCCEEDED**.

**Verified vs. not verified.** Verified: the pure gate + divider logic (unit tests) and both builds.
**Not verified on-device:** the on-screen collapse of the band — the dev `.app` (LSUIElement, unsigned)
isn't GUI-automatable, so the visual result stays a one-click manual smoke test.

**Scope guardrails.** Focused UI/layout fix. Codex **Limits** logic unchanged; Claude/Codex
sleep-prevention logic unchanged; `logs_2.sqlite` never read; no new dependency; `CLAUDE.md` present; the
public wrapper repo untouched. **Not committed / not pushed / not merged.**

---

## 2026-07-11 — Research-led compact Settings redesign

**Task/session:** redesign the Settings window from the oversized grouped-card layout into a short,
aligned native macOS preferences surface, without changing behavior or privacy/power boundaries.

**Research and approval.** Reviewed Apple's HIG guidance for Settings, layout, toggles, disclosures,
pop-up buttons, labels, and materials; SwiftUI's `Settings`, `Form`, and `LabeledContent`; WWDC24's
macOS window guidance; and established pane/alignment patterns. Wrote the practical proposal in
`docs/design/settings-ui-research.md`. The product owner approved Option A (compact aligned form with
provider disclosures) before implementation, per `AGENTS.md`.

**Implementation.** Replaced the 360-point `.grouped` `Form`, oversized cards, centered detection
lines, raw checkbox stacks, standalone Session titles section, and long privacy paragraphs with a
440-point content-height window containing three compact system-colour groups: General, Claude, and
Codex. General now contains only Launch at login, Thermal status, and Show session rows. Claude and
Codex are parallel persisted disclosures with trailing-aligned compact switches, source/freshness
values, and conditional Rows menus. Each Rows menu uses native checkmarked toggle items and the
existing hidden-ID encoding; it appears only when usage is enabled and rows exist. Claude Advanced
contains the existing Desktop-title preference and preview-gated capture setup/remove action. Codex's
source is fixed text, not a fake picker. Removed stale visible "AI Agent" and old Codex no-sleep copy.

**Behavior and keys.** Preserved every existing preference key. The existing
`claudeLimitsSectionExpanded` now expands the Claude provider, and the already-defined
`codexLimitsSectionExpanded` now expands Codex; no key was added. Login item, thermal/session-row
visibility, tracking, usage, source, hidden-row persistence, install/remove behavior, readers, parsers,
data sources, and Claude/Codex power decisions are unchanged. Corrected stale comments/tests/privacy
copy that contradicted ADR 0017 Amendment 3; no executable power logic changed.

**Files touched (path + one line).**
- `Sources/VibeMenuApp/VibeMenuApp.swift` — compact Settings-only layout helpers, new provider layout,
  conditional checkmarked Rows menus, and current Codex automation comments.
- `Sources/VibeMenuCore/CodexSession.swift`, `CodexSessionReader.swift`, `MenuVisibility.swift` —
  documentation-only corrections: pure/read-only session data feeds the separate conservative
  shared-power adapter, and the removed aggregate status wording stays removed.
- `Tests/VibeMenuCoreTests/CodexSessionStateTests.swift`, `AgentSessionRadarTests.swift` — renamed the
  stale legacy-policy suite/comments; assertions remain about `AutomationPolicy`'s unchanged
  Claude-only input and the existing empty-section behavior.
- `docs/design/settings-ui-research.md` — sources, screenshot diagnosis, options, approved design,
  spacing rules, risks, implementation plan, and smoke checklist.
- `docs/PRIVACY.md`, `docs/ARCHITECTURE.md` — reconciled current Codex automation and collapsed-empty
  session-section wording with Amendment 3 and the existing implementation.
- `docs/DEVELOPMENT_LOG.md` — this entry.

**Verification (real output).**
- `swift build` → **Build complete!**
- `scripts/test.sh` → **529 tests in 87 suites passed**.
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug
  -derivedDataPath ./.derivedData build` → **BUILD SUCCEEDED**.

**Verified vs. not verified.** Verified both builds and every test. Launched this worktree's exact
Debug `.app` successfully. The accessibility UI driver could not attach to the menu-bar-only process
(full-path inspection timed out, while the bundle id is shared by several local builds), so the final
on-screen Settings appearance and interactive Rows menu remain manual smoke checks; no visual result was
fabricated. The repository launch skill was deliberately not used because its mandatory path points at
the out-of-scope main repository working tree.

**macOS API assumptions.** The redesign uses public SwiftUI/AppKit surface APIs only (`Settings`,
standard controls/disclosures/menus, `NSColor` semantic colours), all available at the macOS 15
baseline. They need no entitlement or root access and are sandbox-compatible. Appearance can vary with
OS and accessibility settings, which is why light/dark, Increase Contrast, and Reduce Transparency are
listed for manual verification. Existing public `SMAppService` behavior is untouched.

**Scope guardrails.** No new dependency or asset; no parser/reader/data-source/privacy-boundary change;
no Claude/Codex sleep-prevention logic change; no transcript widening; `logs_2.sqlite` not read;
`CLAUDE.md` preserved; only this worktree touched. **Not committed / not pushed / not merged.**

## 2026-07-11 — Add canonical agent handoff context

Added `docs/AGENT_CONTEXT.md` as a concise current-state handoff covering repository
boundaries, product features, privacy/data-source allowlists, build/test commands, the
ChatGPT/Claude/Codex workflow, current master milestones, git/release safety, and reading
order. Chronology remains here; design rationale remains in `docs/decisions/`.

**Verification.** `git diff --check` passed. No build or test run was needed for this
documentation-only change. `CLAUDE.md` and the public wrapper repo were not modified.

## 2026-07-12 — Trust the Run sleep-prevention status

Added a compact secondary status line below the Sleep prevention toggle. The pure core
presentation state now distinguishes `Off`, actual `On · Manual`, `On · Claude`, `On · Codex`,
combined owners in stable Manual → Claude → Codex order, and `Couldn’t enable` when a requested
assertion cannot be acquired. `PowerAssertionModel` exposes only a read-only ordered owner
projection; release failures retain the assertion id and therefore continue to present as active.
Quiet-hold timing was not added because the existing automation state provides reliable ownership,
but not a reliable remaining-time value.

**Verification.** `swift build` initially found and fixed a missing explicit return in the new pure
formatter, then completed with `Build complete! (2.69s)`. `scripts/test.sh` passed with **541 tests
in 88 suites**. `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug
-derivedDataPath ./.derivedData build` ended with `** BUILD SUCCEEDED **`. The required launch
sequence completed with exit 0 and `ps` confirmed the running process was
`./.derivedData/Build/Products/Debug/VibeMenu.app/Contents/MacOS/VibeMenu`.
An already-running `/Applications/VibeMenu.app` copy was found and terminated; no installed copy
remained. `pmset -g assertions` showed the real assertion `pid 10319(VibeMenu)` named
`"VibeMenu Keep Awake"`; the unrelated `powerd` assertion was also present. `git diff --check`
passed. Automated visual inspection was unavailable during implementation: Computer Use timed out
for the menu-bar app, System Events reported assistive access was not allowed, and display capture
was unavailable. The product owner subsequently confirmed the menu layout visually and manually
tested the status/toggle behavior of this original Trust the Run UI; that validation was performed
by the product owner, not by Codex or an automated tool. No real system assertion was created by
unit tests; tests used spy backends only. Public IOKit APIs remain unchanged: no entitlement/root/
private API is required and the assertion is lid-open idle-sleep prevention only. Recommended next
step: verify the follow-up manual-owner transitions after the always-enabled toggle change.

## 2026-07-12 — Keep Sleep prevention switch interactive during automation

Made the manual Sleep prevention switch always interactive while Claude, Codex, or both automation
owners hold the shared assertion. The switch still displays only `manualRequested`; changing it
adds or removes only Manual ownership. Removed the private `manualToggleIsDisabled` model API and
the SwiftUI `.disabled(...)` modifier, corrected nearby comments and architecture documentation,
renamed `failedCreationLeavesStateInactive` to `failedCreationReportsAcquisitionFailure`, and
added focused Claude/Codex/both-owner transition tests. Ownership changes continue to use
`manualRequested || automationRequested`, so a held assertion is never duplicated and is not
released until the final owner releases it.

**Verification.** `swift build` passed with `Build complete! (2.22s)`. `scripts/test.sh` passed with
**544 tests in 88 suites**. `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu
-configuration Debug -derivedDataPath ./.derivedData build` ended with `** BUILD SUCCEEDED **`
(Xcode emitted only its multiple-destination warning and the existing App Intents metadata warning).
The VibeMenu launch sequence ran on `master` and exited 0; `ps` confirmed
`./.derivedData/Build/Products/Debug/VibeMenu.app/Contents/MacOS/VibeMenu`
was running. `pmset -g assertions | grep -iE
"pid [0-9]+\(VibeMenu\)|VibeMenu|Keep Awake|PreventUserIdleSystemSleep"` reported
`pid 17234(VibeMenu)` with `PreventUserIdleSystemSleep` named `"VibeMenu Keep Awake"`, alongside
unrelated Handoff and powerd assertions. `git diff --check` passed. Computer Use could not inspect
the menu or exercise the live toggle: both the display-name request and the current Debug bundle
path request timed out with `Computer Use server error -10005: timeoutReached`. Therefore Codex did
not perform visual or live interaction validation for this follow-up; the prior product-owner
validation recorded above applies to the original Trust the Run UI and does not automatically cover
this new toggle behavior. Unit tests used spy backends only and created no real system assertions.
Recommended next step: product-owner smoke-test the Manual-on/off transitions while an agent hold is
active.

## 2026-07-12 — Schema-driven Codex usage limits (drop the fixed 5-hour/weekly assumption)

Reworked how VibeMenu discovers and displays Codex usage limits so it shows **only the windows Codex
currently exposes**, labels each from its own duration, and drops a window automatically when Codex
stops exposing it — instead of assuming a fixed `primary`=5-hour / `secondary`=weekly pair.

**Investigation (approved local data only).** A privacy-bounded probe read `token_count.rate_limits`
structure + `session_meta.originator` from 68 real `~/.codex` rollout files (1226 events, ~11 days) —
no prompts/responses/tool/reasoning/account/auth, no `logs_2.sqlite`/`state_5.sqlite`/`auth.json`.
Findings: every window carries `{ used_percent, window_minutes, resets_at }`; `window_minutes` is 300
(5-hour) or 10080 (weekly); the window set varies (`[primary,secondary]`, `[primary]`-only, or with a
non-window `credits` sibling); **`primary`/`secondary` are not stable in meaning** (17 events had a
lone `primary` window with `window_minutes 10080`, i.e. weekly); within-file window drops were 0 but
must be honoured; originators are `Codex Desktop` (64) **and `codex_work_desktop`** (4). The committed
exact-match originator gate rejected the `codex_work_desktop` files. Confirmed schema recorded in
[ADR 0017 Amendment 4](decisions/0017-codex-session-support.md).

**Change.**
- `CodexUsageLimit.swift` — removed the fixed `CodexUsageLimitKind` enum; a limit is now
  `{ windowMinutes: Int?, slot, usedPercent, resetsAt }`. Identity/label/order derive from
  `windowMinutes` (300→"5-hour limit", 10080→"Weekly", other exact→"N-hour/day limit", none→neutral
  "Usage limit"); legacy `fiveHour`/`weekly` visibility ids preserved; snapshot sorts shortest-first.
- `CodexUsageLimitReader.swift` — `parseWindows` emits every `rate_limits` child with a numeric
  `used_percent` (excludes `credits`, positional-agnostic, reads `window_minutes` for the label);
  `parseLatest` takes windows **verbatim from the single newest usable `token_count`** (replaces the
  old carry-forward/merge, so a dropped window is not resurrected); `CodexRateLimitReading` now holds a
  `windows` array. **[Superseded same day — see the 2026-07-12 "authoritative-empty" entry below:
  empty/credits-only readings are NOT skipped; a valid `rate_limits` object with zero windows is an
  authoritative empty reading that clears rows.]**
- `CodexRolloutParser.swift` — `isDesktopOriginator` widened to the narrow, both-ends-anchored
  `codex_*_desktop` family plus canonical "Codex Desktop"; still rejects `codex_cli_rs`/look-alikes.
  Shared with session detection, so `codex_work_desktop` sessions also become eligible (correct).
- Tests — rewrote `CodexUsageLimitTests.swift` and extended `CodexTestSupport.swift` /
  `CodexRolloutParserTests.swift` for: one/multiple limits, a disappearing limit (no within-file or
  cross-file resurrection), changed/unknown/absent durations, `credits` excluded, empty/credits-only
  authoritative-empty readings clearing rows, malformed/non-numeric data, CLI+subagent ignored, `codex_work_desktop` accepted,
  provider enable/disable gating + model auto-refresh, and the strict privacy proof extended to
  `credits`. No app UI logic changed (`CodexLimitsView` already iterates `snapshot.limits`).

**In-session adversarial review.** A four-lens review (correctness / privacy / gate / tests) of the diff
found two real code issues, both fixed before finalizing: (1) **major** — `parseWindows` used the
trapping `Int(Double)` on `window_minutes`, so a valid-JSON but out-of-`Int`-range value (e.g. `1e19`)
would crash the reader, violating fail-closed; now range/finiteness-guarded (⇒ neutral label). (2)
**minor** — a `window_minutes ≤ 0` was neutral in `label()` but sorted first and got a `win-0` id in
`sortKey`/`visibilityID`; the model init now normalizes non-positive durations to `nil` so all three
agree. Added regression tests for both, plus an editor-class originator (`codex_vscode`) exclusion and
a stronger provider auto-refresh test (periodic re-read + change-republish; disabled-across-ticks).
Privacy and gate lenses found nothing. (This is not a substitute for the AGENTS.md §18 different-model
review, still recommended.)

**Verification.** `swift build` → `Build complete!`. `scripts/test.sh` → **558 tests in 89 suites**
passed (5 new/rewritten Codex usage suites green). `xcodebuild -project App/VibeMenu.xcodeproj -scheme
VibeMenu -configuration Debug -derivedDataPath ./.derivedData build` → `** BUILD SUCCEEDED **`.
`git diff --check` clean; `CLAUDE.md` unchanged; only the 6 intended files plus pre-existing untracked
`.chatgpt/` and `docs/research/` in `git status`. **Runtime:** the shipped `CodexUsageLimitReader` was
run in-process against the real `~/.codex` and rendered exactly one truthful row — "Weekly · 0% ·
Resets Sun 10:06 PM" from `slot=primary window_minutes=10080` — which the *old* code would have
mislabeled "5-hour limit"; this is the live proof of the positional fix. The stale running Debug
instance (old binary) was gracefully `TERM`-ed and the freshly-built Debug `.app` was launched — it
came up cleanly (new PID, binary mtime matching the xcodebuild run, no crash report). Verified vs not:
the rendered rows were confirmed through the identical reader code path in-process, **not** by driving
the menu-bar popover — that would require enabling the default-off Codex-usage toggle on the owner's
live app (a persisted preference change), so it was left to the owner. macOS API note: no new
system/IOKit/private API — this is local file reads only; the originator-gate widening is the one
behaviour that also touches session detection/sleep and is called out above and in the ADR.
Recommended next step: an independent **Codex** review of the parser/gate/privacy change (AGENTS.md
§18) and owner smoke-test of the live Codex Limits rows with the toggle enabled.

## 2026-07-12 — Codex usage limits: authoritative-empty readings + unique row ids (correction)

Corrected two remaining correctness issues in the same-day schema-driven Codex usage work (above),
driven by the observed product requirement — not an assumed cause. The prior cut treated a valid but
window-less `rate_limits` as *non-authoritative* (skipped, stale rows preserved); the requirement is
the opposite.

**Confirmed semantics (now implemented).**
- **missing `rate_limits`, non-object `rate_limits`, or malformed line → ignore** (can neither add nor
  clear rows). A rollout with no valid `rate_limits` object at all yields **no** reading:
  `CodexRateLimitRollout.parseLatest` returns `nil` (guarded by a new `sawRateLimits` flag), so it can't
  masquerade as an authoritative-empty reading and wrongly clear rows.
- **valid `rate_limits` object with zero qualifying windows (empty `{}` or credits-only) → authoritative
  empty reading**: it clears previously-shown rows, and — across rollouts — a newer authoritative-empty
  reading **wins over** an older rollout that still had windows.
- **valid `rate_limits` object with ≥1 window → authoritative reading of exactly those windows** (verbatim
  from the single newest authoritative event; no merge/carry-forward).

**Change.**
- `CodexUsageLimitReader.swift` — `parseLatest` no longer `continue`s on empty windows; it records every
  valid `rate_limits` object (tracking `sawRateLimits`) and returns `nil` only when none was seen.
  `readSnapshot` no longer gates candidates on `reading.hasLimits`, so an authoritative-empty reading is
  compared by capture time and can win (returning an empty `.rollout` snapshot ⇒ rows removed). Doc
  comments corrected (empty ≠ "no reading"; `hasLimits == false` is a valid authoritative-empty state).
- `CodexUsageLimit.swift` — separated **row identity from visibility identity**: the `Identifiable` `id`
  is now `"<visibilityID>#<slot>"` so two distinct windows of the **same** duration (different slots)
  can't collide; `visibilityID` stays duration-derived so hide/show preferences remain stable. The app
  already uses `visibilityID` for persistence and `id` only for `ForEach`, so no UI change.
- Tests — reversed the two "does-not-clobber" tests into authoritative-empty clears (two-windows→empty,
  credits-only latest); added: newer authoritative-empty beats older-with-limits (reader), newer
  no-`rate_limits` file does **not** clear an older reading (reader), later missing/non-object/malformed
  `rate_limits` does **not** clear a valid earlier reading (parser), no-`rate_limits`-object → `nil`
  (parser), and two same-duration slots have unique row ids (model). Existing one/multi-window,
  dynamic-label, exclusion, refresh, and privacy tests remain green.

**Verification.** `swift build` → `Build complete!`. `scripts/test.sh` → **562 tests in 89 suites**
passed. `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug
-derivedDataPath ./.derivedData build` → `** BUILD SUCCEEDED **`. `git diff --check` clean; `CLAUDE.md`
unchanged. **Runtime:** the shipped `CodexUsageLimitReader` was re-run in-process against the real
`~/.codex` and still rendered the single truthful "Weekly" row; the freshly-built Debug `.app` was
relaunched and came up cleanly (no crash). Nothing staged/committed/pushed; pre-existing untracked
`.chatgpt/` and `docs/research/` preserved. Runtime rows were confirmed via the identical in-process
reader path, not by driving the default-off popover toggle on the live app. Recommended next step
unchanged: an independent **Codex** review (AGENTS.md §18) and owner smoke-test with the toggle enabled.

## 2026-07-14 — "Needs approval" from the `PermissionRequest` hook event (Claude Desktop)

**Task/session:** implement the smallest "Needs approval" feature after proving the signal live in
the Claude Desktop Code tab (see [`decisions/0018-needs-approval.md`](decisions/0018-needs-approval.md)).

**Preamble.** First cleanly reverted an abandoned hook-based "Needs attention" attempt to `HEAD`
(14 tracked files restored; deleted `Tests/VibeMenuCoreTests/ClaudeAttentionTests.swift`,
`docs/decisions/0018-needs-attention.md`, `.chatgpt/operations/last-write.json`; preserved
`docs/research/` and `.claude/settings.local.json`; no `git reset --hard`/`clean`). An Accessibility
investigation found Claude Desktop approvals are web-view elements (no native modal/sheet), so that
route was set aside in favour of the hook approach the owner then directed.

**Local Claude settings (owner-authorized, not repo).** Fresh backup
`~/.claude/settings.json.vibemenu-backup-20260714-000922`; installed the committed hook to
`~/Library/Application Support/VibeMenu/ClaudeHeartbeat/vibemenu-claude-hook.sh`; merged the committed
9-event `hooks` block (unrelated keys preserved, no dupes); then temporarily registered
`PermissionRequest` (matcher `"*"`) for the smoke test.

**Live proof (Desktop Code tab; observed only via VibeMenu's own `{event, sessionID, project}`
heartbeat files — no Accessibility/CLI/DB/log/network).** Baseline Desktop sessions detected. Approve
path (`2ebd49ef`): `UserPromptSubmit → PermissionRequest` (row showed **Needs approval**, sorted
first, timer — confirmed by the owner in the running Debug menu-bar app) `→ PostToolUse → Stop`
(cleared). Ordinary completion (`echo`, plain prompt): `…→ Stop`, no `PermissionRequest`, stayed
`Done`. **Known limitation:** Deny fires no registered event (separate unregistered
`PermissionDenied`), so a denied row lingers until the next event/prune (`17ee1bec` held until its
`SessionEnd`).

**Changed (repo).** `Sources/VibeMenuCore/ClaudeHeartbeat.swift` (add `.permissionRequested` event +
`"PermissionRequest"` mapping; `indicatesWorkInProgress` false — user is the blocker);
`Sources/VibeMenuCore/ClaudeSession.swift` (`derive` → `.permissionRequested`; `displayElapsed`
timer-from-request; refreshed stale "reserved" docs); `Sources/VibeMenuApp/VibeMenuApp.swift` (Claude
row timer uses `displayElapsedLabel`; Codex row unchanged); `Support/ClaudeHeartbeat/settings-snippet.json`
+ `README.md` (document `PermissionRequest`); `docs/ARCHITECTURE.md` (un-reserve `permissionRequested`);
tests in `ClaudeHeartbeatTests.swift` / `ClaudeSessionTests.swift`; new `docs/decisions/0018-needs-approval.md`.

**Validation (real output).** `swift build` clean; `scripts/test.sh` → **564 tests / 89 suites
passed**; `xcodebuild … Debug -derivedDataPath ./.derivedData` → **BUILD SUCCEEDED**; `git diff --check`
clean. Feature also validated against real live heartbeat data via a throwaway path-dependent probe
(the actual `VibeMenuCore` radar logic) rendering `permissionRequested`/"Needs approval" sorted first.

**Verified vs not.** Verified: approve path (active→clear), ordinary-completion=Done, sort-first,
timer-from-request, no-sleep-hold, live in the Debug `.app`. Not verified: the deny *clear* path
(no registered event — limitation above). Nothing committed or pushed.

**Deny investigation (resolved).** Owner asked to also handle Deny. Implemented + registered the
CLI's `PermissionDenied` event, then live-tested: across a 90-min window (incl. a fresh session that
had the hook), **Claude Desktop's Code tab emits no hook event on Deny** — no `PermissionDenied`, no
`Stop`, no `PostToolUse` (only `PermissionRequest` fires; that is why Allow clears and Deny does not).
So `PermissionDenied` was dead code on Desktop and was **reverted**; the deny-linger stands as a
documented limitation (ADR 0018). Owner chose to **keep `PermissionRequest` registered** in live
`~/.claude/settings.json` so the feature runs.

**Next step.** Optional independent (Codex) review of the diff; revisit Deny only if a future Claude
Desktop build starts emitting a Deny hook event.

## 2026-07-15 — Docs currentization + repo hygiene ahead of going public

**Task.** Documentation and repo hygiene only, ahead of making this repo public. No source, app
behavior, or test changes. Nothing committed or staged.

**Ownership.** All tracked files consistently name **Kirill Chistov** as product owner, including
the `Deciders:` line of all 17 ADRs.

**Stale claims corrected.** README was v0.1.1 and Claude-only while the source is v0.2 with Codex
Desktop, Trust the Run, and Needs approval. The `Claude: Active/Idle/Not detected` aggregate row was
still documented in `FAQ.md`, `PRIVACY.md`, and the smoke checklist but no longer exists (verified —
`VibeMenuApp.swift:542-549` renders sessions directly). Also fixed: `ROADMAP.md` claiming "v0.0 —
Repo bootstrap (current)"; `AGENTS.md` §13 saying the app had never been launched; `CLAUDE.md`
claiming no app icon; `PRIVACY.md`/`ARCHITECTURE.md` labelling shipped features v0.3.

**Signing recorded as a phase decision (ADR 0004 Amendment 1).** Per the owner, releases stay
unsigned while the project validates demand — a declined cost that is **revisitable** if adoption or
funding justifies a Developer ID, not a permanent position. The amendment notes that DMG/Homebrew do
**not** technically require signing, and that an updater is ruled out by the no-network invariant.
`SECURITY.md` gained a *"what unsigned actually means for you"* section.

**Accuracy corrections applied in review.** A second pass tightened the first draft's
overstatements, each verified against source: the repo is *being prepared* to go public, not already
public; the quiet-work hold is **Claude-only** (`ClaudeHeartbeat.swift:262,420-438` vs.
`AgentKeepAwake.swift:46-51` — Codex holds only while `.active` in a ~60s window, no cap), so docs no
longer imply Codex shares the 15-minute behavior; Needs approval clears on the session's **next
lifecycle event**, not on Allow (`ClaudeSession.swift:437-443`); there is no *main* window but there
is a Settings one (`VibeMenuApp.swift:401-403`); build-from-source avoids trusting the published
binary but still yields an unsigned app; "transcript-free" became "does not read transcript message
content", preserving the ADR-approved title-record exception.

**Second consistency pass (same day), also source-verified.** The heartbeat README still told users
to look for the aggregate row and a DEBUG "diagnostics row" — neither exists (`VibeMenuApp.swift`
has no diagnostics UI; DEBUG detection output goes to Console.app via `os.Logger`
`claude-detect`); rewritten to the real Session Radar labels and the real assertion status strings
(`On · Claude`, `On · Manual and Claude`, `Off` — `PowerAssertionState.swift:74-95`). `ARCHITECTURE.md`
likewise still described the menu as displaying `Claude: Active/Idle/Not detected`; corrected —
`Active`/`Waiting` are internal detection states, not UI. `SECURITY.md` now documents all three hook
fields (`hook_event_name`, `session_id`, `cwd`→basename, reduced inside the parser —
`vibemenu-claude-hook.sh:100`) and separates the heartbeat reader from the title-only resolver
instead of claiming VibeMenu never reads transcripts. `PRIVACY.md`'s "What is stored" was
understated (claimed settings + memory only): it now covers the 11 `UserDefaults` keys, the
VibeMenu-owned heartbeat/usage files and who writes each, the **normalized** persisted usage
snapshot (`ClaudeUsageLimitAutoReader.swift:45-55` — no raw bytes, org ids, or cost), and DEBUG-only
logging; also dropped the false claim that CPU/memory/battery are read (only
`ProcessInfo.thermalState` is live — `Monitoring.swift:64-66` is a TODO). `FAQ.md` invented a
"No active sessions" label — the section renders nothing at all when no rows survive
(`VibeMenuApp.swift:486-496,547`); also stopped attributing Launch at Login to *notarization*
(registration keys off a signature). README's Debug `xcodebuild` now passes
`-derivedDataPath ./.derivedData`, matching the documented output path. `INSTALL.md`'s
"no other system changes" became an accurate inventory (opt-in status-line write with backup,
hook, Application Support data, `UserDefaults`, login item).

**Other.** Release-checklist Part B held privacy checks that apply to *every* release; moved into
Part A as a new §8 gate, plus smoke steps for previously-uncovered features. `git rm`'d
`default.profraw` and `reddit_launch_draft_pack.md` (personal `~/Downloads` paths) — left deleted but
**unstaged**. `.gitignore` gained `*.profraw`/`*.profdata`/`*.trace`, `**/.DS_Store`, `.chatgpt/`,
`.claude/settings.local.json`. README screenshot commented out with a `TODO(screenshot)` (the asset
is the v0.1.x UI). `CLAUDE.md`'s preserve-verbatim rule now permits explicitly scoped factual
corrections. Left alone: untracked `docs/research/`, the wrapper repo, and stale code comments
(`ClaudeActivityModel.swift:136`,
`Package.swift:38`) wanting a separate pass.

**Release-state discrepancy (open owner task).** Published releases here stop at **v0.1.1**; the v0.2
zip went to the wrapper repo. Download links are therefore version-agnostic
(`../../releases/latest`), noting the source is v0.2.

**Validation.** `swift build` → `Build complete!`; `scripts/test.sh` → **564 tests / 89 suites
passed** (unchanged from the 2026-07-14 baseline, as expected for a docs-only diff);
`xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug -derivedDataPath
./.derivedData build` → **BUILD SUCCEEDED**, which also confirms the README's newly-documented output
path (`.derivedData/Build/Products/Debug/VibeMenu.app`) and that `.derivedData/` stays gitignored;
`git diff --check` clean; `git status --porcelain` confirms zero changes under `Sources/`, `Tests/`,
`App/`, `scripts/`, `Package.swift`; all intra-doc anchors and relative links resolve. **Not**
verified: the app was **built but not launched**, so the UI strings quoted in the docs were read from
source rather than observed on screen.

**Next step.** Owner review, especially ADR 0004 Amendment 1 (a decision recorded, not made). Then:
fresh screenshot → commit → make the repo public → publish v0.2 here. A full Git-history/privacy
audit remains outstanding and is **not** covered by this pass — history was not rewritten, so past
commits may still contain the removed clutter and absolute paths.

## 2026-07-16 — Recognise `StopFailure`: fix finished Claude sessions stuck on "Quiet" (ADR 0019)

**Task/session:** fix Claude sessions that have finished but stay displayed as **Quiet**. Hypothesis
(from the owner): Claude Code fires `StopFailure` — not `Stop` — when a turn ends on an API error, and
VibeMenu didn't recognise it. Verify against source + the official hook lifecycle, then make the
narrowest fix. See [`decisions/0019-stopfailure-heartbeat.md`](decisions/0019-stopfailure-heartbeat.md).

**Root cause (traced in source, not guessed).** `ClaudeSessionState.derive` reads **Done** only when
the newest heartbeat event is a non-work finish (`Stop`/`Notification`/`SessionStart`/`SessionEnd`),
and **Quiet** (`.quietWorking`) when the newest event *is* work-in-progress and has aged past the 120s
window but is within the 15-min quiet-hold cap. So a session finishes but stays Quiet **iff its turn
ended with no finish event overwriting the last work event.** On an API error that is exactly what
happens: `StopFailure` fires and `Stop` does **not**. VibeMenu mapped `"StopFailure"` → `.unknown`,
and `.unknown` `indicatesWorkInProgress` (0010 holds for unknown/future events on purpose), so an
errored-out session (1) read **Quiet** for up to ~15 min then went `.stale`, and (2) kept **holding**
automatic sleep prevention after the turn had ended. Normal `Stop` completions were never affected —
verified: `derive(.stop,…) == .done`, and the sample hook already wires `Stop`. This is a missing
*recognised finish event*, not a timing problem, so **no** silence heuristic / shortened timeout was
introduced (that would regress the 0010 quiet-work hold, which the constraints protect).

**External fact verified.** Consulted the official Claude Code hooks reference
(`code.claude.com/docs/en/hooks.md`) via a `claude-code-guide` subagent: `StopFailure` is a real event,
top-level `hook_event_name == "StopFailure"`, it fires when a turn ends on an API error, **`Stop` does
not fire** on that path, and a matcher of `"*"`/`""`/omitted matches all error types.

**Fix (narrow, additive; classified exactly like `Stop`).**
- `Sources/VibeMenuCore/ClaudeHeartbeat.swift`: add `ClaudeHeartbeatEvent.stopFailure`; map
  `"StopFailure"`; `isWaitingEvent == true`, `indicatesWorkInProgress == false` (the compile-forced
  exhaustive switch), `isSessionEnd == false` (the *turn* ended, not the session). No new
  `ClaudeSessionState`: `derive` → `.done`, `automationIntent` → `.release`, display `evaluate` →
  `.waiting` all follow with zero special-casing. `.unknown`'s hold-within-cap safety net is
  **unchanged**.
- `Support/ClaudeHeartbeat/settings-snippet.json`: add a matcher-less `StopFailure` block (fires on
  every error type, mirroring `Stop`).
- `Support/ClaudeHeartbeat/README.md`: add `StopFailure` to the wired-events list + a "Why
  `StopFailure`?" explainer (API-error finish → Done + release; no matcher; only the safe
  `{event, session id, folder}` recorded — never the error/tool/text).
- Tests (`ClaudeHeartbeatTests.swift`, `ClaudeSessionTests.swift`): mapping + classification; on-disk
  decode → recognised event (not `.unknown`); `derive` → `.done` at all ages (with the stuck-Quiet
  bug and the fix shown side by side on one 300s timeline); `automationIntent` → `.release` + a
  still-working sibling still holds; display → `.waiting`; the radar⇔automation drift-guard extended;
  and a **subprocess privacy test** feeding a realistic `StopFailure` payload with error type/message,
  asserting none of it leaks (only the safe fields written).
- `docs/decisions/0019-stopfailure-heartbeat.md` (new ADR, mirrors 0018).

**Manual step for existing installs (required for the fix to take effect).** The code recognises the
event, but the hook must emit it. Add to the `hooks` object in `~/.claude/settings.json` (same
absolute script path as the other entries), then restart Claude Code:
`"StopFailure": [ { "hooks": [ { "type": "command", "command": "'/ABSOLUTE/PATH/TO/vibemenu-claude-hook.sh'" } ] } ]`.
VibeMenu did **not** touch the real `~/.claude/settings.json` — only the sample snippet + docs.

**Validation.** `swift build` → `Build complete! (2.11s)`; `scripts/test.sh` → **570 tests / 89
suites passed** (was 564; +6 new `stopFailure` tests, each confirmed run+passed in the output);
`xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug build` → **BUILD
SUCCEEDED**; `git diff --check` clean; `git status --short` shows only the intended 5 tracked files
(+ this log + the new ADR). Diff is +142/−8 across the touched files.

**Not verified.** A real API-error turn was **not** reproduced on this machine, so the end-to-end path
(Claude writes a `StopFailure` heartbeat → row flips to Done → assertion releases) is **unverified
live** — the mechanism is proven by source + unit tests and the external event fact by the hooks
reference, but not observed on screen. Smallest next experiment is in ADR 0019 (§ *Verification*):
install the block, trigger a rate-limit/overload finish, and watch the heartbeat file's `event`,
the radar row, and `pmset -g assertions`.

**Next step.** Owner review; optional live confirmation via the experiment above. Not committed.

## 2026-07-17 — Attention v1

Implemented the approved option-1 slice: one default-off Agent notifications toggle, transition-only
Claude approval/Done and Codex Done notifications, reusable-turn timer resets, and provider-level
Claude Desktop / ChatGPT activation from both rows and notification clicks. Added the pure transition
and timer tests plus `docs/decisions/0020-attention-v1.md`. The pre-existing `docs/AGENT_CONTEXT.md`
and `docs/research/` changes were preserved untouched.

Validation run:

- `swift build` → `Build complete! (5.20s)`.
- `swift test --filter AttentionTests` → **9 tests in 1 suite passed**.
- `scripts/test.sh` → **579 tests in 90 suites passed**.
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build` → **BUILD SUCCEEDED** (Xcode emitted only its existing multiple-destination warning).
- `git diff --check` → clean.
- Launched the Debug app; the built plist reports `LSUIElement = true`, `agentNotifications = 0`, and the local provider plists report `com.anthropic.claudefordesktop` and `com.openai.codex`.

During implementation, compilation exposed and fixed the expected macOS adapter issues: the
notification delegate now inherits `NSObject`, the static routing key is explicitly nonisolated, and
the notification response completion handler is called before the main-actor activation task. No
network, transcript reads, new dependency, Accessibility automation, private API, root, or power-loop
change was added.

Not verified live: the macOS permission prompt/actual delivery, real Claude and Codex reusable turns,
provider activation from a row or notification, and drag-vs-tap behavior in the menu UI. The
computer-use accessibility inspection timed out on this menu-bar-only app. The pure transition,
timer, permission-gate, provider-target, ordering, dismissal, overflow, state-derivation, and
sleep-prevention tests passed. Recommended next step: owner smoke-test one reusable turn in each
provider with notifications explicitly enabled, then click a row and notification.

## 2026-07-17 — Independent Attention v1 review: generation-aware deduplication

**Review result.** Confirmed the primary blocker in the uncommitted implementation: the attention
tracker compared only derived display state. That could notify on a same-heartbeat Working → Done
reclassification and could miss a newer Claude completion, Claude permission request, or Codex
completion when polling observed the same target state twice.

**Correction.** `AttentionTransitionTracker` now compares safe activity generations: Claude
`lastEventAt`; Codex `lastActivity` plus the allowlisted `task_complete` marker. Repeated identical
timestamps/markers stay silent. The first snapshot per provider remains a silent baseline; after that,
a newly appearing target-state session can notify. The explicit Codex “Track Codex sessions” setting
resets that provider baseline on disable/re-enable, so its first subsequent snapshot is silent without
silently suppressing ordinary new sessions. Notification payload routing remains provider-only, and
the existing safe display name is the only human-readable field. Timer-reset and sleep-prevention
paths remain separate from notification tracking.

**Validation run.** `swift test --filter AttentionTests` → **16 tests in 1 suite passed**; `swift build`
→ **Build complete!**; `scripts/test.sh` → **586 tests in 90 suites passed**; `xcodebuild -project
App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build`
→ **BUILD SUCCEEDED**; `git diff --check` → clean. The Xcode build emitted its existing multiple-
destination warning and a non-fatal AppIntents metadata warning; no build/test failures occurred.

**Gesture/privacy/manual boundary.** SwiftUI's simultaneous-gesture composition could let the tap and
drag recognizers succeed independently, so both rows now use an exclusive tap-before-drag composition;
a drag-to-hide cannot also activate its provider through this gesture path. The context menu remains a
separate secondary-click path. Manual verification is still required for drag-to-hide vs. plain click,
right-click hide, actual notification permission/delivery, provider activation, and real reusable
Claude/Codex turns. No app launch is claimed from this review. The earlier implementation entry's
launch/plist observation remains explicitly separate from these unverified live behaviors.

**Next step.** Owner smoke-test the manual checklist, then review the focused uncommitted diff. No
commit or push was performed; unrelated `docs/AGENT_CONTEXT.md` and `docs/research/` work was preserved.

## 2026-07-17 — Attention v1 completion and reusable-turn correction

Fixed the remaining Attention v1 behavior without changing the app-side notification or activation
surface. Claude notification generations are now the safe heartbeat timestamp plus normalized event;
same-event reclassification is silent, while a same-second `UserPromptSubmit` → `Stop` replacement is
a completion generation. Claude finished notifications require `Stop` or `StopFailure`; bare
`SessionStart`, process/age-derived Done, and silence do not notify. Same-second latest-record
selection prefers a finish/approval event over an older work/lifecycle classification. Genuine
`Stop`/`StopFailure` session rows become Done before process/age checks, so the next normal refresh
removes the timer and releases the existing Claude automation intent. Claude reusable-turn timing now
starts a new Done/Stale/Unknown → `PermissionRequest` turn at the request timestamp, preserves that
start after approval resumes work, and does not reset an already-running turn's original start.

Validation run:

- `swift test --filter AttentionTests` → **24 tests in 1 suite passed**.
- `swift test --filter ClaudeHeartbeatTests` → **55 tests in 6 suites passed**.
- `swift test --filter ClaudeSessionTests` → **68 tests in 6 suites passed**.
- `swift build` → **Build complete! (0.22s)**.
- `scripts/test.sh` → **594 tests in 90 suites passed**.
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build` → **BUILD SUCCEEDED**; Xcode emitted its existing multiple-destination warning and the non-fatal AppIntents metadata warning.
- `git diff --check` → clean.

The first focused run exposed and fixed a test-fixture error: the immediate-finish test advanced past
the unchanged 30-minute prune horizon. The existing StopFailure test also still expected an old
process/age degradation to Stale; it now asserts the requested unconditional Done finish behavior.

Manual safe-field check: the installed heartbeat directory contained only `SessionEnd` records and
one historical `Stop` record at inspection time; no `StopFailure` or live Working/Quiet → Stop sequence
was available. No real Claude turn, notification permission/delivery, provider activation, or row
gesture smoke test was claimed. No hook configuration was modified. No transcript content, prompt,
response, tool, error, path, repository URL, or session ID was inspected or logged.

**Next step.** Owner smoke-test one real Claude turn with the existing hook configured and notifications
explicitly enabled, inspecting only `event`/`updatedAt`, then verify the one notification and provider
activation manually. No commit or push was performed.

## 2026-07-18 — Claude completion latch

Confirmed the remaining Claude-only Attention v1 failure at the safe heartbeat boundary. A real
subagent turn produced `UserPromptSubmit → PreToolUse → SubagentStart → SubagentStop → PostToolUse →
Stop → SubagentStop`; the trailing `SubagentStop` replaced the genuine finish in the old hook, and
because it is work-like but not display-active, the row was reclassified as Quiet with a new timer.
The hook now reads only the previous VibeMenu-owned safe `event` and, after `Stop`/`StopFailure`,
ignores all repeated/trailing events except `UserPromptSubmit`, `PermissionRequest`, and `SessionEnd`.
The safe heartbeat schema and all Codex paths are unchanged.

Validation run:

- `swift test --filter ClaudeHeartbeatScriptTests` → **16 tests passed**.
- `swift build` → **Build complete!**
- `scripts/test.sh` → **602 tests in 90 suites passed**.
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build` → **BUILD SUCCEEDED**; existing multiple-destination and non-fatal AppIntents metadata warnings only.
- `/bin/sh -n Support/ClaudeHeartbeat/vibemenu-claude-hook.sh` → clean.
- `git diff --check` → clean after the final documentation updates.

Manual result:

- The pre-fix live capture reproduced the exact late-event sequence above using only normalized event
  and `updatedAt` output.
- The local VibeMenu-owned hook copy was synchronized to the patched repository hook without editing
  `~/.claude/settings.json`. A second real subagent turn then produced
  `UserPromptSubmit → PreToolUse → SubagentStart → SubagentStop → PostToolUse → Stop`; no later safe
  heartbeat replacement appeared during the capture window, and the final safe event remained `Stop`.
- The Debug app was launched from `./.derivedData/Build/Products/Debug/VibeMenu.app`; its process and
  built plist were present with `LSUIElement = true`.
- The menu-bar-only row/timer view, notification delivery, row/notification activation, and exact
  one-notification live delivery could not be observed because the local accessibility surface
  exposes no VibeMenu menu window and notifications are opt-in. Pure transition, timer, sleep-intent,
  and notification-generation tests passed. The heartbeat capture read and emitted only normalized
  event/`updatedAt` fields; no transcript content, prompt, response, tool data, path, or session
  content was read from the heartbeat files or logged.

The initial focused run exposed two timestamp-relative test assertions and they were corrected to
measure elapsed time from the retained `UserPromptSubmit`/`PermissionRequest` turn start. No source
behavior or user settings were changed by those fixes. Recommended next step: owner manually click a
visible Session Radar row and, if notifications are enabled, one Done notification to verify provider
activation on this menu-bar-only build. No commit or push was performed.

## 2026-07-18 — Standard Attention notification sound

Updated the shared Attention v1 delivery path so Claude **Needs approval**, Claude **finished**, and
Codex **finished** notifications request `.alert` and `.sound` authorization, set
`content.sound = .default`, and request `.banner` and `.sound` during foreground presentation.
Actual playback remains controlled by the Mac's notification, Focus, volume, and sound settings. The
existing single **Agent notifications** toggle, transition deduplication, provider activation,
timers, completion latch, Codex path, gestures, dismissal, ordering, and sleep-prevention behavior
are unchanged. No sound toggle, custom sound, sound selection, badge, grouping, reminder, or history
behavior was added. macOS does not show the authorization prompt again after the first response, so
a prior alerts-only authorization may require enabling VibeMenu notification sounds in macOS
notification settings before testing.

Validation run:

- `swift build` → **Build complete! (3.81s)**.
- `scripts/test.sh` → **602 tests in 90 suites passed**.
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build` → **BUILD SUCCEEDED**; existing multiple-destination and non-fatal AppIntents metadata warnings only.
- `git diff --check` → clean.

Manual result: the Debug app was launched from `./.derivedData/Build/Products/Debug/VibeMenu.app`.
macOS Notifications showed VibeMenu's **Allow notifications** switch on with Desktop, Notification
Center, and Lock Screen enabled, but no VibeMenu sound control was available; this is consistent
with the existing alerts-only authorization caveat. While the Debug app was running, a temporary
heartbeat containing only safe synthetic `UserPromptSubmit`, `Stop`, and `SessionEnd` fields exercised
the real Claude completion-notification path, then the heartbeat was moved to Trash. Audible playback
was **not verified**: the current macOS authorization did not expose sound permission, and the tool
cannot independently hear the Mac's speaker output. The **Agent notifications** preference remained
enabled; ordinary alert notifications were not disabled because system sound was unavailable. No
Claude settings, transcript content, or protected research files were modified. No commit or push was
performed.

**Next step.** After the owner enables VibeMenu notification sounds in macOS notification settings,
manually confirm one visible Attention notification and its standard macOS sound with the Mac's
notification, Focus, volume, and sound settings permitting it.

## 2026-07-18 — Centralized Recent sessions expansion

**Task.** Replace the asymmetric Claude/Codex session overflow with one bounded, provider-neutral
Recent sessions expansion (ADR 0017 Amendment 5). This remains a display affordance, not a session-
history screen or persistent queue.

**What changed.** `AgentSessionRadar.Presentation` now exposes `items`, `overflowItems`,
`hiddenCount`, and `olderHiddenCount`. The presenter keeps the shared four-row primary prefix,
merges eligible hidden Claude/Codex suffixes with the same cross-provider priority/recency comparison,
and caps the expanded list at ten rows. `AgentSessionsSection` now has one collapsed control and
renders both existing provider-specific row views in the unified expansion, preserving activation,
drag-right hiding, right-click hiding, provider pills, and name handling. Focused pure presenter tests
cover provider-only and mixed overflow, ranking, caps, counts, no-overflow, and prefiltered hidden
rows. The required research files were preserved untouched.

**Validation.**

- `swift test --filter AgentSessionRadarTests` → **27 tests in 2 suites passed**.
- `swift build` → **Build complete! (0.38s)**.
- `scripts/test.sh` → **614 tests in 90 suites passed**.
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build` → **BUILD SUCCEEDED**; only the existing multiple-destination warning and non-fatal AppIntents metadata warning appeared.
- `git diff --check` → clean.

**Manual result.** The Debug app was launched from `./.derivedData/Build/Products/Debug/VibeMenu.app`
and its process was present. The first accessibility capture was ambiguous because an installed app
with the same bundle identifier was also running; after isolating the Debug process, the menu-bar-only
accessibility capture timed out. The requested live one-control/expanded mixed-provider row, click,
and hide smoke was therefore **not verified live**; the pure presenter tests and app build are the
available validation. No settings, transcript content, network call, or protected research file was
changed.

**Next step.** Owner smoke-test with more than four Codex sessions and a mixed Claude/Codex list:
confirm one control, shared ordering, provider activation, drag-right hide, and right-click hide.

## 2026-07-18 — Reactive Claude approval menu-bar indicator

Corrected the Attention v1 menu-bar implementation in place. The raw Claude session list still feeds
the existing `ClaudeActivityModel.needsAttention` decision, but the custom `MenuBarExtra` label now
selects `MenuBarAttentionIcon` for a genuine `.permissionRequested` session and the existing
`MenuBarIcon` otherwise. The attention asset is original-color artwork; the normal asset remains a
template so macOS controls its adaptive light/dark menu-bar appearance. Accessibility exposes only
`VibeMenu` with `Normal` or `Needs attention`; no notification, session derivation, timer, approval
inference, or Claude Deny behavior changed.

The supplied source PNG was inspected as 1024×1024 RGBA with alpha 0…255. Its visible artwork bounds
are x=179…844 and y=269…754 (exclusive bounds 179,269–845,755), leaving symmetric horizontal and
vertical padding of 179px and 269px. Only that transparent outer margin was removed; the visible
artwork was then deterministically rasterized with the system `sips` tool into the normal asset's
18/36/54px canvases, with matching visible bounds of 16×12, 32×24, and 48×36. Alpha and the baked
orange artwork remain intact; there is no background, redraw, or new dependency. The catalog omits
template intent for `MenuBarAttentionIcon`, while `VibeMenuApp.swift` explicitly requests
`.renderingMode(.original)`.
The existing `MenuBarIcon` PNGs were byte-identical to `HEAD`.

Focused tests cover no sessions; Working, Quiet, Done, Stale, and Unknown; one approval; mixed
ordinary/approval sessions; clearing approval; and a hidden approval row remaining present in the raw
attention decision. No notification, session derivation, timer, power, dismissal, ordering, overflow,
activation, or app setting behavior was changed.

Validation:

- `swift test --filter MenuBarAttentionTests` → **6 tests in 1 suite passed**.
- `swift build` → **Build complete! (0.14s)**.
- `scripts/test.sh` → **620 tests in 91 suites passed after 1.100 seconds**.
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData clean build` → **BUILD SUCCEEDED**; the existing multiple-destination warning and non-fatal AppIntents metadata warning appeared. The build emitted `Contents/Resources/Assets.car`; `assetutil` reported `MenuBarAttentionIcon` at 18/36px with `Opaque: false` and `Template Mode: automatic`, and `MenuBarIcon` with `Template Mode: template`.
- `git diff --check` → clean.

Manual result: duplicate VibeMenu processes were terminated, `HEAD` was confirmed as
`b9d1f34f2aad10ad8f0fa80df3abb74673e3b35b`, and exactly
`./.derivedData/Build/Products/Debug/VibeMenu.app` was launched and verified by its executable path.
Computer Use timed out for both the exact app and `SystemUIServer`;
a read-only screen capture did not expose an identifiable VibeMenu status item or menu. Therefore
normal, orange Needs approval, approval-clear, menu-closed/open, hidden-row, and light/dark visual
transitions are **unverified**. The pure raw-list hidden-row rule remains covered by the existing
attention tests. No system/application settings, Claude settings, transcript content, or protected
research files were changed.

**Next step.** Owner smoke-test the three icon transitions from the exact Debug artifact with one real
Claude `PermissionRequest` and its next lifecycle event, including a hidden pending row and closed/open
menu plus light/dark appearances when available. No commit or push was performed.


## 2026-07-19 — Documentation synchronization and headless feasibility checkpoint

Synchronized the live product, roadmap, architecture, privacy, security, installation, FAQ,
release checklist, and canonical agent handoff with committed `master` at `3234e3a`:
Attention v1 notifications and provider activation, completion latching, the original-color orange
Needs approval menu-bar asset, and the centralized provider-neutral Recent sessions expansion are
now described as committed behavior rather than uncommitted work. Product positioning now states the
approved direction: VibeMenu is the open-source power guardian for local coding agents; agent tracking
is a bounded sensing layer, not a broad dashboard/control-center strategy.

Recorded the owner-run feasibility checkpoint without claiming a shipped feature: two short tests on
the current Apple Silicon Mac held `SleepDisabled=1` while a process logged once per second with the
lid closed. The largest observed execution gaps were 1s and 2s, and both runs ended with
`SleepDisabled=0`. This proves basic CPU continuity on that machine only. Networking, real-agent
progress, long-duration thermal behavior, global-setting ownership, helper/app crash and reboot
cleanup, signing/notarization, and cross-model support remain unverified. No privileged helper or
closed-lid code was added; research and the two protected untracked demand-research drafts were left
unchanged.


## 2026-07-24 — Prepare v0.3 release (docs/version only; feature development paused)

Prepared the `v0.3` release of the standalone power-and-attention utility. Product decision: active
feature development is now **paused**; VibeMenu enters maintenance/feedback mode, and future work
(including any headless/lid-closed exploration) depends on actual user demand. The unfinished
Experimental Headless Agent Runs implementation had already been removed before this release, so v0.3
ships with **no headless setting, no privileged helper, and no closed-lid code**; closing the lid may
still sleep the Mac.

Changes were limited to release/version documentation — **no application source or test files were
touched, and no app behavior changed**:

- `App/Info.plist`: `CFBundleShortVersionString` 0.2 → **0.3**, `CFBundleVersion` 3 → **4**.
- `README.md`: source badge → v0.3; added the shared four-row Session Radar + centralized
  provider-neutral Recent sessions expansion, the orange menu-bar attention state, and the opt-in
  Claude Needs approval / Done notifications to the feature list; replaced the "published release may
  lag behind source" note with durable wording (tagged releases correspond to their attached
  binaries, `master` may later move ahead); packaging example → 0.3; added a maintenance-mode note.
- `docs/AGENT_CONTEXT.md`, `docs/PRODUCT.md`, `docs/ROADMAP.md`, `docs/FAQ.md`, `docs/ARCHITECTURE.md`,
  `docs/RELEASE_CHECKLIST.md`: reframed stale "headless is the active next milestone / under
  investigation" language and the "latest binary is v0.1.1 / release lags source" claims to the
  shipped-and-paused v0.3 posture. Historical headless research, the owner-run `SleepDisabled` test
  record, and ADR references (0020, 0021) were preserved as history, not erased.

Verification (real output):

- `swift build` → **Build complete!**
- `scripts/test.sh` → **620 tests in 91 suites passed**.
- `xcodebuild … -configuration Debug -derivedDataPath ./.derivedData build` → **BUILD SUCCEEDED**.
- `xcodebuild … -configuration Release -derivedDataPath ./.derivedData-release build` → **BUILD
  SUCCEEDED**; the built Release bundle reports `CFBundleShortVersionString=0.3` / `CFBundleVersion=4`.
- `git diff --check` clean; exactly the eight release/version files above changed.
- Tracked-files privacy/security scan clean: no secrets/certs/tokens, no personal absolute paths, no
  network code (only `DispatchSourceTimer.resume()`), no headless helper / LaunchDaemon / installer,
  and all opt-in data sources (`showCodexSessions`, `showClaudeLimits`, `showCodexLimits`,
  `useDesktopTitles`) still default to off.

`CLAUDE.md` and the two protected untracked demand-research drafts were left unchanged (the drafts are
locally excluded via `.git/info/exclude`).

**Next step / publication gate.** After committing and pushing this release commit, package with
`scripts/package-github-release.sh 0.3` and run the owner-assisted packaged-app smoke test on the exact
`dist/VibeMenu-v0.3-macos-arm64.zip` app. Only after that gate passes: create annotated tag `v0.3` on
this commit, push it, and publish the GitHub Release "VibeMenu v0.3" with the archive attached. The
release remains **unsigned and not notarized**.

## 2026-07-26 — Debug pass: Claude Session Radar had no rows; Codex usage source dried up

Focused pre-release debugging pass on two reported failures. No release action was taken.

**Claude Session Radar showed nothing while Claude was running — root cause: a registered hook
pointing at a deleted script.** Live, metadata-only evidence separated the layers cleanly: the exact
process name `claude` still matches (so L1 process detection is intact), `~/.claude/projects/**`
session-file mtimes were seconds old (L1 recency intact), `~/.claude/settings.json` still carried all
eleven VibeMenu hook entries with a correct absolute, quoted path — but
`~/Library/Application Support/VibeMenu/ClaudeHeartbeat/` (script *and* `sessions/`) no longer existed,
so every hook invocation failed silently. Because both the radar store and `automationIntent` are fed
**only** by heartbeat records, the result was zero Claude rows and no Claude keep-awake owner, while the
menu still read Claude **Active** from L1 — a half-working appearance rather than a visible failure.
Nothing in `~/.claude` had changed shape (no layout/schema drift): re-copying the committed script to
the path the existing entries name restored delivery immediately, with no settings edit and no Claude
restart.

**Codex usage limits are stale because the only approved source stopped being written.** The newest
`~/.codex/sessions/**/rollout-*.jsonl` (and `session_index.jsonl`) write is 2026-07-24T17:28, while
Codex Desktop was running during this pass and only its `logs_2.sqlite` / `state_5.sqlite` stores were
updating — both explicitly forbidden sources. Everything on disk is therefore older than
`CodexUsageLimitReader.defaultRecencyHorizon` (24 h), so `.unavailable` is the **correct** reader
output; the reader, the 5 s provider tick, and the launch-time `start()` were all verified healthy.
A fresher reading cannot be obtained under the current invariants: `rate_limits` only appears when
Codex itself runs a turn, and a personal allowance lookup would need an authenticated OpenAI request
(AGENTS.md §8). Nothing was faked; only the copy was made truthful.

Changes:

- `Sources/VibeMenuCore/CodexUsageLimit.swift` — new pure `CodexUsageLimitsMenuCopy`: an empty-state
  line that no longer promises that *opening* Codex Desktop produces data (only a Codex turn writes a
  reading), plus help text that derives its stated freshness window from
  `CodexUsageLimitReader.defaultRecencyHorizon`, says VibeMenu never contacts OpenAI, and drops the
  stale "5-hour and weekly windows only" claim (the reader has been schema-driven since the ADR 0017
  amendment).
- `Sources/VibeMenuApp/VibeMenuApp.swift` — `CodexLimitsView` empty state now renders that core copy
  instead of inline strings. Display-only; no reader, timer, or automation change.
- `Tests/VibeMenuCoreTests/CodexUsageLimitTests.swift` — regression test pinning the truthfulness
  properties of that copy (local/turn-written source, horizon matches the reader constant, no-network
  statement, no fixed window pair).
- `Tests/VibeMenuCoreTests/ClaudeHeartbeatTests.swift` — regression test
  `noHeartbeatRecordsMeansNoClaudeHoldAndNoRadarRow`: with no heartbeat records but a live process and
  1-second-old L1 metadata, the display reads `.active` while automation `.release`s and the radar store
  is empty. This pins the hook dependency that made the failure invisible, and is the guard rail for any
  future decision to let L1 hold on its own (a power-assertion change ⇒ product approval, AGENTS.md).
- `Support/ClaudeHeartbeat/README.md` — setup/troubleshooting fix for exactly this failure mode: use the
  fully expanded path (single quotes never expand `~`), keep the script where the entries point, a
  "nothing appears? check the script is still there" check with the repair, and a removal step that
  takes the settings entries out **before** deleting the files.

Verification (real output):

- `swift build` → **Build complete! (15.62s)**
- `scripts/test.sh` → **622 tests in 91 suites passed** (620 before; both new tests observed passing).
- `xcodebuild … -configuration Debug -derivedDataPath ./.derivedData build` → **BUILD SUCCEEDED**.
- `git diff --check` → clean.
- Live smoke (Debug bundle, ~15 s, then stopped): its own path-free `claude-detect` diagnostics read
  `process=true, heartbeat=Active age=1s sessions=1, result=Active` / `intent=hold` on successive ~2 s
  ticks, and `pmset -g assertions` showed that instance holding its own `VibeMenu Keep Awake` assertion
  11 s after launch — so hook delivery, heartbeat parsing, session folding, and automatic sleep
  ownership are all confirmed end-to-end without opening the menu. Only VibeMenu-owned heartbeat fields,
  process names, and file mtimes were read.
- Not verified here: the popover's rendered Claude row and the Codex section's new empty-state line
  (menu-bar popover is not accessibility-inspectable in this environment) — owner UI check.

**Release-state note (premise correction).** The task assumed v0.3 was untagged/unpublished and asked for
docs to say so. Evidence says otherwise: annotated tag `v0.3` → `deb0dc1` exists locally **and on
origin**, and GitHub Release "VibeMenu v0.3" is published (not a draft, 2026-07-26T11:45:09Z) with
`VibeMenu-v0.3-macos-arm64.zip` attached. The release-state docs are therefore already correct and were
left untouched. The changes above put `master` ahead of the `v0.3` tag, which is the documented normal
state; the local `dist/VibeMenu-v0.3-macos-arm64.zip` still matches the tag but no longer matches
`master`, so any future build must be repackaged rather than reused.

**Next step.** Owner decision on the ranked findings — chiefly whether L1-only detection should hold
sleep prevention (a power-assertion change needing a proposal + ADR), and whether Codex Desktop still
writes rollouts at all (run one Codex turn, then re-check `~/.codex/sessions/`). If it does not, both
Codex features lose their only approved source and that needs a product call, not a parser change.

## 2026-07-26 — Bounded L1 fallback for automatic Claude keep-awake (ADR 0010 amendment)

Follow-up to the debug pass above, implementing the owner-directed resolution of its open question:
automatic Claude keep-awake must not be wholly dependent on the optional heartbeat hook. Post-v0.3
maintenance work on `master`; **not committed**.

**Behaviour implemented.** `ClaudeActivityState.automationIntent` gains one narrow branch:

1. No visible `claude` process ⇒ `.release`, unchanged and still evaluated first.
2. Heartbeat records present ⇒ **unchanged ADR 0010 semantics** (work events hold within the
   15-minute quiet cap; `Stop`/`StopFailure`/`SessionEnd`/`Notification`/`SessionStart` release).
3. Record list **empty** ⇒ bounded L1 fallback: the existing L1 rule (`evaluate(signals:now:
   recencyThreshold:) == .active`) decides, so a visible process plus `~/.claude` metadata inside
   `defaultRecencyThreshold` (10s) holds, and stale or absent metadata releases.
4. The fallback gets **no** quiet-hold extension — the 15-minute cap stays hook-only, because L1
   cannot separate silent work from a finished turn (ADR 0008). No new duration was introduced; the
   existing L1 window is reused and passed through from `ClaudeActivityProvider.recencyThreshold`.
5. Power only. The Session Radar is untouched and remains heartbeat-only: no session id, title,
   project, state, or row is fabricated from coarse L1. This is the single deliberate divergence
   from `sessionsKeepAwakeIntent`, whose equivalence with `automationIntent` still holds for every
   heartbeat-derived input; both sides are documented in code.

Manual keep-awake semantics are untouched (`effectiveKeepAwake == manualRequested ||
automationRequested`; automation never writes `manualRequested`).

Changes:

- `Sources/VibeMenuCore/ClaudeHeartbeat.swift` — the empty-records L1 fallback branch plus a new
  `l1RecencyThreshold` parameter (defaulted, so existing call sites are unaffected), and the doc
  comment recording why it is scoped this narrowly.
- `Sources/VibeMenuCore/ClaudeActivityProvider.swift` — passes its own injectable `recencyThreshold`
  into `automationIntent` so display and automation share one window.
- `Sources/VibeMenuCore/ClaudeSession.swift` — notes the one deliberate radar/automation divergence
  on `sessionsKeepAwakeIntent`.
- `Tests/VibeMenuCoreTests/ClaudeHeartbeatTests.swift` — the previous no-heartbeat characterization
  test is replaced by six regression tests: fresh L1 + process ⇒ hold; stale/absent metadata ⇒
  release (with the 10s boundary and the explicit absence of any 120s/600s/900s grace); no process ⇒
  release even with fresh metadata; every heartbeat finish event ⇒ release despite fresh L1 metadata;
  heartbeat work events keep the full bounded quiet-hold (300s/900s hold, 901s release) with stale
  L1; and the fallback holds power while `ClaudeSessionStore` stays empty. One neighbouring comment
  (`noHeartbeatsReleases`) was corrected to say bare process presence still never holds.
- `docs/decisions/0010-quiet-work-hold.md` — status marked amended plus an "Amendment (2026-07-26):
  bounded L1 fallback" section with context, the five scope limits, consequences, and the two known
  limits (no silent-gap bridging; leftover heartbeat files from a partially-removed hook suppress the
  fallback until deleted).
- `docs/ARCHITECTURE.md`, `docs/PRODUCT.md`, `docs/AGENT_CONTEXT.md`, `docs/FAQ.md`,
  `docs/INSTALL.md`, `README.md`, `Support/ClaudeHeartbeat/README.md` — wording corrected only where
  it now misstates behaviour: automatic Claude keep-awake degrades to coarse L1 without the hook,
  while per-session Session Radar rows, working/waiting states, **Needs approval**, and the
  quiet-work hold still require it. Two sentences in the heartbeat README's new troubleshooting
  section previously said a broken hook leaves *no* Claude keep-awake owner; that is no longer true
  and now reads "falls back to coarse keep-awake". No fabricated per-session tracking is claimed
  anywhere.

Verification (real output):

- `scripts/test.sh --filter ClaudeAutomationIntentTests` → **25 tests in 1 suite passed**.
- `swift build` → **Build complete!**
- `scripts/test.sh` → **627 tests in 91 suites passed** (622 before).
- `xcodebuild … -configuration Debug -derivedDataPath ./.derivedData build` → **BUILD SUCCEEDED**.
- `git diff --check` → clean.
- Not verified here: live behaviour of the fallback in the running app (no menu-bar popover
  inspection in this environment, and the local hook is currently installed and working, so the
  empty-records path does not occur on this machine). The pure decision is exhaustively unit-tested;
  the owner smoke check is "temporarily remove the hook entries, confirm Claude still shows as a
  keep-awake owner while actively working and releases shortly after it stops, with no Claude rows."

**Next step.** Owner UI smoke check of that fallback path, plus the still-open Codex question from
the previous entry (does Codex Desktop still write rollouts at all?). Nothing is committed.

## 2026-07-27 — Correction: the L1 fallback trigger is heartbeat *staleness*, not an empty file list

Correction to the previous entry's amendment, on `master`; **not committed**. No product-behaviour
question was reopened — this fixes an implementation defect that made the approved behaviour
unreachable in the very situation it was written for.

**Defect.** The fallback branch triggered on `heartbeats.isEmpty`, but
`ClaudeActivityProvider.readHeartbeatRecords` returns *every* decodable file in the sessions
directory, including stale and `SessionEnd` leftovers. A hook that stops writing (script moved or
deleted — the 2026-07-26 incident) almost always leaves its last per-session files behind, so the
list is not empty and the fallback stayed switched off **indefinitely**. The amendment's own "known
limit (b)" recorded this as accepted; on review it is not acceptable, because it removes the fallback
from the exact failure mode that motivated it.

**Behaviour now implemented** (`automationIntent`, in order):

1. No visible `claude` process ⇒ `.release` — unchanged, still first.
2. Reduce to the newest record per session.
3. **Unchanged ADR 0010 hold:** any live, non-ended, work-in-progress session within the 15-minute
   `quietHoldCap` ⇒ `.hold`. The 600–900s band still holds here and never reaches step 4.
4. When nothing holds, check whether any newest record is still inside `heartbeatStaleThreshold`.
5. If one is ⇒ `.release`: heartbeat state stays authoritative. Recent `Stop`, `StopFailure`,
   `SessionEnd`, `Notification`, `PermissionRequest`, and `SessionStart` all count, so a fresh finish
   is never resurrected by the fresh L1 metadata that the finished turn's own transcript write leaves
   behind.
6. Only when **every** newest record is absent or older than `heartbeatStaleThreshold` does the
   existing L1 rule decide: visible process + `~/.claude` metadata inside `l1RecencyThreshold` ⇒
   `.hold`; stale or missing ⇒ `.release`.

Still no quiet-work extension for L1, no new duration (the existing 600s stale window and 10s L1
window are reused), no Session Radar row, and no change to the 15-minute cap or to manual keep-awake.

Changes:

- `Sources/VibeMenuCore/ClaudeHeartbeat.swift` — single-pass rewrite of the decision body per the
  order above, plus a defaulted `heartbeatStaleThreshold` parameter; doc comment rewritten to state
  the staleness trigger, the finish-authority rule, and why the stale window bounds only step 4.
- `Sources/VibeMenuCore/ClaudeActivityProvider.swift` — passes its configured
  `heartbeatStaleThreshold` (alongside `recencyThreshold`) into `automationIntent`.
- `Sources/VibeMenuCore/ClaudeSession.swift` — divergence note on `sessionsKeepAwakeIntent` restated
  in terms of "no recent heartbeat record" rather than "no records".
- `Tests/VibeMenuCoreTests/ClaudeHeartbeatTests.swift` — fallback tests reworked and extended:
  stale leftover *work* files (901s, 3600s) and stale leftover *finish* files (601s, every finish/
  waiting/lifecycle event) no longer suppress the fallback; fresh finish events stay authoritative at
  1s and at the 600s boundary; the 600–900s work band holds; multi-session cases (one fresh finish
  suppresses the fallback, one in-cap work event still holds globally); process-absent releases on
  every path; the exact 10s L1 boundary (9.999/10/10.001) with and without leftovers; radar stays
  empty during an L1-only hold, including one caused by leftovers. Added one integration-style test
  that writes **sanitized fixtures** to a temp directory, reads them via
  `ClaudeActivityProvider.readHeartbeatRecords`, and feeds the result into `automationIntent` — the
  path that made `isEmpty` wrong. No real runtime files are read or written by tests.
- `docs/decisions/0010-quiet-work-hold.md` — amendment heading/date corrected, decision restated as
  the six-step order, "staleness, not file count" recorded as scope limit 1 with the reason the first
  implementation was wrong, and the known limits rewritten (leftovers now merely delay the fallback
  by the stale window; L1 is machine-global/coarse; continuous L1 activity can hold continuously
  because the 10s window rolls forward each tick).
- `docs/ARCHITECTURE.md` (incl. the `automationIntent` signature), `docs/AGENT_CONTEXT.md`,
  `docs/PRODUCT.md`, `docs/FAQ.md`, `docs/INSTALL.md`, `README.md` — "no heartbeat records" wording
  replaced with "no recent heartbeat signal", plus the broken-hook case and the finish-authority rule.
- `Support/ClaudeHeartbeat/README.md` — troubleshooting now says a broken hook falls back once its
  last heartbeat ages out (within ten minutes) and that deleting leftovers is tidy-up, not a
  requirement; the removal step's closing line matches; **new owner smoke-test section "Checking the
  baseline fallback"** describing the real trigger (no heartbeat written in the last ten minutes),
  the `ls -lT` precondition check, an ongoing conversation as the stimulus rather than a silent tool
  call, `pmset -g assertions` while it works, the ~10s release, and no radar row at any point.

The Codex usage-copy work from the previous entries is untouched and still truthful.

Verification (real output):

- `scripts/test.sh --filter 'ClaudeAutomationIntentTests|ClaudeHeartbeatDecodeTests|SessionAggregateEquivalenceTests'`
  → **39 tests in 3 suites passed**.
- `swift build` → **Build complete!**
- `scripts/test.sh` → **633 tests in 91 suites passed** (627 before).
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build`
  → **BUILD SUCCEEDED**.
- `git diff --check` → clean.
- Not verified here: live behaviour in the running app. The app was built but not launched, no menu
  or `pmset` state was observed, and no real Claude settings, hook installation, or heartbeat files
  were modified — the local hook remains installed and working, so the fallback path does not occur
  on this machine. The decision is pure and exhaustively unit-tested, including through the real
  reader over temp fixtures.

**Owner smoke checks still outstanding.** (1) With the hook working, confirm a finished turn still
releases promptly (`On · Claude` → `Off` shortly after `Stop`) — the finish-authority rule. (2) With
the hook's script removed *and its leftover files left in place*, wait past ten minutes, then confirm
Claude appears as a keep-awake owner while a conversation is actively running and releases ~10s after
it goes quiet, with no Claude Session Radar rows — the corrected trigger. Follow
`Support/ClaudeHeartbeat/README.md` → "Checking the baseline fallback". The open Codex question (does
Codex Desktop still write rollouts at all?) is unchanged. Nothing is committed.

## 2026-07-28 — Unified ChatGPT app verified; OpenAI naming with Work/Codex modes (ADR 0017 Amd. 6)

**Goal.** Verify the shipped OpenAI session/usage readers end-to-end against the unified ChatGPT
app's fresh Work and Codex rollouts, then apply the minimal user-visible compatibility update only if
verification succeeded. Claude and Claude-limits behaviour out of scope and untouched.

**Verification first (no repo change).** A throwaway scratch package outside the repo linked
`VibeMenuCore` and ran the shipped readers in-process against the real `~/.codex`, printing
allowlist-only diagnostics (derived state, timings, presence/length of title and folder name, a
SHA-256 digest of the session id, and the `rate_limits` key structure — never titles, folder names,
paths, prompts, responses, tool text, or account fields). Results:

- `CodexSessionReader` returned **both** recent sessions with distinct ids: one from `originator`
  `codex_work_desktop` (Work) and one from `Codex Desktop` (Codex). Both passed the existing
  `isDesktopOriginator` gate, both were non-subagent, and both resolved a safe `thread_name` title
  from the existing session index (resolution confirmed by a boolean + length; no title text printed).
- State derivation was correct: a completed turn read `Done` inside the 15-minute `doneWindow` on the
  first read and `Stale` on a later read, with `showsElapsedTimer == false` and a `.release`
  keep-awake intent in both cases.
- `CodexUsageLimitReader` returned a non-`unavailable` `.rollout` snapshot: exactly **one** `Weekly`
  row (`slot=primary`, `window_minutes=10080`). The `null` `secondary` and every newer unrelated
  non-window sibling (deliberately not enumerated here) were ignored and reach nothing.
- Freshness is **turn-bound**: the newest `token_count` timestamp did not move while the app's usage
  screen was open, and the snapshot aged `fresh` → `stale` ("as of 20m ago") purely with the clock.

**No existing reader bug was found**, so no parser/wiring fix was needed. The update below is
presentation-only.

**Changes.**
- `Sources/VibeMenuCore/CodexSession.swift` — new `CodexSessionMode` (`.work` / `.codex`) derived from
  the originator's anchored `codex_<segment>_desktop` middle segment (`work` ⇒ Work; everything else
  accepted by the gate ⇒ Codex); `CodexSession` stores `mode` and computes `agent` from it, so the raw
  originator never reaches the UI.
- `Sources/VibeMenuCore/CodexSessionReader.swift` — derives the mode at the one place the originator
  is known.
- `Sources/VibeMenuCore/CodexUsageLimit.swift` — menu/Settings copy: shared-allowance + turn-bound
  wording, a Settings source name naming both modes.
- `Sources/VibeMenuCore/Attention.swift` — `AttentionProvider.displayName` (`OpenAI` / `Claude`) for
  notification titles, kept separate from the stable `rawValue` routing key.
- `Sources/VibeMenuApp/VibeMenuApp.swift` — `OpenAI limits` section header; Settings group `OpenAI`
  with `Track OpenAI sessions`, the new source name, and the shared-allowance note; per-mode row pill;
  notification title uses `displayName`; row tooltip reworded.
- `Tests/VibeMenuCoreTests/CodexSessionModeTests.swift` — new sanitized suites for mode derivation,
  both modes as independent accepted sessions, mode-invariant keep-awake, the weekly-only/null-secondary
  reading, unrelated siblings ignored, newest-across-modes wins into one shared section, the copy, the
  routing-key separation, and legacy `codexLimitsHiddenIDs` compatibility.
- `docs/decisions/0017-codex-session-support.md` — Amendment 6. `docs/AGENT_CONTEXT.md`,
  `docs/ARCHITECTURE.md`, `docs/design/settings-ui-research.md` — narrow current-state updates.

**Storage.** No key changed and no migration exists: `showCodexSessions`, `showCodexLimits`,
`codexLimitsHiddenIDs`, `codexLimitsSectionExpanded`, and the duration-derived `fiveHour`/`weekly`
`visibilityID`s are all as before. Verified live against the owner's real persisted
`codexLimitsHiddenIDs = fiveHour`: after the rename that row is still hidden and only `Weekly` shows.

**Commands run.**
- `swift build` → **Build complete!**
- `scripts/test.sh` → **646 tests in 94 suites passed** (633 before).
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build`
  → **BUILD SUCCEEDED**.
- `git diff --check` → clean.
- The freshly built Debug `.app` was relaunched and stayed up; `pmset -g assertions` showed
  `pid <n>(VibeMenu) … "VibeMenu Keep Awake"`, held by Claude activity at the time.

**Verified vs. not verified.** Verified: reader output, derived modes and pills, the single shared
Weekly row, turn-bound freshness, the preference-compatibility result, the exact user-visible strings,
builds and tests, and that the app launches. **Not verified here:** the on-screen popover and Settings
rendering (this menu-bar-only environment does not expose the popover to inspection), and Codex/Work
*sleep ownership in isolation* — Claude activity held the assertion throughout, so a Work- or
Codex-only hold could not be attributed. No real ChatGPT/Claude/Codex/VibeMenu settings were modified;
no network, telemetry, dependency, or new data source was added. Nothing is committed.

**Owner smoke checks outstanding.** (1) Open the menu during a live Work turn and a live Codex turn:
confirm each row appears without restarting VibeMenu, carries the right **Work**/**Codex** pill, and
shows a running timer while `Active`. (2) With Claude idle, confirm sleep prevention lists VibeMenu as
an owner while a Work or Codex turn runs and releases within ~60s of it finishing. (3) Confirm the
menu header reads **OpenAI limits** with one shared row, and Settings shows the **OpenAI** group,
**Track OpenAI sessions**, source **ChatGPT (Work + Codex)**, and the shared-allowance note.

## 2026-07-28 — Final naming: `ChatGPT Work` pill, `ChatGPT limits`, and separate Work/Codex sleep owners

**Task.** Pre-release polish on top of the same working tree as the entry above: make the Session
Radar pill say what it means, stop collapsing the ChatGPT desktop app's two modes into one sleep
owner, finish the user-visible provider naming, and drop the `Experimental` classification from both
limits sections. Presentation and ownership only — no new data source, parsing, network access, or
privacy scope, and session detection / state derivation / activity timing are untouched.

**Problems fixed.**
1. The Work pill read a bare `Work`, which is too vague beside a `Working` state word.
2. Sleep prevention reported one merged `Codex` owner for both modes — and, worse, derived it from a
   whole-list "any session active" intent, so a finishing Work turn could release the assertion while
   a Codex turn was still running (and vice versa). Only one of the two was ever named.
3. Limits/Settings still said `OpenAI` / `OpenAI limits` / `Track OpenAI sessions`.
4. Both limits sections still carried a visible `Experimental` chip.

**Changes.**
- `Sources/VibeMenuCore/CodexSession.swift` — `CodexSessionMode.work.label` is now `ChatGPT Work`
  (`.codex` unchanged). Still derived; the raw originator still never reaches the UI.
- `Sources/VibeMenuCore/AgentKeepAwake.swift` — new `AgentKeepAwakeSource.chatGPTWork` (raw value
  `"work"`, never stored or displayed), and `CodexSessionActivity.automationIntent` is now
  **mode-scoped** (`automationIntent(_:mode:)`). The whole-list entry point was **removed**, not kept
  as a convenience: it was the exact path that collapsed both modes into one owner.
- `Sources/VibeMenuCore/PowerAssertionState.swift` — `PowerAssertionOwner.chatGPTWork`
  (`"ChatGPT Work"`), plus a total `PowerAssertionOwner(source:)` mapping. Owner order is driven by
  `AgentKeepAwakeSource.allCases`, so the label is stable regardless of which source held first:
  Manual → Claude → Codex → ChatGPT Work.
- `Sources/VibeMenuCore/PowerAssertionManager.swift` — `updateChatGPTWorkAutomation(_:)` beside the
  now Codex-only `updateCodexAutomation(_:)`. Still one shared IOKit assertion, still
  `manualRequested || automationRequested`, and manual ownership is unchanged.
- `Sources/VibeMenuCore/CodexUsageLimit.swift` — `sectionTitle` (`ChatGPT limits`),
  `settingsGroupTitle` (`ChatGPT`), and `settingsTrackSessionsTitle` (`Track ChatGPT sessions`) added
  beside the existing copy so the visible strings are unit-tested. Source name unchanged
  (`ChatGPT (Work + Codex)`); every explanatory sentence is unchanged.
- `Sources/VibeMenuApp/VibeMenuApp.swift` — the session callback now refreshes **both** intents from
  the same raw list before recording attention state; the limits header and Settings labels render the
  core constants; both `Text("Experimental")` badges removed; stale "experimental" comments trimmed.
- `Tests/VibeMenuCoreTests/ChatGPTOwnershipTests.swift` — new: pills, per-mode holds, both owners on
  one assertion, either mode finishing keeping the other's hold, release only after both, the
  three-agent and manual-first labels, stable ordering from a shuffled source list, cleanup clearing
  every owner, usage limits still unable to hold, the final naming, the absent `Experimental` badge
  (source-level guard over `VibeMenuApp.swift`, like the existing shim-script test), and preference-key
  compatibility.
- `Tests/VibeMenuCoreTests/AgentKeepAwakeTests.swift`, `CodexSessionModeTests.swift` — updated for the
  mode-scoped intent; the old "mode changes no power behaviour" test became a per-mode isolation test.
- `docs/decisions/0017-codex-session-support.md` (Amendment 6 corrected to the shipped naming +
  separate owners), `docs/AGENT_CONTEXT.md`, `docs/ARCHITECTURE.md`, `docs/PRODUCT.md`,
  `docs/ROADMAP.md`, `docs/design/settings-ui-research.md` — narrow current-state updates.

**Storage.** Unchanged again: `showCodexSessions`, `showCodexLimits`, `codexLimitsHiddenIDs`,
`codexLimitsSectionExpanded`, and the `fiveHour`/`weekly` `visibilityID`s all keep their values, and a
test asserts both the key literals and the decoded row visibility. Internal `Codex*` type names and
`AttentionProvider.codex.rawValue` are untouched.

**Commands run.**
- `swift build` → **Build complete!**
- `scripts/test.sh` → **668 tests in 97 suites passed** (646 before).
- `xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build`
  → **BUILD SUCCEEDED**.
- `git diff --check` → clean.

**Verified vs. not verified.** Verified by tests and build: the pill strings, per-mode hold/release
independence in both directions, one assertion for multiple owners, the exact owner ordering and
label text, cleanup, the inability of usage-limit state to hold, the final naming constants, the
absence of an `Experimental` badge in the app source, and preference compatibility. **Not verified
here:** on-screen rendering of the menu and Settings (this menu-bar-only environment does not expose
the popover to inspection), and live attribution of a Work-only vs. Codex-only hold in the running
app. No app was launched for this entry. No network, telemetry, dependency, or new data source was
added; nothing is committed.

**Left as owner decisions (still say "OpenAI").** `AttentionProvider.codex.displayName` (notification
titles), the session-row hide tooltip, and the body copy inside the limits section
(`No recent OpenAI usage data…`, `never contacts OpenAI`, `share one OpenAI allowance`). These sit
outside the four renames this task scoped, and the last two are literally about OpenAI's servers
rather than the app, so they were left rather than changed unilaterally.

**Owner smoke checks outstanding.** (1) During a live Work turn, confirm the pill reads
**ChatGPT Work** and Sleep prevention reads `On · ChatGPT Work`. (2) With Work and Codex both running,
confirm `On · Codex and ChatGPT Work`, then finish one and confirm the assertion stays held and the
label drops to the survivor only. (3) With Claude also working, confirm
`On · Claude, Codex, and ChatGPT Work`, and with the manual switch on,
`On · Manual, Claude, Codex, and ChatGPT Work`. (4) Confirm the menu header reads **ChatGPT limits**
with no `Experimental` chip, Claude Limits likewise, and Settings shows **ChatGPT** /
**Track ChatGPT sessions** / source **ChatGPT (Work + Codex)** with the shared-allowance note intact.

## 2026-08-01 — Maintenance checkpoint review

Reviewed the complete working-tree diff for the ChatGPT naming and independent Work/Codex ownership
checkpoint. Corrected the Claude heartbeat support README's stale fallback description, and aligned
the architecture notes and Session Radar comments with the shipped ChatGPT Work/Codex labels and
mode-scoped ownership. No product behavior, privacy scope, data source, polling, or energy behavior
was changed during this review.

**Verification.** `swift build` completed successfully; `scripts/test.sh` passed **668 tests in 97
suites**; focused ownership, mode-derivation, copy/compatibility, and Claude-fallback tests passed;
the required `xcodebuild ... -derivedDataPath ./.derivedData build` reported **BUILD SUCCEEDED**;
and `git diff --check` was clean. Verified: sanitized source/test changes contain no personal absolute
paths or live private data, and generated/runtime files remain ignored. Not verified here: live
menu-bar popover/Settings rendering or live Work/Codex attribution in a running app.

**Next step.** Investigate the reported VibeMenu energy usage separately; no energy optimization was
started in this checkpoint.

## 2026-08-01 — Cache unchanged ChatGPT rollouts; poll display-only limits every 30 seconds

Reduced measured ChatGPT monitoring work without changing the five-second session discovery/state
cadence or any sleep-prevention rule. `CodexSessionReader` now keeps a lock-serialized, in-memory
cache keyed by rollout URL plus content mtime, attribute mtime, byte size, and Foundation's stable
file resource identifier. Each entry is only the existing allowlisted `CodexRolloutSummary` (or a
negative nil result for the current unreadable/malformed identity); final session state is re-derived
on every read from that summary, the current clock, and the configured active/idle/done/recency
windows. The current candidate set prunes deletion, horizon expiry, and entries beyond the existing
400-file scan cap. `CodexUsageLimitProvider.refreshInterval` changed from 5 to 30 seconds; its first
fire remains immediate, its test interval remains injectable, and the limits model remains
display-only.

Added sanitized coverage for warm-cache reuse, clock-only state aging, appended activity and
`task_complete`, same-path atomic replacement, truncation, malformed changed files failing closed,
deletion/horizon eviction, Work/Codex identity and per-mode intent, and the 400-entry bound. Limits
tests now pin the 30-second production cadence alongside the unchanged five-second session cadence,
immediate first read, enablement on the next provider cycle, idempotent model start, and complete
timer cancellation. Existing ownership tests continue to prove one shared assertion, independent
Work/Codex/manual ownership, and no usage-limit path into sleep prevention.

**Release measurement (active Codex implementation turn, not a fully idle-agent run).** One Release
VibeMenu process was sampled 61 times at one-second intervals per scenario using `top`; “near zero”
means `%CPU <= 0.1`. The current metadata-only candidate count was 2 rollout files / 2,159,834 bytes
inside the one-hour session horizon and 15 files / 48,873,962 bytes inside the 24-hour limits horizon.

- all optional monitoring off: CPU avg 1.007%, peak 2.5%; POWER avg 1.020, peak 2.5; 26/61 near-zero;
- ChatGPT limits only: CPU avg 1.367%, peak 11.7%; POWER avg 1.380, peak 11.7; 26/61 near-zero;
- ChatGPT sessions only, active turn: CPU avg 2.036%, peak 9.5%; POWER avg 2.056, peak 9.6;
  22/61 near-zero;
- sessions + limits, active turn: CPU avg 2.305%, peak 13.0%; POWER avg 2.326, peak 13.0;
  24/61 near-zero.

Against the supplied earlier Release averages (1.02% / 2.70% / 4.38% / 5.75%), limits-only fell
49.4%, active-turn sessions-only fell 53.5%, and active-turn sessions + limits fell 59.9%; all-off was
effectively unchanged. Earlier peak CPU, POWER, and near-zero counts were not supplied, so those
before/after dimensions cannot be compared honestly. Sanitized cache diagnostics recorded a cold
tick as 1 candidate / 0 hits / 1 reparse, an unchanged warm tick as 1 / 1 / 0, a changed append tick
as 1 / 0 / 1, and the bound as 400 candidates / 400 cached summaries. A 20-second stack sample with
both features enabled showed the remaining hottest ChatGPT work was the required parse of the rollout
that this active turn had just changed (201 samples under `readSessions`, including 93 + 74 in parser
timestamp/JSON work); the unchanged candidate walk was 27 samples and the still-uncached safe title
index read was 20. Claude heartbeat decoding also appeared (14 samples) but was not modified.

**Validation.** `swift build` completed; `scripts/test.sh` passed **682 tests in 98 suites**;
`xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Release
-derivedDataPath ./.derivedData build` reported **BUILD SUCCEEDED**; `git diff --check` was clean.
The modified Release app launched and stayed running. One focused test initially compared ISO-rounded
timestamps for exact equality; it was corrected to a 10 ms tolerance. The first Release launch was
attempted before a complete executable was present; rerunning the requested Release build produced
the app and the launch succeeded. A stack-driven cleanup then removed a redundant per-candidate
`attributesOfItem` call in favor of the resource identifier returned by the discovery stat; the
focused cache suite and Release build passed again afterward.

**Verified vs. not verified.** Verified: cache reuse/invalidation/fail-closed behavior, fresh state
aging, unchanged session cadence, 30-second limits cadence, immediate/provider lifecycle behavior,
mode and ownership invariants, privacy-safe summary-only storage, builds/tests, Release launch, and
the active-turn measurements above. No network, telemetry, new data source, dependency, private API,
preference key, Claude-monitoring logic, or power assertion code changed. The measurement preferences
were restored and the final Release process was relaunched. Not verified: a truly idle-agent session
measurement, on-screen menu/Settings rendering, and a live observed completion-to-assertion release
after this implementation turn ends. Recommended next step: after the owner repeats an idle-agent
baseline, profile Claude monitoring separately; the sample shows it contributes to remaining work,
but this patch deliberately leaves it untouched.
