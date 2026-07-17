import Foundation

// Claude detection L2 — hook heartbeat (docs/decisions/0008-claude-heartbeat-detection.md).
// This pure evaluator reports internal Claude state; the app-level power model treats
// only `.active` as an automatic keep-awake request.
//
// L1 (ClaudeActivityState.evaluate) reads process presence + session-file *mtime* and
// cannot tell "working" from "waiting for input". L2 adds a **VibeMenu-owned** heartbeat:
// an opt-in Claude Code hook script (Support/ClaudeHeartbeat/vibemenu-claude-hook.sh)
// writes a tiny, privacy-constrained per-session JSON file each time a hook fires. Those
// files carry ONLY a schema version, a timestamp, the hook *event name*, and the
// *session id* — never prompt/response/tool/transcript/cwd contents. Reading them is safe
// because they are ours, not Claude's transcripts (docs/PRIVACY.md, AGENTS.md §6).
//
// This file is pure and I/O-free: the event/record value types, the malformed-safe
// decoder (Data → record?), and the aggregate decision are all unit-tested with synthetic
// inputs. The file enumeration + reading lives in the ClaudeActivityProvider adapter.

// MARK: - Heartbeat event

/// The Claude Code hook events VibeMenu observes, normalised from the raw
/// `hook_event_name` string. Verified live in the user's local-agent environment:
/// `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `SessionEnd`
/// all fire; `Notification` is included for the "needs attention / waiting" signal.
/// `SubagentStart`/`SubagentStop` are the subagent (Task) lifecycle events — per the
/// current Claude Code hooks reference, `SubagentStop` fires when *one* subagent finishes
/// and returns control to the parent turn, which keeps running, so it is **not** a
/// session-level finish (see `docs/decisions/0010`).
public enum ClaudeHeartbeatEvent: String, Codable, Equatable, Sendable, CaseIterable {
    case sessionStart
    case userPromptSubmit
    case preToolUse
    case postToolUse
    case subagentStart
    case subagentStop
    case notification
    /// A tool-use permission prompt is pending: Claude Code's documented `PermissionRequest` hook,
    /// which fires when Claude asks the user to Allow/Deny a tool — **at the moment the approval
    /// dialog is presented, before the user responds** (verified live in the Claude Desktop Code
    /// tab). This is the high-priority "needs the user" signal the radar surfaces as
    /// `.permissionRequested` ("Needs approval"). It clears when the **next** lifecycle event
    /// (`PostToolUse`/`Stop`/…) overwrites the session's heartbeat after the user responds.
    ///
    /// Note the **Deny** path has no equivalent signal on Claude Desktop: its Code tab fires *no*
    /// hook event when the user denies (verified live — not `Stop`, `PostToolUse`, or the CLI's
    /// `PermissionDenied`), so a denied row keeps this state until the session's next event
    /// (`SessionEnd`/a new prompt) or the prune horizon (docs/decisions/0018).
    case permissionRequested
    case stop
    /// The turn ended because of an **API error**, not a normal completion: Claude Code's
    /// documented `StopFailure` hook, which fires when the request errored out (rate limit,
    /// overloaded, server error, auth/billing failure, …) instead of `Stop`. Crucially, on the
    /// error path **`Stop` does not fire — only `StopFailure`** (verified against the Claude Code
    /// hooks reference), so without recognising it the session's newest heartbeat stays the last
    /// *work* event (`PreToolUse`/`PostToolUse`/…). That leaves a **finished** session stuck as
    /// `.quietWorking` ("Quiet") until it ages out to `.stale`, and — because an unrecognised name
    /// falls to `.unknown`, which `indicatesWorkInProgress` — keeps automatic sleep prevention held
    /// after the turn already ended (docs/decisions/0019). Treated exactly like `Stop`: a finished
    /// turn awaiting the user (`isWaitingEvent`, **not** `indicatesWorkInProgress`), so it derives
    /// `.done` and releases the hold. It is **not** `isSessionEnd` — the session stays alive and the
    /// user can retry, at which point the next event overwrites this heartbeat.
    case stopFailure
    case sessionEnd
    /// Any hook name we do not recognise (kept explicit rather than dropped, so a future
    /// Claude Code event still records a live-session heartbeat instead of vanishing).
    case unknown

