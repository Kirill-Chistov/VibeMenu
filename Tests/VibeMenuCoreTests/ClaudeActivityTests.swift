import Foundation
import Testing
@testable import VibeMenuCore

// Uses Swift Testing (see AutomationPolicyTests). These tests exercise the pure L1
// detection logic and the observable model with no dependency on a real `claude`
// process or `~/.claude` directory: `ClaudeActivityState.evaluate` is a pure function
// over synthetic (processPresent, mtime) signals, and the model is driven by a fake
// provider. The real filesystem/process adapter (`ClaudeActivityProvider`) is a thin,
// separately-unverified layer by design.

// MARK: - Pure decision table

/// The five required L1 cases plus the documented extra rows.
@Suite("ClaudeActivityState.evaluate")
struct ClaudeActivityEvaluateTests {
    // A fixed "now" and helpers so recency is deterministic (no wall-clock reads).
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func recent() -> Date { now.addingTimeInterval(-5) }    // 5s old ⇒ within 10s
    private func stale() -> Date { now.addingTimeInterval(-300) }   // 5m old ⇒ past 10s

    private func evaluate(process: Bool, mtime: Date?) -> ClaudeActivityState {
        ClaudeActivityState.evaluate(
            signals: ClaudeActivitySignals(
                processPresent: process,
                mostRecentSessionActivity: mtime
            ),
            now: now
        )
    }

    /// 1. No process + no session metadata ⇒ `.notDetected`.
    @Test func noProcessNoMetadataIsNotDetected() {
        #expect(evaluate(process: false, mtime: nil) == .notDetected)
    }

    /// 2. Process present + no session metadata at all ⇒ `.running` (design choice:
    ///    we can see the process but have no activity signal, so we report presence
    ///    without over-claiming "active").
    @Test func processPresentNoMetadataIsRunning() {
        #expect(evaluate(process: true, mtime: nil) == .running)
    }

    /// 3. Process present + recent session metadata ⇒ `.active`.
    @Test func processPresentRecentMetadataIsActive() {
        #expect(evaluate(process: true, mtime: recent()) == .active)
    }

    /// 4. Process present + stale session metadata ⇒ `.idle`.
    @Test func processPresentStaleMetadataIsIdle() {
        #expect(evaluate(process: true, mtime: stale()) == .idle)
    }

    /// 4b. The core finished-reply case: the `claude` process is still alive (waiting for
    ///     input) but the last write is older than the 10s window ⇒ `.idle`, not `.active`.
    ///     Guards the latency fix: process presence alone must not pin the row to `.active`.
    @Test func processPresentActivityOlderThanTenSecondsIsIdle() {
        let fifteenSecondsAgo = now.addingTimeInterval(-15)
        #expect(evaluate(process: true, mtime: fifteenSecondsAgo) == .idle)
    }

    /// 5. No process + recent session metadata ⇒ conservative `.idle` (process
    ///    inspection can miss a short-lived / differently-named host process; fresh
    ///    files mean Claude was active moments ago, but we don't claim a running process).
    @Test func noProcessRecentMetadataIsIdle() {
        #expect(evaluate(process: false, mtime: recent()) == .idle)
    }

    /// Extra: no process + stale metadata ⇒ `.notDetected` (leftover files from past
    ///    sessions must not pin the UI to `.idle` forever).
    @Test func noProcessStaleMetadataIsNotDetected() {
        #expect(evaluate(process: false, mtime: stale()) == .notDetected)
    }

    /// The default recency window is the fast 10s L1 value (was 90s → 20s → 10s). Pinned
    /// explicitly so a change to the constant is a deliberate, visible edit — and so the
    /// finished-reply fall-off latency stays in the intended ~10s range.
    @Test func defaultRecencyThresholdIsTenSeconds() {
        #expect(ClaudeActivityState.defaultRecencyThreshold == 10)
    }

    /// Boundary: mtime exactly at the threshold counts as recent (≤, not <).
    @Test func exactlyThresholdCountsAsRecent() {
        let atThreshold = now.addingTimeInterval(-ClaudeActivityState.defaultRecencyThreshold)
        #expect(evaluate(process: true, mtime: atThreshold) == .active)
    }

    /// Just past the 10s window ⇒ stale: process + slightly-too-old files ⇒ `.idle`,
    /// and no process + slightly-too-old files ⇒ `.notDetected`. Makes the new,
    /// faster active→idle fall-off explicit.
    @Test func justPastThresholdCountsAsStale() {
        let justStale = now.addingTimeInterval(-(ClaudeActivityState.defaultRecencyThreshold + 1))
        #expect(evaluate(process: true, mtime: justStale) == .idle)
        #expect(evaluate(process: false, mtime: justStale) == .notDetected)
    }

