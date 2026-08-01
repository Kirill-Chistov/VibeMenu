import Foundation
import Testing
@testable import VibeMenuCore

// Codex usage-limits tests (docs/decisions/0017): the pure duration-driven model + formatting, the
// schema-driven `CodexRateLimitRollout` parser (including a strict **privacy** proof and the
// no-resurrection semantics), the file reader over synthetic rollouts, per-row visibility, and the
// provider/model auto-refresh. Sanitized fixtures only — never the real ~/.codex.
//
// The central invariants under test (the product requirement): VibeMenu shows exactly the windows the
// latest authoritative reading exposes, labels each from its own `window_minutes` (not its slot), and
// drops a window automatically when Codex stops exposing it — never reviving one from older data.

@Suite("CodexUsageLimit — model + formatting")
struct CodexUsageLimitModelTests {

    private var posixCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "en_US_POSIX")
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test("used_percent is clamped to 0…100; NaN/inf → 0")
    func clamp() {
        #expect(CodexUsageLimit(windowMinutes: 300, usedPercent: 150, resetsAt: nil).usedPercent == 100)
        #expect(CodexUsageLimit(windowMinutes: 300, usedPercent: -10, resetsAt: nil).usedPercent == 0)
        #expect(CodexUsageLimit(windowMinutes: 10080, usedPercent: .nan, resetsAt: nil).usedPercent == 0)
        #expect(CodexUsageLimit(windowMinutes: 10080, usedPercent: .infinity, resetsAt: nil).usedPercent == 0)
    }

    @Test("Labels are derived from window_minutes, not slot position")
    func labelDerivation() {
        // The two durations Codex currently emits keep their familiar names…
        #expect(CodexUsageLimit.label(windowMinutes: 300) == "5-hour limit")
        #expect(CodexUsageLimit.label(windowMinutes: 10080) == "Weekly")
        // …other exact durations are named truthfully from the duration…
        #expect(CodexUsageLimit.label(windowMinutes: 60) == "1-hour limit")
        #expect(CodexUsageLimit.label(windowMinutes: 180) == "3-hour limit")
        #expect(CodexUsageLimit.label(windowMinutes: 1440) == "Daily")
        #expect(CodexUsageLimit.label(windowMinutes: 2880) == "2-day limit")
        #expect(CodexUsageLimit.label(windowMinutes: 90) == "90-minute limit")
        // …and a window with no provable duration gets a neutral label, never a fabricated one.
        #expect(CodexUsageLimit.label(windowMinutes: nil) == "Usage limit")
        #expect(CodexUsageLimit.label(windowMinutes: 0) == "Usage limit")
        #expect(CodexUsageLimit.label(windowMinutes: -5) == "Usage limit")
        // displayLabel routes through label(windowMinutes:).
        #expect(CodexUsageLimit(windowMinutes: 300, usedPercent: 16, resetsAt: nil).displayLabel == "5-hour limit")
        #expect(CodexUsageLimit(windowMinutes: 10080, usedPercent: 3, resetsAt: nil).displayLabel == "Weekly")
    }

    @Test("A slot named `primary` that is really the weekly window labels as Weekly (position ≠ meaning)")
    func positionalIndependenceOfLabel() {
        // The real bug this fixes: `primary` is not always the 5-hour window.
        let primaryIsWeekly = CodexUsageLimit(windowMinutes: 10080, usedPercent: 4, resetsAt: nil, slot: "primary")
        #expect(primaryIsWeekly.displayLabel == "Weekly")
        #expect(primaryIsWeekly.visibilityID == "weekly")
    }

    @Test("Stable ids: duration-derived (legacy fiveHour/weekly preserved), slot fallback")
    func ids() {
        #expect(CodexUsageLimit(windowMinutes: 300, usedPercent: 1, resetsAt: nil).visibilityID == "fiveHour")
        #expect(CodexUsageLimit(windowMinutes: 10080, usedPercent: 1, resetsAt: nil).visibilityID == "weekly")
        #expect(CodexUsageLimit(windowMinutes: 4321, usedPercent: 1, resetsAt: nil).visibilityID == "win-4321")
        // No duration → fall back to the structural slot key, never a fabricated identity.
        #expect(CodexUsageLimit(windowMinutes: nil, usedPercent: 1, resetsAt: nil, slot: "primary").visibilityID == "slot-primary")
        #expect(CodexUsageLimit(windowMinutes: nil, usedPercent: 1, resetsAt: nil, slot: "").visibilityID == "unknown")
        // The per-row `id` qualifies the visibility id with the slot (so two same-duration windows never
        // collide); a slot-less window keeps the bare visibility id.
        #expect(CodexUsageLimit(windowMinutes: 300, usedPercent: 1, resetsAt: nil, slot: "primary").id == "fiveHour#primary")
        #expect(CodexUsageLimit(windowMinutes: 300, usedPercent: 1, resetsAt: nil).id == "fiveHour")
    }

    @Test("Two distinct windows with the same duration have unique row IDs (but share a visibility id)")
    func rowIdsUniqueForSameDuration() {
        // Distinct windows come from distinct rate_limits slots; the duration alone is not unique.
        let a = CodexUsageLimit(windowMinutes: 300, usedPercent: 10, resetsAt: nil, slot: "primary")
        let b = CodexUsageLimit(windowMinutes: 300, usedPercent: 20, resetsAt: nil, slot: "extra")
        #expect(a.id != b.id)                       // no Identifiable collision
        #expect(a.visibilityID == b.visibilityID)   // but the same hide/show preference key
        // A whole snapshot of same-duration windows yields all-unique ids.
        let snap = CodexUsageLimitSnapshot(limits: [a, b], capturedAt: nil, source: .rollout)
        #expect(Set(snap.limits.map(\.id)).count == snap.limits.count)
    }

    @Test("Conservative severity thresholds (≥75 warning, ≥90 critical)")
    func severity() {
        #expect(CodexUsageLimit(windowMinutes: 300, usedPercent: 10, resetsAt: nil).severity == .normal)
        #expect(CodexUsageLimit(windowMinutes: 300, usedPercent: 80, resetsAt: nil).severity == .warning)
        #expect(CodexUsageLimit(windowMinutes: 300, usedPercent: 95, resetsAt: nil).severity == .critical)
    }

    @Test("percentText rounds; fraction is 0…1")
    func percentAndFraction() {
        let l = CodexUsageLimit(windowMinutes: 300, usedPercent: 16.4, resetsAt: nil)
        #expect(l.percentText == "16%")
        #expect(abs(l.fraction - 0.164) < 0.0001)
    }

    @Test("resetText: relative within a day, absolute beyond, soon, and unknown")
    func resetText() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cal = posixCalendar
        let inTwoFortyish = CodexUsageLimit(windowMinutes: 300, usedPercent: 10, resetsAt: now.addingTimeInterval(2 * 3600 + 40 * 60))
        #expect(inTwoFortyish.resetText(now: now, calendar: cal) == "Resets in 2 hr 40 min")
        let soon = CodexUsageLimit(windowMinutes: 300, usedPercent: 10, resetsAt: now.addingTimeInterval(30))
        #expect(soon.resetText(now: now, calendar: cal) == "Resets soon")
        let unknown = CodexUsageLimit(windowMinutes: 300, usedPercent: 10, resetsAt: nil)
        #expect(unknown.resetText(now: now, calendar: cal) == "Reset time unknown")
        let farOut = CodexUsageLimit(windowMinutes: 10080, usedPercent: 10, resetsAt: now.addingTimeInterval(3 * 24 * 3600))
        #expect(farOut.resetText(now: now, calendar: cal).hasPrefix("Resets "))
        #expect(!farOut.resetText(now: now, calendar: cal).contains("in "))   // absolute, not relative
    }

    @Test("Snapshot freshness: fresh / stale(age) / unavailable + ageNote")
    func snapshotStatus() {
        let now = Date()
        let rows = [CodexUsageLimit(windowMinutes: 300, usedPercent: 16, resetsAt: nil)]
        let fresh = CodexUsageLimitSnapshot(limits: rows, capturedAt: now.addingTimeInterval(-60), source: .rollout)
        #expect(fresh.status(now: now) == .fresh)
        #expect(fresh.ageNote(now: now) == nil)

        let stale = CodexUsageLimitSnapshot(limits: rows, capturedAt: now.addingTimeInterval(-30 * 60), source: .rollout)
        if case .stale = stale.status(now: now) {} else { Issue.record("expected stale") }
        #expect(stale.ageNote(now: now) == "as of 30m ago")

        #expect(CodexUsageLimitSnapshot.unavailable.status(now: now) == .unavailable)
        #expect(CodexUsageLimitSnapshot.unavailable.hasData == false)
    }

    @Test("Snapshot sorts shortest-window-first regardless of input order; ties broken by slot")
    func snapshotSorted() {
        let weekly = CodexUsageLimit(windowMinutes: 10080, usedPercent: 3, resetsAt: nil, slot: "secondary")
        let five = CodexUsageLimit(windowMinutes: 300, usedPercent: 16, resetsAt: nil, slot: "primary")
        let snap = CodexUsageLimitSnapshot(limits: [weekly, five], capturedAt: nil, source: .rollout)
        #expect(snap.limits.map(\.displayLabel) == ["5-hour limit", "Weekly"])

        // Duration-less windows sort last; ties break deterministically by slot.
        let a = CodexUsageLimit(windowMinutes: nil, usedPercent: 1, resetsAt: nil, slot: "z")
        let b = CodexUsageLimit(windowMinutes: nil, usedPercent: 1, resetsAt: nil, slot: "a")
        let snap2 = CodexUsageLimitSnapshot(limits: [a, five, b], capturedAt: nil, source: .rollout)
        #expect(snap2.limits.map(\.slot) == ["primary", "a", "z"])
    }

    @Test("Collapsed settings header")
    func summary() {
        #expect(CodexUsageLimitsSummary.collapsedHeader(enabled: false, freshness: "live") == "Off")
        #expect(CodexUsageLimitsSummary.collapsedHeader(enabled: true, freshness: "live") == "On · live")
        #expect(CodexUsageLimitsSummary.collapsedHeader(enabled: true, freshness: nil) == "On")
    }

    /// Regression guard for the empty-state wording (2026-07-26). The previous copy — "No Codex usage
    /// data yet — open Codex Desktop, then check Settings" — promised something VibeMenu cannot deliver:
    /// merely launching Codex writes no reading, only a Codex **turn** does, and VibeMenu is never
    /// allowed to ask OpenAI for the current allowance. The copy must therefore say the data is
    /// *recent*-bounded and locally written, state the reader's real freshness window, and state the
    /// no-network limitation.
    @Test("Empty-state copy is truthful about the local, turn-written source and no-network limit")
    func emptyStateCopyIsTruthful() {
        let line = CodexUsageLimitsMenuCopy.emptyState
        #expect(line.contains("Codex"))
        #expect(line.contains("locally"))
        // Must not tell the user that opening the app (rather than running a turn) refreshes the data.
        #expect(!line.lowercased().contains("open codex"))

        let help = CodexUsageLimitsMenuCopy.emptyStateHelp
        // The stated freshness window tracks the reader's own horizon, so copy can't drift from code.
        let hours = Int(CodexUsageLimitReader.defaultRecencyHorizon / 3600)
        #expect(help.contains("last \(hours) h"))
        #expect(help.contains("never contacts OpenAI"))
        // Never claims a fixed 5-hour + weekly pair: the reader is schema-driven (ADR 0017 amendment).
        #expect(!help.contains("5-hour and weekly"))
    }
}

