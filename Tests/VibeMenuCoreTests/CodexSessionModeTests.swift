import Foundation
import Testing
@testable import VibeMenuCore

// Unified OpenAI desktop app compatibility — Work + Codex modes
// (docs/decisions/0017-codex-session-support.md, Amendment 6).
//
// The unified ChatGPT app writes **both** its Work sessions (`originator` `codex_work_desktop`) and
// its Codex sessions (`originator` `Codex Desktop`) into the same already-approved rollout tree, and
// both report the **same** shared server-side allowance through the same `token_count.rate_limits`
// object. These tests prove that:
//
//   * each originator derives the right safe `CodexSessionMode` (and the raw originator never
//     reaches a session value);
//   * both stay accepted Desktop sessions with independent row identities;
//   * a weekly-only reading with a `null` secondary and the newer unrelated siblings still produces
//     exactly one correctly labelled Weekly row and leaks nothing;
//   * the persisted per-row visibility encoding is unchanged by the user-visible rename.
//
// Sanitized fixtures only — no real `~/.codex` data.

@Suite("CodexSessionMode — safe Work/Codex derivation")
struct CodexSessionModeTests {

    @Test("`codex_work_desktop` derives .work")
    func workOriginatorDerivesWork() {
        #expect(CodexSessionMode.derive(originator: "codex_work_desktop") == .work)
        // Casing and stray whitespace must not change the mode: the real files are Codex-controlled.
        #expect(CodexSessionMode.derive(originator: "CODEX_WORK_DESKTOP") == .work)
        #expect(CodexSessionMode.derive(originator: "  codex_work_desktop  ") == .work)
        #expect(CodexSessionMode.derive(originator: "codex_work_desktop").label == "ChatGPT Work")
    }

    @Test("The canonical Codex Desktop originator derives .codex")
    func codexOriginatorDerivesCodex() {
        #expect(CodexSessionMode.derive(originator: CodexRolloutParser.desktopOriginator) == .codex)
        #expect(CodexSessionMode.derive(originator: "codex desktop") == .codex)
        #expect(CodexSessionMode.derive(originator: "Codex Desktop").label == "Codex")
    }

    @Test("An unknown desktop-family originator falls back to .codex, never a guessed Work")
    func unknownFamilyFallsBackToCodex() {
        // Accepted by the Desktop gate but not the Work segment ⇒ conservative default.
        #expect(CodexRolloutParser.isDesktopOriginator("codex_personal_desktop"))
        #expect(CodexSessionMode.derive(originator: "codex_personal_desktop") == .codex)
        // A substring match must not promote to Work.
        #expect(CodexSessionMode.derive(originator: "codex_workspace_desktop") == .codex)
        // Non-desktop / degenerate inputs are total and safe.
        #expect(CodexSessionMode.derive(originator: "codex_cli_rs") == .codex)
        #expect(CodexSessionMode.derive(originator: "codex__desktop") == .codex)
        #expect(CodexSessionMode.derive(originator: "") == .codex)
    }

    @Test("Both Work and Codex rollouts stay accepted Desktop sessions, with independent identities")
    func bothModesReadAsSeparateSessions() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()

        CodexFixture.write(
            CodexFixture.rollout(
                sessionID: "s-work", originator: "codex_work_desktop",
                cwd: "/Users/SECRET_USER/Work/SECRET_PARENT/WorkProject",
                start: now.addingTimeInterval(-30),
                events: [(0, "task_started", [:]), (20, "user_message", [:])],
                includeSensitive: true
            ),
            named: "rollout-work.jsonl", into: dir
        )
        CodexFixture.write(
            CodexFixture.rollout(
                sessionID: "s-codex", originator: CodexRolloutParser.desktopOriginator,
                cwd: "/Users/SECRET_USER/Work/SECRET_PARENT/CodexProject",
                start: now.addingTimeInterval(-40),
                events: [(0, "task_started", [:]), (10, "user_message", [:])],
                includeSensitive: true
            ),
            named: "rollout-codex.jsonl", into: dir
        )