    /// Clock skew: a future mtime (negative age) is treated as recent, not stale.
    @Test func futureMtimeCountsAsRecent() {
        let future = now.addingTimeInterval(60)
        #expect(evaluate(process: true, mtime: future) == .active)
        #expect(evaluate(process: false, mtime: future) == .idle)
    }

    /// 7. The logic needs only metadata: `ClaudeActivitySignals` carries a Bool and an
    ///    optional Date — no transcript contents are part of the input at all. This test
    ///    documents that structurally (it constructs signals with only those two fields).
    @Test func decisionUsesOnlyMetadataSignals() {
        let signals = ClaudeActivitySignals(processPresent: true, mostRecentSessionActivity: recent())
        // Reachable purely from metadata; nothing here reads or needs file contents.
        #expect(ClaudeActivityState.evaluate(signals: signals, now: now) == .active)
    }
}

// MARK: - Privacy-safe diagnostics

/// The DEBUG diagnostics summary must expose the raw signals behind a decision (process
/// flag, heartbeat aggregate + age + session count, L1 mtime age, threshold, result) and
/// must never leak paths, session ids, or contents. These L1-fallback cases pass no
/// heartbeats; the heartbeat-populated cases live in `ClaudeHeartbeatTests`.
@Suite("ClaudeActivityDiagnostics")
struct ClaudeActivityDiagnosticsTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func diagnose(process: Bool, mtime: Date?) -> ClaudeActivityDiagnostics {
        ClaudeActivityState.diagnostics(
            heartbeats: [],
            signals: ClaudeActivitySignals(
                processPresent: process,
                mostRecentSessionActivity: mtime
            ),
            now: now
        )
    }

    /// 5. Summary includes the process flag, the (empty) heartbeat fields, the newest L1
    ///    age, the threshold, and the result — e.g.
    ///    `process=true, heartbeat=none age=none sessions=0, newestAge=7s, threshold=10s,
    ///    result=Active`.
    @Test func summaryIncludesProcessAgeThresholdResult() {
        let diag = diagnose(process: true, mtime: now.addingTimeInterval(-7))
        #expect(diag.processPresent == true)
        #expect(diag.heartbeatState == nil)
        #expect(diag.heartbeatAgeSeconds == nil)
        #expect(diag.sessionCount == 0)
        #expect(diag.newestAgeSeconds == 7)
        #expect(diag.thresholdSeconds == 10)
        #expect(diag.result == .active)

        let summary = diag.summary
        #expect(summary.contains("process=true"))
        #expect(summary.contains("heartbeat=none age=none sessions=0"))
        #expect(summary.contains("newestAge=7s"))
        #expect(summary.contains("threshold=10s"))
        #expect(summary.contains("result=Active"))
        #expect(summary == "process=true, heartbeat=none age=none sessions=0, "
            + "newestAge=7s, threshold=10s, result=Active")
    }

    /// 5b. When no session files were observed, the L1 age reads `none` (not a fake 0s),
    ///     and the result is honest for "process, no files" ⇒ `.running`.
    @Test func summaryUsesNoneWhenNoSessionActivity() {
        let diag = diagnose(process: true, mtime: nil)
        #expect(diag.newestAgeSeconds == nil)
        #expect(diag.result == .running)
        #expect(diag.summary.contains("newestAge=none"))
        #expect(diag.summary == "process=true, heartbeat=none age=none sessions=0, "
            + "newestAge=none, threshold=10s, result=Running")
    }

    /// 5c. The finished-reply case is legible in the summary: process alive, files aged
    ///     past the window ⇒ `result=Idle`, so a human reading the row sees *why*.
    @Test func summaryShowsFinishedReplyAgingOutToIdle() {
        let diag = diagnose(process: true, mtime: now.addingTimeInterval(-15))
        #expect(diag.result == .idle)
        #expect(diag.summary.contains("newestAge=15s"))
        #expect(diag.summary.contains("result=Idle"))
    }

    /// 6. The summary carries **no paths and no contents** — only the metadata fields.
    ///    Asserts the absence of any path-like or home-directory substrings for a range of
    ///    input states, so a leak would fail the test.
    @Test func summaryContainsNoPathsOrContents() {
        let cases: [ClaudeActivityDiagnostics] = [
            diagnose(process: true, mtime: now.addingTimeInterval(-3)),
            diagnose(process: false, mtime: now.addingTimeInterval(-3)),
            diagnose(process: true, mtime: nil),
            diagnose(process: false, mtime: nil),
            diagnose(process: true, mtime: now.addingTimeInterval(-300))
        ]
        for diag in cases {
            let summary = diag.summary
            #expect(!summary.contains("/"))
            #expect(!summary.lowercased().contains(".claude"))
            #expect(!summary.lowercased().contains("users"))
            #expect(!summary.lowercased().contains("projects"))
            #expect(!summary.contains(".jsonl"))
        }
    }

    /// The threshold shown in the summary reflects a non-default L1 recency window, so the
    /// diagnostics always report the value actually in effect at runtime.
    @Test func summaryReflectsNonDefaultThreshold() {
        let diag = ClaudeActivityState.diagnostics(
            heartbeats: [],
            signals: ClaudeActivitySignals(processPresent: true, mostRecentSessionActivity: now.addingTimeInterval(-3)),
            now: now,
            l1RecencyThreshold: 25
        )
        #expect(diag.thresholdSeconds == 25)
        #expect(diag.summary.contains("threshold=25s"))
    }
}