@Suite("CodexRateLimitRollout — schema-driven parser + privacy + no resurrection")
struct CodexRateLimitRolloutTests {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Multiple exposed limits: primary→5-hour and secondary→Weekly with used_percent + resets_at")
    func extractsMultipleWindows() {
        let primaryReset = start.addingTimeInterval(3 * 3600)
        let secondaryReset = start.addingTimeInterval(5 * 24 * 3600)
        let rl = CodexFixture.rateLimitsObject([
            ("primary", CodexFixture.windowObject(percent: 16, windowMinutes: 300, resets: primaryReset)),
            ("secondary", CodexFixture.windowObject(percent: 3, windowMinutes: 10080, resets: secondaryReset)),
        ])
        let text = CodexFixture.rollout(start: start, events: [
            (1, "task_started", [:]),
            CodexFixture.tokenCountEvent(offset: 2, rateLimits: rl),
        ])
        let reading = try! #require(CodexRateLimitRollout.parseLatest(text: text, fallbackCaptured: start))
        #expect(reading.hasLimits)
        let rows = reading.snapshot().limits
        #expect(rows.map(\.displayLabel) == ["5-hour limit", "Weekly"])
        let five = try! #require(rows.first)
        #expect(five.usedPercent == 16)
        #expect(abs((five.resetsAt ?? .distantPast).timeIntervalSince(primaryReset)) < 1)
        #expect(rows.last?.usedPercent == 3)
    }

