import Foundation
import Observation

// Observable surface for Codex Desktop session detection (docs/decisions/0017-codex-session-support.md).
//
// Mirrors the Claude usage-limit slice: a thin timer provider gathers the session list from the
// read-only `CodexSessionReading` adapter and republishes it through an `@Observable` model the
// menu reads.
//
// **Feeds sleep prevention (Fix 1).** Originally Codex session detection was display-only. It now also
// contributes to VibeMenu's *shared* keep-awake decision, just like Claude activity: an active Codex
// session holds the automatic assertion via `onSessionsChange` →
// `CodexSessionActivity.automationIntent` → `PowerAssertionModel.updateCodexAutomation`. This is
// deliberately conservative (only `.active` holds; it ages out on its own) and is gated by the opt-in
// `showCodexSessions` preference — with the feature off the provider publishes `[]`, so Codex cannot
// affect sleep at all. Codex **usage limits** remain strictly display-only and never touch the loop.

// MARK: - Provider protocol

/// Observes the Codex session list and reports it. The seam lets the model be driven by a fake in
/// tests with no timer or real files.
public protocol CodexSessionObserving: AnyObject {
    /// The most recently read session list (empty before the first refresh / when disabled).
    var sessions: [CodexSession] { get }

    /// Begin observing. `onSessions` is called on the main queue with the first list, then again
    /// whenever it changes. Calling `start` again re-subscribes.
    func start(onSessions: @escaping @Sendable ([CodexSession]) -> Void)

    /// Stop observing and release the timer.
    func stop()
}

// MARK: - Real provider

/// Coarse periodic refresh that reads the Codex session list via `CodexSessionReading` and publishes
/// it on change. Gated by an injected `isEnabled` closure consulted **before any file access**, so
/// with the feature off (the default) each tick is a single bool check touching no file — matching
/// the opt-in posture of the usage section (docs/decisions/0016) and the Desktop-title resolver
/// (docs/decisions/0014). Idle cost when enabled is one bounded, stat-filtered walk per interval.
///
/// Concurrency: `@unchecked Sendable` — mutable state is guarded by `lock`; the timer fires on a
/// private utility queue and delivers `onSessions` on the main queue.
public final class CodexSessionProvider: CodexSessionObserving, @unchecked Sendable {
    /// Display-only refresh cadence. ~5 s keeps the list current shortly after opening the menu
    /// while staying a coarse, coalesced wakeup doing negligible work (lightweight budget,
    /// docs/decisions/0006).
    public static let refreshInterval: TimeInterval = 5
    public static let refreshLeeway: TimeInterval = 1

    private let reader: CodexSessionReading
    private let isEnabled: @Sendable () -> Bool
    private let queue = DispatchQueue(
        label: "com.kirillchistov.VibeMenu.codex-sessions", qos: .utility
    )
    private let lock = NSLock()
    private var _sessions: [CodexSession] = []
    private var onSessions: (@Sendable ([CodexSession]) -> Void)?
    private var didEmit = false
    private var timer: DispatchSourceTimer?

    public init(
        reader: CodexSessionReading = CodexSessionReader(),
        isEnabled: @escaping @Sendable () -> Bool
    ) {
        self.reader = reader
        self.isEnabled = isEnabled
    }

    public var sessions: [CodexSession] {
        lock.lock(); defer { lock.unlock() }
        return _sessions
    }

    public func start(onSessions: @escaping @Sendable ([CodexSession]) -> Void) {
        stop()
        lock.lock()
        self.onSessions = onSessions
        self.didEmit = false
        lock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: Self.refreshInterval,
            leeway: .milliseconds(Int(Self.refreshLeeway * 1000))
        )
        timer.setEventHandler { [weak self] in self?.refresh() }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        lock.lock()
        onSessions = nil
        lock.unlock()
    }

    deinit { stop() }

    /// One refresh tick: when disabled, publish `[]` without touching the filesystem; when enabled,
    /// read the current sessions. Emits the first value once, then only on change.
    private func refresh() {
        let newSessions = isEnabled() ? reader.readSessions(now: Date()) : []

        lock.lock()
        let shouldEmit = !didEmit || newSessions != _sessions
        didEmit = true
        _sessions = newSessions
        let callback = onSessions
        lock.unlock()

        if shouldEmit, let callback {
            DispatchQueue.main.async { callback(newSessions) }
        }
    }
}

