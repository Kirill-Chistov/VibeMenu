import Foundation
import Testing
@testable import VibeMenuCore

// I/O adapter tests for `CodexSessionReader` (docs/decisions/0017). Uses synthetic rollout files in
// a throwaway temp directory — never the real ~/.codex. Covers the originator gate (CLI ignored),
// folder-name-only output, malformed/large/missing-file safety, the mtime prefilter, dedup, and cap.

@Suite("CodexSessionReader — reading + gating")
struct CodexSessionReaderTests {

    private func reader(_ dir: URL, maxFileBytes: Int = CodexSessionReader.defaultMaxFileBytes,
                        headTailBytes: Int = CodexSessionReader.defaultHeadTailBytes) -> CodexSessionReader {
        CodexSessionReader(directory: dir, maxFileBytes: maxFileBytes, headTailBytes: headTailBytes)
    }

    @Test("Missing directory → empty list (never a crash)")
    func missingDirectory() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        #expect(reader(dir).readSessions(now: Date()).isEmpty)
    }

    @Test("Internal subagent rollouts are dropped (not user-facing Desktop sessions)")
    func subagentRolloutIgnored() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        // A real Desktop session.
        CodexFixture.write(
            CodexFixture.rollout(sessionID: "s-main", cwd: "/w/MyProject", start: now.addingTimeInterval(-20),
                                 events: [(0, "task_started", [:]), (10, "user_message", [:])],
                                 source: "vscode"),
            named: "rollout-main.jsonl", into: dir
        )
        // A subagent rollout with a *different* id — must be dropped so it never phantoms a row.
        CodexFixture.write(
            CodexFixture.rollout(sessionID: "s-guardian", cwd: "/w/MyProject", start: now.addingTimeInterval(-15),
                                 events: [(0, "task_started", [:])],
                                 source: ["subagent": ["other": "guardian"]]),
            named: "rollout-guardian.jsonl", into: dir
        )
        let sessions = reader(dir).readSessions(now: now)
        #expect(sessions.count == 1)
        #expect(sessions.first?.id == "s-main")
    }

    @Test("Originator gate is case-insensitive (a casing change doesn't hide every session)")
    func originatorCaseInsensitive() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        CodexFixture.write(
            CodexFixture.rollout(sessionID: "s-lower", originator: "codex desktop", cwd: "/w/MyProject",
                                 start: now.addingTimeInterval(-20), events: [(0, "user_message", [:])]),
            named: "rollout-lower.jsonl", into: dir
        )
        #expect(reader(dir).readSessions(now: now).count == 1)
    }

    @Test("Reads a Desktop rollout as one session with the folder basename only")
    func readsDesktopSession() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        CodexFixture.write(
            CodexFixture.rollout(
                sessionID: "s-desktop", cwd: "/Users/SECRET_USER/Work/SECRET_PARENT/MyProject",
                start: now.addingTimeInterval(-30),
                events: [(0, "task_started", [:]), (20, "user_message", [:])]   // active, mid-turn
            ),
            named: "rollout-s-desktop.jsonl", into: dir
        )
        let sessions = reader(dir).readSessions(now: now)
        #expect(sessions.count == 1)
        let s = try! #require(sessions.first)
        #expect(s.id == "s-desktop")
        #expect(s.folderName == "MyProject")
        #expect(s.state == .active)
        // No sensitive marker on any string field of the session.
        let mirror = Mirror(reflecting: s)
        for child in mirror.children {
            if let str = child.value as? String {
                for marker in CodexFixture.sensitiveMarkers {
                    #expect(!str.contains(marker))
                }
            }
        }
    }

    @Test("Codex CLI sessions are ignored (originator gate)")
    func cliIgnored() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        CodexFixture.write(
            CodexFixture.rollout(sessionID: "cli-1", originator: "codex_cli_rs",
                                 start: now.addingTimeInterval(-10), events: [(0, "task_started", [:])]),
            named: "rollout-cli-1.jsonl", into: dir
        )
        CodexFixture.write(
            CodexFixture.rollout(sessionID: "desk-1", start: now.addingTimeInterval(-10),
                                 events: [(0, "task_started", [:])]),
            named: "rollout-desk-1.jsonl", into: dir
        )
        let sessions = reader(dir).readSessions(now: now)
        #expect(sessions.map(\.id) == ["desk-1"])
    }

    @Test("Malformed file is skipped; a valid sibling still reads")
    func malformedSkipped() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        CodexFixture.write("this is not json\n{bad", named: "rollout-bad.jsonl", into: dir)
        CodexFixture.write(
            CodexFixture.rollout(sessionID: "ok", start: now.addingTimeInterval(-5),
                                 events: [(0, "task_complete", [:])]),
            named: "rollout-ok.jsonl", into: dir
        )
        let sessions = reader(dir).readSessions(now: now)
        #expect(sessions.map(\.id) == ["ok"])
        #expect(sessions.first?.state == .done)
    }

    @Test("Content older than the recency horizon is dropped even if the file was just written")
    func staleContentDropped() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        // Last activity 2h ago (> 60min horizon), but the file mtime is now.
        CodexFixture.write(
            CodexFixture.rollout(sessionID: "old", start: now.addingTimeInterval(-2 * 3600),
                                 events: [(0, "task_complete", [:])]),
            named: "rollout-old.jsonl", into: dir
        )
        #expect(reader(dir).readSessions(now: now).isEmpty)
    }

    @Test("mtime prefilter skips files not modified within the horizon")
    func mtimePrefilter() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        // Content is fresh, but the file mtime is backdated 2h → the cheap stat prefilter skips it.
        CodexFixture.write(
            CodexFixture.rollout(sessionID: "backdated", start: now.addingTimeInterval(-5),
                                 events: [(0, "task_started", [:])]),
            named: "rollout-backdated.jsonl", into: dir, mtime: now.addingTimeInterval(-2 * 3600)
        )
        #expect(reader(dir).readSessions(now: now).isEmpty)
    }

    @Test("A session id appearing in two files is deduped to the newest activity")
    func dedupBySessionID() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        CodexFixture.write(
            CodexFixture.rollout(sessionID: "dup", start: now.addingTimeInterval(-300),
                                 events: [(0, "task_complete", [:])]),
            named: "rollout-dup-old.jsonl", into: dir
        )
        CodexFixture.write(
            CodexFixture.rollout(sessionID: "dup", start: now.addingTimeInterval(-20),
                                 events: [(0, "task_started", [:])]),   // newer, active
            named: "rollout-dup-new.jsonl", into: dir
        )
        let sessions = reader(dir).readSessions(now: now)
        #expect(sessions.count == 1)
        #expect(sessions.first?.state == .active)   // the newer row wins
    }

    @Test("Large file over the byte cap still reads via head+tail (meta + completion survive)")
    func largeFileHeadTail() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        // Build a rollout whose middle is bloated well past a tiny 512-byte cap, but whose head
        // (session_meta) and tail (task_complete) are intact.
        let start = now.addingTimeInterval(-10)
        var lines = [CodexFixture.line(
            timestamp: start, type: "session_meta",
            payload: ["session_id": "big", "id": "big", "originator": "Codex Desktop",
                      "cwd": "/x/y/BigProj", "timestamp": CodexFixture.iso(start)]
        )]
        for i in 0..<50 {
            lines.append(CodexFixture.line(
                timestamp: start.addingTimeInterval(Double(i) * 0.1), type: "event_msg",
                payload: ["type": "reasoning", "text": String(repeating: "x", count: 200)]
            ))
        }
        lines.append(CodexFixture.line(
            timestamp: now, type: "event_msg", payload: ["type": "task_complete"]
        ))
        CodexFixture.write(lines.joined(separator: "\n") + "\n", named: "rollout-big.jsonl", into: dir)

        let sessions = reader(dir, maxFileBytes: 512, headTailBytes: 256).readSessions(now: now)
        #expect(sessions.count == 1)
        #expect(sessions.first?.id == "big")
        #expect(sessions.first?.folderName == "BigProj")
        #expect(sessions.first?.state == .done)   // tail task_complete detected
    }

    @Test("Sessions come back most-active-first")
    func sortedMostActiveFirst() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        CodexFixture.write(
            CodexFixture.rollout(sessionID: "done1", start: now.addingTimeInterval(-30),
                                 events: [(0, "task_complete", [:])]),
            named: "rollout-done1.jsonl", into: dir
        )
        CodexFixture.write(
            CodexFixture.rollout(sessionID: "active1", start: now.addingTimeInterval(-10),
                                 events: [(0, "task_started", [:])]),
            named: "rollout-active1.jsonl", into: dir
        )
        let sessions = reader(dir).readSessions(now: now)
        #expect(sessions.map(\.id) == ["active1", "done1"])   // active sorts before done
    }
}