    @Test("One exposed limit: a single window is shown alone")
    func oneWindow() {
        let rl = CodexFixture.rateLimitsObject([
            ("primary", CodexFixture.windowObject(percent: 42, windowMinutes: 300, resets: start)),
        ])
        let text = CodexFixture.rollout(start: start, events: [CodexFixture.tokenCountEvent(offset: 1, rateLimits: rl)])
        let reading = try! #require(CodexRateLimitRollout.parseLatest(text: text, fallbackCaptured: start))
        #expect(reading.windows.count == 1)
        #expect(reading.snapshot().limits.map(\.displayLabel) == ["5-hour limit"])
    }

    @Test("Position ≠ meaning: a lone `primary` window with window 10080 shows as Weekly")
    func primarySlotCanBeWeekly() {
        // Real data has single-window readings whose only window (`primary`) is the weekly one.
        let rl = CodexFixture.rateLimitsObject([
            ("primary", CodexFixture.windowObject(percent: 4, windowMinutes: 10080, resets: start)),
        ])
        let text = CodexFixture.rollout(start: start, events: [CodexFixture.tokenCountEvent(offset: 1, rateLimits: rl)])
        let reading = try! #require(CodexRateLimitRollout.parseLatest(text: text, fallbackCaptured: start))
        let rows = reading.snapshot().limits
        #expect(rows.count == 1)
        #expect(rows.first?.displayLabel == "Weekly")
        #expect(rows.first?.visibilityID == "weekly")
    }

    @Test("Changed/unknown durations: an unfamiliar window_minutes is labelled truthfully; absent → neutral")
    func changedOrUnknownDurations() {
        let rl = CodexFixture.rateLimitsObject([
            ("primary", CodexFixture.windowObject(percent: 10, windowMinutes: 720, resets: start)),   // 12h
            ("secondary", CodexFixture.windowObject(percent: 5, windowMinutes: nil, resets: start)),  // no duration
        ])
        let text = CodexFixture.rollout(start: start, events: [CodexFixture.tokenCountEvent(offset: 1, rateLimits: rl)])
        let reading = try! #require(CodexRateLimitRollout.parseLatest(text: text, fallbackCaptured: start))
        let rows = reading.snapshot().limits
        // 720 → "12-hour limit" (truthful), and the duration-less window → "Usage limit" (neutral), sorted last.
        #expect(rows.map(\.displayLabel) == ["12-hour limit", "Usage limit"])
        #expect(rows.first?.visibilityID == "win-720")
        #expect(rows.last?.visibilityID == "slot-secondary")
    }

