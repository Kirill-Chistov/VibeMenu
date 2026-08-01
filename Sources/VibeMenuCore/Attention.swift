import Foundation

// Attention v1 — pure transition rules shared by the app-side notification and navigation
// adapters. This file deliberately carries only provider names, safe display names, states, and
// timestamps already present in the Session Radar models. It never reads or stores transcript
// content, paths, prompts, responses, session ids in emitted events, or any external state.

// MARK: - Provider activation + notification value types

/// The two provider families surfaced by the Session Radar. `codex` means Codex/Work sessions;
/// their owning desktop application is ChatGPT (see the app-side bundle identifier mapping).
public enum AttentionProvider: String, Equatable, Hashable, Sendable, CaseIterable {
    case claude = "Claude"
    case codex = "Codex"

    /// The public bundle identifier used by the app-side activation adapter. Keeping this mapping
    /// pure makes the navigation target explicit and testable without touching AppKit.
    public var applicationBundleIdentifier: String {
        switch self {
        case .claude: "com.anthropic.claudefordesktop"
        case .codex: "com.openai.codex"
        }
    }

    /// The user-visible provider name (notification titles). Deliberately **separate** from
    /// `rawValue`, which stays the stable routing key stored in notification `userInfo` — renaming
    /// the visible label must not change routing. `codex` covers both Work and Codex sessions of the
    /// one OpenAI desktop app, so its visible name is the provider, not one of its modes
    /// (docs/decisions/0017, Amendment 6).
    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "OpenAI"
        }
    }
}

/// A notification-worthy transition. It intentionally has no session id: notification identifiers
/// and userInfo are not allowed to carry session ids or other private metadata.
public struct AttentionNotification: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case needsApproval
        case finished

        public var bodyText: String {
            switch self {
            case .needsApproval: "needs approval"
            case .finished: "finished"
            }
        }
    }

    public let provider: AttentionProvider
    public let displayName: String
    public let kind: Kind

    public init(provider: AttentionProvider, displayName: String, kind: Kind) {
        self.provider = provider
        self.displayName = displayName
        self.kind = kind
    }
}

/// The provider values stored in a notification are also the only values accepted back from a
/// notification click. Unknown or malformed values fail closed.
public enum AttentionNavigation {
    public static func provider(fromNotificationValue value: String) -> AttentionProvider? {
        AttentionProvider(rawValue: value)
    }
}

// MARK: - Notification permission state

public enum AttentionNotificationPermissionAction: Equatable, Sendable {
    case none
    case requestAuthorization
}

/// Pure persisted preference state. The app-side adapter performs the asynchronous macOS
/// permission request; this type defines the small rule that a requested-on toggle is committed
/// only after authorization succeeds.
public struct AttentionNotificationPreference: Equatable, Sendable {
    public private(set) var isEnabled: Bool

    public init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    /// Begin an explicit Settings toggle. Launching or observing the app does not call this method,
    /// so it has no permission-request action; only `requested == true` returns a request action.
    public mutating func beginUserChange(
        requested: Bool
    ) -> AttentionNotificationPermissionAction {
        isEnabled = false
        return requested ? .requestAuthorization : .none
    }

    /// Commit the result of the explicit macOS authorization request.
    public mutating func finishAuthorization(granted: Bool) {
        isEnabled = granted
    }

    /// Filter transition events at the delivery boundary. State tracking still runs while the
    /// preference is off, but nothing is handed to the macOS notification adapter.
    public func deliverable(_ events: [AttentionNotification]) -> [AttentionNotification] {
        isEnabled ? events : []
    }

    /// Apply an explicit toggle request. `permissionGranted` is meaningful only when enabling;
    /// a denied or not-yet-resolved request always leaves the preference off.
    public mutating func apply(requested: Bool, permissionGranted: Bool = false) {
        isEnabled = requested && permissionGranted
    }
}

// MARK: - Transition deduplication

private enum AttentionSessionState: Equatable, Sendable {
    case working
    case quiet
    case needsApproval
    case finished
    case other
}