        let sessions = CodexSessionReader(directory: dir).readSessions(now: now)
        #expect(sessions.count == 2)
        // Two rows, two ids — a Work session never collapses into the Codex one (or vice versa).
        #expect(Set(sessions.map(\.id)) == ["s-work", "s-codex"])

        let work = try! #require(sessions.first { $0.id == "s-work" })
        let codex = try! #require(sessions.first { $0.id == "s-codex" })
        #expect(work.mode == .work)
        #expect(work.agent == "ChatGPT Work")
        #expect(codex.mode == .codex)
        #expect(codex.agent == "Codex")
        // Each keeps its own folder/state; the modes do not share row state.
        #expect(work.folderName == "WorkProject")
        #expect(codex.folderName == "CodexProject")

        // The raw originator must never reach the session value, and nothing sensitive may leak.
        for session in sessions {
            for child in Mirror(reflecting: session).children {
                guard let text = child.value as? String else { continue }
                #expect(!text.contains("codex_work_desktop"))
                #expect(!text.lowercased().contains("originator"))
                for marker in CodexFixture.sensitiveMarkers {
                    #expect(!text.contains(marker))
                }
            }
        }
    }

    @Test("The visible turn-timer copy carries the mode through unchanged")
    func timerCopyPreservesMode() {
        let now = Date()
        let session = CodexSession(
            id: "s-work", state: .active, folderName: "P", startedAt: now, lastActivity: now,
            mode: .work
        )
        #expect(session.withTimerStart(now).mode == .work)
        #expect(session.withTimerStart(now).agent == "ChatGPT Work")
    }

    @Test("Each mode derives its keep-awake hold from its own sessions only")
    func modeScopedKeepAwake() {
        let now = Date()
        func session(_ mode: CodexSessionMode, _ state: CodexSessionState) -> CodexSession {
            CodexSession(id: "s-\(mode.rawValue)", state: state, folderName: "P",
                         startedAt: now, lastActivity: now, mode: mode)
        }
        // Same conservative state rule for both modes: only `.active` holds.
        #expect(CodexSessionActivity.automationIntent([session(.work, .active)], mode: .work) == .hold)
        #expect(CodexSessionActivity.automationIntent([session(.codex, .active)], mode: .codex) == .hold)
        #expect(CodexSessionActivity.automationIntent([session(.work, .done)], mode: .work) == .release)
        #expect(CodexSessionActivity.automationIntent([session(.codex, .done)], mode: .codex) == .release)

        // …and one mode's activity never speaks for the other: an active Work session must not
        // produce a Codex hold, or a finished Codex session would look like it was still working.
        #expect(CodexSessionActivity.automationIntent([session(.work, .active)], mode: .codex) == .release)
        #expect(CodexSessionActivity.automationIntent([session(.codex, .active)], mode: .work) == .release)

        // Mixed list: each mode reads only its own row.
        let mixed = [session(.work, .active), session(.codex, .done)]
        #expect(CodexSessionActivity.automationIntent(mixed, mode: .work) == .hold)
        #expect(CodexSessionActivity.automationIntent(mixed, mode: .codex) == .release)
    }
}

@Suite("OpenAI limits — shared allowance presentation + newer rate_limits siblings")
struct OpenAISharedLimitsTests {

    /// A weekly-only reading in the shape the app can write: one `primary` window that is really the
    /// **weekly** one, a **null** `secondary`, and unrelated non-window siblings.
    ///
    /// The sibling keys here are deliberately **synthetic and generic** (`unknown_scalar` /
    /// `unknown_object`), not copied from any app's schema: what the reader must guarantee is that a
    /// sibling *of any name* carrying no numeric `used_percent` is not a window. Naming real fields
    /// would document another app's account/plan/billing schema in this repo for no test value.
    private func weeklyOnlyRateLimits(resets: Date) -> [String: Any] {
        [
            "primary": CodexFixture.windowObject(percent: 12, windowMinutes: 10080, resets: resets),
            "secondary": NSNull(),
            // Unrelated siblings: a null, a non-object scalar, and an object with no `used_percent`.
            // None is a usage window; none may surface.
            "unknown_null": NSNull(),
            "unknown_scalar": "SECRET_LIMIT",
            "unknown_object": ["some_number": 555_555, "some_flag": true, "some_text": "SECRET_PLAN"],
        ]
    }