    @Test("Malformed durations fail CLOSED, never crash: out-of-Int-range / zero window_minutes → neutral")
    func malformedDurationFailsClosed() {
        // window_minutes far beyond Int64 range (valid JSON) previously trapped `Int(Double)`; and a
        // zero duration is not provable. Neither may crash the reader — both become neutral rows.
        let text = CodexFixture.rollout(start: start, events: [
            (1, "token_count", ["rate_limits": [
                "primary": ["used_percent": 16, "window_minutes": 1e19, "resets_at": start.timeIntervalSince1970],
                "secondary": ["used_percent": 3, "window_minutes": 0, "resets_at": start.timeIntervalSince1970],
            ]]),
        ])
        let reading = try! #require(CodexRateLimitRollout.parseLatest(text: text, fallbackCaptured: start))
        let rows = reading.snapshot().limits
        // Both windows still show (they carry a percentage) but with a neutral label + slot id — no
        // crash, no fabricated duration, and both sort last (duration-less), tie-broken by slot.
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.displayLabel == "Usage limit" })
        #expect(rows.allSatisfy { $0.windowMinutes == nil })
        #expect(rows.map(\.visibilityID) == ["slot-primary", "slot-secondary"])
    }

    @Test("The `credits` object is not a usage window and is excluded")
    func creditsExcluded() {
        let rl = CodexFixture.rateLimitsObject([
            ("primary", CodexFixture.windowObject(percent: 16, windowMinutes: 300, resets: start)),
            ("secondary", CodexFixture.windowObject(percent: 3, windowMinutes: 10080, resets: start)),
        ], credits: true)
        let text = CodexFixture.rollout(start: start, events: [CodexFixture.tokenCountEvent(offset: 1, rateLimits: rl)])
        let reading = try! #require(CodexRateLimitRollout.parseLatest(text: text, fallbackCaptured: start))
        // Only the two real windows — never a `credits` row.
        #expect(reading.windows.count == 2)
        #expect(reading.snapshot().limits.allSatisfy { $0.slot == "primary" || $0.slot == "secondary" })
    }

    @Test("Uses the newest token_count reading (percentages evolve across a session)")
    func newestWins() {
        let reset = start.addingTimeInterval(3 * 3600)
        let older = CodexFixture.rateLimitsObject([
            ("primary", CodexFixture.windowObject(percent: 5, windowMinutes: 300, resets: reset)),
            ("secondary", CodexFixture.windowObject(percent: 1, windowMinutes: 10080, resets: reset)),
        ])
        let newer = CodexFixture.rateLimitsObject([
            ("primary", CodexFixture.windowObject(percent: 42, windowMinutes: 300, resets: reset)),
            ("secondary", CodexFixture.windowObject(percent: 9, windowMinutes: 10080, resets: reset)),
        ])
        let text = CodexFixture.rollout(start: start, events: [
            CodexFixture.tokenCountEvent(offset: 1, rateLimits: older),
            CodexFixture.tokenCountEvent(offset: 60, rateLimits: newer),
        ])
        let reading = try! #require(CodexRateLimitRollout.parseLatest(text: text, fallbackCaptured: start))
        let rows = reading.snapshot().limits
        #expect(rows.first(where: { $0.displayLabel == "5-hour limit" })?.usedPercent == 42)
        #expect(rows.first(where: { $0.displayLabel == "Weekly" })?.usedPercent == 9)
    }

    @Test("AUTHORITATIVE EMPTY: latest event goes from two windows to an empty rate_limits → rows cleared")
    func twoWindowsToEmptyClearsRows() {
        let reset = start.addingTimeInterval(3 * 3600)
        let good = CodexFixture.rateLimitsObject([
            ("primary", CodexFixture.windowObject(percent: 42, windowMinutes: 300, resets: reset)),
            ("secondary", CodexFixture.windowObject(percent: 9, windowMinutes: 10080, resets: reset)),
        ])
        let text = CodexFixture.rollout(start: start, events: [
            CodexFixture.tokenCountEvent(offset: 1, rateLimits: good),
            // A later turn writes a VALID but empty rate_limits object — an authoritative empty reading
            // that clears the rows (Codex now exposes no windows). It must NOT be ignored.
            (60, "token_count", ["rate_limits": [String: Any]()]),
        ])
        let reading = try! #require(CodexRateLimitRollout.parseLatest(text: text, fallbackCaptured: start))
        #expect(reading.hasLimits == false)               // authoritative empty
        #expect(reading.snapshot().limits.isEmpty)
        #expect(reading.snapshot().hasData == false)
    }

    @Test("AUTHORITATIVE EMPTY: a later credits-only reading clears earlier windows")
    func creditsOnlyLatestClearsRows() {
        let good = CodexFixture.rateLimitsObject([
            ("primary", CodexFixture.windowObject(percent: 20, windowMinutes: 300, resets: start)),
        ])
        let creditsOnly = CodexFixture.rateLimitsObject([], includeSiblings: true, credits: true)
        let text = CodexFixture.rollout(start: start, events: [
            CodexFixture.tokenCountEvent(offset: 1, rateLimits: good),
            // credits is a valid rate_limits object with zero *usage windows* → authoritative empty.
            CodexFixture.tokenCountEvent(offset: 60, rateLimits: creditsOnly),
        ])
        let reading = try! #require(CodexRateLimitRollout.parseLatest(text: text, fallbackCaptured: start))
        #expect(reading.snapshot().limits.isEmpty)
    }

    @Test("A later event with MISSING or MALFORMED rate_limits does NOT clear a valid earlier reading")
    func laterMissingOrMalformedDoesNotClear() {
        let reset = start.addingTimeInterval(3 * 3600)
        let good = CodexFixture.rateLimitsObject([
            ("primary", CodexFixture.windowObject(percent: 30, windowMinutes: 300, resets: reset)),
            ("secondary", CodexFixture.windowObject(percent: 7, windowMinutes: 10080, resets: reset)),
        ])
        // Later events: a token_count with NO rate_limits key, a token_count with a NON-OBJECT
        // rate_limits, and a truly malformed JSON line. None is an authoritative rate_limits object, so
        // the earlier valid reading must survive intact.
        var text = CodexFixture.rollout(start: start, events: [
            CodexFixture.tokenCountEvent(offset: 1, rateLimits: good),
            (60, "token_count", ["info": ["total_token_usage": ["total_tokens": 5]]]),   // no rate_limits
            (120, "token_count", ["rate_limits": "oops-not-an-object"]),                 // non-object
        ])
        text += "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":\n"  // malformed line
        let reading = try! #require(CodexRateLimitRollout.parseLatest(text: text, fallbackCaptured: start))
        let rows = reading.snapshot().limits
        #expect(rows.map(\.displayLabel) == ["5-hour limit", "Weekly"])
        #expect(rows.first?.usedPercent == 30)
    }

    @Test("NO RESURRECTION: a newer reading that drops a window shows only the windows it carries")
    func disappearingWindowIsNotRevived() {
        let reset = start.addingTimeInterval(3 * 3600)
        // Earlier reading exposes both windows…
        let both = CodexFixture.rateLimitsObject([
            ("primary", CodexFixture.windowObject(percent: 20, windowMinutes: 300, resets: reset)),
            ("secondary", CodexFixture.windowObject(percent: 5, windowMinutes: 10080, resets: reset)),
        ])
        // …the newest reading exposes only the 5-hour window (weekly no longer present).
        let onlyFive = CodexFixture.rateLimitsObject([
            ("primary", CodexFixture.windowObject(percent: 25, windowMinutes: 300, resets: reset)),
        ])
        let text = CodexFixture.rollout(start: start, events: [
            CodexFixture.tokenCountEvent(offset: 1, rateLimits: both),
            CodexFixture.tokenCountEvent(offset: 60, rateLimits: onlyFive),
        ])
        let reading = try! #require(CodexRateLimitRollout.parseLatest(text: text, fallbackCaptured: start))
        let rows = reading.snapshot().limits
        // Only the 5-hour row survives; the weekly window is NOT carried forward from the earlier event.
        #expect(rows.map(\.displayLabel) == ["5-hour limit"])
        #expect(rows.first?.usedPercent == 25)
        #expect(!rows.contains { $0.displayLabel == "Weekly" })
    }

    @Test("Non-Codex-rollout text (no session_meta) → nil")
    func noMetaNil() {
        #expect(CodexRateLimitRollout.parseLatest(text: "{\"nope\":true}\ngarbage", fallbackCaptured: start) == nil)
    }

    @Test("A rollout with no rate_limits object at all → no authoritative reading (nil), not empty")
    func noRateLimitsObjectIsNotAReading() {
        // A session with an originator but no token_count carrying a rate_limits object has no
        // authoritative reading — it must NOT masquerade as an authoritative-empty reading (which would
        // wrongly clear rows). parseLatest returns nil so the reader ignores the file entirely.
        let text = CodexFixture.rollout(start: start, events: [(1, "user_message", [:])])
        #expect(CodexRateLimitRollout.parseLatest(text: text, fallbackCaptured: start) == nil)
        // Even a token_count whose rate_limits is missing/non-object yields no reading.
        let noRL = CodexFixture.rollout(start: start, events: [
            (1, "token_count", ["info": ["total_token_usage": ["total_tokens": 9]]]),
        ])
        #expect(CodexRateLimitRollout.parseLatest(text: noRL, fallbackCaptured: start) == nil)
    }

    @Test("Malformed lines are skipped, not fatal")
    func malformedSafe() {
        let rl = CodexFixture.rateLimitsObject([
            ("primary", CodexFixture.windowObject(percent: 10, windowMinutes: 300, resets: start)),
        ])
        var text = CodexFixture.rollout(start: start, events: [CodexFixture.tokenCountEvent(offset: 1, rateLimits: rl)])
        text = "{ this is not json, but it mentions rate_limits\n" + text + "\n}{bad originator line"
        let reading = try! #require(CodexRateLimitRollout.parseLatest(text: text, fallbackCaptured: start))
        #expect(reading.snapshot().limits.first?.usedPercent == 10)
    }

    @Test("A string used_percent is rejected (a text value can't sneak in as a percentage)")
    func numericOnly() {
        let text = CodexFixture.rollout(
            start: start,
            events: [(1, "token_count", ["rate_limits": ["primary": ["used_percent": "not-a-number", "window_minutes": 300]]])]
        )
        let reading = try! #require(CodexRateLimitRollout.parseLatest(text: text, fallbackCaptured: start))
        #expect(reading.hasLimits == false)   // non-numeric percent ⇒ no window
    }

    @Test("PRIVACY: no prompt/response/tool/reasoning/plan/account/token/credits field ever surfaces")
    func privacy() throws {
        // A fully sensitive rollout: forbidden meta (system prompt, repo, account), forbidden event
        // payloads (prompt/response/reasoning/tool text), a rate_limits object carrying
        // SECRET_LIMIT/SECRET_PLAN + token counts in `info`, and a credits object with a marker balance.
        var events: [(TimeInterval, String, [String: Any])] = [
            (0, "task_started", [:]),
            (1, "user_message", ["message": "SECRET_PROMPT refactor please"]),
            (2, "reasoning", ["text": "SECRET_REASONING"]),
            (3, "agent_message", ["message": "SECRET_RESPONSE"]),
            (5, "task_complete", ["last_agent_message": "SECRET_TOOL_OUTPUT"]),
        ]
        let rl = CodexFixture.rateLimitsObject([
            ("primary", CodexFixture.windowObject(percent: 16, windowMinutes: 300, resets: start)),
            ("secondary", CodexFixture.windowObject(percent: 3, windowMinutes: 10080, resets: start)),
        ], credits: true)
        events.append(CodexFixture.tokenCountEvent(offset: 4, rateLimits: rl))
        let text = CodexFixture.rollout(start: start, events: events, includeSensitive: true)

        let reading = try #require(CodexRateLimitRollout.parseLatest(text: text, fallbackCaptured: start))
        let snapshot = reading.snapshot()
        // Encode everything that could reach the UI and assert no forbidden marker is present.
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        for marker in CodexFixture.sensitiveMarkers {
            #expect(!encoded.contains(marker), "snapshot leaked \(marker)")
        }
        // Only the two numeric windows survive; no token counts (4242), no credits balance (555555).
        #expect(snapshot.limits.count == 2)
        #expect(!encoded.contains("4242"))
        #expect(!encoded.contains("555555"))
        #expect(reading.originator == CodexRolloutParser.desktopOriginator)
    }
}