    /// Map a raw `hook_event_name` (as written into the heartbeat file) to a case.
    /// Unrecognised names become `.unknown` — never a crash, never a silent drop.
    public init(hookEventName: String) {
        switch hookEventName {
        case "SessionStart": self = .sessionStart
        case "UserPromptSubmit": self = .userPromptSubmit
        case "PreToolUse": self = .preToolUse
        case "PostToolUse": self = .postToolUse
        case "SubagentStart": self = .subagentStart
        case "SubagentStop": self = .subagentStop
        case "Notification": self = .notification
        case "PermissionRequest": self = .permissionRequested
        case "Stop": self = .stop
        case "StopFailure": self = .stopFailure
        case "SessionEnd": self = .sessionEnd
        default: self = .unknown
        }
    }

    /// Events that indicate Claude is **actively working** (a prompt was just submitted,
    /// a tool call is starting/finishing, or a subagent was just spawned). Drives the
    /// Active/Waiting **display** state. Note this is deliberately *narrower* than
    /// `indicatesWorkInProgress` (which governs the keep-awake *automation* decision):
    /// `subagentStop` and unknown/future events are not shown as Active, but they still
    /// hold sleep prevention so a silent gap never triggers a false release.
    public var isActiveEvent: Bool {
        switch self {
        case .userPromptSubmit, .preToolUse, .postToolUse, .subagentStart: return true
        default: return false
        }
    }

    /// Events that indicate Claude has **stopped and is waiting** (finished replying, ended a
    /// turn on an API error, or posted a notification asking for attention). `stopFailure` is a
    /// finish just like `stop` — the turn is over and the user is now the one to act (retry).
    public var isWaitingEvent: Bool {
        switch self {
        case .stop, .stopFailure, .notification: return true
        default: return false
        }
    }

    /// The session has ended; its heartbeat should be excluded from detection.
    public var isSessionEnd: Bool { self == .sessionEnd }

    /// A bare session-**lifecycle** event that, on its own, signals *no actual work was done* —
    /// the session merely started or ended, with no prompt submitted and no tool run. Used by the
    /// radar to tell the Claude **desktop app's throwaway home-directory launches**
    /// (`SessionStart` → `SessionEnd`, nothing in between) apart from a real session that
    /// submitted a prompt or ran a tool (docs/decisions/0011 task step 3). `SessionStart` and
    /// `SessionEnd` are lifecycle-only; every work event (`UserPromptSubmit`, `PreToolUse`,
    /// `PostToolUse`, subagent lifecycle) and the attention/finish events (`Stop`,
    /// `Notification`) are not.
    public var isLifecycleOnly: Bool {
        switch self {
        case .sessionStart, .sessionEnd: return true
        default: return false
        }
    }

    /// Whether this event — as a session's *most recent* heartbeat — means work is still
    /// in progress **for the keep-awake automation decision** (subject to the bounded
    /// quiet-hold cap). This is intentionally distinct from `isActiveEvent`
    /// (docs/decisions/0010): the automation contract must not release sleep prevention
    /// during a long silent tool/subagent/build phase, so it treats subagent lifecycle
    /// events *and* unknown/future events as "still working". Only the events that mean
    /// Claude has genuinely finished the turn or is blocked waiting for the user —
    /// `stop`, `notification`, `sessionStart` (started, no prompt yet) — count as
    /// not-working. (`sessionEnd` is excluded upstream before this is consulted.)
    ///
    /// - `subagentStop`: a subagent finished but the **parent turn keeps running**, so it
    ///   must never trigger a global release (task rule 5). Held (within the cap).
    /// - `unknown`: a hook name we do not recognise (e.g. a future subagent/tool event).
    ///   Held (within the cap) so an unknown event can never cause a false release
    ///   (task rule 5). Bounded by the cap, so it can't pin sleep prevention forever.
    /// - `notification`: Claude Code notifications are permission/idle/attention prompts —
    ///   i.e. **waiting for the user**, not working (SPEC §5.1 lets the Mac sleep while an
    ///   agent is blocked on input). Classified conservatively as not-working and
    ///   documented (task rule 6); manual keep-awake still covers "hold while I'm away".
    public var indicatesWorkInProgress: Bool {
        switch self {
        case .userPromptSubmit, .preToolUse, .postToolUse,
             .subagentStart, .subagentStop, .unknown:
            return true
        case .sessionStart, .notification, .permissionRequested, .stop, .stopFailure, .sessionEnd:
            // `.permissionRequested`: Claude is blocked on a user Allow/Deny decision — the *user*
            // is the bottleneck, not Claude, so the Mac may sleep (SPEC §5.1, like `.notification`).
            // `.stopFailure`: the turn already ended (on an API error), so — exactly like `.stop` —
            // there is no work in flight to hold for; releasing lets the Mac sleep (docs/decisions/0019).
            return false
        }
    }
}

