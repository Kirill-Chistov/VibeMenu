import Foundation

// Provider-neutral keep-awake plumbing for the shared "agent activity" sleep-prevention decision
// (docs/decisions/0017-codex-session-support.md, Fix 1).
//
// VibeMenu's automatic keep-awake was originally owned solely by Claude detection: Claude computed a
// `.hold`/`.release` intent and `PowerAssertionModel` applied it as its single `automationRequested`
// bit. Codex session detection was deliberately display-only and never touched the power loop.
//
// This slice makes the ChatGPT desktop app an equal *input* to the same decision without changing the
// assertion itself. `PowerAssertionModel` tracks a **set** of holding sources (see
// PowerAssertionManager.swift), so Claude, Codex, and ChatGPT Work each independently hold/release and
// the effective automation request is simply "any source is holding". One shared IOKit assertion is
// still created. Manual keep-awake still wins over all of it, exactly as before.
//
// Everything here is pure and I/O-free so the activity → hold/release mapping is unit-tested with
// synthetic sessions. It reuses `ClaudeAutomationIntent` (a plain hold/release) as the neutral intent
// type rather than inventing a parallel enum.

/// Which watched agent is asking VibeMenu to hold the automatic keep-awake assertion. Provider-neutral
/// so the power model can OR together independent hold requests without knowing anything about either
/// agent's internals.
///
/// The two modes of the unified ChatGPT desktop app are **separate sources**, not one collapsed
/// "OpenAI" owner: a Work turn and a Codex turn are independent pieces of work, and the user must be
/// able to see which one is holding. Keeping them apart is also a correctness property — if they
/// shared a source, one mode finishing would clear the other's hold and could release the assertion
/// while real work was still running. `allCases` order is the stable presentation order.
public enum AgentKeepAwakeSource: String, Equatable, Sendable, CaseIterable {
    /// Claude Code detection (L1 + L2 heartbeat) — the original owner of the automation loop.
    case claude
    /// An active **Codex**-mode session of the ChatGPT desktop app (docs/decisions/0017, Fix 1).
    case codex
    /// An active **ChatGPT Work**-mode session of the same app. Its own source so it holds and
    /// releases independently of `.codex` (docs/decisions/0017, Amendment 6).
    ///
    /// The raw value is deliberately `"work"` — short, and it never reaches storage or the UI (the
    /// visible name comes from `PowerAssertionOwner`).
    case chatGPTWork = "work"
}

/// Pure mapping from the ChatGPT desktop session list to a keep-awake intent for the shared
/// agent-activity decision (docs/decisions/0017, Fix 1). I/O-free, so it is exhaustively unit-tested.
///
/// **Deliberately conservative.** Only a session VibeMenu currently reads as `.active` holds — i.e. a
/// session with *very recent* rollout activity whose latest turn is not finished (`CodexSessionState`
/// `activeWindow`, 60 s). Every other state — `.idle`, `.done`, `.stale`, `.unknown` — releases. This
/// gives the hold a natural, bounded lifetime with no separate cap: once a session goes quiet past the
/// active window the reader re-derives it to `.idle` on its next tick and the hold drops. So:
///
///   * an actively-working session can prevent sleep;
///   * a finished / idle / stale session never does (task rule: "only done/stale exist ⇒ no assertion");
///   * a stale, missing, or unavailable list is `[]` here ⇒ `.release`;
///   * when tracking is **disabled** the provider publishes `[]` (it self-gates before any file
///     access), so every mode returns `.release` and neither can affect sleep at all.
///
/// **Per-mode by construction.** The intent is always asked for one `CodexSessionMode`, so ChatGPT
/// Work and Codex reach `PowerAssertionModel` as two independent holds. There is deliberately no
/// whole-list "any session active" entry point: that would collapse both modes into one owner, and a
/// Work turn ending could then release an assertion a live Codex turn still needs.
///
/// It reads only the derived session *state* and `mode`, never usage-limit refresh timestamps or any
/// other signal (task rule: "do not use usage-limit refresh timestamps as activity"; the limits
/// section stays display-only).
public enum CodexSessionActivity {
    /// Whether any session **of the given mode** is active enough to hold the shared keep-awake
    /// assertion. Sessions of the other mode are ignored entirely, so each mode's hold is derived
    /// from its own activity alone.
    public static func automationIntent(
        _ sessions: [CodexSession],
        mode: CodexSessionMode
    ) -> ClaudeAutomationIntent {
        sessions.contains { $0.mode == mode && $0.state == .active } ? .hold : .release
    }
}
