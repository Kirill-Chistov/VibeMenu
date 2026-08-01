import Foundation
import IOKit.pwr_mgt
import os

// Sleep prevention ("Keep Awake"), v0.1 slice 3 (docs/decisions/0005-v0-1-scope.md).
//
// This wires a *real* macOS power assertion behind the same kind of injectable seam
// the thermal slice uses (see ThermalStatusProvider.swift): a tiny syscall adapter
// (`PowerAssertionCreating`) is wrapped by a manager (`SystemPowerAssertionManager`)
// that owns the idempotency + state + error handling, which in turn is republished by
// a `@MainActor @Observable` `PowerAssertionModel` for the menu-bar UI.
//
// Ownership model: the observable model keeps the user's manual preference separate from the
// temporary **agent** automation request. The automation request is itself the OR of every holding
// agent (Claude, Codex-mode, and ChatGPT Work-mode session activity — docs/decisions/0017, Fix 1 and
// Amendment 6). Only the effective OR of manual and automation is applied to IOKit:
// `manualRequested || automationRequested`, and it still creates exactly one shared assertion.
//
// Scope (hard limits — AGENTS.md §9, docs/SECURITY.md):
//   * Prevents *idle system sleep only*, while the lid is open.
//   * Public, documented, sandbox-tolerable, non-root APIs only:
//     `IOPMAssertionCreateWithName` / `IOPMAssertionRelease` with
//     `kIOPMAssertPreventUserIdleSystemSleep`.
//   * NOT clamshell / lid-closed. NOT `pmset disablesleep`. No `caffeinate`
//     subprocess, no privileged helper, no root, no private APIs, no SMC/IOReport.
//   * No timer, no polling loop (docs/decisions/0006-lightweight-resource-budget.md):
//     an assertion is a passive kernel flag held until released.

// MARK: - Low-level syscall seam

/// The minimal surface over the IOKit power-assertion syscalls, isolated so the
/// manager's idempotency/state logic can be unit-tested with a spy — without ever
/// creating a real system assertion in tests.
///
/// `create` returns an opaque assertion id on success, or `nil` on failure (the
/// caller must treat `nil` as "no assertion is held").
///
/// `release` returns `true` on success and `false` on failure, so the manager can
/// keep holding the id (and log) rather than silently forgetting an assertion the
/// kernel still considers live. A `Bool` keeps this seam free of IOKit types, just
/// like `create`'s `UInt32?`.
public protocol PowerAssertionCreating: AnyObject {
    func create(name: String) -> UInt32?
    @discardableResult
    func release(_ id: UInt32) -> Bool
}

/// Real, public-API backend: `IOPMAssertionCreateWithName` /
/// `IOPMAssertionRelease` with `kIOPMAssertPreventUserIdleSystemSleep`.
///
/// These are public, documented IOKit power-management APIs — no entitlement, no
/// root, sandbox-tolerable, and stable across Apple Silicon generations
/// (docs/ARCHITECTURE.md "Public-API preference"). The held assertion mirrors what
/// `pmset -g assertions` reports.
public final class IOKitPowerAssertion: PowerAssertionCreating {
    public init() {}

    public func create(name: String) -> UInt32? {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &id
        )
        guard result == kIOReturnSuccess else { return nil }
        return id
    }

    @discardableResult
    public func release(_ id: UInt32) -> Bool {
        // Report success/failure so the manager keeps the id (and logs) on failure
        // rather than dropping an assertion the kernel still holds.
        return IOPMAssertionRelease(id) == kIOReturnSuccess
    }
}

// MARK: - Manager

/// Manages a single sleep-prevention assertion. `preventIdleSleep()` / `allowSleep()`
/// are idempotent and never throw: at most one assertion is ever held, and a failed
/// creation is exposed as `.acquisitionFailed` while remaining fail-closed.
public protocol PowerAsserting: AnyObject {
    var state: PowerAssertionState { get }
    /// Request prevention of idle *system* sleep (lid open). Idempotent — calling it
    /// while already active is a no-op and does not create a second assertion.
    func preventIdleSleep()
    /// Release any held assertion. Idempotent and safe to call when already inactive.
    func allowSleep()
}

/// Real manager over a `PowerAssertionCreating` backend. Holds at most one assertion;
/// `state` is derived from whether an id is currently held, so it can never drift out
/// of sync with reality.
///
/// Concurrency: this type is **not** internally synchronized. It is intended to be
/// driven through the `@MainActor` `PowerAssertionModel` (the only caller today), so
/// all access is main-actor-bound and serialized in practice. If a future automation
/// path calls it off the main actor, serialize access (or actor-isolate the manager)
/// first — do not call `preventIdleSleep()` / `allowSleep()` concurrently as-is.
public final class SystemPowerAssertionManager: PowerAsserting {
    /// Name shown for the assertion in `pmset -g assertions`.
    public static let defaultAssertionName = "VibeMenu Keep Awake"

    private let backend: PowerAssertionCreating
    private let assertionName: String
    private let log = Logger(subsystem: "com.kirillchistov.VibeMenu", category: "power")