@Suite("CodexUsageLimitReader — file adapter")
struct CodexUsageLimitReaderTests {

    private func reader(_ dir: URL) -> CodexUsageLimitReader {
        CodexUsageLimitReader(directory: dir)
    }

    private func twoWindow(primary: Double, secondary: Double, resets: Date) -> [String: Any] {
        CodexFixture.rateLimitsObject([
            ("primary", CodexFixture.windowObject(percent: primary, windowMinutes: 300, resets: resets)),
            ("secondary", CodexFixture.windowObject(percent: secondary, windowMinutes: 10080, resets: resets)),
        ])
    }

    @Test("Missing directory → unavailable (never a crash)")
    func missingDir() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        #expect(reader(dir).readSnapshot().source == .unavailable)
    }

    @Test("Reads the newest Codex Desktop reading; ignores CLI and subagent rollouts")
    func readsDesktopIgnoresOthers() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        // CLI rollout (wrong originator) — must be ignored even though it's newest.
        CodexFixture.write(
            CodexFixture.rollout(originator: "codex_cli_rs", start: now.addingTimeInterval(-30),
                events: [CodexFixture.tokenCountEvent(offset: 0, rateLimits: twoWindow(primary: 99, secondary: 99, resets: now))]),
            named: "rollout-cli.jsonl", into: dir, mtime: now.addingTimeInterval(-5)
        )
        // Subagent rollout — must be ignored.
        CodexFixture.write(
            CodexFixture.rollout(start: now.addingTimeInterval(-40),
                events: [CodexFixture.tokenCountEvent(offset: 0, rateLimits: twoWindow(primary: 88, secondary: 88, resets: now))],
                source: ["subagent": ["other": "guardian"]]),
            named: "rollout-sub.jsonl", into: dir, mtime: now.addingTimeInterval(-6)
        )
        // The real Desktop session.
        CodexFixture.write(
            CodexFixture.rollout(start: now.addingTimeInterval(-50),
                events: [CodexFixture.tokenCountEvent(offset: 0, rateLimits: twoWindow(primary: 16, secondary: 3, resets: now))]),
            named: "rollout-desktop.jsonl", into: dir, mtime: now.addingTimeInterval(-10)
        )
        let snap = reader(dir).readSnapshot()
        #expect(snap.source == .rollout)
        #expect(snap.limits.first(where: { $0.displayLabel == "5-hour limit" })?.usedPercent == 16)
        #expect(snap.limits.first(where: { $0.displayLabel == "Weekly" })?.usedPercent == 3)
    }

    @Test("Accepts the newer `codex_work_desktop` originator (family gate)")
    func acceptsCodexWorkDesktopOriginator() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        CodexFixture.write(
            CodexFixture.rollout(originator: "codex_work_desktop", start: now.addingTimeInterval(-30),
                events: [CodexFixture.tokenCountEvent(offset: 0, rateLimits: twoWindow(primary: 22, secondary: 7, resets: now))]),
            named: "rollout-work.jsonl", into: dir, mtime: now.addingTimeInterval(-5)
        )
        let snap = reader(dir).readSnapshot()
        #expect(snap.source == .rollout)
        #expect(snap.limits.first(where: { $0.displayLabel == "5-hour limit" })?.usedPercent == 22)
    }

    @Test("Ignores an editor-class originator (codex_vscode) even with a valid reading")
    func ignoresEditorOriginator() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        CodexFixture.write(
            CodexFixture.rollout(originator: "codex_vscode", start: now.addingTimeInterval(-30),
                events: [CodexFixture.tokenCountEvent(offset: 0, rateLimits: twoWindow(primary: 50, secondary: 20, resets: now))]),
            named: "rollout-vscode.jsonl", into: dir, mtime: now.addingTimeInterval(-5)
        )
        // The editor originator is not the Desktop family → dropped → nothing to show.
        #expect(reader(dir).readSnapshot().source == .unavailable)
    }

    @Test("Picks the reading with the newest capture time, not merely the newest-mtime file")
    func newestCaptureWinsOverNewestMtime() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        // File A: newest mtime, but its token_count is old (touched by a non-turn event after the last
        // turn). Its rate_limits reads 99%.
        CodexFixture.write(
            CodexFixture.rollout(start: now.addingTimeInterval(-20 * 60),
                events: [CodexFixture.tokenCountEvent(offset: 0, rateLimits: twoWindow(primary: 99, secondary: 99, resets: now))]),
            named: "rollout-A.jsonl", into: dir, mtime: now.addingTimeInterval(-1 * 60)
        )
        // File B: older mtime, but a much fresher token_count (2 min ago), reading 16%/3%.
        CodexFixture.write(
            CodexFixture.rollout(start: now.addingTimeInterval(-3 * 60),
                events: [CodexFixture.tokenCountEvent(offset: 60, rateLimits: twoWindow(primary: 16, secondary: 3, resets: now))]),
            named: "rollout-B.jsonl", into: dir, mtime: now.addingTimeInterval(-2 * 60)
        )
        let snap = reader(dir).readSnapshot()
        // The fresher capture (B) must win, even though A's file mtime is newer.
        #expect(snap.limits.first(where: { $0.displayLabel == "5-hour limit" })?.usedPercent == 16)
    }

    @Test("NO RESURRECTION across files: a window in an older rollout is never revived into a newer reading")
    func noResurrectionAcrossFiles() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        // Older file: both windows.
        CodexFixture.write(
            CodexFixture.rollout(sessionID: "old", start: now.addingTimeInterval(-30 * 60),
                events: [CodexFixture.tokenCountEvent(offset: 0, rateLimits: twoWindow(primary: 40, secondary: 12, resets: now))]),
            named: "rollout-old.jsonl", into: dir, mtime: now.addingTimeInterval(-20 * 60)
        )
        // Newer file (authoritative): only the 5-hour window.
        let onlyFive = CodexFixture.rateLimitsObject([
            ("primary", CodexFixture.windowObject(percent: 18, windowMinutes: 300, resets: now)),
        ])
        CodexFixture.write(
            CodexFixture.rollout(sessionID: "new", start: now.addingTimeInterval(-2 * 60),
                events: [CodexFixture.tokenCountEvent(offset: 0, rateLimits: onlyFive)]),
            named: "rollout-new.jsonl", into: dir, mtime: now.addingTimeInterval(-1 * 60)
        )
        let snap = reader(dir).readSnapshot()
        // The current reading is the newer file's single window; the older file's Weekly is NOT revived.
        #expect(snap.limits.map(\.displayLabel) == ["5-hour limit"])
        #expect(snap.limits.first?.usedPercent == 18)
    }

    @Test("AUTHORITATIVE EMPTY across files: a newer empty reading beats an older rollout with limits")
    func newerAuthoritativeEmptyBeatsOlderWithLimits() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        // Older file: a real reading with two windows, captured ~10 min ago.
        CodexFixture.write(
            CodexFixture.rollout(sessionID: "old", start: now.addingTimeInterval(-15 * 60),
                events: [CodexFixture.tokenCountEvent(offset: 0, rateLimits: twoWindow(primary: 40, secondary: 12, resets: now))]),
            named: "rollout-old.jsonl", into: dir, mtime: now.addingTimeInterval(-10 * 60)
        )
        // Newer file: a VALID but empty rate_limits, captured ~1 min ago (authoritative empty).
        CodexFixture.write(
            CodexFixture.rollout(sessionID: "new", start: now.addingTimeInterval(-2 * 60),
                events: [(60, "token_count", ["rate_limits": [String: Any]()])]),
            named: "rollout-new.jsonl", into: dir, mtime: now.addingTimeInterval(-30)
        )
        let snap = reader(dir).readSnapshot()
        // The newest authoritative reading is empty → no rows, even though an older rollout had limits.
        #expect(snap.limits.isEmpty)
        #expect(snap.hasData == false)
    }

    @Test("A newer rollout with NO rate_limits object does NOT clear an older rollout's limits")
    func newerWithoutRateLimitsDoesNotClear() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        // Older file: a real reading with two windows.
        CodexFixture.write(
            CodexFixture.rollout(sessionID: "old", start: now.addingTimeInterval(-15 * 60),
                events: [CodexFixture.tokenCountEvent(offset: 0, rateLimits: twoWindow(primary: 44, secondary: 8, resets: now))]),
            named: "rollout-old.jsonl", into: dir, mtime: now.addingTimeInterval(-10 * 60)
        )
        // Newer file: a fresh Desktop session with NO rate_limits object yet (missing) → no reading, so
        // it must not clear the older rollout's limits.
        CodexFixture.write(
            CodexFixture.rollout(sessionID: "new", start: now.addingTimeInterval(-1 * 60),
                events: [(30, "user_message", [:])]),
            named: "rollout-new.jsonl", into: dir, mtime: now.addingTimeInterval(-30)
        )
        let snap = reader(dir).readSnapshot()
        // The older authoritative reading still shows; the newer no-rate_limits file is ignored.
        #expect(snap.limits.map(\.displayLabel) == ["5-hour limit", "Weekly"])
        #expect(snap.limits.first?.usedPercent == 44)
    }

    @Test("No Codex Desktop rollout with limits → unavailable")
    func noneWithLimits() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        CodexFixture.write(
            CodexFixture.rollout(start: now.addingTimeInterval(-30), events: [(0, "user_message", [:])]),
            named: "rollout-nolimits.jsonl", into: dir, mtime: now
        )
        #expect(reader(dir).readSnapshot().source == .unavailable)
    }
}

