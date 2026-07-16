import Foundation
@testable import VibeMenuCore

// Sanitized Codex rollout fixtures for the Codex session-detection tests
// (docs/decisions/0017-codex-session-support.md).
//
// IMPORTANT: these fixtures are fully synthetic — **no real `~/.codex` data**. They deliberately
// stuff the *forbidden* fields (fake system prompt, repo URL, prompt/response/reasoning/tool text,
// account id, auth token) into the rollout so the privacy tests can prove none of them ever reach a
// `CodexRolloutSummary` / `CodexSession`. The safe marker strings all start with `SECRET_` so a test
// can assert no output field contains them.

enum CodexFixture {
    /// The sensitive markers embedded in `includeSensitive` fixtures — none of these may appear in
    /// any parsed output field.
    static let sensitiveMarkers = [
        "SECRET_SYSTEM_PROMPT", "SECRET_REPO", "SECRET_USER", "SECRET_PARENT",
        "SECRET_PROMPT", "SECRET_RESPONSE", "SECRET_REASONING", "SECRET_TOOL_OUTPUT",
        "SECRET_COMMAND", "sk-SECRETKEY", "acct_SECRET", "SECRET_LIMIT", "SECRET_PLAN",
    ]

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// One JSONL envelope line.
    static func line(timestamp: Date, type: String, payload: [String: Any]) -> String {
        let obj: [String: Any] = ["timestamp": iso(timestamp), "type": type, "payload": payload]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(decoding: data, as: UTF8.self)
    }