    /// The id of the currently held assertion, or `nil` when none is held.
    private var assertionID: UInt32?
    /// Whether the most recent requested acquisition failed. This is cleared when
    /// the request is removed or a later acquisition succeeds.
    private var acquisitionFailed = false

    public init(
        backend: PowerAssertionCreating,
        assertionName: String = SystemPowerAssertionManager.defaultAssertionName
    ) {
        self.backend = backend
        self.assertionName = assertionName
    }

    /// Convenience: the real IOKit-backed manager used by the app.
    public convenience init() {
        self.init(backend: IOKitPowerAssertion())
    }

    public var state: PowerAssertionState {
        if assertionID != nil { return .preventingIdleSleep }
        return acquisitionFailed ? .acquisitionFailed : .inactive
    }

    public func preventIdleSleep() {
        guard assertionID == nil else { return } // already holding one — idempotent
        guard let id = backend.create(name: assertionName) else {
            // Failure path: stay fail-closed, do not crash, but expose the distinction
            // between no request and an unsuccessful requested acquisition.
            acquisitionFailed = true
            // No transcript content or project paths here (docs/SECURITY.md).
            log.error("Failed to create sleep-prevention assertion; staying fail-closed.")
            return
        }
        acquisitionFailed = false
        assertionID = id
    }

    public func allowSleep() {
        guard let id = assertionID else {
            acquisitionFailed = false
            return
        } // nothing held — idempotent
        guard backend.release(id) else {
            // Release failed: keep holding the id so a later retry can free it, and
            // stay `.preventingIdleSleep` (state is derived from `assertionID`) so
            // the UI does not falsely claim the assertion is gone. Log locally only —
            // no transcript content or project paths (docs/SECURITY.md).
            log.error("Failed to release sleep-prevention assertion; still holding it.")
            return
        }
        acquisitionFailed = false
        assertionID = nil
    }

    deinit {
        // Backstop cleanup: never leak an assertion if the manager is torn down.
        // Best-effort on the teardown path — nothing further to retry against here.
        if let id = assertionID {
            backend.release(id)
        }
    }
}

// MARK: - Observable app model

/// `@MainActor @Observable` surface the menu-bar UI binds to. Owns no low-level system
/// knowledge itself — it drives a `PowerAsserting` manager (injected) and republishes
/// its `state` so the `MenuBarExtra` re-renders on manual or automation changes.
///
/// Mirrors the thermal slice's `ThermalStatusModel` shape: low-level adapter stays out
/// of the observable surface, and tests can drive it with a spy-backed manager.
@MainActor
@Observable
public final class PowerAssertionModel {
    /// Whether VibeMenu is currently holding a sleep-prevention assertion.
    public private(set) var state: PowerAssertionState

    /// The user's long-term manual preference. This is what the menu toggle displays.
    public private(set) var manualRequested: Bool

    /// Temporary automation request owned by **agent activity**. `true` whenever *any* watched agent
    /// (Claude and/or Codex) is currently holding — the OR of `holdingSources`. This does not mutate
    /// `manualRequested`.
    public private(set) var automationRequested: Bool

    /// The set of agents currently requesting a keep-awake hold (docs/decisions/0017, Fix 1). Claude,
    /// Codex, and ChatGPT Work feed this independently through `updateClaudeAutomation`,
    /// `updateCodexAutomation`, and `updateChatGPTWorkAutomation`; the effective `automationRequested`
    /// is simply "this set is non-empty", so any one agent working holds the assertion and only *all*
    /// of them releasing drops it. It remains private; the UI gets the stable read-only
    /// `activeHoldingSources` projection below.
    private var holdingSources: Set<AgentKeepAwakeSource> = []

    @ObservationIgnored private let manager: PowerAsserting

    public init(manager: PowerAsserting) {
        self.manager = manager
        self.state = manager.state
        self.manualRequested = manager.state == .preventingIdleSleep
        self.automationRequested = false
    }

    /// The effective assertion request applied to the power manager.
    public var effectiveIsActive: Bool { manualRequested || automationRequested }

    /// Backward-compatible alias for the effective assertion state.
    public var isActive: Bool { state == .preventingIdleSleep }

    /// Active automation owners in stable product order (Claude, then Codex, then ChatGPT Work). The
    /// mutable ownership set stays private so callers cannot alter the power decision.
    public var activeHoldingSources: [AgentKeepAwakeSource] {
        AgentKeepAwakeSource.allCases.filter { holdingSources.contains($0) }
    }

    /// Pure, honest presentation state for the menu's status line.
    public var statusPresentation: PowerAssertionPresentationState {
        PowerAssertionPresentationState(
            assertionState: state,
            manualRequested: manualRequested,
            automationSources: activeHoldingSources
        )
    }

    /// Compact status text for the menu's secondary Sleep prevention line.
    public var statusLabel: String { statusPresentation.text }

    /// Whether the menu's manual switch should appear on. This intentionally ignores the
    /// temporary automation state.
    public var manualToggleIsOn: Bool { manualRequested }