// MARK: - Heartbeat record

/// One privacy-safe heartbeat: the latest event VibeMenu saw for a Claude Code session.
///
/// A pure value type so the aggregate decision can be unit-tested with synthetic records.
/// Note what is *not* here: no prompt/response text, no tool input/output, no transcript
/// path, no full cwd — only a session id, an event, a timestamp, and (schema 2+) the project
/// **folder name** the hook derived from cwd's final path component.
public struct ClaudeHeartbeatRecord: Equatable, Sendable {
    /// The Claude Code session id (an opaque identifier; never shown in diagnostics).
    public let sessionID: String

    /// The most recent hook event observed for this session.
    public let event: ClaudeHeartbeatEvent

    /// When the heartbeat file was last written (from the file's `updatedAt`).
    public let updatedAt: Date

    /// The project **folder name** for this session, i.e. the final path component of the
    /// session's cwd, captured by the opt-in hook (schema 2+). Never a full path, never a
    /// parent directory — the hook takes `basename(cwd)` and writes only that. `nil` for
    /// schema-1 heartbeat files (written before this field existed) or when the hook couldn't
    /// determine a folder name (missing/odd cwd), so the radar falls back to a generic label.
    public let project: String?

    public init(sessionID: String, event: ClaudeHeartbeatEvent, updatedAt: Date, project: String? = nil) {
        self.sessionID = sessionID
        self.event = event
        self.updatedAt = updatedAt
        self.project = project
    }
}

extension ClaudeHeartbeatRecord {
    /// The heartbeat-file schema VibeMenu writes/reads. Bumped only on a breaking layout
    /// change; the reader tolerates unknown future versions best-effort. **v2** adds the
    /// optional `project` folder-name field (docs/decisions/0012-session-name-from-cwd.md);
    /// the reader still accepts v1 files (no `project`) unchanged.
    public static let currentSchemaVersion = 2

    /// The on-disk heartbeat-file shape. Only these five fields are ever present; the hook
    /// script writes nothing else (Support/ClaudeHeartbeat/vibemenu-claude-hook.sh). `project`
    /// is absent in schema-1 files and decodes to `nil`.
    private struct FileDTO: Decodable {
        let schemaVersion: Int?
        let updatedAt: Double?   // epoch seconds
        let event: String?       // raw hook_event_name
        let sessionID: String?
        let project: String?     // project folder name (schema 2+); absent ⇒ nil
    }

    /// Pure, malformed-safe decode of one heartbeat file's bytes. Returns `nil` for
    /// anything that isn't a heartbeat object with the required `updatedAt`, `event`, and
    /// `sessionID` fields — so a truncated write, a non-JSON file, or a stray file is
    /// simply ignored rather than crashing the reader. Reads only the five known fields; the
    /// optional `project` is trimmed and an empty/whitespace value normalises to `nil`.
    public static func decode(from data: Data) -> ClaudeHeartbeatRecord? {
        guard let dto = try? JSONDecoder().decode(FileDTO.self, from: data) else { return nil }
        guard
            let sessionID = dto.sessionID, !sessionID.isEmpty,
            let updatedAt = dto.updatedAt,
            let event = dto.event
        else { return nil }
        let project = dto.project?.trimmingCharacters(in: .whitespaces)
        return ClaudeHeartbeatRecord(
            sessionID: sessionID,
            event: ClaudeHeartbeatEvent(hookEventName: event),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            project: (project?.isEmpty == false) ? project : nil
        )
    }
}

// MARK: - Automation intent (keep-awake hold vs release)