    @Test("A weekly-only reading with a null secondary produces exactly one Weekly row")
    func weeklyOnlyProducesOneWeeklyRow() {
        let now = Date()
        let resets = now.addingTimeInterval(3 * 24 * 3600)
        let text = CodexFixture.rollout(
            sessionID: "s-work", originator: "codex_work_desktop", start: now.addingTimeInterval(-60),
            events: [CodexFixture.tokenCountEvent(offset: 30, rateLimits: weeklyOnlyRateLimits(resets: resets))]
        )
        let reading = try! #require(CodexRateLimitRollout.parseLatest(text: text, fallbackCaptured: now))
        #expect(CodexRolloutParser.isDesktopOriginator(reading.originator))

        let snapshot = reading.snapshot()
        #expect(snapshot.limits.count == 1)
        let row = try! #require(snapshot.limits.first)
        // Labelled from its own duration, not from the `primary` slot it happened to occupy.
        #expect(row.windowMinutes == 10080)
        #expect(row.displayLabel == "Weekly")
        #expect(row.slot == "primary")
        #expect(row.percentText == "12%")
    }

    @Test("Unrelated `rate_limits` siblings are ignored and never surface")
    func unrelatedSiblingsIgnored() {
        let now = Date()
        let text = CodexFixture.rollout(
            sessionID: "s-codex", start: now.addingTimeInterval(-60),
            events: [CodexFixture.tokenCountEvent(
                offset: 30, rateLimits: weeklyOnlyRateLimits(resets: now.addingTimeInterval(3600))
            )]
        )
        let reading = try! #require(CodexRateLimitRollout.parseLatest(text: text, fallbackCaptured: now))
        // Only the one real window: a null, a scalar, and an object without `used_percent` are not.
        #expect(reading.windows.count == 1)
        #expect(reading.windows.map(\.slot) == ["primary"])

        for row in reading.snapshot().limits {
            for child in Mirror(reflecting: row).children {
                guard let text = child.value as? String else { continue }
                for marker in CodexFixture.sensitiveMarkers {
                    #expect(!text.contains(marker))
                }
            }
            // The row's user-visible strings carry no plan/limit identity either.
            #expect(!row.displayLabel.contains("SECRET"))
            #expect(!row.visibilityID.contains("SECRET"))
            #expect(!row.id.contains("SECRET"))
        }
    }

    @Test("Work and Codex share one allowance section — the newest reading across modes wins")
    func newestReadingAcrossModesWins() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()

        // Older Codex-mode reading with a different percentage…
        CodexFixture.write(
            CodexFixture.rollout(
                sessionID: "s-codex", originator: CodexRolloutParser.desktopOriginator,
                start: now.addingTimeInterval(-600),
                events: [CodexFixture.tokenCountEvent(offset: 0, rateLimits: CodexFixture.rateLimitsObject(
                    [("primary", CodexFixture.windowObject(percent: 5, windowMinutes: 10080, resets: nil))]
                ))]
            ),
            named: "rollout-codex.jsonl", into: dir, mtime: now.addingTimeInterval(-600)
        )
        // …and a newer Work-mode reading of the SAME shared allowance.
        CodexFixture.write(
            CodexFixture.rollout(
                sessionID: "s-work", originator: "codex_work_desktop",
                start: now.addingTimeInterval(-120),
                events: [CodexFixture.tokenCountEvent(offset: 0, rateLimits: CodexFixture.rateLimitsObject(
                    [("primary", CodexFixture.windowObject(percent: 42, windowMinutes: 10080, resets: nil))]
                ))]
            ),
            named: "rollout-work.jsonl", into: dir, mtime: now.addingTimeInterval(-120)
        )

