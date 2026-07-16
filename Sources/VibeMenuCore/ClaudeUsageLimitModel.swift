import Foundation
import Observation

// Observable surface for the Claude usage-limit section (docs/decisions/0016-claude-usage-limits.md).
//
// Mirrors the Claude-detection slice: a thin timer provider gathers the snapshot from the
// read-only file adapter and republishes it through an `@Observable` model the menu reads.
// Display-only — unlike detection it never touches the keep-awake automation loop.

// MARK: - Provider protocol

/// Observes the usage-limit file and reports snapshots. The seam lets the model be driven by a
/// fake in tests with no timer or real file.
public protocol ClaudeUsageLimitObserving: AnyObject {
    /// The most recently read snapshot (`.unavailable` before the first refresh).
    var snapshot: ClaudeUsageLimitSnapshot { get }

    /// Begin observing. `onSnapshot` is called on the main queue with the first snapshot, then
    /// again whenever it changes. Calling `start` again re-subscribes.
    func start(onSnapshot: @escaping @Sendable (ClaudeUsageLimitSnapshot) -> Void)

    /// Stop observing and release the timer.
    func stop()
}

// MARK: - Real provider

/// Coarse periodic refresh that reads VibeMenu's usage file via `ClaudeUsageLimitReading` and
/// publishes the snapshot on change. Gated by an injected `isEnabled` closure consulted **before
/// any file access**, so with the feature off (the default) each tick is a single bool check and
/// touches no file — matching the "off ⇒ zero work" posture of the opt-in Desktop-title resolver
/// (docs/decisions/0014). Idle cost when enabled is one tiny file read per interval.
///
/// Concurrency: `@unchecked Sendable` — mutable state is guarded by `lock`; the timer fires on a
/// private utility queue and delivers `onSnapshot` on the main queue.
public final class ClaudeUsageLimitProvider: ClaudeUsageLimitObserving, @unchecked Sendable {
    /// Display-only refresh cadence. The file changes at most once per assistant message; ~5 s
    /// keeps the section current shortly after opening the menu while staying a coarse, coalesced
    /// wakeup doing negligible work (lightweight budget, docs/decisions/0006).
    public static let refreshInterval: TimeInterval = 5
    public static let refreshLeeway: TimeInterval = 1

    private let reader: ClaudeUsageLimitReading
    private let isEnabled: @Sendable () -> Bool
    private let queue = DispatchQueue(
        label: "com.kirillchistov.VibeMenu.claude-usage", qos: .utility
    )
    private let lock = NSLock()
    private var _snapshot: ClaudeUsageLimitSnapshot = .unavailable
    private var onSnapshot: (@Sendable (ClaudeUsageLimitSnapshot) -> Void)?
    private var didEmit = false
    private var timer: DispatchSourceTimer?

    public init(
        reader: ClaudeUsageLimitReading = FileClaudeUsageLimitReader(),
        isEnabled: @escaping @Sendable () -> Bool
    ) {
        self.reader = reader
        self.isEnabled = isEnabled
    }

    public var snapshot: ClaudeUsageLimitSnapshot {
        lock.lock(); defer { lock.unlock() }
        return _snapshot
    }

    public func start(onSnapshot: @escaping @Sendable (ClaudeUsageLimitSnapshot) -> Void) {
        stop()
        lock.lock()
        self.onSnapshot = onSnapshot
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
        onSnapshot = nil
        lock.unlock()
    }

    deinit { stop() }

    /// One refresh tick: when disabled, publish `.unavailable` without touching the file; when
    /// enabled, read the snapshot. Emits the first value once, then only on change.
    private func refresh() {
        let newSnapshot = isEnabled() ? reader.readSnapshot() : .unavailable

        lock.lock()
        let shouldEmit = !didEmit || newSnapshot != _snapshot
        didEmit = true
        _snapshot = newSnapshot
        let callback = onSnapshot
        lock.unlock()

        if shouldEmit, let callback {
            DispatchQueue.main.async { callback(newSnapshot) }
        }
    }
}

// MARK: - Observable model

/// Observable app-state object that feeds the menu the current usage-limit snapshot.
///
/// `@MainActor` because it backs SwiftUI; `@Observable` so the `MenuBarExtra` re-renders when the
/// snapshot changes. Observation is started once at app launch; opening the menu only displays the
/// current snapshot (the view's `TimelineView` re-derives the reset countdowns + staleness from
/// the absolute timestamps as time passes, so an unchanged snapshot still ticks correctly).
@MainActor
@Observable
public final class ClaudeUsageLimitModel {
    /// The current snapshot (`.unavailable` until the first refresh arrives, or whenever the
    /// feature is off / no data exists).
    public private(set) var snapshot: ClaudeUsageLimitSnapshot

    @ObservationIgnored private let provider: ClaudeUsageLimitObserving
    @ObservationIgnored private var isObserving = false

    public init(provider: ClaudeUsageLimitObserving) {
        self.provider = provider
        self.snapshot = provider.snapshot
    }

    /// Start observing. Idempotent, so it is safe to call unconditionally at app launch.
    public func start() {
        guard !isObserving else { return }
        isObserving = true
        provider.start(onSnapshot: { [weak self] newValue in
            MainActor.assumeIsolated {
                self?.snapshot = newValue
            }
        })
    }

    /// Stop observing. A later `start()` re-subscribes.
    public func stop() {
        isObserving = false
        provider.stop()
    }
}