/// What VibeMenu's **automatic** keep-awake should do, derived from Claude activity.
///
/// Deliberately separate from the Active/Waiting/Idle **display** state
/// (`ClaudeActivityState`): the display may read *Idle* while automation still *holds*
/// sleep prevention during a long silent tool/subagent phase (docs/decisions/0010). Only
/// `.hold` is a request; `.release` lets the Mac follow its normal sleep policy (unless
/// the user's manual keep-awake is on, which always wins and is applied separately in
/// `PowerAssertionModel`).
public enum ClaudeAutomationIntent: String, Equatable, Sendable, CaseIterable {
    /// Keep automatic sleep prevention held (Claude is working, or quietly-but-still
    /// working within the bounded cap).
    case hold
    /// Release automatic sleep prevention (Claude finished, is waiting for the user, the
    /// process is gone, or the quiet-hold cap has elapsed).
    case release
}

// MARK: - L2 aggregate decision

extension ClaudeActivityState {
    /// How fresh a heartbeat's latest event must be to still count as `active`. Generous
    /// enough to bridge a long single tool call or a long "thinking" gap between hook
    /// events (during which no hook fires), but bounded so a crashed/hung session ages out
    /// of `active` rather than sticking there forever. The prompt `Stop`/`Notification`
    /// events move a finished session to `waiting` immediately, independent of this window.
    public static let defaultHeartbeatActiveThreshold: TimeInterval = 120

    /// Maximum age of a heartbeat record before it is ignored entirely (treated as if the
    /// session had no heartbeat, falling back to L1). This is the "do not let a stale
    /// heartbeat pin the UI forever" backstop (task rule 6): several minutes, after which a
    /// forgotten session file no longer influences detection.
    public static let defaultHeartbeatStaleThreshold: TimeInterval = 600

    /// Bounded **quiet-hold cap** for the keep-awake automation: after the last
    /// *work-in-progress* heartbeat, automatic sleep prevention stays held for at most this
    /// long even when no further hook fires — bridging a long silent tool call, subagent
    /// run, build, or test phase (task rules 3–4, docs/decisions/0010). Past the cap with no
    /// new active event, automation releases so a hung or stale session can never keep the
    /// Mac awake forever. **15 minutes.** Much larger than the display active window (120s)
    /// on purpose: the display may fall back to *Idle* after 120s while automation keeps
    /// holding up to this cap — the two are deliberately decoupled, so an aged active
    /// heartbeat is *not* collapsed into "finished".
    public static let defaultQuietHoldCap: TimeInterval = 15 * 60

    /// The heartbeat-only aggregate over the live sessions, plus the metadata the DEBUG
    /// diagnostics surface. Separated from `evaluate` so both share one code path.
    struct HeartbeatAggregate: Equatable {
        /// `.active` if any live session is actively working; else `.waiting` if any live
        /// session is stopped/waiting; else `nil` (no fresh, non-ended heartbeat records).
        var state: ClaudeActivityState?
        /// Age of the newest fresh, non-ended record (clamped ≥ 0), or `nil` if none.
        var newestFreshAge: TimeInterval?
        /// Count of fresh, non-ended sessions considered.
        var sessionCount: Int
    }

    /// Reduce raw heartbeat records to the aggregate. Pure.
    ///
    /// Per session (newest record wins if several are passed): a `SessionEnd` is excluded;
    /// a record older than `staleThreshold` is ignored; otherwise the record is *fresh and
    /// live* and votes `.active` (an active event within `activeThreshold`) or `.waiting`
    /// (a `Stop`/`Notification`, an active event that has aged past `activeThreshold`, or a
    /// `SessionStart`/unknown event — all "live but not actively working"). The aggregate
    /// is `.active` if any session votes active, else `.waiting` if any votes waiting.
    static func heartbeatAggregate(
        _ records: [ClaudeHeartbeatRecord],
        now: Date,
        activeThreshold: TimeInterval,
        staleThreshold: TimeInterval
    ) -> HeartbeatAggregate {
        var sawActive = false
        var sawWaiting = false
        var newest: TimeInterval?
        var count = 0

        for record in latestRecordPerSession(records) {
            if record.event.isSessionEnd { continue }              // ended → excluded
            let age = now.timeIntervalSince(record.updatedAt)
            if age > staleThreshold { continue }                    // stale → ignored

            count += 1
            let clampedAge = max(0, age)                            // future mtime ⇒ 0
            if newest == nil || clampedAge < newest! { newest = clampedAge }

            if record.event.isActiveEvent && age <= activeThreshold {
                sawActive = true
            } else {
                sawWaiting = true
            }
        }

        let state: ClaudeActivityState? = sawActive ? .active : (sawWaiting ? .waiting : nil)
        return HeartbeatAggregate(state: state, newestFreshAge: newest, sessionCount: count)
    }