    /// UI label for the "Sleep prevention" row: "Active" or "Inactive".
    public var displayLabel: String {
        switch state {
        case .inactive: "Inactive"
        case .preventingIdleSleep: "Active"
        case .acquisitionFailed: "Couldn’t enable"
        }
    }

    /// Turn manual keep-awake on. Updates only the manual preference, then applies the
    /// effective manual-or-automation assertion state. Idempotent.
    public func enable() {
        setManualRequested(true)
    }

    /// Turn manual keep-awake off. Updates only the manual preference, then applies the
    /// effective manual-or-automation assertion state. Idempotent.
    public func disable() {
        setManualRequested(false)
    }

    /// Flip the manual preference (menu control).
    public func toggle() {
        setManualRequested(!manualRequested)
    }

    /// Set the user's manual preference without touching automation ownership.
    public func setManualRequested(_ requested: Bool) {
        manualRequested = requested
        applyEffectiveRequest()
    }

    /// Feed a keep-awake **automation intent** from a specific agent into the shared automation owner
    /// (docs/decisions/0017, Fix 1). `.hold` records that agent as holding; `.release` drops it. The
    /// effective automation request is the OR of all holding agents, so Claude and Codex contribute
    /// independently and the assertion is held while *either* is working and dropped only when *all*
    /// release.
    ///
    /// It **never** mutates `manualRequested`: the effective assertion stays
    /// `manualRequested || automationRequested`, so manual keep-awake always wins and a later
    /// automation release cannot turn the user's manual switch off.
    public func updateAgentAutomation(_ source: AgentKeepAwakeSource, intent: ClaudeAutomationIntent) {
        if intent == .hold {
            holdingSources.insert(source)
        } else {
            holdingSources.remove(source)
        }
        automationRequested = !holdingSources.isEmpty
        applyEffectiveRequest()
    }

    /// Feed the keep-awake **automation intent** from Claude detection (v0.1.1).
    ///
    /// This is the automation entry point the app wires to Claude detection: `.hold`
    /// requests sleep prevention, `.release` drops Claude's request. Crucially it is
    /// driven by `ClaudeActivityState.automationIntent(...)`, which holds through a long
    /// silent tool/subagent phase (up to the bounded cap) instead of releasing the moment an
    /// active heartbeat ages out of the display window (docs/decisions/0010).
    ///
    /// A thin wrapper over `updateAgentAutomation(.claude, …)` — Claude's behaviour is exactly as
    /// before; it is now just one of several possible holding sources.
    public func updateClaudeAutomation(_ intent: ClaudeAutomationIntent) {
        updateAgentAutomation(.claude, intent: intent)
    }

    /// Feed the keep-awake **automation intent** from **Codex**-mode session detection
    /// (docs/decisions/0017, Fix 1). `.hold` (an active Codex-mode session, per
    /// `CodexSessionActivity.automationIntent(_:mode:)`) requests sleep prevention; `.release` drops
    /// only Codex's request. Like Claude it never mutates `manualRequested`, and it holds only
    /// *session activity* — never usage limits, which stay display-only.
    ///
    /// This is scoped to `.codex` alone: ChatGPT Work has its own entry point below, so a Codex turn
    /// finishing can never release a hold that a live Work turn still needs.
    public func updateCodexAutomation(_ intent: ClaudeAutomationIntent) {
        updateAgentAutomation(.codex, intent: intent)
    }

    /// Feed the keep-awake **automation intent** from **ChatGPT Work**-mode session detection
    /// (docs/decisions/0017, Amendment 6). The exact mirror of `updateCodexAutomation`, on its own
    /// independent source: `.hold` while a Work-mode session is active, `.release` otherwise, and
    /// neither mode's release touches the other's hold. Never mutates `manualRequested`.
    public func updateChatGPTWorkAutomation(_ intent: ClaudeAutomationIntent) {
        updateAgentAutomation(.chatGPTWork, intent: intent)
    }

    /// Feed a Claude activity **display** state into the automation owner.
    ///
    /// Retained as a simpler state-only entry point (and for tests). `.active` requests
    /// sleep prevention; every other state releases automation. The app itself drives
    /// automation through `updateClaudeAutomation(_:)` instead, because the display state
    /// alone cannot distinguish a genuine finish (`Stop` ⇒ `.waiting`) from an aged-out
    /// active heartbeat that is still quietly working (also `.waiting`) — the exact
    /// collapse v0.1.1 fixes (docs/decisions/0010).
    public func updateClaudeActivity(_ claudeState: ClaudeActivityState) {
        updateAgentAutomation(.claude, intent: claudeState == .active ? .hold : .release)
    }

    /// Release any held assertion on the app teardown path (Quit). Idempotent. Clears every agent
    /// hold so no source can pin the assertion across teardown.
    public func cleanup() {
        holdingSources.removeAll()
        automationRequested = false
        manager.allowSleep()
        state = manager.state
    }

    private func applyEffectiveRequest() {
        if effectiveIsActive {
            manager.preventIdleSleep()
        } else {
            manager.allowSleep()
        }
        state = manager.state
    }
}