// MARK: - Display labels

/// 6. Display labels used by the menu-bar "Claude" row.
@Suite("ClaudeActivityState display labels")
struct ClaudeActivityLabelTests {
    @Test func internalLabelsMatchRawStates() {
        #expect(ClaudeActivityState.unknown.displayName == "Unknown")
        #expect(ClaudeActivityState.notDetected.displayName == "Not detected")
        #expect(ClaudeActivityState.running.displayName == "Running")
        #expect(ClaudeActivityState.active.displayName == "Active")
        #expect(ClaudeActivityState.idle.displayName == "Idle")
        #expect(ClaudeActivityState.waiting.displayName == "Waiting")
    }

    @Test func menuLabelsAreSimplified() {
        #expect(ClaudeActivityState.active.menuDisplayName == "Active")
        #expect(ClaudeActivityState.notDetected.menuDisplayName == "Not detected")
        #expect(ClaudeActivityState.unknown.menuDisplayName == "Not detected")

        for state in [ClaudeActivityState.waiting, .running, .idle] {
            #expect(state.menuDisplayName == "Idle")
        }
    }
}

// MARK: - Observable model

/// A fake provider so model/state-update behavior is testable without a real process
/// or `~/.claude` directory.
private final class FakeClaudeProvider: ClaudeActivityObserving {
    var state: ClaudeActivityState
    private var onChange: (@Sendable (ClaudeActivityState) -> Void)?
    private var onAutomation: (@Sendable (ClaudeAutomationIntent) -> Void)?
    private var onSessions: (@Sendable ([ClaudeSession]) -> Void)?
    private var onDiagnostics: (@Sendable (String) -> Void)?

    /// The last diagnostics summary the model was handed (if any), so tests can assert the
    /// DEBUG diagnostics channel is wired without a real provider.
    private(set) var lastDiagnostics: String?

    /// The initial keep-awake intent the fake emits on `start()`.
    private let initialIntent: ClaudeAutomationIntent

    /// The initial Session Radar list the fake emits on `start()`.
    private let initialSessions: [ClaudeSession]

    /// How many times `start()` / `stop()` were invoked, so tests can prove the model's
    /// idempotency (repeated `start()` must not re-subscribe / spin up a duplicate timer).
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(
        initial: ClaudeActivityState,
        initialIntent: ClaudeAutomationIntent = .release,
        initialSessions: [ClaudeSession] = []
    ) {
        self.state = initial
        self.initialIntent = initialIntent
        self.initialSessions = initialSessions
    }

    func start(
        onChange: @escaping @Sendable (ClaudeActivityState) -> Void,
        onAutomation: @escaping @Sendable (ClaudeAutomationIntent) -> Void,
        onSessions: @escaping @Sendable ([ClaudeSession]) -> Void,
        onDiagnostics: @escaping @Sendable (String) -> Void
    ) {
        startCount += 1
        self.onChange = onChange
        self.onAutomation = onAutomation
        self.onSessions = onSessions
        self.onDiagnostics = onDiagnostics
        onChange(state)
        onAutomation(initialIntent)
        onSessions(initialSessions)
    }

    func stop() {
        stopCount += 1
        onChange = nil
        onAutomation = nil
        onSessions = nil
        onDiagnostics = nil
    }

    /// Simulate a detection-state change.
    func emit(_ value: ClaudeActivityState) {
        state = value
        onChange?(value)
    }

    /// Simulate the provider pushing a new keep-awake intent (independent of display state).
    func emitAutomation(_ intent: ClaudeAutomationIntent) {
        onAutomation?(intent)
    }

    /// Simulate the provider pushing a new Session Radar list.
    func emitSessions(_ sessions: [ClaudeSession]) {
        onSessions?(sessions)
    }

    /// Simulate the provider pushing a diagnostics summary (DEBUG channel).
    func emitDiagnostics(_ summary: String) {
        lastDiagnostics = summary
        onDiagnostics?(summary)
    }
}

/// The observable model reflects the provider's value and updates on change. Marked
/// `@MainActor` because `ClaudeActivityModel` is main-actor isolated.
@Suite("ClaudeActivityModel", .serialized)
@MainActor
struct ClaudeActivityModelTests {