private struct AttentionSessionKey: Hashable, Sendable {
    let provider: AttentionProvider
    let id: String
}

private struct AttentionSessionSnapshot: Equatable, Sendable {
    let key: AttentionSessionKey
    let state: AttentionSessionState
    let displayName: String
    let generationAt: Date
    /// Claude's normalized heartbeat event is part of its safe generation identity. A timestamp
    /// alone is not enough because the hook uses second precision and can replace a work event with
    /// `Stop` in the same second.
    let claudeEvent: ClaudeHeartbeatEvent?
    /// Codex has one safe completion marker (`task_complete`) in addition to its activity time.
    /// Repeated identical marker/timestamp pairs remain silent.
    let isCompletionMarker: Bool
}

/// Stateful, in-memory transition deduplication for the two notification events.
///
/// The first snapshot for each provider establishes a silent baseline. After that, a target-state
/// session emits only when its safe activity generation advances: Claude uses `lastEventAt` plus its
/// normalized heartbeat event, while Codex uses `lastActivity` plus the `task_complete` marker.
/// This deliberately ignores derived-state churn caused by process presence or age. A newly
/// appearing target-state session is eligible after the provider baseline; an explicit
/// `reset(provider:)` starts a fresh silent baseline for provider enablement/reset without
/// suppressing ordinary new sessions forever.
public struct AttentionTransitionTracker: Equatable, Sendable {
    private var previous: [AttentionSessionKey: AttentionSessionSnapshot] = [:]
    private var baselinedProviders: Set<AttentionProvider> = []

    public init() {}

    /// Clear one provider's current snapshot and baseline. The next snapshot for that provider is
    /// silent, while the other provider's baseline and generations remain intact.
    public mutating func reset(provider: AttentionProvider) {
        previous = previous.filter { $0.key.provider != provider }
        baselinedProviders.remove(provider)
    }

    /// Record the current Claude snapshot and return newly-entered Needs approval/Done events.
    public mutating func updateClaude(_ sessions: [ClaudeSession]) -> [AttentionNotification] {
        let snapshots = sessions.map { session in
            AttentionSessionSnapshot(
                key: AttentionSessionKey(provider: .claude, id: session.id),
                state: Self.claudeState(session.state),
                displayName: session.displayName,
                generationAt: session.lastEventAt,
                claudeEvent: session.event,
                isCompletionMarker: false
            )
        }
        return update(snapshots, provider: .claude)
    }

    /// Record the current Codex snapshot and return newly-entered Done events.
    public mutating func updateCodex(_ sessions: [CodexSession]) -> [AttentionNotification] {
        let snapshots = sessions.map { session in
            AttentionSessionSnapshot(
                key: AttentionSessionKey(provider: .codex, id: session.id),
                state: Self.codexState(session.state),
                displayName: session.displayName,
                generationAt: session.lastActivity,
                claudeEvent: nil,
                isCompletionMarker: session.endedWithCompletion
            )
        }
        return update(snapshots, provider: .codex)
    }

    private mutating func update(
        _ snapshots: [AttentionSessionSnapshot], provider: AttentionProvider
    ) -> [AttentionNotification] {
        let baseline = previous
        let isBaseline = !baselinedProviders.contains(provider)

        var events: [AttentionNotification] = []
        if !isBaseline {
            for snapshot in snapshots {
                guard let kind = Self.notificationKind(for: snapshot, provider: provider) else {
                    continue
                }

                // A new session after a provider baseline is real new activity, so it is eligible
                // immediately. Existing sessions require a newer safe generation, not a different
                // derived state: Working → Done at one heartbeat timestamp stays silent, while
                // Done@t1 → Done@t2 and NeedsApproval@t1 → NeedsApproval@t2 both notify.
                guard let old = baseline[snapshot.key] else {
                    events.append(AttentionNotification(
                        provider: snapshot.key.provider,
                        displayName: snapshot.displayName,
                        kind: kind
                    ))
                    continue
                }
                guard Self.isNewerGeneration(snapshot, than: old, provider: provider) else { continue }
                events.append(AttentionNotification(
                    provider: snapshot.key.provider,
                    displayName: snapshot.displayName,
                    kind: kind
                ))
            }
        }

        baselinedProviders.insert(provider)

        // Keep only current rows for this provider. This bounds the in-memory tracker; an explicit
        // provider reset clears its baseline before the next snapshot, while the other provider's
        // baseline remains intact.
        previous = previous.filter { $0.key.provider != provider }
        for snapshot in snapshots {
            previous[snapshot.key] = snapshot
        }
        return events
    }