    /// Keep only the newest record per session id (defensive — the reader passes one file
    /// per session, but duplicates must not double-count or let an older event win).
    static func latestRecordPerSession(
        _ records: [ClaudeHeartbeatRecord]
    ) -> [ClaudeHeartbeatRecord] {
        var latest: [String: ClaudeHeartbeatRecord] = [:]
        for record in records {
            if let existing = latest[record.sessionID], existing.updatedAt >= record.updatedAt {
                continue
            }
            latest[record.sessionID] = record
        }
        return Array(latest.values)
    }

    /// Pure L2 decision: fold the hook heartbeat, the process cross-check, and the L1
    /// metadata fallback into one display state. I/O-free.
    ///
    /// Precedence (task rules 1–8):
    /// 1. Any live session actively working ⇒ `.active`.
    /// 2. Else any live session stopped/waiting ⇒ `.waiting`.
    /// 3. `SessionEnd` sessions are excluded; stale records are ignored.
    /// 4. No fresh, non-ended heartbeat records ⇒ fall back to L1 `evaluate(signals:)`.
    ///
    /// Process cross-check (task rule 7): a heartbeat is not proof a process is live, so if
    /// the heartbeat says `.active`/`.waiting` but **no `claude` process is visible**, we
    /// never report `.active` — a fresh heartbeat (within `activeThreshold`) is reported as
    /// `.waiting`, and anything older falls back to L1 (which, with no process and stale
    /// files, yields `.notDetected`). This stops a stale/crashed `active` from sticking.
    public static func evaluate(
        heartbeats: [ClaudeHeartbeatRecord],
        signals: ClaudeActivitySignals,
        now: Date,
        heartbeatActiveThreshold: TimeInterval = ClaudeActivityState.defaultHeartbeatActiveThreshold,
        heartbeatStaleThreshold: TimeInterval = ClaudeActivityState.defaultHeartbeatStaleThreshold,
        l1RecencyThreshold: TimeInterval = ClaudeActivityState.defaultRecencyThreshold
    ) -> ClaudeActivityState {
        let aggregate = heartbeatAggregate(
            heartbeats,
            now: now,
            activeThreshold: heartbeatActiveThreshold,
            staleThreshold: heartbeatStaleThreshold
        )

        func l1Fallback() -> ClaudeActivityState {
            evaluate(signals: signals, now: now, recencyThreshold: l1RecencyThreshold)
        }

        guard let candidate = aggregate.state else {
            return l1Fallback()   // no fresh heartbeat ⇒ L1 (task rules 3, 5, 6)
        }

        // Process present confirms a live session: report the heartbeat verdict as-is.
        if signals.processPresent {
            return candidate
        }

        // No visible process: never claim `.active`. Trust a *fresh* heartbeat as
        // `.waiting`; otherwise defer to L1 (task rule 7 / 11).
        if let age = aggregate.newestFreshAge, age <= heartbeatActiveThreshold {
            return .waiting
        }
        return l1Fallback()
    }