@Suite("CodexSessionReader — unchanged-rollout cache")
struct CodexSessionReaderCacheTests {

    private func reader(
        _ dir: URL,
        recencyHorizon: TimeInterval = 120,
        maxSessions: Int = CodexSessionReader.defaultMaxSessions,
        activeWindow: TimeInterval = CodexSessionState.defaultActiveWindow,
        idleWindow: TimeInterval = CodexSessionState.defaultIdleWindow,
        doneWindow: TimeInterval = CodexSessionState.defaultDoneWindow
    ) -> CodexSessionReader {
        CodexSessionReader(
            directory: dir,
            recencyHorizon: recencyHorizon,
            maxSessions: maxSessions,
            activeWindow: activeWindow,
            idleWindow: idleWindow,
            doneWindow: doneWindow
        )
    }

    private func append(_ line: String, to url: URL) {
        let handle = try! FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try! handle.seekToEnd()
        try! handle.write(contentsOf: Data(line.utf8))
    }

    @Test("An unchanged rollout is parsed once across repeated reads")
    func unchangedParsedOnce() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        CodexFixture.write(
            CodexFixture.rollout(
                sessionID: "cached", start: now.addingTimeInterval(-10),
                events: [(0, "task_started", [:])]
            ),
            named: "rollout-cached.jsonl", into: dir, mtime: now
        )
        let subject = reader(dir)

