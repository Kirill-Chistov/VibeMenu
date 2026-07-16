import Foundation

// Provider-neutral keep-awake plumbing for the shared "agent activity" sleep-prevention decision
// (docs/decisions/0017-codex-session-support.md, Fix 1).
//
// VibeMenu's automatic keep-awake was originally owned solely by Claude detection: Claude computed a
// `.hold`/`.release` intent and `PowerAssertionModel` applied it as its single `automationRequested`
// bit. Codex session detection was deliberately display-only and never touched the power loop.
//
// This slice makes Codex an equal *input* to the same decision without changing the assertion itself.
// `PowerAssertionModel` now tracks a **set** of holding sources (see PowerAssertionManager.swift), so
// Claude and Codex each independently hold/release and the effective automation request is simply
// "any source is holding". Manual keep-awake still wins over all of it, exactly as before.
//
// Everything here is pure and I/O-free so the activity → hold/release mapping is unit-tested with
// synthetic sessions. It reuses `ClaudeAutomationIntent` (a plain hold/release) as the neutral intent
// type rather than inventing a parallel enum.

/// Which watched agent is asking VibeMenu to hold the automatic keep-awake assertion. Provider-neutral
/// so the power model can OR together independent hold requests without knowing anything about either
/// agent's internals.
public enum AgentKeepAwakeSource: String, Equatable, Sendable, CaseIterable {
    /// Claude Code detection (L1 + L2 heartbeat) — the original owner of the automation loop.
    case claude
    /// Codex Desktop session detection — an active/recent Codex session (docs/decisions/0017, Fix 1).
    case codex
}

/// Pure mapping from the Codex session list to a keep-awake intent for the shared agent-activity
/// decision (docs/decisions/0017, Fix 1). I/O-free, so it is exhaustively unit-tested.
///
/// **Deliberately conservative.** Only a session VibeMenu currently reads as `.active` holds — i.e. a
/// session with *very recent* rollout activity whose latest turn is not finished (`CodexSessionState`
/// `activeWindow`, 60 s). Every other state — `.idle`, `.done`, `.stale`, `.unknown` — releases. This
/// gives the hold a natural, bounded lifetime with no separate cap: once a session goes quiet past the
/// active window the reader re-derives it to `.idle` on its next tick and the hold drops. So:
///
///   * an actively-working Codex session can prevent sleep;
///   * a finished / idle / stale session never does (task rule: "only done/stale exist ⇒ no assertion");
///   * a stale, missing, or unavailable list is `[]` here ⇒ `.release`;
///   * when Codex tracking is **disabled** the provider publishes `[]` (it self-gates before any file
///     access), so this returns `.release` and Codex cannot affect sleep at all.
///
/// It reads only the derived session *state*, never usage-limit refresh timestamps or any other signal
/// (task rule: "do not use usage-limit refresh timestamps as activity"; Codex Limits stays display-only).
public enum CodexSessionActivity {
    /// Whether any Codex session is active enough to hold the shared keep-awake assertion.
    public static func automationIntent(_ sessions: [CodexSession]) -> ClaudeAutomationIntent {
        sessions.contains { $0.state == .active } ? .hold : .release
    }
}