    /// Pure keep-awake **automation** decision: should VibeMenu hold or release automatic
    /// sleep prevention right now? I/O-free, so it is exhaustively unit-tested and re-run
    /// each detection tick — the bounded cap is enforced by that periodic re-evaluation, not
    /// a one-shot timer (docs/decisions/0010), which keeps the whole decision pure.
    ///
    /// This is the fix at the heart of v0.1.1: it is **decoupled from the Active/Waiting
    /// display state** so that an active heartbeat aging past the 120s display window is
    /// treated as *quiet-but-still-running* (held) rather than *finished* (released). The
    /// four situations are kept distinct (task expectations):
    ///   * **active** — a work-in-progress event within the cap ⇒ `.hold`.
    ///   * **quiet-but-still-running** — a work-in-progress event older than the display
    ///     window but within the cap, process still present, no finish signal ⇒ `.hold`.
    ///   * **finished** — the session's newest event is `Stop`/`SessionEnd`, or the `claude`
    ///     process is gone ⇒ `.release`.
    ///   * **not detected / stale** — no live work-in-progress session, or the last active
    ///     event is older than the cap ⇒ `.release`.
    ///
    /// Precedence (task rules 1–7):
    /// 1. **Process cross-check / process gone.** A heartbeat is never proof of a live
    ///    process, so with no visible `claude` process we always `.release` (rules 2, 7) —
    ///    a stale/crashed heartbeat can never pin sleep prevention.
    /// 2. Per live session (newest record wins): `SessionEnd` is excluded; a session whose
    ///    newest event does not `indicatesWorkInProgress` (Stop / Notification /
    ///    SessionStart) does not hold.
    /// 3. A work-in-progress session holds iff its newest event is within `quietHoldCap`
    ///    (rules 3–4). Any one holding session ⇒ `.hold` (a finished session never forces a
    ///    global release while another session is still working — rule 5).
    /// 4. Otherwise ⇒ `.release`.
    ///
    /// Note the cap — not the L2 display "stale" window — is this decision's only age bound.
    /// The stale window (600s) is intentionally *shorter* than the cap (900s) because it
    /// serves the display ("don't pin the UI to a forgotten heartbeat"), whereas the cap is
    /// the automation backstop ("hold long silent work, but never forever"). Applying the
    /// stale window here would cap the hold at 10 minutes and defeat the 15-minute contract,
    /// so a record past the cap simply does not hold (its own bound already covers "forgotten
    /// session").
    ///
    /// A new active event refreshes the hold implicitly: it becomes the session's newest
    /// record, so its age resets and the cap is measured from it (task rule: active event
    /// during quiet hold cancels the pending release).
    public static func automationIntent(
        heartbeats: [ClaudeHeartbeatRecord],
        signals: ClaudeActivitySignals,
        now: Date,
        quietHoldCap: TimeInterval = ClaudeActivityState.defaultQuietHoldCap
    ) -> ClaudeAutomationIntent {
        // 1. Process gone / cross-check: never hold without a visible live process.
        guard signals.processPresent else { return .release }

        // 2–4. Any live, non-ended, work-in-progress session within the cap holds.
        for record in latestRecordPerSession(heartbeats) {
            if record.event.isSessionEnd { continue }            // explicit finish → excluded
            guard record.event.indicatesWorkInProgress else { continue }  // finished/waiting
            // Clamp a future timestamp (clock skew) to 0 so it counts as fresh, not expired.
            let age = max(0, now.timeIntervalSince(record.updatedAt))
            if age <= quietHoldCap { return .hold }
        }
        return .release
    }

    /// Pure, I/O-free DEBUG diagnostics for the L2 decision: the process flag, the
    /// heartbeat aggregate (state / newest age / live-session count), the L1 mtime age +
    /// threshold, and the final result — enough to explain *why* a state was chosen
    /// without re-deriving anything. Metadata only; see `ClaudeActivityDiagnostics`.
    public static func diagnostics(
        heartbeats: [ClaudeHeartbeatRecord],
        signals: ClaudeActivitySignals,
        now: Date,
        heartbeatActiveThreshold: TimeInterval = ClaudeActivityState.defaultHeartbeatActiveThreshold,
        heartbeatStaleThreshold: TimeInterval = ClaudeActivityState.defaultHeartbeatStaleThreshold,
        l1RecencyThreshold: TimeInterval = ClaudeActivityState.defaultRecencyThreshold
    ) -> ClaudeActivityDiagnostics {
        let aggregate = heartbeatAggregate(
            heartbeats,
            now: now,
            activeThreshold: heartbeatActiveThreshold,
            staleThreshold: heartbeatStaleThreshold
        )
        let result = evaluate(
            heartbeats: heartbeats,
            signals: signals,
            now: now,
            heartbeatActiveThreshold: heartbeatActiveThreshold,
            heartbeatStaleThreshold: heartbeatStaleThreshold,
            l1RecencyThreshold: l1RecencyThreshold
        )
        let mtimeAge = signals.mostRecentSessionActivity
            .map { Int(now.timeIntervalSince($0).rounded()) }
        return ClaudeActivityDiagnostics(
            processPresent: signals.processPresent,
            heartbeatState: aggregate.state,
            heartbeatAgeSeconds: aggregate.newestFreshAge.map { Int($0.rounded()) },
            sessionCount: aggregate.sessionCount,
            newestAgeSeconds: mtimeAge,
            thresholdSeconds: Int(l1RecencyThreshold.rounded()),
            result: result
        )
    }
}