        #expect(subject.readSessions(now: now).map(\.id) == ["cached"])
        #expect(subject.cacheDiagnostics == CodexSessionCacheDiagnostics(
            candidateFiles: 1, cacheHits: 0, filesReparsed: 1, cachedFiles: 1
        ))

        #expect(subject.readSessions(now: now).map(\.id) == ["cached"])
        #expect(subject.cacheDiagnostics == CodexSessionCacheDiagnostics(
            candidateFiles: 1, cacheHits: 1, filesReparsed: 0, cachedFiles: 1
        ))
    }

    @Test("State ages from active to idle and stale without reparsing")
    func stateAgesWithoutReparse() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        CodexFixture.write(
            CodexFixture.rollout(
                sessionID: "aging", start: now,
                events: [(0, "task_started", [:])]
            ),
            named: "rollout-aging.jsonl", into: dir, mtime: now
        )
        let subject = reader(
            dir, recencyHorizon: 100, activeWindow: 10, idleWindow: 20, doneWindow: 20
        )

        #expect(subject.readSessions(now: now).first?.state == .active)
        #expect(subject.readSessions(now: now.addingTimeInterval(11)).first?.state == .idle)
        #expect(subject.cacheDiagnostics.filesReparsed == 0)
        #expect(subject.cacheDiagnostics.cacheHits == 1)
        #expect(subject.readSessions(now: now.addingTimeInterval(21)).first?.state == .stale)
        #expect(subject.cacheDiagnostics.filesReparsed == 0)
        #expect(subject.cacheDiagnostics.cacheHits == 1)
    }

    @Test("Appending activity invalidates the cache on the next read")
    func appendedActivityInvalidates() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let start = now.addingTimeInterval(-120)
        let url = CodexFixture.write(
            CodexFixture.rollout(
                sessionID: "append-activity", start: start,
                events: [(0, "task_started", [:])]
            ),
            named: "rollout-append-activity.jsonl", into: dir, mtime: now
        )
        let subject = reader(dir, recencyHorizon: 300)
        #expect(subject.readSessions(now: now).first?.state == .idle)

        append(CodexFixture.line(
            timestamp: now, type: "event_msg", payload: ["type": "task_started"]
        ) + "\n", to: url)

        let updated = try! #require(subject.readSessions(now: now).first)
        #expect(updated.state == .active)
        #expect(abs(updated.lastActivity.timeIntervalSince(now)) < 0.01)
        #expect(subject.cacheDiagnostics.cacheHits == 0)
        #expect(subject.cacheDiagnostics.filesReparsed == 1)
    }

    @Test("Appending task_complete invalidates and releases that mode")
    func appendedCompletionInvalidatesAndReleases() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let start = now.addingTimeInterval(-10)
        let url = CodexFixture.write(
            CodexFixture.rollout(
                sessionID: "append-complete", originator: "codex_work_desktop", start: start,
                events: [(0, "task_started", [:])]
            ),
            named: "rollout-append-complete.jsonl", into: dir, mtime: now
        )
        let subject = reader(dir)
        let active = subject.readSessions(now: now)
        #expect(active.first?.state == .active)
        #expect(CodexSessionActivity.automationIntent(active, mode: .work) == .hold)

        append(CodexFixture.line(
            timestamp: now, type: "event_msg", payload: ["type": "task_complete"]
        ) + "\n", to: url)

        let completed = subject.readSessions(now: now)
        #expect(completed.first?.state == .done)
        #expect(completed.first?.endedWithCompletion == true)
        #expect(CodexSessionActivity.automationIntent(completed, mode: .work) == .release)
        #expect(subject.cacheDiagnostics.filesReparsed == 1)
    }

    @Test("Same-path replacement and truncation both invalidate")
    func replacementAndTruncationInvalidate() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let oldText = CodexFixture.rollout(
            sessionID: "old-1", start: now, events: [(0, "task_started", [:])]
        )
        let newText = CodexFixture.rollout(
            sessionID: "new-2", start: now, events: [(0, "task_started", [:])]
        )
        #expect(oldText.utf8.count == newText.utf8.count)
        let url = CodexFixture.write(
            oldText, named: "rollout-replaced.jsonl", into: dir, mtime: now
        )
        let subject = reader(dir)
        #expect(subject.readSessions(now: now).map(\.id) == ["old-1"])

        // Atomic write replaces the file identity. Preserve the same mtime and size so this phase
        // specifically exercises the stable resource-identifier part of the cache identity.
        try! Data(newText.utf8).write(to: url, options: .atomic)
        try! FileManager.default.setAttributes(
            [.modificationDate: now], ofItemAtPath: url.path
        )
        #expect(subject.readSessions(now: now).map(\.id) == ["new-2"])
        #expect(subject.cacheDiagnostics.filesReparsed == 1)

        let handle = try! FileHandle(forWritingTo: url)
        try! handle.truncate(atOffset: 0)
        try! handle.close()
        #expect(subject.readSessions(now: now).isEmpty)
        #expect(subject.cacheDiagnostics.filesReparsed == 1)
        #expect(subject.cacheDiagnostics.cachedFiles == 1)   // negative result replaced stale active
    }

    @Test("A malformed changed file cannot preserve an old active result")
    func changedMalformedFailsClosed() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let url = CodexFixture.write(
            CodexFixture.rollout(
                sessionID: "fail-closed", start: now,
                events: [(0, "task_started", [:])]
            ),
            named: "rollout-fail-closed.jsonl", into: dir, mtime: now
        )
        let subject = reader(dir)
        #expect(subject.readSessions(now: now).first?.state == .active)

        try! Data("{malformed changed rollout\n".utf8).write(to: url)
        #expect(subject.readSessions(now: now).isEmpty)
        #expect(subject.cacheDiagnostics.filesReparsed == 1)
        #expect(subject.cacheDiagnostics.cachedFiles == 1)

        // The nil summary is reusable only while that malformed file is unchanged.
        #expect(subject.readSessions(now: now).isEmpty)
        #expect(subject.cacheDiagnostics.cacheHits == 1)
        #expect(subject.cacheDiagnostics.filesReparsed == 0)
    }

    @Test("Deleted and horizon-expired files are evicted")
    func deletionAndHorizonExpiryEvict() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let deletedURL = CodexFixture.write(
            CodexFixture.rollout(
                sessionID: "deleted", start: now,
                events: [(0, "task_started", [:])]
            ),
            named: "rollout-deleted.jsonl", into: dir, mtime: now
        )
        CodexFixture.write(
            CodexFixture.rollout(
                sessionID: "expires", start: now,
                events: [(0, "task_started", [:])]
            ),
            named: "rollout-expires.jsonl", into: dir, mtime: now
        )
        let subject = reader(dir, recencyHorizon: 30)
        #expect(subject.readSessions(now: now).count == 2)
        #expect(subject.cacheDiagnostics.cachedFiles == 2)

        try! FileManager.default.removeItem(at: deletedURL)
        #expect(subject.readSessions(now: now).map(\.id) == ["expires"])
        #expect(subject.cacheDiagnostics.cachedFiles == 1)

        #expect(subject.readSessions(now: now.addingTimeInterval(31)).isEmpty)
        #expect(subject.cacheDiagnostics.candidateFiles == 0)
        #expect(subject.cacheDiagnostics.cachedFiles == 0)
    }

    @Test("Work and Codex modes survive cache reuse as independent sessions")
    func modesSurviveCacheReuse() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        CodexFixture.write(
            CodexFixture.rollout(
                sessionID: "work-cache", originator: "codex_work_desktop", start: now,
                events: [(0, "task_started", [:])]
            ),
            named: "rollout-work-cache.jsonl", into: dir, mtime: now
        )
        CodexFixture.write(
            CodexFixture.rollout(
                sessionID: "codex-cache", start: now,
                events: [(0, "task_started", [:])]
            ),
            named: "rollout-codex-cache.jsonl", into: dir, mtime: now
        )
        let subject = reader(dir)
        _ = subject.readSessions(now: now)
        let cached = subject.readSessions(now: now)

        #expect(cached.first { $0.id == "work-cache" }?.mode == .work)
        #expect(cached.first { $0.id == "codex-cache" }?.mode == .codex)
        #expect(CodexSessionActivity.automationIntent(cached, mode: .work) == .hold)
        #expect(CodexSessionActivity.automationIntent(cached, mode: .codex) == .hold)
        #expect(subject.cacheDiagnostics.cacheHits == 2)
        #expect(subject.cacheDiagnostics.filesReparsed == 0)
    }

    @Test("The cache is bounded by the existing candidate-file cap")
    func cacheIsBounded() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        for index in 0..<(CodexSessionReader.maxFilesScanned + 1) {
            let fileTime = now.addingTimeInterval(-Double(index) / 1000)
            CodexFixture.write(
                CodexFixture.rollout(
                    sessionID: "bounded-\(index)", start: fileTime,
                    events: [(0, "task_started", [:])]
                ),
                named: "rollout-bounded-\(index).jsonl", into: dir, mtime: fileTime
            )
        }
        let subject = reader(dir, recencyHorizon: 300, maxSessions: 1)
        _ = subject.readSessions(now: now)

        #expect(subject.cacheDiagnostics.candidateFiles == CodexSessionReader.maxFilesScanned)
        #expect(subject.cacheDiagnostics.filesReparsed == CodexSessionReader.maxFilesScanned)
        #expect(subject.cacheDiagnostics.cachedFiles == CodexSessionReader.maxFilesScanned)
    }
}