    /// Build a full rollout file's text.
    ///
    /// - `events`: `(offsetSecondsFromStart, event_msg category, extraPayload)` in chronological
    ///   order. The category is the only thing the parser reads; `extraPayload` lets a test add
    ///   forbidden content (prompt/response/tool text) to prove it's ignored.
    /// - `includeSensitive`: also stuff `base_instructions`, `git.origin_url`, etc. into the meta.
    /// - `source`: the `session_meta.source` value — a string like `"vscode"` (a real Desktop-launched
    ///   session) or a `["subagent": …]` dict (an internal subagent run the reader must drop).
    static func rollout(
        sessionID: String = "sess-abc123",
        originator: String = CodexRolloutParser.desktopOriginator,
        cwd: String = "/Users/someone/Work/MyProject",
        start: Date,
        events: [(TimeInterval, String, [String: Any])] = [],
        includeSensitive: Bool = false,
        includeMeta: Bool = true,
        source: Any? = nil
    ) -> String {
        var lines: [String] = []

        if includeMeta {
            var meta: [String: Any] = [
                "session_id": sessionID,
                "id": sessionID,
                "originator": originator,
                "cwd": cwd,
                "timestamp": iso(start),
            ]
            if let source { meta["source"] = source }
            if includeSensitive {
                meta["base_instructions"] = "SECRET_SYSTEM_PROMPT do the thing"
                meta["git"] = [
                    "origin_url": "git@github.com:acme/SECRET_REPO.git",
                    "branch": "SECRET_branch",
                    "commit_hash": "deadbeef",
                ]
                meta["account_id"] = "acct_SECRET"
            }
            lines.append(line(timestamp: start, type: "session_meta", payload: meta))
        }

        for (offset, category, extra) in events {
            var payload: [String: Any] = ["type": category]
            for (k, v) in extra { payload[k] = v }
            lines.append(line(timestamp: start.addingTimeInterval(offset), type: "event_msg", payload: payload))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// A `rate_limits` payload matching the real Codex shape: `primary` (5-hour, window 300) and
    /// `secondary` (weekly, window 10080), each with `used_percent` + `resets_at`. The extra
    /// `limit_id`/`plan_type`/`credits`/`limit_name` fields mirror the real object so tests can prove
    /// the parser ignores them. `resets_at` values are absolute epoch seconds.
    static func rateLimits(
        primaryPercent: Double, secondaryPercent: Double,
        primaryResets: Date, secondaryResets: Date,
        primaryWindow: Int = 300, secondaryWindow: Int = 10080
    ) -> [String: Any] {
        [
            "limit_id": "codex",            // generic — must never surface
            "limit_name": "SECRET_LIMIT",   // must never surface
            "plan_type": "SECRET_PLAN",     // account tier — must never surface
            "credits": NSNull(),
            "primary": [
                "used_percent": primaryPercent,
                "window_minutes": primaryWindow,
                "resets_at": primaryResets.timeIntervalSince1970,
            ],
            "secondary": [
                "used_percent": secondaryPercent,
                "window_minutes": secondaryWindow,
                "resets_at": secondaryResets.timeIntervalSince1970,
            ],
        ]
    }

    /// A `token_count` event tuple (for `rollout(events:)`) carrying a `rate_limits` object plus the
    /// sensitive-but-ignored `info` token counts.
    static func tokenCountEvent(offset: TimeInterval, rateLimits: [String: Any]) -> (TimeInterval, String, [String: Any]) {
        (offset, "token_count", [
            "rate_limits": rateLimits,
            "info": ["total_token_usage": ["total_tokens": 4242], "model_context_window": 200000],
        ])
    }

    /// One `rate_limits` window child object, matching the real per-window shape: `used_percent`
    /// (required) plus optional `window_minutes` (duration → label) and `resets_at` (epoch seconds).
    /// Pass `windowMinutes: nil` to model a window that carried a percentage but no duration.
    static func windowObject(percent: Double, windowMinutes: Int?, resets: Date?) -> [String: Any] {
        var w: [String: Any] = ["used_percent": percent]
        if let windowMinutes { w["window_minutes"] = windowMinutes }
        if let resets { w["resets_at"] = resets.timeIntervalSince1970 }
        return w
    }

    /// A `rate_limits` object built from explicit `(slot, windowObject)` pairs, so a test can model any
    /// window set — one window, several, an unknown/absent duration, or a `primary` slot that is
    /// actually the weekly window. `includeSiblings` adds the real non-window strings
    /// (`limit_id`/`limit_name`/`plan_type`) that must never surface; `credits` adds the real
    /// `credits` object (`balance`/`has_credits`/`unlimited`) — NOT a usage window, so it must be
    /// excluded. `SECRET_` markers let the privacy test prove none of it leaks.
    static func rateLimitsObject(
        _ slots: [(slot: String, window: [String: Any])],
        includeSiblings: Bool = true,
        credits: Bool = false
    ) -> [String: Any] {
        var rl: [String: Any] = [:]
        if includeSiblings {
            rl["limit_id"] = "codex"
            rl["limit_name"] = "SECRET_LIMIT"
            rl["plan_type"] = "SECRET_PLAN"
        }
        if credits {
            rl["credits"] = ["balance": 555555, "has_credits": true, "unlimited": false]
        }
        for (slot, window) in slots { rl[slot] = window }
        return rl
    }

    /// Build a synthetic `session_index.jsonl` from `(id, threadName)` pairs. When `includeSensitive`
    /// is set, each line also carries the *forbidden* fields the real index has NO business exposing
    /// to VibeMenu (`cwd`, `first_user_message`, `preview`, `git_origin_url`), all stuffed with
    /// `SECRET_` markers, so a test can prove the parser reads ONLY `id` + `thread_name`.
    static func sessionIndex(
        _ entries: [(id: String, threadName: String)], includeSensitive: Bool = true
    ) -> String {
        entries.map { entry in
            var obj: [String: Any] = [
                "id": entry.id,
                "thread_name": entry.threadName,
                "updated_at": 1_700_000_000,
            ]
            if includeSensitive {
                obj["cwd"] = "/Users/SECRET_USER/Work/SECRET_PARENT/MyProject"
                obj["first_user_message"] = "SECRET_PROMPT please refactor the thing"
                obj["preview"] = "SECRET_RESPONSE here you go"
                obj["git_origin_url"] = "git@github.com:acme/SECRET_REPO.git"
            }
            let data = try! JSONSerialization.data(withJSONObject: obj)
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n") + "\n"
    }

    /// Write a `session_index.jsonl` into `directory`, returning its URL.
    @discardableResult
    static func writeIndex(
        _ text: String, into directory: URL, named name: String = "session_index.jsonl"
    ) -> URL {
        write(text, named: name, into: directory)
    }

    /// A "busy" fixture: a completed turn whose event payloads are stuffed with forbidden content.
    static func completedTurnWithSensitivePayloads(start: Date) -> String {
        rollout(
            cwd: "/Users/SECRET_USER/Work/SECRET_PARENT/MyProject",
            start: start,
            events: [
                (0, "task_started", [:]),
                (1, "user_message", ["message": "SECRET_PROMPT please refactor"]),
                (2, "reasoning", ["text": "SECRET_REASONING thinking hard"]),
                (3, "agent_message", ["message": "SECRET_RESPONSE here you go"]),
                (4, "token_count", ["info": ["total_token_usage": 1234]]),
                (5, "task_complete", ["last_agent_message": "SECRET_TOOL_OUTPUT done"]),
            ],
            includeSensitive: true
        )
    }

    /// Write a rollout file into `directory` and optionally backdate its mtime. Returns the URL.
    @discardableResult
    static func write(
        _ text: String, named name: String, into directory: URL, mtime: Date? = nil
    ) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try? Data(text.utf8).write(to: url)
        if let mtime {
            try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
        return url
    }

    /// A fresh temp directory for a reader test.
    static func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeMenuCodexTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