@Suite("CodexUsageLimitVisibility — per-row, separate from Claude")
struct CodexUsageLimitVisibilityTests {

    @Test("Hide/show round-trips through the persisted string")
    func roundTrip() {
        var v = CodexUsageLimitVisibility()
        let weekly = CodexUsageLimit(windowMinutes: 10080, usedPercent: 3, resetsAt: nil)
        #expect(v.isVisible(weekly))
        v.setHidden(true, for: weekly)
        #expect(v.isHidden(weekly))
        let restored = CodexUsageLimitVisibility(persisted: v.persisted)
        #expect(restored.isHidden(weekly))
    }

    @Test("Filters a snapshot to non-hidden rows, order preserved")
    func filters() {
        let five = CodexUsageLimit(windowMinutes: 300, usedPercent: 16, resetsAt: nil)
        let weekly = CodexUsageLimit(windowMinutes: 10080, usedPercent: 3, resetsAt: nil)
        let snap = CodexUsageLimitSnapshot(limits: [five, weekly], capturedAt: nil, source: .rollout)
        var v = CodexUsageLimitVisibility()
        v.setHidden(true, for: five)
        #expect(v.visibleLimits(in: snap).map(\.displayLabel) == ["Weekly"])
    }

    @Test("A hidden row that later disappears then returns stays hidden (set is not pruned)")
    func hiddenSurvivesDisappearance() {
        let five = CodexUsageLimit(windowMinutes: 300, usedPercent: 16, resetsAt: nil)
        var v = CodexUsageLimitVisibility()
        v.setHidden(true, for: five)
        // Snapshot with no rows at all — nothing prunes the hidden set.
        _ = v.visibleLimits(in: .unavailable)
        // The window returns later; the earlier hide choice still applies.
        #expect(v.isHidden(five))
    }
}