// Title resolution from `session_index.jsonl` (docs/decisions/0017). Synthetic index + rollouts in a
// throwaway dir; the reader is given an explicit index URL inside that same dir so it never touches the
// real ~/.codex. Covers the id-join, the folder/generic fallbacks, unsafe-title rejection + no leakage,
// and safe handling of stale/orphan index entries.
@Suite("CodexSessionReader — session titles from the index")
struct CodexSessionReaderTitleTests {

    /// A reader whose title index lives inside this test's own temp dir (never the real index).
    private func reader(_ dir: URL) -> CodexSessionReader {
        CodexSessionReader(
            directory: dir,
            titleReader: CodexSessionIndexReader(url: dir.appendingPathComponent("session_index.jsonl"))
        )
    }

    @Test("A safe index title becomes the display name, joined by session id")
    func titleFromIndex() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        CodexFixture.write(
            CodexFixture.rollout(sessionID: "s-1", cwd: "/w/MyProject", start: now.addingTimeInterval(-20),
                                 events: [(0, "task_started", [:])]),
            named: "rollout-s-1.jsonl", into: dir
        )
        CodexFixture.writeIndex(CodexFixture.sessionIndex([("s-1", "Polish the menu")]), into: dir)

        let s = try! #require(reader(dir).readSessions(now: now).first)
        #expect(s.id == "s-1")
        #expect(s.title == "Polish the menu")
        #expect(s.folderName == "MyProject")
        #expect(s.displayName == "Polish the menu")   // title wins over folder
    }

    @Test("No index entry for the session → falls back to the folder name")
    func fallbackToFolder() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        CodexFixture.write(
            CodexFixture.rollout(sessionID: "s-2", cwd: "/w/MyProject", start: now.addingTimeInterval(-20),
                                 events: [(0, "task_started", [:])]),
            named: "rollout-s-2.jsonl", into: dir
        )
        // Index has some *other* session, not s-2.
        CodexFixture.writeIndex(CodexFixture.sessionIndex([("s-other", "Unrelated")]), into: dir)

        let s = try! #require(reader(dir).readSessions(now: now).first)
        #expect(s.title == nil)
        #expect(s.displayName == "MyProject")
    }

    @Test("No safe title and no folder name → the generic 'Codex session'")
    func fallbackToGeneric() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        // cwd "/" yields no folder name; no index entry either.
        CodexFixture.write(
            CodexFixture.rollout(sessionID: "s-3", cwd: "/", start: now.addingTimeInterval(-20),
                                 events: [(0, "task_started", [:])]),
            named: "rollout-s-3.jsonl", into: dir
        )
        let s = try! #require(reader(dir).readSessions(now: now).first)
        #expect(s.folderName == nil)
        #expect(s.title == nil)
        #expect(s.displayName == CodexSession.genericName)
    }

    @Test("An unsafe index title is dropped → folder fallback, and nothing sensitive leaks")
    func unsafeTitleDropped() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        CodexFixture.write(
            CodexFixture.rollout(sessionID: "s-4", cwd: "/w/MyProject", start: now.addingTimeInterval(-20),
                                 events: [(0, "task_started", [:])]),
            named: "rollout-s-4.jsonl", into: dir
        )
        // A path-like "title" that must be rejected by the sanitiser.
        CodexFixture.writeIndex(CodexFixture.sessionIndex([("s-4", "/Users/bob/secret/Project")]), into: dir)

        let s = try! #require(reader(dir).readSessions(now: now).first)
        #expect(s.title == nil)
        #expect(s.displayName == "MyProject")
        #expect(!s.displayName.contains("/"))
        // No sensitive marker or path fragment on any string field of the session.
        let mirror = Mirror(reflecting: s)
        for child in mirror.children {
            if let str = child.value as? String {
                #expect(!str.contains("secret"))
                for marker in CodexFixture.sensitiveMarkers { #expect(!str.contains(marker)) }
            }
        }
    }

    @Test("An index entry for a session with no recent rollout is ignored (no phantom row)")
    func staleIndexEntryIgnored() {
        let dir = CodexFixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        CodexFixture.write(
            CodexFixture.rollout(sessionID: "s-5", cwd: "/w/MyProject", start: now.addingTimeInterval(-20),
                                 events: [(0, "task_started", [:])]),
            named: "rollout-s-5.jsonl", into: dir
        )
        // The index also lists an archived/old thread with no corresponding recent rollout file.
        CodexFixture.writeIndex(
            CodexFixture.sessionIndex([("s-5", "Live one"), ("s-ghost", "Archived thread")]),
            into: dir
        )
        let sessions = reader(dir).readSessions(now: now)
        #expect(sessions.map(\.id) == ["s-5"])          // the ghost index entry never becomes a row
        #expect(sessions.first?.displayName == "Live one")
    }
}