// MARK: - Observable model

/// Observable app-state object that feeds the menu the current Codex session list.
///
/// `@MainActor` because it backs SwiftUI; `@Observable` so the `MenuBarExtra` re-renders when the
/// list changes. Observation is started once at app launch; opening the menu only displays the
/// current list (the view's `TimelineView` re-derives the elapsed labels as time passes).
@MainActor
@Observable
public final class CodexSessionModel {
    /// The current Codex Desktop sessions (empty until the first refresh, or whenever the feature is
    /// off / none are found), most-active-first. This is the **raw** list — it drives the shared
    /// keep-awake decision (docs/decisions/0017, Fix 1) and is *not* filtered by user dismissals, so
    /// hiding a row from the menu never changes whether an active Codex session prevents sleep.
    public private(set) var sessions: [CodexSession]

    /// The list the unified AI Agent menu actually draws: `sessions` minus rows the user manually hid
    /// (docs/decisions/0017, Fix 2). A dismissed row stays out until the session shows newer activity,
    /// at which point it reappears here automatically. Recomputed whenever `sessions` changes or the
    /// user dismisses a row — mirrors `ClaudeActivityModel.visibleSessions`.
    public private(set) var visibleSessions: [CodexSession] = []

    /// User-dismissed Codex rows (pure hide-only registry, keyed on the stable session id). Owned here
    /// because dismissal is a main-actor UI action; the provider is unaware of it. Never persisted — an
    /// app restart clears it.
    @ObservationIgnored private var dismissed = DismissedCodexRegistry()

    @ObservationIgnored private let provider: CodexSessionObserving
    @ObservationIgnored private var isObserving = false
    /// Model-owned visible-turn timer state. The reader remains stateless; this store is what lets
    /// a persistent Codex session reset its displayed clock after Done → newer activity.
    @ObservationIgnored private var turnTimers = CodexSessionTurnStore()

    /// Optional app-lifetime hook for **keep-awake ownership** (docs/decisions/0017, Fix 1): called on
    /// the main actor with the **raw** session list whenever it changes. The app wires this to
    /// `PowerAssertionModel.updateCodexAutomation(_:)` (via `CodexSessionActivity.automationIntent`) so
    /// an active Codex session holds the automatic keep-awake without ever mutating the user's manual
    /// preference. Deliberately fed the raw list, not `visibleSessions`, so hiding a row is display-only.
    @ObservationIgnored public var onSessionsChange: (([CodexSession]) -> Void)?

    public init(provider: CodexSessionObserving) {
        self.provider = provider
        self.sessions = provider.sessions
        self.visibleSessions = dismissed.reconcile(with: provider.sessions)
    }

    /// Start observing. Idempotent, so it is safe to call unconditionally at app launch.
    public func start() {
        guard !isObserving else { return }
        isObserving = true
        provider.start(onSessions: { [weak self] newValue in
            MainActor.assumeIsolated {
                guard let self else { return }
                let timedSessions = self.turnTimers.update(
                    newValue, previousSessions: self.sessions
                )
                self.sessions = timedSessions
                // Re-apply dismissals: hidden rows stay hidden until they show newer activity, and
                // dismissals for pruned sessions are dropped (see `reconcile`).
                self.visibleSessions = self.dismissed.reconcile(with: timedSessions)
                // Feed the raw list into the shared keep-awake decision (display-independent).
                self.onSessionsChange?(timedSessions)
            }
        })
    }

    /// Stop observing. A later `start()` re-subscribes.
    public func stop() {
        isObserving = false
        provider.stop()
    }

    /// Manually hide a Codex session row (docs/decisions/0017, Fix 2). **VibeMenu-only:** removes the
    /// row from `visibleSessions` and nothing more — it does not delete any Codex data, stop the
    /// session, or write any file, and it does **not** change whether the session prevents sleep. The
    /// row reappears on its own once the session shows newer activity. Recomputes `visibleSessions`
    /// immediately so the UI can animate the removal.
    public func dismiss(_ session: CodexSession) {
        dismissed.dismiss(session)
        visibleSessions = dismissed.reconcile(with: sessions)
    }
}