// MARK: - Provider + model auto-refresh

/// A fake reader whose scripted snapshot can change mid-test, counting reads so a test can prove the
/// enable-gate short-circuits and that the provider re-reads on later ticks.
private final class CountingCodexUsageReader: CodexUsageLimitReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var _snapshot: CodexUsageLimitSnapshot
    init(snapshot: CodexUsageLimitSnapshot) { self._snapshot = snapshot }
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return _count }
    func setSnapshot(_ s: CodexUsageLimitSnapshot) { lock.lock(); _snapshot = s; lock.unlock() }
    func readSnapshot() -> CodexUsageLimitSnapshot {
        lock.lock(); _count += 1; let s = _snapshot; lock.unlock()
        return s
    }
}

/// A thread-safe boolean the test can flip to model the user toggling the feature at runtime.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Bool
    init(_ v: Bool) { self.v = v }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

/// A fake provider that lets a test push snapshots synchronously (no timer, no files).
private final class FakeCodexUsageProvider: CodexUsageLimitObserving, @unchecked Sendable {
    private(set) var snapshot: CodexUsageLimitSnapshot = .unavailable
    private var callback: (@Sendable (CodexUsageLimitSnapshot) -> Void)?
    func start(onSnapshot: @escaping @Sendable (CodexUsageLimitSnapshot) -> Void) {
        callback = onSnapshot
        callback?(snapshot)
    }
    func stop() { callback = nil }
    func emit(_ newSnapshot: CodexUsageLimitSnapshot) {
        snapshot = newSnapshot
        callback?(newSnapshot)
    }
}

