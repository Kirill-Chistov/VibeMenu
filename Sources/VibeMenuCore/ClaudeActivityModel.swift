import Foundation
import Observation

/// Observable app-state object that feeds the menu-bar UI the live Claude-detection
/// (L1 + L2) state.
///
/// Mirrors `ThermalStatusModel`: it owns no system knowledge itself — it takes a
/// `ClaudeActivityObserving` via dependency injection and republishes its values as
/// observable state, so the low-level heartbeat/process/filesystem adapter stays separate
/// from the observable surface and tests can drive state changes with a fake provider.
///
/// Observation is started once at app launch (see `VibeMenuApp`); opening the menu only
/// displays the current state. The model can notify an app-lifetime coordinator when the
/// state changes, so Claude `.active` can temporarily request sleep prevention without
/// mutating the user's manual preference.
///
/// `@MainActor` because it backs SwiftUI; `@Observable` so the `MenuBarExtra` re-renders
/// when `state` changes.
@MainActor
@Observable
public final class ClaudeActivityModel {
    /// Current Claude detection state (`.unknown` until the first refresh arrives).
    public private(set) var state: ClaudeActivityState

    /// Current keep-awake **automation intent** (`.release` until the first refresh
    /// arrives). Deliberately separate from `state`: the display may read Idle while this
    /// still reads `.hold` during a long silent tool/subagent phase (docs/decisions/0010).
    public private(set) var automationIntent: ClaudeAutomationIntent = .release

    /// The raw Session Radar list from the provider: one entry per live Claude Code session,
    /// sorted attention-first (docs/decisions/0011-session-radar.md). A display-only view of the
    /// same heartbeat records — it never drives the power loop. Empty until the first refresh
    /// arrives, and whenever no live sessions are detected. The UI reads `visibleSessions`, which
    /// is this list with user-dismissed rows removed.
    public private(set) var sessions: [ClaudeSession] = []

    /// The Session Radar list the UI actually draws: `sessions` minus rows the user manually
    /// hid (docs/decisions/0013-session-title-and-dismiss.md). A dismissed row stays out until
    /// the session emits a newer event, at which point it reappears here automatically. Recomputed
    /// whenever `sessions` changes or the user dismisses a row.
    public private(set) var visibleSessions: [ClaudeSession] = []

    /// User-dismissed rows (pure hide-only registry). Owned here because dismissal is a main-actor
    /// UI action; the provider is unaware of it. Never persisted — an app restart clears it.
    @ObservationIgnored private var dismissed = DismissedSessionRegistry()

    /// Latest privacy-safe, path-free diagnostic summary (metadata only; see
    /// `ClaudeActivityDiagnostics.summary`). Fed **only in DEBUG builds** — the provider
    /// never delivers diagnostics in Release, so this stays `nil` there. Surfaced in a
    /// DEBUG-only diagnostics plumbing to reveal *why* detection chose a state (e.g. the
    /// L2 heartbeat aggregate, or an L1 finished-reply aging out of `active`). Never affects
    /// the displayed state or any decision.
    public private(set) var debugSummary: String?

    @ObservationIgnored private let provider: ClaudeActivityObserving

    /// Whether observation is already running, so repeated `start()` calls (e.g. app launch
    /// plus any later re-entry) do not re-subscribe or spin up a duplicate provider timer.
    @ObservationIgnored private var isObserving = false

    /// Optional app-lifetime hook for observing display-state changes. Called on the main
    /// actor after `state` is updated.
    @ObservationIgnored public var onStateChange: ((ClaudeActivityState) -> Void)?

    /// Optional app-lifetime hook for **automation ownership**: called on the main actor
    /// after `automationIntent` is updated. The app wires this to
    /// `PowerAssertionModel.updateClaudeAutomation(_:)` so Claude activity holds/releases the
    /// automatic keep-awake without ever mutating the user's manual preference.
    @ObservationIgnored public var onAutomationChange: ((ClaudeAutomationIntent) -> Void)?

    public init(provider: ClaudeActivityObserving) {
        self.provider = provider
        self.state = provider.state
    }

    /// Start observing Claude-detection changes. Idempotent: calling it again while already
    /// observing is a no-op, so it is safe to invoke unconditionally at app launch (and the
    /// provider never ends up with more than one live timer).
    public func start() {
        guard !isObserving else { return }
        isObserving = true
        provider.start(
            onChange: { [weak self] newValue in
                // The provider guarantees main-queue delivery, so we are already on the
                // main actor here.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.state = newValue
                    self.onStateChange?(newValue)
                }
            },
            onAutomation: { [weak self] intent in
                // Also main-queue-delivered by the provider.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.automationIntent = intent
                    self.onAutomationChange?(intent)
                }
            },
            onSessions: { [weak self] sessions in
                // Session Radar list; main-queue-delivered by the provider.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sessions = sessions
                    // Re-apply dismissals: hidden rows stay hidden until they emit a newer
                    // event, and dismissals for pruned sessions are dropped (see `reconcile`).
                    self.visibleSessions = self.dismissed.reconcile(with: sessions)
                }
            },
            onDiagnostics: { [weak self] summary in
                // DEBUG-only in practice (the provider never calls this in Release), also
                // delivered on the main queue.
                MainActor.assumeIsolated {
                    self?.debugSummary = summary
                }
            }
        )
    }

    /// Stop observing. After stopping, a later `start()` will re-subscribe.
    public func stop() {
        isObserving = false
        provider.stop()
    }

    /// Manually hide a Session Radar row (docs/decisions/0013-session-title-and-dismiss.md).
    /// **VibeMenu-only:** removes the row from `visibleSessions` and nothing more — it does not
    /// delete any Claude data, stop or kill the session, or write any file. The row reappears on
    /// its own once the session emits a newer event. Recomputes `visibleSessions` immediately so
    /// the UI can animate the removal.
    public func dismiss(_ session: ClaudeSession) {
        dismissed.dismiss(session)
        visibleSessions = dismissed.reconcile(with: sessions)
    }

    /// UI label for the "Claude" row: Active / Idle / Not detected.
    public var displayLabel: String {
        state.menuDisplayName
    }
}