        let snapshot = CodexUsageLimitReader(directory: dir).readSnapshot()
        // One shared section — never a separate Work row beside a Codex row.
        #expect(snapshot.limits.count == 1)
        #expect(snapshot.limits.first?.percentText == "42%")
        #expect(snapshot.source == .rollout)
    }

    @Test("Settings/menu copy states the shared allowance and turn-bound freshness")
    func sharedAllowanceCopyIsTruthful() {
        let note = CodexUsageLimitsMenuCopy.sharedAllowanceNote
        #expect(note.contains("Work"))
        #expect(note.contains("Codex"))
        #expect(note.contains("share one OpenAI allowance"))
        // Must say a reading comes from a real turn, not from opening the app or the usage screen.
        #expect(note.contains("runs a turn"))
        #expect(note.contains("usage"))
        #expect(note.lowercased().contains("does not refresh it"))

        // The empty state and its help repeat the same limitation.
        #expect(CodexUsageLimitsMenuCopy.emptyState.contains("Work or Codex turn"))
        #expect(CodexUsageLimitsMenuCopy.emptyStateHelp.contains(note))

        // The Settings source names both modes of the one local source, never a raw originator.
        let source = CodexUsageLimitsMenuCopy.settingsSourceName
        #expect(source.contains("Work"))
        #expect(source.contains("Codex"))
        #expect(!source.contains("_desktop"))
    }

    @Test("The visible provider rename does not change the stable notification routing key")
    func providerDisplayNameIsSeparateFromRoutingKey() {
        #expect(AttentionProvider.codex.displayName == "OpenAI")
        #expect(AttentionProvider.claude.displayName == "Claude")
        // `rawValue` is what a delivered notification stores/round-trips; it must stay put.
        #expect(AttentionProvider.codex.rawValue == "Codex")
        #expect(AttentionProvider(rawValue: "Codex") == .codex)
        #expect(AttentionProvider.codex.applicationBundleIdentifier == "com.openai.codex")
    }
}

@Suite("OpenAI limits — persisted preferences survive the user-visible rename")
struct OpenAILimitsPreferenceCompatibilityTests {

    /// The app's storage keys (`showCodexSessions`, `showCodexLimits`, `codexLimitsHiddenIDs`,
    /// `codexLimitsSectionExpanded`) are deliberately unchanged by the rename, so a current user
    /// keeps their enablement and hidden-row choices. What `VibeMenuCore` owns — and what this
    /// asserts — is the *encoding* stored under `codexLimitsHiddenIDs` and the duration-derived
    /// `visibilityID`s it references.
    @Test("Legacy hidden-row ids still hide the same rows after the rename")
    func legacyHiddenIDsStillApply() {
        let now = Date()
        let weekly = CodexUsageLimit(windowMinutes: 10080, usedPercent: 12, resetsAt: now, slot: "primary")
        let fiveHour = CodexUsageLimit(windowMinutes: 300, usedPercent: 7, resetsAt: now, slot: "secondary")
        // The two ids a pre-rename install may already have persisted.
        #expect(weekly.visibilityID == "weekly")
        #expect(fiveHour.visibilityID == "fiveHour")

        let visibility = CodexUsageLimitVisibility(persisted: "weekly")
        #expect(visibility.isHidden(weekly))
        #expect(visibility.isVisible(fiveHour))

        let snapshot = CodexUsageLimitSnapshot(
            limits: [weekly, fiveHour], capturedAt: now, source: .rollout
        )
        #expect(visibility.visibleLimits(in: snapshot).map(\.visibilityID) == ["fiveHour"])
    }

    @Test("A hide choice round-trips through the unchanged persisted encoding")
    func hideChoiceRoundTrips() {
        var visibility = CodexUsageLimitVisibility(persisted: "fiveHour")
        visibility.setHidden(true, id: "weekly")
        // Sorted, newline-joined — exactly what the existing `codexLimitsHiddenIDs` key stores.
        #expect(visibility.persisted == "fiveHour\nweekly")
        #expect(CodexUsageLimitVisibility(persisted: visibility.persisted).hiddenIdentifiers
            == ["fiveHour", "weekly"])
    }
}