    @Test func exposesInitialValueFromProvider() {
        let model = ClaudeActivityModel(provider: FakeClaudeProvider(initial: .unknown))
        #expect(model.state == .unknown)
        #expect(model.displayLabel == "Not detected")
    }

    @Test func updatesWhenProviderEmitsChange() {
        let provider = FakeClaudeProvider(initial: .notDetected)
        let model = ClaudeActivityModel(provider: provider)
        model.start()
        #expect(model.state == .notDetected)
        #expect(model.displayLabel == "Not detected")

        provider.emit(.active)
        #expect(model.state == .active)
        #expect(model.displayLabel == "Active")

        provider.emit(.idle)
        #expect(model.displayLabel == "Idle")

        provider.emit(.waiting)
        #expect(model.displayLabel == "Idle")

        provider.emit(.running)
        #expect(model.displayLabel == "Idle")
    }

    @Test func callsStateChangeHookAfterUpdates() {
        let provider = FakeClaudeProvider(initial: .notDetected)
        let model = ClaudeActivityModel(provider: provider)
        var observed: [ClaudeActivityState] = []
        model.onStateChange = { observed.append($0) }

        model.start()
        provider.emit(.active)
        provider.emit(.waiting)

        #expect(observed == [.notDetected, .active, .waiting])
    }

    /// The model republishes the provider's keep-awake intent on its own `automationIntent`
    /// property and fires `onAutomationChange` — the app wires this to the power model. The
    /// intent stream is independent of the display-state stream.
    @Test func republishesAutomationIntentIndependentlyOfState() {
        let provider = FakeClaudeProvider(initial: .active, initialIntent: .hold)
        let model = ClaudeActivityModel(provider: provider)
        var observed: [ClaudeAutomationIntent] = []
        model.onAutomationChange = { observed.append($0) }

        model.start()
        #expect(model.automationIntent == .hold)   // initial intent from provider

        // Display falls back to Idle while the automation intent keeps holding (the quiet
        // hold): the two streams move independently.
        provider.emit(.waiting)
        #expect(model.automationIntent == .hold)

        // Then the cap elapses: intent releases even though the display is unchanged.
        provider.emitAutomation(.release)
        #expect(model.automationIntent == .release)

        #expect(observed == [.hold, .release])
    }

    /// The model republishes the provider's Session Radar list on its `sessions` property.
    /// The list is a display-only view and is independent of the display state / intent
    /// streams.
    @Test func republishesSessionsFromProvider() {
        let now = Date(timeIntervalSince1970: 5_000_000)
        let seed = ClaudeSession(
            id: "seed", state: .working, event: .preToolUse, startedAt: now, lastEventAt: now
        )
        let provider = FakeClaudeProvider(initial: .active, initialSessions: [seed])
        let model = ClaudeActivityModel(provider: provider)
        #expect(model.sessions.isEmpty)   // nothing pushed until start()

        model.start()
        #expect(model.sessions == [seed])

        let updated = [
            ClaudeSession(id: "a", state: .done, event: .stop, startedAt: now, lastEventAt: now),
            ClaudeSession(id: "b", state: .working, event: .postToolUse, startedAt: now, lastEventAt: now)
        ]
        provider.emitSessions(updated)
        #expect(model.sessions == updated)

        provider.emitSessions([])
        #expect(model.sessions.isEmpty)
    }

    @Test func exposesDiagnosticsSummaryFromProvider() {
        let provider = FakeClaudeProvider(initial: .notDetected)
        let model = ClaudeActivityModel(provider: provider)
        #expect(model.debugSummary == nil)   // nothing pushed yet

        model.start()
        provider.emitDiagnostics("process=true, newestAge=7s, threshold=10s, result=Active")
        #expect(model.debugSummary == "process=true, newestAge=7s, threshold=10s, result=Active")
    }

    /// `start()` is idempotent: repeated calls (e.g. app launch plus any later re-entry)
    /// must subscribe the provider exactly once, so the provider never ends up with a
    /// duplicate timer. This backs the move of Claude observation to app-launch time.
    @Test func startIsIdempotent() {
        let provider = FakeClaudeProvider(initial: .notDetected)
        let model = ClaudeActivityModel(provider: provider)

        model.start()
        model.start()
        model.start()
        #expect(provider.startCount == 1)
    }

    /// After `stop()`, a later `start()` re-subscribes (start → stop → start ⇒ two starts),
    /// so termination cleanup followed by a fresh launch still works.
    @Test func startAfterStopResubscribes() {
        let provider = FakeClaudeProvider(initial: .notDetected)
        let model = ClaudeActivityModel(provider: provider)

        model.start()
        model.start()          // idempotent no-op
        #expect(provider.startCount == 1)

        model.stop()
        #expect(provider.stopCount == 1)

        model.start()          // re-subscribes after stop
        #expect(provider.startCount == 2)
    }
}