@Suite("CodexUsageLimitProvider + Model — automatic refresh, display-only")
struct CodexUsageLimitRefreshTests {

    private func snapshotWithData(percent: Double = 21) -> CodexUsageLimitSnapshot {
        CodexUsageLimitSnapshot(
            limits: [CodexUsageLimit(windowMinutes: 300, usedPercent: percent, resetsAt: nil)],
            capturedAt: Date(), source: .rollout
        )
    }

    /// Poll the provider's published snapshot until `predicate` holds or the timeout elapses.
    private func waitForSnapshot(
        _ provider: CodexUsageLimitProvider,
        timeout: TimeInterval = 2.0,
        where predicate: (CodexUsageLimitSnapshot) -> Bool
    ) async -> CodexUsageLimitSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let s = provider.snapshot
            if predicate(s) { return s }
            try? await Task.sleep(nanoseconds: 10_000_000)   // 10 ms
        }
        return provider.snapshot
    }

    @Test("Enabled: the provider re-reads on each tick and republishes a CHANGED reading")
    func periodicRefreshRepublishesChanges() async {
        // A fast interval so several ticks happen quickly (production cadence is 5 s; injectable only
        // for tests). The reader starts at 21%, then flips to 55% mid-run.
        let reader = CountingCodexUsageReader(snapshot: snapshotWithData(percent: 21))
        let provider = CodexUsageLimitProvider(reader: reader, isEnabled: { true }, interval: 0.03, leeway: 0.005)
        provider.start { _ in }
        let first = await waitForSnapshot(provider) { $0.limits.first?.usedPercent == 21 }
        #expect(first.limits.first?.usedPercent == 21)
        let countAfterFirst = reader.readCount

        reader.setSnapshot(snapshotWithData(percent: 55))
        let second = await waitForSnapshot(provider) { $0.limits.first?.usedPercent == 55 }
        provider.stop()
        #expect(second.limits.first?.usedPercent == 55)     // picked up the change on a later tick
        #expect(reader.readCount > countAfterFirst)          // it genuinely re-read
    }

    @Test("Disabled: ticks keep firing but the reader is never called; the surface stays unavailable")
    func disabledSkipsReaderAcrossTicks() async {
        let flag = AtomicFlag(true)
        let reader = CountingCodexUsageReader(snapshot: snapshotWithData())
        let provider = CodexUsageLimitProvider(reader: reader, isEnabled: { flag.value }, interval: 0.03, leeway: 0.005)
        provider.start { _ in }
        // Prove the timer is genuinely live: while enabled it reads and publishes.
        _ = await waitForSnapshot(provider) { $0.hasData }
        #expect(reader.readCount >= 1)

        // Now disable at runtime: further ticks must NOT touch the reader, and the surface collapses.
        flag.value = false
        let collapsed = await waitForSnapshot(provider) { $0.source == .unavailable }
        #expect(collapsed.source == .unavailable)
        let readsAtDisable = reader.readCount
        // Let several more tick periods elapse; the reader count must not advance while disabled.
        try? await Task.sleep(nanoseconds: 200_000_000)   // ~6 tick periods
        provider.stop()
        #expect(reader.readCount == readsAtDisable)
    }

    @MainActor
    @Test("Model republishes provider changes, and collapses to empty when windows vanish")
    func modelRepublishesChanges() {
        let provider = FakeCodexUsageProvider()
        let model = CodexUsageLimitModel(provider: provider)
        model.start()
        #expect(model.snapshot.source == .unavailable)   // initial

        provider.emit(snapshotWithData())
        #expect(model.snapshot.hasData)
        #expect(model.snapshot.limits.first?.usedPercent == 21)

        // A later reading that drops all windows collapses the surface — no stale rows linger.
        provider.emit(.unavailable)
        #expect(model.snapshot.hasData == false)
        model.stop()
    }
}