    private static func notificationKind(
        for snapshot: AttentionSessionSnapshot,
        provider: AttentionProvider
    ) -> AttentionNotification.Kind? {
        switch provider {
        case .claude:
            if snapshot.state == .needsApproval && snapshot.claudeEvent == .permissionRequested {
                return .needsApproval
            }
            if snapshot.state == .finished,
               let event = snapshot.claudeEvent,
               event.isTurnCompletionEvent {
                return .finished
            }
            return nil
        case .codex:
            return snapshot.state == .finished ? .finished : nil
        }
    }

    private static func isNewerGeneration(
        _ current: AttentionSessionSnapshot,
        than previous: AttentionSessionSnapshot,
        provider: AttentionProvider
    ) -> Bool {
        if current.generationAt != previous.generationAt {
            return current.generationAt > previous.generationAt
        }

        // Claude's hook timestamp has one-second precision, so the event is the second half of its
        // generation. This admits `UserPromptSubmit@t → Stop@t`, while a process-derived
        // Working@t → Done@t reclassification keeps the same event and stays silent.
        if provider == .claude {
            return current.claudeEvent != previous.claudeEvent
        }

        // A Codex completion marker is an additional safe generation signal. This handles a
        // completion marker arriving at the same timestamp as the preceding activity without
        // making repeated `task_complete` polling noisy.
        return current.isCompletionMarker
            && !previous.isCompletionMarker
    }

    private static func claudeState(_ state: ClaudeSessionState) -> AttentionSessionState {
        switch state {
        case .working: .working
        case .quietWorking: .quiet
        case .permissionRequested: .needsApproval
        case .done: .finished
        case .stale, .unknown: .other
        }
    }

    private static func codexState(_ state: CodexSessionState) -> AttentionSessionState {
        switch state {
        case .active: .working
        case .idle: .quiet
        case .done: .finished
        case .stale, .unknown: .other
        }
    }
}

// MARK: - Reusable Codex turn timer

/// Preserves a visible Codex turn timer across provider refreshes. Codex exposes a reliable
/// completion marker plus allowlisted activity timestamps, so a new turn is the first newer
/// activity after a completed snapshot whose latest marker is no longer `task_complete`.
public struct CodexSessionTurnStore: Equatable, Sendable {
    private var turnStarts: [String: Date] = [:]

    public init() {}

    /// Stateful update with the prior published session list. The model keeps the provider's raw
    /// metadata and this timer-bearing display list distinct without adding I/O or side effects to
    /// the reader.
    public mutating func update(_ sessions: [CodexSession], previousSessions: [CodexSession]) -> [CodexSession] {
        let previousByID = Dictionary(uniqueKeysWithValues: previousSessions.map { ($0.id, $0) })
        var nextStarts: [String: Date] = [:]

        for session in sessions {
            let start: Date
            if let previous = previousByID[session.id],
               session.lastActivity > previous.lastActivity,
               previous.endedWithCompletion,
               !session.endedWithCompletion {
                // Done → newer non-completion activity is a new turn. Use the allowlisted activity
                // timestamp so the visible timer starts at the same safe event boundary.
                start = session.lastActivity
            } else if let existing = turnStarts[session.id] {
                start = existing
            } else if let incoming = session.timerStartedAt {
                start = incoming
            } else {
                // First observation of an active/idle turn: the newest allowlisted activity is the
                // only honest timestamp available for a request-relative visible timer.
                start = session.lastActivity
            }
            nextStarts[session.id] = start
        }

        turnStarts = nextStarts
        return sessions.map { $0.withTimerStart(turnStarts[$0.id]) }
    }
}
