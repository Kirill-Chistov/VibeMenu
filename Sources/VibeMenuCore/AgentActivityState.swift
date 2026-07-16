import Foundation

/// Coarse, metadata-only view of what a watched coding agent (Claude Code first,
/// Codex later) is doing.
///
/// VibeMenu derives this from *process presence* and *file modification times*
/// only — never from the contents of Claude Code / Codex transcripts (see
/// `docs/PRIVACY.md` and SPEC §5.1). Real detection is **not** implemented yet; this
/// type only defines the shape the monitor will eventually produce.
public enum AgentActivityState: String, Equatable, Sendable, CaseIterable {
    /// Monitoring has not started, or the state is not yet known.
    case unknown

    /// No watched agent process is present.
    case noAgent

    /// An agent is present, but its session has been quiet past the grace period.
    case idle

    /// An agent is actively working (recent session-file activity / heartbeat).
    case working

    /// An agent is present but paused, waiting for user input.
    ///
    /// Per SPEC §5.1 this is deliberately *not* treated as "working": VibeMenu
    /// should let the Mac sleep while an agent is blocked on a permission prompt.
    case waitingForInput
}
