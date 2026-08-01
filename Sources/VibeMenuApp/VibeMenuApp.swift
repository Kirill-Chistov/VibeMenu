import AppKit
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications
import VibeMenuCore

/// Real `LoginItemControlling` backend over the **public** `SMAppService.mainApp`
/// (`ServiceManagement`, macOS 13+; baseline is macOS 15). No helper app, no
/// `SMJobBless`, no root, no private APIs, no new dependency — a system framework.
///
/// This adapter lives in `VibeMenuApp`, not `VibeMenuCore`, so the core stays free of
/// `SMAppService`; the core drives it through `LoginItemControlling`
/// (docs/decisions/0009-launch-at-login.md).
///
/// `isEnabled` maps the actual `SMAppService.mainApp.status` — the single source of
/// truth — to a Bool: only `.enabled` is ON. `register()` / `unregister()` forward the
/// throwing public calls; `LoginItemModel` catches and re-reads the status.
///
/// Caveat (honest): in unsigned / ad-hoc Debug builds, register/unregister may throw or
/// behave inconsistently. Full behavior is only trustworthy in a signed/notarized build.
final class SMAppServiceLoginItemController: LoginItemControlling {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

/// Provider-level activation adapter for Attention v1. It uses only public AppKit APIs and never
/// attempts to identify a thread, conversation, project, or window. A missing bundle URL or a
/// failed activation is intentionally ignored — a row/notification click must never guess or touch
/// another application.
@MainActor
final class ProviderApplicationActivator {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func activate(_ provider: AttentionProvider) {
        let bundleIdentifier = provider.applicationBundleIdentifier
        guard let applicationURL = workspace.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else {
            return
        }

        if let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first {
            _ = running.activate(options: [.activateAllWindows])
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: applicationURL, configuration: configuration) { _, _ in
            // Provider launch errors are deliberately swallowed. The expected app was identified
            // by its bundle id, and there is no safe fallback target to try.
        }
    }
}

/// App-side notification coordinator. Transition detection remains in `VibeMenuCore`; this type
/// owns only the public macOS permission/delivery/delegate APIs and the shared provider activator.
@MainActor
@Observable
final class AttentionNotificationModel: NSObject, UNUserNotificationCenterDelegate {
    nonisolated private static let providerUserInfoKey = "vibemenu_provider"

    /// Observable Settings value. It is committed only after macOS grants authorization.
    private(set) var isEnabled: Bool

    @ObservationIgnored private let center: UNUserNotificationCenter
    @ObservationIgnored private let activator: ProviderApplicationActivator
    @ObservationIgnored private var tracker = AttentionTransitionTracker()
    @ObservationIgnored private var preference: AttentionNotificationPreference
    @ObservationIgnored private var permissionRequestGeneration = 0

    init(
        center: UNUserNotificationCenter = .current(),
        activator: ProviderApplicationActivator = ProviderApplicationActivator()
    ) {
        self.center = center
        self.activator = activator
        self.preference = AttentionNotificationPreference(
            isEnabled: UserDefaults.standard.bool(forKey: PreferenceKey.agentNotifications)
        )
        self.isEnabled = preference.isEnabled
        super.init()
        center.delegate = self

        // Reading authorization status is not a permission request. If a previously stored ON
        // preference no longer has authorization, fail closed without prompting at launch.
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .denied
                || settings.authorizationStatus == .notDetermined else { return }
            Task { @MainActor [weak self] in
                self?.disable()
            }
        }
    }

    /// Toggle notifications. Permission is requested only on an explicit enable action; `.alert`
    /// and `.sound` are the requested authorization capabilities. Delivered notifications use
    /// `.default`, while actual playback remains controlled by the Mac's notification, Focus,
    /// volume, and sound settings.
    func setEnabled(_ requested: Bool) {
        permissionRequestGeneration += 1
        let generation = permissionRequestGeneration
        let action = preference.beginUserChange(requested: requested)
        isEnabled = preference.isEnabled

        guard action == .requestAuthorization else {
            UserDefaults.standard.set(false, forKey: PreferenceKey.agentNotifications)
            return
        }

        // Keep the UI off while the system prompt is unresolved. This also makes a denial return
        // to the exact same state as an explicit off toggle.
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor [weak self] in
                guard let self, self.permissionRequestGeneration == generation else { return }
                self.preference.finishAuthorization(granted: granted)
                self.isEnabled = self.preference.isEnabled
                UserDefaults.standard.set(
                    self.isEnabled, forKey: PreferenceKey.agentNotifications
                )
            }
        }
    }

    /// Receive Claude state snapshots even while notifications are off. That keeps transition
    /// state current, so turning notifications on never replays an existing Done/approval state.
    func recordClaude(_ sessions: [ClaudeSession]) {
        deliver(tracker.updateClaude(sessions))
    }

    /// Receive Codex state snapshots even while notifications are off. Empty snapshots when the
    /// provider has no sessions are still ordinary snapshots; the Settings binding explicitly
    /// resets the provider baseline for a disable/re-enable cycle.
    func recordCodex(_ sessions: [CodexSession]) {
        deliver(tracker.updateCodex(sessions))
    }

    /// Establish a fresh silent baseline after an explicit provider disable/re-enable action.
    func resetProviderBaseline(_ provider: AttentionProvider) {
        tracker.reset(provider: provider)
    }

    /// Shared by Session Radar row taps and notification clicks.
    func activate(_ provider: AttentionProvider) {
        activator.activate(provider)
    }

    private func disable() {
        preference.apply(requested: false)
        isEnabled = preference.isEnabled
        UserDefaults.standard.set(false, forKey: PreferenceKey.agentNotifications)
    }

    private func deliver(_ events: [AttentionNotification]) {
        for event in preference.deliverable(events) {
            let content = UNMutableNotificationContent()
            // Visible provider name, not the stable `rawValue` routing key below (ADR 0017, Amd. 6).
            content.title = "\(event.provider.displayName) — \(event.displayName)"
            content.body = event.kind.bodyText
            content.sound = .default
            // Provider name is the only routing metadata. The random request id contains no session
            // id, and no path/message/error/tool data enters the request or its userInfo.
            content.userInfo = [Self.providerUserInfoKey: event.provider.rawValue]
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let rawProvider = response.notification.request.content.userInfo[Self.providerUserInfoKey]
            as? String
        let provider = rawProvider.flatMap(AttentionNavigation.provider(fromNotificationValue:))
        completionHandler()
        Task { @MainActor [weak self] in
            if let provider {
                self?.activate(provider)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

/// App-side adapter that performs the opt-in, preview-gated, reversible one-click install of
/// VibeMenu's Claude Code usage-limit statusLine shim (docs/decisions/0016-claude-usage-limits.md).
///
/// All the risky *logic* (composing/wrapping/uninstalling the statusLine, base64-encoding the
/// wrapped command) lives in the pure, unit-tested `StatusLineInstaller` in `VibeMenuCore`; this
/// type only does the side effects the pure code can't: materialise the shim script to a stable
/// path, read `~/.claude/settings.json`, write a timestamped backup first, and write the composed
/// result. It is deliberately the *only* place VibeMenu writes to the user's Claude config, it never
/// runs without an explicit button press + preview, and every write is preceded by a backup, so it is
/// a narrow, honest extension of VibeMenu's prior "never edits settings.json" stance. Lives here in
/// `VibeMenuApp.swift` (rather than its own file) because the Xcode `.app` target compiles this
/// source explicitly.
@MainActor
@Observable
final class ClaudeUsageInstallModel {
    /// The current install state, refreshed from disk. `nil` until first `refresh()`.
    private(set) var state: StatusLineInstaller.InstallState?

    /// The last error surfaced to the UI (e.g. settings.json unreadable), or `nil`.
    private(set) var lastError: String?

    /// `~/.claude/settings.json`.
    private let settingsURL: URL

    /// Where the shim is materialised: VibeMenu's own Application Support subtree (not `~/.claude`).
    private let shimURL: URL

    init(
        settingsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json"),
        shimURL: URL = ClaudeUsageInstallModel.defaultShimURL
    ) {
        self.settingsURL = settingsURL
        self.shimURL = shimURL
    }

    static var defaultShimURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("VibeMenu/ClaudeUsage", isDirectory: true)
            .appendingPathComponent(ClaudeUsageStatusLineShim.fileName, isDirectory: false)
    }

    /// Whether VibeMenu's shim is currently installed as the statusLine command.
    var isInstalled: Bool {
        if case .installed = state { return true }
        return false
    }

    /// A human-readable description of what installing will change, for the confirmation dialog.
    var previewText: String {
        StatusLineInstaller.preview(settingsData: try? Data(contentsOf: settingsURL), shimPath: shimURL.path)
    }

    /// Re-read `~/.claude/settings.json` and recompute the install state.
    func refresh() {
        state = StatusLineInstaller.detect(settingsData: try? Data(contentsOf: settingsURL), shimPath: shimURL.path)
    }

    /// Materialise the shim, back up settings.json, and compose VibeMenu's statusLine (wrapping any
    /// existing one). Idempotent. On any failure, records `lastError` and leaves settings unchanged.
    func install() {
        lastError = nil
        let existing = try? Data(contentsOf: settingsURL)
        // Refuse to write over a settings.json that exists but is not a JSON object (syntax error, or
        // an array/scalar): composing would silently drop every other key. Surface an error instead.
        guard StatusLineInstaller.canSafelyModify(settingsData: existing) else {
            lastError = "Your ~/.claude/settings.json isn't valid JSON, so VibeMenu won't modify it. "
                + "Fix it (or remove it) and try again."
            return
        }
        do {
            try materializeShim()
            let result = StatusLineInstaller.compose(settingsData: existing, shimPath: shimURL.path)
            try backupThenWrite(result.updatedJSON, existing: existing)
            refresh()
        } catch {
            lastError = "Could not install: \(error.localizedDescription)"
        }
    }

    /// Remove VibeMenu's statusLine (restoring any wrapped command), after backing up. Leaves the
    /// materialised shim file in place (harmless; unreferenced) and a non-VibeMenu statusLine untouched.
    func uninstall() {
        lastError = nil
        guard let existing = try? Data(contentsOf: settingsURL) else { refresh(); return }
        // Same guard as install: never rewrite an unparseable settings.json (would drop the user's keys).
        guard StatusLineInstaller.canSafelyModify(settingsData: existing) else {
            lastError = "Your ~/.claude/settings.json isn't valid JSON, so VibeMenu won't modify it. "
                + "Remove the statusLine entry by hand, or restore a settings.json.vibemenu-backup-* file."
            return
        }
        do {
            let updated = StatusLineInstaller.uninstall(settingsData: existing, shimPath: shimURL.path)
            try backupThenWrite(updated, existing: existing)
            refresh()
        } catch {
            lastError = "Could not remove: \(error.localizedDescription)"
        }
    }

    /// Write the embedded shim source to the stable path and mark it executable (0755). Rewritten on
    /// every install so it always matches this app version.
    private func materializeShim() throws {
        try FileManager.default.createDirectory(
            at: shimURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(ClaudeUsageStatusLineShim.source.utf8).write(to: shimURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimURL.path)
    }

    /// Back up the existing settings.json (if any) to `settings.json.vibemenu-backup-<timestamp>`,
    /// **then** atomically write the new content. The backup write is *not* optional: if it fails we
    /// throw and leave settings.json untouched, so we never overwrite without a good backup. The stamp
    /// carries a short random suffix so two writes in the same second can't collide on one backup file.
    private func backupThenWrite(_ data: Data, existing: Data?) throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let existing {
            let backup = settingsURL.deletingLastPathComponent()
                .appendingPathComponent("settings.json.vibemenu-backup-\(Self.backupStamp())")
            try existing.write(to: backup, options: .atomic)   // must succeed before we overwrite
        }
        try data.write(to: settingsURL, options: .atomic)
    }

    private static func backupStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))"
    }
}

/// Menu-bar shell for VibeMenu.
///
/// STATUS (v0.0): this shell compiles from the command line (`swift build`) *and*
/// is wrapped into a launchable, menu-bar-only `.app` by `App/VibeMenu.xcodeproj`
/// (target `VibeMenu`, `LSUIElement = true`, bundle id `com.kirillchistov.VibeMenu`),
/// which links `VibeMenuCore` and reuses this exact source — see
/// `docs/decisions/0007-app-wrapper-structure.md` and README → "Build & run the menu-bar
/// app". The app has been built and launched and confirmed to run as a menu-bar
/// accessory with no Dock icon (`LSUIElement` effective, via LaunchServices). Still
/// deferred: an app icon, Developer-ID signing, and notarization. A literal click on
/// the dropdown / Quit item remains a manual smoke-test step.
///
/// v0.1 wires three real signals. **Thermal pressure** is live via `ThermalStatusModel`,
/// which observes `ProcessInfo.processInfo.thermalState` /
/// `thermalStateDidChangeNotification` through `SystemThermalStatusProvider` (public
/// API, event-driven, no polling). **Sleep prevention** is live via
/// `PowerAssertionModel`: the user's manual preference stays separate from the temporary
/// Claude automation request, and the real IOKit assertion is held when either asks for it
/// (`kIOPMAssertPreventUserIdleSystemSleep`) — idle *system* sleep only, lid open, no
/// clamshell (docs/decisions/0005-v0-1-scope.md). **Claude detection (L1 + L2)** is live via
/// `ClaudeActivityModel` — the "Claude" row is intentionally simplified to Active / Idle /
/// Not detected. L1 uses process presence + session-file *mtime* (metadata, never
/// contents); the opt-in **hook heartbeat (L2)** — VibeMenu-owned per-session files under
/// Application Support, never Claude transcripts — adds the reliable internal
/// Active/Waiting split (docs/decisions/0008-claude-heartbeat-detection.md).
/// App delegate that owns the app-lifetime models and the launch/termination hooks.
///
/// It owns the `PowerAssertionModel` so that *any* termination path — the in-menu
/// Quit button, an Apple-event quit (`osascript … to quit`), or an app-driven
/// `NSApplication.terminate` — releases the held assertion via
/// `applicationWillTerminate`. This complements (does not replace) the Quit button's
/// explicit `cleanup()` and the manager's `deinit` backstop.
///
/// It also owns the `ClaudeActivityModel` (L1 + L2 detection) and **starts observation at
/// app launch** in `applicationDidFinishLaunching`, not when the menu is first opened, so
/// detection and automatic keep-awake are live regardless of whether the user ever opens
/// the dropdown. Observation is stopped on termination.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Owned for the app's lifetime; holds/releases the real power assertion.
    let keepAwake = PowerAssertionModel(manager: SystemPowerAssertionManager())

    // Owned for the app's lifetime; establishes silent transition baselines, manages opt-in local
    // notifications, and shares provider activation with Session Radar row clicks.
    let attention = AttentionNotificationModel()

    // Owned for the app's lifetime; observes Claude detection (L1 + L2) while VibeMenu
    // runs and feeds the automatic keep-awake owner.
    //
    // Session Radar titles resolve through a composite chain (docs/decisions/0014): the opt-in
    // Claude Desktop title index first, then the transcript title. The Desktop resolver is gated
    // by the `useDesktopTitles` preference — read live from `UserDefaults` each lookup, so flipping
    // the setting takes effect on the next ~2s tick with no restart. When the setting is off (the
    // default) the Desktop resolver touches nothing and the chain behaves exactly as before.
    let claude = ClaudeActivityModel(provider: ClaudeActivityProvider(
        titleResolver: CompositeTitleResolver([
            DesktopTitleResolver(isEnabled: {
                UserDefaults.standard.bool(forKey: PreferenceKey.useDesktopTitles)
            }),
            TranscriptTitleResolver(),
        ])
    ))

    // Owned for the app's lifetime; reflects the actual `SMAppService.mainApp` login-item
    // status and toggles it from Settings → General. No persisted duplicate bool.
    let loginItem = LoginItemModel(controller: SMAppServiceLoginItemController())

    // Owned for the app's lifetime; publishes the opt-in Claude usage-limits
    // snapshot (docs/decisions/0016-claude-usage-limits.md). Display-only — it never touches the
    // keep-awake automation loop. The composite reader resolves the user's chosen source (Auto /
    // Claude Desktop local cache / Claude Code status line), both read live from `UserDefaults`: the
    // provider is gated on `showClaudeLimits`, so with the feature off (the default) it does no file
    // I/O, and flipping the toggle or source takes effect on the next ~5 s tick with no restart.
    let usage = ClaudeUsageLimitModel(provider: ClaudeUsageLimitProvider(
        reader: CompositeClaudeUsageLimitReader(
            mode: { PreferenceKey.claudeLimitsSourceMode }
        ),
        isEnabled: { UserDefaults.standard.bool(forKey: PreferenceKey.showClaudeLimits) }
    ))

    // Owned for the app's lifetime; performs the opt-in, preview-gated, reversible one-click install
    // of the usage-capture statusLine shim into ~/.claude/settings.json (docs/decisions/0016). The
    // risky compose/uninstall logic is pure + unit-tested in `StatusLineInstaller`; this only does the
    // side effects (materialise the shim, back up, write). Never runs without an explicit button press.
    let usageInstall = ClaudeUsageInstallModel()

    // Owned for the app's lifetime; publishes the opt-in **Codex Desktop** session rows
    // (docs/decisions/0017-codex-session-support.md). It reads only allowlisted
    // metadata (session id, "Codex Desktop" originator, project *folder name*, activity timestamps, a
    // task_complete done marker) from Codex's own rollout files. Like Claude activity it now feeds the
    // shared keep-awake decision (Fix 1): an active Codex session holds the automatic assertion (wired
    // in `applicationDidFinishLaunching`). The provider self-gates on `showCodexSessions` (read live
    // from `UserDefaults`): off (the default) ⇒ no file I/O and an empty list, so Codex neither shows
    // rows nor affects sleep; flipping the toggle takes effect on the next ~5 s tick with no restart.
    let codexSessions = CodexSessionModel(provider: CodexSessionProvider(
        isEnabled: { UserDefaults.standard.bool(forKey: PreferenceKey.showCodexSessions) }
    ))

    // Owned for the app's lifetime; publishes the opt-in **Codex Desktop usage limits** (5-hour +
    // weekly) read locally from Codex's own rollout `token_count.rate_limits`
    // (docs/decisions/0017-codex-session-support.md). Display-only — like the Claude usage section it
    // never touches the keep-awake loop. The provider self-gates on `showCodexLimits` (read live from
    // `UserDefaults`): off (the default) ⇒ no file I/O; flipping the toggle takes effect on the next
    // ~5 s tick with no restart. Reads ONLY the numeric rate-limit fields — never prompts, responses,
    // tool output, token counts, plan/account, or auth.
    let codexUsage = CodexUsageLimitModel(provider: CodexUsageLimitProvider(
        isEnabled: { UserDefaults.standard.bool(forKey: PreferenceKey.showCodexLimits) }
    ))

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Automatic keep-awake is driven by the keep-awake *intent* (hold vs release), not
        // the raw display state: it holds through long silent tool/subagent phases up to a
        // bounded cap and releases promptly on a genuine finish (docs/decisions/0010). This
        // never mutates the user's manual preference.
        claude.onAutomationChange = { [keepAwake] intent in
            keepAwake.updateClaudeAutomation(intent)
        }
        claude.onSessionsChange = { [attention] sessions in
            attention.recordClaude(sessions)
        }
        // ChatGPT desktop session activity feeds the *same* shared keep-awake decision
        // (docs/decisions/0017, Fix 1). An active session holds the automatic assertion; done/idle/stale
        // releases, and when the feature is off the list is empty ⇒ `.release` for both modes, so it
        // can't affect sleep. The raw (un-hidden) session list is used, so hiding a row from the menu is
        // purely display-only. Deliberately conservative — see `CodexSessionActivity.automationIntent`.
        //
        // The app's two modes are refreshed as **two independent owners** from the same list, so one
        // mode finishing never releases a hold the other still needs, and the menu can name which one
        // is holding. Both intents are applied before attention state is recorded.
        codexSessions.onSessionsChange = { [keepAwake, attention] sessions in
            keepAwake.updateCodexAutomation(
                CodexSessionActivity.automationIntent(sessions, mode: .codex)
            )
            keepAwake.updateChatGPTWorkAutomation(
                CodexSessionActivity.automationIntent(sessions, mode: .work)
            )
            attention.recordCodex(sessions)
        }
        // Begin Claude observation at launch (not on first menu appearance). `start()` is
        // idempotent, so this can never spin up a duplicate provider timer.
        claude.start()
        // Begin the usage-limit file observation too. Idempotent; the provider self-gates on the
        // (default-off) preference, so this is a cheap bool check per tick until the user opts in.
        usage.start()
        // Begin Codex session observation on the same terms. It self-gates on the default-off
        // `showCodexSessions`, so it does no file I/O or automation work until the user opts in.
        codexSessions.start()
        // Begin Codex usage-limit observation (display-only; self-gates on the default-off
        // `showCodexLimits`, so it does no file I/O until the user opts in).
        codexUsage.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        keepAwake.cleanup()
        claude.stop()
        usage.stop()
        codexSessions.stop()
        codexUsage.stop()
    }
}

/// `UserDefaults`/`@AppStorage` keys for the menu-bar visibility preferences. Kept in
/// one place so the menu and the Settings window read/write the exact same keys. This
/// is the whole "settings architecture" for this slice — two booleans, nothing more.
enum PreferenceKey {
    static let showClaudeStatus = "showClaudeStatus"
    static let showThermalStatus = "showThermalStatus"
    /// Opt-in local notifications for Claude approval/completion and Codex completion. The app-side
    /// coordinator writes this only after macOS grants permission; unset/false is the default.
    static let agentNotifications = "agentNotifications"
    /// Opt-in Claude usage-limits section (docs/decisions/0016-claude-usage-limits.md).
    /// Default **off** — it reads best-effort / version-fragile local Claude data, so it stays
    /// off unless the user turns it on. When off, the usage provider does no file I/O
    /// and the section never renders.
    static let showClaudeLimits = "showClaudeLimits"
    /// Which local source feeds the usage section: `auto` (prefer fresh Desktop cache, else Claude
    /// Code status line), `desktopCache`, or `claudeCode`. Persisted as the enum's raw string; default
    /// `auto` when unset. (ADR 0016.)
    static let claudeLimitsSource = "claudeLimitsSource"

    /// The persisted source mode, decoded with an `auto` fallback for unset/invalid values.
    static var claudeLimitsSourceMode: ClaudeUsageLimitSourceMode {
        UserDefaults.standard.string(forKey: claudeLimitsSource)
            .flatMap(ClaudeUsageLimitSourceMode.init(rawValue:)) ?? .auto
    }
    /// Per-row visibility for the usage section: the newline-joined set of hidden stable ids
    /// (`ClaudeUsageLimit.visibilityID`). Empty/unset ⇒ every detected row is shown (the default);
    /// the user hides individual rows in Settings. Decoded via `ClaudeUsageLimitVisibility(persisted:)`.
    /// (ADR 0016.)
    static let claudeLimitsHiddenIDs = "claudeLimitsHiddenIDs"
    /// Whether the "Claude usage limits" settings section is expanded. Persisted so the folded/expanded
    /// choice survives reopening Settings; default collapsed (a clean header). (ADR 0016.)
    static let claudeLimitsSectionExpanded = "claudeLimitsSectionExpanded"
    /// Opt-in: read Session Radar titles from the Claude Desktop app's local session index
    /// (docs/decisions/0014-enhanced-desktop-titles.md). Default **off** — it reads another app's
    /// private cache, so it stays opt-in. `UserDefaults.bool` returns `false` when unset, matching
    /// the `@AppStorage(... ) = false` default in `SettingsView`.
    static let useDesktopTitles = "useDesktopTitles"
    /// Opt-in **Codex Desktop** session detection for the shared session rows
    /// (docs/decisions/0017-codex-session-support.md). Default **off** — it reads another app's
    /// local rollout files (version-fragile), so it stays opt-in. Kept fully separate from the
    /// Claude preferences. When enabled, only an `.active` Codex session can contribute to the
    /// shared keep-awake decision; off means no file I/O and no Codex automation input.
    /// `UserDefaults.bool` returns `false` when unset, matching the view default.
    static let showCodexSessions = "showCodexSessions"

    /// Opt-in ChatGPT usage limits (docs/decisions/0017-codex-session-support.md).
    /// Default **off** — it reads best-effort, version-fragile local data, so it stays
    /// off unless the user turns it on. When off the provider does no file I/O and the
    /// section never renders. Kept fully separate from the Claude usage keys. (This key name is
    /// intentionally reused from the earlier Codex attempt so its stale `UserDefaults` value — off —
    /// becomes meaningful again rather than being orphaned.)
    static let showCodexLimits = "showCodexLimits"
    /// Per-row visibility for the Codex usage section: newline-joined hidden stable ids
    /// (`CodexUsageLimit.visibilityID`). Empty/unset ⇒ every detected row shown. Separate from Claude's
    /// `claudeLimitsHiddenIDs` so hiding a Codex row never touches Claude and vice-versa.
    static let codexLimitsHiddenIDs = "codexLimitsHiddenIDs"
    /// Whether the "Codex usage limits" settings sub-area is expanded; persisted, default collapsed.
    static let codexLimitsSectionExpanded = "codexLimitsSectionExpanded"
}

@main
struct VibeMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Owned for the app's lifetime; observes thermal changes while VibeMenu runs.
    @State private var thermal = ThermalStatusModel(provider: SystemThermalStatusProvider())

    var body: some Scene {
        // The label observes the raw Claude session list, so the icon updates even when the
        // optional Agent notifications setting is off.
        MenuBarExtra {
            MenuContentView(
                thermal: thermal,
                claude: appDelegate.claude,
                usage: appDelegate.usage,
                codex: appDelegate.codexSessions,
                codexUsage: appDelegate.codexUsage,
                keepAwake: appDelegate.keepAwake,
                attention: appDelegate.attention
            )
                // Claude observation is started at app launch (AppDelegate), so opening the
                // menu only displays current state. Thermal is event-driven; start it when
                // the menu first appears (idempotent, so re-appearing doesn't double-subscribe).
                .onAppear {
                    thermal.start()
                }
        } label: {
            MenuBarIconLabel(claude: appDelegate.claude)
        }
        .menuBarExtraStyle(.window)

        // Dedicated Settings window (⌘, and the in-menu "Settings…" item). SwiftUI owns
        // its lifecycle; because the app is LSUIElement/menu-bar-only, the in-menu opener
        // also activates the app so the window can come to front (see MenuContentView).
        Settings {
            SettingsView(
                loginItem: appDelegate.loginItem,
                install: appDelegate.usageInstall,
                attention: appDelegate.attention
            )
        }
    }
}

/// Reactive label for the raw Claude attention state. Normal uses the existing template asset so
/// macOS controls its light/dark menu-bar appearance; attention uses a separate baked-color asset.
private struct MenuBarIconLabel: View {
    let claude: ClaudeActivityModel

    var body: some View {
        Group {
            if claude.needsAttention {
                Image("MenuBarAttentionIcon")
                    .renderingMode(.original)
            } else {
                Image("MenuBarIcon")
                    .renderingMode(.template)
            }
        }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("VibeMenu")
            .accessibilityValue(claude.needsAttention ? "Needs attention" : "Normal")
    }
}

/// Dropdown content. The Claude, Thermal, and Sleep-prevention rows all reflect real
/// state; there is no placeholder status row and no visible debug row.
struct MenuContentView: View {
    // Observable thermal state (v0.1's first real signal).
    var thermal: ThermalStatusModel

    // Observable Claude detection (L1 + L2) state; `.active` drives built-in automation.
    var claude: ClaudeActivityModel

    // Observable Claude usage-limit snapshot (opt-in; docs/decisions/0016).
    var usage: ClaudeUsageLimitModel

    // Observable Codex Desktop session list (opt-in; active sessions feed shared automation; ADR 0017).
    var codex: CodexSessionModel

    // Observable Codex Desktop usage-limit snapshot (opt-in; docs/decisions/0017).
    var codexUsage: CodexUsageLimitModel

    // Observable manual sleep-prevention state.
    var keepAwake: PowerAssertionModel

    // Shared provider activation + notification state.
    var attention: AttentionNotificationModel

    // User visibility preferences (persisted). Defaults match the spec: both rows shown.
    @AppStorage(PreferenceKey.showClaudeStatus) private var showClaudeStatus = true
    @AppStorage(PreferenceKey.showThermalStatus) private var showThermalStatus = true
    // Opt-in Codex Desktop session detection; default off (see PreferenceKey.showCodexSessions / ADR 0017).
    @AppStorage(PreferenceKey.showCodexSessions) private var showCodexSessions = false
    // Opt-in usage-limits section; default off (see PreferenceKey.showClaudeLimits / ADR 0016).
    @AppStorage(PreferenceKey.showClaudeLimits) private var showClaudeLimits = false
    // Per-row visibility: newline-joined hidden stable ids. Observed here so hiding a row in Settings
    // updates the menu live (see PreferenceKey.claudeLimitsHiddenIDs / ADR 0016).
    @AppStorage(PreferenceKey.claudeLimitsHiddenIDs) private var claudeLimitsHiddenIDs = ""
    // Opt-in Codex usage limits; default off (see PreferenceKey.showCodexLimits / ADR 0017).
    @AppStorage(PreferenceKey.showCodexLimits) private var showCodexLimits = false
    // Per-row visibility for the Codex usage section; separate from Claude's (see PreferenceKey.codexLimitsHiddenIDs).
    @AppStorage(PreferenceKey.codexLimitsHiddenIDs) private var codexLimitsHiddenIDs = ""

    // Opens the dedicated Settings scene. Available macOS 14+; baseline is macOS 15.
    @Environment(\.openSettings) private var openSettings

    /// The user's per-row hide/show choices, decoded from the persisted string.
    private var usageVisibility: ClaudeUsageLimitVisibility {
        ClaudeUsageLimitVisibility(persisted: claudeLimitsHiddenIDs)
    }

    /// The user's per-row hide/show choices for the Codex usage section.
    private var codexUsageVisibility: CodexUsageLimitVisibility {
        CodexUsageLimitVisibility(persisted: codexLimitsHiddenIDs)
    }

    /// Whether the Claude Limits section has anything to draw: the feature is on **and** either there
    /// is at least one *visible* (non-hidden) row, or there is no data yet (so the setup hint shows).
    /// When the feature is on, data exists, but every detected row is hidden, this is `false` so the
    /// section — and its divider — disappear entirely rather than leaving an empty box (task E).
    private var claudeLimitsHasContent: Bool {
        guard showClaudeLimits else { return false }
        guard usage.snapshot.hasData else { return true }
        return !usageVisibility.visibleLimits(in: usage.snapshot).isEmpty
    }

    /// Whether the Codex Limits section has anything to draw: the feature is on **and** either there is
    /// at least one *visible* (non-hidden) row, or there is no data yet (so the honest empty state
    /// shows). When on with data but every row hidden, this is `false` so the section and its divider
    /// disappear rather than leaving an empty box.
    private var codexLimitsHasContent: Bool {
        guard showCodexLimits else { return false }
        guard codexUsage.snapshot.hasData else { return true }
        return !codexUsageVisibility.visibleLimits(in: codexUsage.snapshot).isEmpty
    }

    /// Whether the AI Agent sessions section has anything to draw. The feature must be on **and** at
    /// least one **visible** (non-hidden, radar-eligible) session row must survive interleaving and the
    /// shared cap. There is deliberately no "no sessions at all" placeholder: whether the user has
    /// **hidden every row** or there simply **are no sessions**, this is `false`, so the section *and its
    /// dividers* disappear entirely and the slot reserves zero height — instead of a muted "No active
    /// sessions" line that, wrapped by its dividers and the stack spacing, read as a tall empty gap
    /// between Codex Limits and Thermal pressure. Mirrors `claudeLimitsHasContent` /
    /// `codexLimitsHasContent`, so the existing divider rules (drawn from these effective flags) stay
    /// correct with no `MenuVisibility` change. The pure decision lives in
    /// `AgentSessionRadar.hasVisibleContent` so it is unit-tested without SwiftUI or I/O.
    private var agentSessionsHasContent: Bool {
        // Snapshot the exact list the section would render (dismissals applied before cap/interleave),
        // so hidden rows are filtered *before* this gate, never after layout.
        let claudeRadar = SessionRadar.present(
            claude.visibleSessions, now: Date(), homeFolderName: SessionRadar.currentHomeFolderName
        )
        let codexVisible = showCodexSessions ? codex.visibleSessions : []
        return AgentSessionRadar.hasVisibleContent(
            showSessions: showClaudeStatus, claude: claudeRadar, codex: codexVisible
        )
    }

    /// Pure decision for which status sections / dividers to draw. Each Limits section, and the AI Agent
    /// sessions section, renders whenever its feature is enabled and has visible content — so the
    /// effective flags fold in per-row visibility (`claudeLimitsHasContent` / `codexLimitsHasContent` /
    /// `agentSessionsHasContent`).
    private var visibility: MenuVisibility {
        MenuVisibility(
            showClaudeStatus: agentSessionsHasContent,
            showThermalStatus: showThermalStatus,
            showClaudeLimits: claudeLimitsHasContent,
            showCodexLimits: codexLimitsHasContent
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("VibeMenu")
                .font(.headline)

            Divider()

            // Opt-in Claude usage-limits section (docs/decisions/0016). It sits at
            // the top of the status stack, above the Session Radar. Dividers are drawn *above* each
            // visible section that has another above it, so no stray/doubled separators appear when a
            // section is hidden.
            if visibility.isClaudeLimitsRowVisible {
                ClaudeLimitsView(usage: usage, visibility: usageVisibility) {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            }
            // Opt-in Codex Desktop usage-limits section (docs/decisions/0017),
            // directly beneath Claude Limits and above the AI Agent sessions. Same divider rules.
            if visibility.isDividerAboveCodexLimitsRow {
                Divider()
            }
            if visibility.isCodexLimitsRowVisible {
                CodexLimitsView(usage: codexUsage, visibility: codexUsageVisibility) {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            }
            if visibility.isDividerAboveClaudeRow {
                Divider()
            }
            // The unified **AI Agent sessions** section: Claude session rows and (opt-in) Codex Desktop
            // session rows shown directly, with no textual status line (docs/decisions/0017). Gated by
            // `agentSessionsHasContent` (via `isClaudeRowVisible`): it is instantiated **only** when at
            // least one visible row survives, so when there are zero visible rows the section and its
            // dividers are omitted entirely and reserve zero height — never an empty box or placeholder.
            if visibility.isClaudeRowVisible {
                AgentSessionsSection(
                    claude: claude,
                    codex: codex,
                    codexEnabled: showCodexSessions,
                    activate: attention.activate
                )
            }
            // Separate the section above (Limits or Session Radar) from the Thermal pressure reading
            // with the same plain divider used above Sleep prevention. Only when Thermal and at least
            // one section above it are visible, so a hidden neighbour never leaves a stray separator.
            if visibility.isDividerAboveThermalRow {
                Divider()
            }
            if visibility.isThermalRowVisible {
                // Only the pressure *value* carries the thermal color/weight; the
                // "Thermal pressure:" label stays plain like every other menu row.
                Text("Thermal pressure: ")
                    + Text(thermal.displayLabel)
                        .foregroundColor(thermalColor(thermal.displayStyle))
                        .fontWeight(thermalWeight(thermal.displayStyle))
            }

            // Divider between the status rows and Sleep prevention. Hidden when both
            // status rows are hidden, so we never leave an empty section or a doubled
            // separator above Sleep prevention.
            if visibility.isStatusDividerVisible {
                Divider()
            }

            // One compact row: label on the left, native macOS switch on the right.
            // The switch displays only the user's manual preference. Claude automation may
            // still hold the effective assertion underneath, while the switch remains
            // available for changing only the manual preference.
            HStack {
                Text("Sleep prevention")
                Spacer()
                Toggle("", isOn: Binding(
                    get: { keepAwake.manualToggleIsOn },
                    set: { keepAwake.setManualRequested($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                // Make this top-level switch read as less visually dominant (~30% smaller)
                // without shrinking the "Sleep prevention" label or the row text. Native
                // `.controlSize(.small)` alone isn't ~30%, so scale the switch itself by 0.7,
                // anchored trailing so it stays flush to the right edge and keeps a usable
                // click target. Applied only here — Settings toggles stay full-size.
                .controlSize(.small)
                .scaleEffect(0.7, anchor: .trailing)
            }

            // Compact, honest status for the underlying assertion. This is separate from the
            // manual switch: automation may own the assertion while the switch is off, and a
            // failed acquisition must never render as "On".
            HStack(spacing: 5) {
                Image(systemName: sleepPreventionStatusSymbol(keepAwake.state))
                Text(keepAwake.statusLabel)
            }
            .font(.caption)
            .foregroundStyle(sleepPreventionStatusColor(keepAwake.state))
            .padding(.leading, 2)

            Divider()

            // Footer: both top-level actions on one horizontal row to keep the menu
            // short — Settings… on the left, Quit VibeMenu on the right. The Spacer
            // pushes them apart so neither is cramped; keyboard shortcuts are preserved.
            HStack {
                Button("Settings…") {
                    // LSUIElement/menu-bar-only apps aren't active, so the Settings window
                    // would otherwise open behind other apps. Activate first, then open, so
                    // it reliably comes to front.
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                .keyboardShortcut(",")

                Spacer()

                Button("Quit VibeMenu") {
                    // Release any held assertion before exiting. Belt-and-suspenders with
                    // `AppDelegate.applicationWillTerminate` (covers Apple-event quits) and
                    // the manager's deinit; the OS also drops per-process assertions.
                    keepAwake.cleanup()
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(12)
        // Deliberately narrow and menu-bar-like. The prior 380 read as bulky; 270 was too tight,
        // so 320 is the comfortable middle. `SessionRow` spends the width well: a leading dot gutter,
        // a flexible two-line content column (state word + agent pill up top, session name below), and
        // a fixed trailing timer column (48). The reserved timer column means every row aligns and the
        // name always tail-truncates before the trailing space instead of expanding into it. The
        // two-line rows are taller than the old single-line ones but stay compact.
        .frame(width: 320, alignment: .leading)
    }

    /// Translate the core's framework-free `ThermalDisplayStyle` into a SwiftUI
    /// semantic color. Uses system colors only (no hard-coded RGB): green / orange /
    /// red, and the default primary text color for the "Unknown" fallback.
    private func thermalColor(_ style: ThermalDisplayStyle) -> Color {
        switch style {
        case .nominal: .green
        case .fair: .orange
        case .serious, .critical: .red
        case .unknown: .primary
        }
    }

    /// Native semantic symbol for the status line. The wording remains the source of truth;
    /// the symbol is a small visual aid and is never the only indication of state.
    private func sleepPreventionStatusSymbol(_ state: PowerAssertionState) -> String {
        switch state {
        case .inactive: "circle"
        case .preventingIdleSleep: "checkmark.circle.fill"
        case .acquisitionFailed: "exclamationmark.triangle.fill"
        }
    }

    /// Semantic system colours only; the text remains explicit for colour-inaccessible users.
    private func sleepPreventionStatusColor(_ state: PowerAssertionState) -> Color {
        switch state {
        case .inactive: .secondary
        case .preventingIdleSleep: .green
        case .acquisitionFailed: .orange
        }
    }

    /// Critical is the only state that leans on weight: red + semibold to read as an
    /// alert without any animation. Everything else keeps the default weight.
    private func thermalWeight(_ style: ThermalDisplayStyle) -> Font.Weight {
        switch style {
        case .critical: .semibold
        default: .regular
        }
    }
}

/// The shared Claude/Codex session section (docs/decisions/0017-codex-session-support.md).
///
/// Replaces the old Claude-only `SessionRadarView` and the later aggregate agent-status line:
/// there is now **no textual status row at all** and **no empty-state
/// placeholder**. The sessions area shows real per-session rows directly, most-active/recent first.
/// Claude Code session rows are **unchanged** (`SessionRow`) and opt-in Codex Desktop rows
/// (`CodexSessionRow`) render interleaved with a clear provider pill. Both providers' hidden rows are
/// filtered *before* interleaving, so the user can hide every row; when nothing visible remains the
/// parent (via `agentSessionsHasContent` / `AgentSessionRadar.hasVisibleContent`) does not instantiate
/// this section at all, so the whole section and its dividers collapse to zero height — never a
/// forced-back row, an empty box, or a "No active sessions" line, whether the sessions were hidden or
/// there simply are none.
///
/// The two providers share one **compact budget** of four primary rows. Any eligible remainder is
/// exposed through one centralized, bounded Recent sessions expansion; the model keeps its rows in
/// the same cross-provider priority/recency order as the primary list.
struct AgentSessionsSection: View {
    var claude: ClaudeActivityModel
    var codex: CodexSessionModel
    /// Whether Codex detection is enabled (opt-in `showCodexSessions`). When off, Codex neither
    /// contributes to the status nor shows any rows.
    let codexEnabled: Bool
    let activate: (AttentionProvider) -> Void

    /// Whether the shared "+N more recent sessions" overflow is expanded. Local + collapsed by
    /// default, so the list starts compact each time the menu content is recreated.
    @State private var showOverflowSessions = false

    var body: some View {
        // One periodic timeline so elapsed labels tick and the age-based visibility rules
        // re-evaluate while the menu is open; it costs nothing while the menu is closed.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            // Claude radar — unchanged rules (drop home-noise, cap 4, hide old done/stale, …).
            let claudeRadar = SessionRadar.present(
                claude.visibleSessions, now: now, homeFolderName: SessionRadar.currentHomeFolderName
            )
            // Codex sessions only when enabled, and only the **visible** ones (user-dismissed Codex
            // rows are removed *before* interleaving/capping, exactly like Claude's `visibleSessions`,
            // so a hidden row can never be forced back by the cap or a same-tick interleave — Fix 2).
            // The two providers share ONE compact 4-row budget, but `AgentSessionRadar` **interleaves**
            // them by activity instead of "all Claude first" — so a busy Codex session is never forced
            // below an idle Claude one. When Codex is off/empty this is exactly the old Claude-only list
            // (docs/decisions/0017).
            let codexSessions = codexEnabled ? codex.visibleSessions : []
            let agentList = AgentSessionRadar.present(claude: claudeRadar, codex: codexSessions)

            VStack(alignment: .leading, spacing: 6) {
                // No aggregate status line and no empty-state placeholder anymore: the sessions area
                // shows session rows directly (docs/decisions/0017). The parent instantiates this section
                // only when `agentSessionsHasContent` is true — i.e. at least one visible row exists — so
                // in steady state `agentList.items` is non-empty. If the radar's time-based rules age the
                // last row out on a tick before the parent re-evaluates, the list renders nothing at all
                // (zero height) rather than reserving space for a "No active sessions" line.

                // The interleaved visible session rows: Claude rows keep their exact visuals + drag/
                // right-click dismiss; Codex rows carry the "Codex" pill. Hiding either row type is
                // presentation-only and never changes the raw session list used by automation.
                ForEach(agentList.items) { item in
                    switch item {
                    case .claude(let row):
                        SessionRow(row: row, now: now, onActivate: { activate(.claude) }) {
                            // Animate the removal; `dismiss` only hides the row in VibeMenu — it never
                            // touches Claude data or the session itself.
                            withAnimation(.easeOut(duration: 0.22)) { claude.dismiss(row.session) }
                        }
                    case .codex(let row):
                        CodexSessionRow(row: row, now: now, onActivate: { activate(.codex) }) {
                            // Animate the removal; `dismiss` only hides the row in VibeMenu — it never
                            // touches Codex data, the session, or whether it prevents sleep.
                            withAnimation(.easeOut(duration: 0.22)) { codex.dismiss(row.session) }
                        }
                    }
                }

                // One provider-neutral overflow control. Its model already contains the next rows
                // from both providers in shared priority/recency order; SwiftUI only selects the
                // existing provider-specific row renderer for each item.
                if agentList.hiddenCount > 0 {
                    Button {
                        showOverflowSessions.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            if showOverflowSessions {
                                Text("Recent sessions")
                                Image(systemName: "chevron.down")
                            } else {
                                Text("+\(agentList.hiddenCount) more recent session\(agentList.hiddenCount == 1 ? "" : "s")")
                                Image(systemName: "chevron.right")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(showOverflowSessions
                        ? "Hide the older recent sessions again."
                        : "Show more recent sessions.")

                    if showOverflowSessions {
                        ForEach(agentList.overflowItems) { item in
                            switch item {
                            case .claude(let row):
                                SessionRow(row: row, now: now, onActivate: { activate(.claude) }) {
                                    withAnimation(.easeOut(duration: 0.22)) { claude.dismiss(row.session) }
                                }
                            case .codex(let row):
                                CodexSessionRow(row: row, now: now, onActivate: { activate(.codex) }) {
                                    withAnimation(.easeOut(duration: 0.22)) { codex.dismiss(row.session) }
                                }
                            }
                        }
                        if agentList.olderHiddenCount > 0 {
                            Text("+\(agentList.olderHiddenCount) older session\(agentList.olderHiddenCount == 1 ? "" : "s") hidden")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .animation(.snappy, value: showOverflowSessions)
        }
    }
}

/// One compact Session Radar row laid out on **two lines**: a state-coloured dot in the gutter,
/// then a content column whose top line is the state word **followed by the agent pill** (with the
/// elapsed timer pinned far right) and whose bottom line is the session **name** on its own. The
/// name is Claude Code's own session title when safely readable, else the project folder name
/// (docs/decisions/0013-session-title-and-dismiss.md, docs/decisions/0012-session-name-from-cwd.md),
/// and tail-truncates before the trailing edge. The raw session id is intentionally not shown (opaque
/// and unhelpful — see docs/PRIVACY.md); the agent pill reads "Claude" (the only agent in v0.2) so the
/// row is already agent-labelled for a future multi-agent pass. Keeping the pill beside the state word
/// groups "what's happening / which agent" on one glanceable line and gives the name the full second
/// line to itself.
///
/// **Dismiss:** drag the row to the right past a threshold to hide it, or use its right-click
/// context menu ("Hide from VibeMenu") — the reliable fallback if the drag gesture is flaky in the
/// `MenuBarExtra` window. Either way it only hides the row in VibeMenu; Claude is untouched.
struct SessionRow: View {
    let row: RadarRow
    let now: Date
    /// Activates Claude Desktop on a plain click; drag and context-menu gestures remain hide-only.
    let onActivate: () -> Void
    /// Hide this row (animated by the caller). VibeMenu-only; see the type doc.
    let onDismiss: () -> Void

    /// How far the row must be dragged rightward before releasing dismisses it.
    private static let dismissThreshold: CGFloat = 64

    /// Fixed width of the trailing timer column. It is **always reserved** — even on rows that show no
    /// timer (`.done`/`.stale`) — so the content column always ends at the same x and rows stay
    /// aligned; the session name can never expand into this space. Wide enough for "10m 05s" at
    /// caption size.
    private static let timerColumnWidth: CGFloat = 48

    /// Live horizontal drag offset, so the row follows the finger/trackpad and springs back if
    /// the drag is too short to dismiss.
    @State private var dragOffset: CGFloat = 0

    private var session: ClaudeSession { row.session }

    var body: some View {
        // Two-line row: a state-coloured dot in the gutter, then a content column whose **top line**
        // is the state word + agent pill and whose **bottom line** is the session name, with the
        // elapsed timer pinned to a fixed trailing column so it always sits on the top line at a
        // constant x. Leading with "state + agent" up top and the name below lets the user scan
        // "what's happening" and "which session" as two glanceable lines.
        HStack(alignment: .top, spacing: 8) {
            // Status dot — nudged down so it centres on the top (status) line rather than the whole
            // two-line block; it belongs to the state word beside it, not the name below.
            Circle()
                .fill(SessionRow.color(session.state.displayStyle))
                .frame(width: 8, height: 8)
                .padding(.top, 4)

            // Content column: state word + agent pill on top, session name below. It claims the row's
            // flexible width (via the greedy top line and the name's `maxWidth: .infinity`), so both
            // lines end before the reserved timer column instead of pushing it around.
            VStack(alignment: .leading, spacing: 3) {
                // Top line: the state word — semibold when the session needs the user (a real
                // approval prompt) so it pops (a normal finished turn reads "Done", docs/decisions/0015)
                // — immediately followed by the agent pill (always "Claude" in v0.2), so state and
                // agent read together. A trailing spacer keeps them left-aligned; the reserved timer
                // column (outer HStack) owns the far right.
                HStack(spacing: 6) {
                    Text(session.state.label)
                        .fontWeight(session.state.needsAttention ? .semibold : .regular)
                        .lineLimit(1)

                    Text(session.agent)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        // Subtle, translucent chip — dark-on-dark, never a bright badge.
                        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.08)))

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Bottom line: the session name on its own — Claude Code's title when known, else the
                // folder name (with a disambiguation index if two visible rows share a name). It aligns
                // under the state word (same content-column leading edge, not under the dot). Single-line,
                // tail-truncated, and greedy (`maxWidth: .infinity`) so it ellipsizes before the row's
                // trailing edge rather than wrapping or expanding into the timer column.
                Text(row.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Elapsed time: a fixed trailing column, **always reserved** (even on rows that show no
            // timer, e.g. `.done`) so every row's content column ends at the same x and the name can
            // never grow into this space. Shows the timer only for live/working/approval rows — a
            // finished `.done` session shows an empty string (a running clock on a finished turn is
            // meaningless) while still holding the column open. Nudged to align with the top line.
            Text(session.state.showsElapsedTimer ? session.displayElapsedLabel(now: now) : "")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: SessionRow.timerColumnWidth, alignment: .trailing)
                .padding(.top, 1)
        }
        // Keep the whole row (including the trailing gap) hit-testable for the drag.
        .contentShape(Rectangle())
        .offset(x: dragOffset)
        // Fade as it slides away, so a partial drag reads as "letting go will dismiss".
        .opacity(dragOffset > 0 ? Double(max(0, 1 - dragOffset / (Self.dismissThreshold * 2))) : 1)
        // Tap and drag are mutually exclusive: a drag-to-hide can never also activate Claude Desktop.
        // Notification clicks use the same provider callback. Keep the context menu separate below.
        .gesture(
            TapGesture()
                .onEnded { onActivate() }
                .exclusively(before:
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            // Rightward only; a left drag does nothing (clamped to 0).
                            dragOffset = max(0, value.translation.width)
                        }
                        .onEnded { value in
                            if value.translation.width > Self.dismissThreshold {
                                onDismiss()   // caller wraps in withAnimation; the removal transition plays
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    dragOffset = 0   // too short → snap back
                                }
                            }
                        }
                )
        )
        // Reliable fallback for hiding a row if the drag gesture is unreliable in the menu window.
        .contextMenu {
            Button("Hide from VibeMenu") { onDismiss() }
        }
        .help("Drag right, or right-click → Hide, to remove this session from VibeMenu (Claude is untouched).")
        // Slide out to the right + fade when removed, matching the swipe direction.
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    /// Map the core's framework-free `ClaudeSessionDisplayStyle` to a SwiftUI semantic colour
    /// (system colours only — no hard-coded RGB), mirroring `MenuContentView.thermalColor`.
    static func color(_ style: ClaudeSessionDisplayStyle) -> Color {
        switch style {
        case .working: .green
        case .waiting: .blue
        case .attention: .orange
        case .done: .secondary
        case .inactive: Color.secondary.opacity(0.6)
        }
    }
}

/// One ChatGPT desktop session row (docs/decisions/0017-codex-session-support.md). Mirrors the
/// Claude `SessionRow`'s two-line layout — a state-coloured dot, then a content column with the
/// state word + a clear **"ChatGPT Work" / "Codex" mode pill** on top and the project **folder name** below, and an
/// elapsed timer pinned to a fixed trailing column — so Claude and Codex rows read as one list.
///
/// **Hide is a view-only control (Fix 2).** Like `SessionRow`, the row can be dragged right past a
/// threshold — or right-clicked → "Hide from VibeMenu" — to remove it from the list; either way it only
/// hides the row in VibeMenu and touches no Codex data. It does **not** change whether the session
/// prevents sleep: the keep-awake decision reads the raw session list, not this hidden view. The name is
/// only the project folder name / safe title (never a path or session id); the timer shows the real
/// session duration for an active row and is blank otherwise. No prompt/response/tool text is ever shown
/// (docs/PRIVACY.md).
struct CodexSessionRow: View {
    let row: CodexRow
    let now: Date
    /// Activates ChatGPT on a plain click; drag and context-menu gestures remain hide-only.
    let onActivate: () -> Void
    /// Hide this row (animated by the caller). VibeMenu-only; see the type doc.
    let onDismiss: () -> Void

    /// How far the row must be dragged rightward before releasing dismisses it (matches `SessionRow`).
    private static let dismissThreshold: CGFloat = 64

    /// Fixed width of the trailing timer column, always reserved so rows align (matches `SessionRow`).
    private static let timerColumnWidth: CGFloat = 48

    /// Live horizontal drag offset, so the row follows the finger/trackpad and springs back if the
    /// drag is too short to dismiss (matches `SessionRow`).
    @State private var dragOffset: CGFloat = 0

    private var session: CodexSession { row.session }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Status dot — nudged to centre on the top (status) line.
            Circle()
                .fill(CodexSessionRow.color(session.state.displayStyle))
                .frame(width: 8, height: 8)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 3) {
                // Top line: the state word immediately followed by the mode pill ("ChatGPT Work" / "Codex").
                HStack(spacing: 6) {
                    Text(session.state.label)
                        .lineLimit(1)

                    Text(session.agent)   // CodexSessionMode.label — "ChatGPT Work" or "Codex"
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.08)))

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Bottom line: the project folder name (or a generic label), tail-truncated.
                Text(row.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Elapsed session duration — only for an active row; the column is always reserved so
            // rows stay aligned with the Claude rows above.
            Text(session.state.showsElapsedTimer ? session.elapsedLabel(now: now) : "")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: CodexSessionRow.timerColumnWidth, alignment: .trailing)
                .padding(.top, 1)
        }
        // Keep the whole row (including the trailing gap) hit-testable for the drag.
        .contentShape(Rectangle())
        .offset(x: dragOffset)
        // Fade as it slides away, so a partial drag reads as "letting go will dismiss".
        .opacity(dragOffset > 0 ? Double(max(0, 1 - dragOffset / (Self.dismissThreshold * 2))) : 1)
        // Tap and drag are mutually exclusive: a drag-to-hide can never also activate ChatGPT.
        // Notification clicks use the same provider callback. Keep the context menu separate below.
        .gesture(
            TapGesture()
                .onEnded { onActivate() }
                .exclusively(before:
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            // Rightward only; a left drag does nothing (clamped to 0).
                            dragOffset = max(0, value.translation.width)
                        }
                        .onEnded { value in
                            if value.translation.width > Self.dismissThreshold {
                                onDismiss()   // caller wraps in withAnimation; the removal transition plays
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    dragOffset = 0   // too short → snap back
                                }
                            }
                        }
                )
        )
        // Reliable fallback for hiding a row if the drag gesture is unreliable in the menu window.
        .contextMenu {
            Button("Hide from VibeMenu") { onDismiss() }
        }
        .help("Drag right, or right-click → Hide, to remove this OpenAI session from VibeMenu. VibeMenu "
            + "reads only the project folder name and activity time — never prompts, responses, tool "
            + "output, paths, or repo URLs; the OpenAI app is untouched.")
        // Slide out to the right + fade when removed, matching the swipe direction.
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    /// Map the core's framework-free `CodexSessionDisplayStyle` to a SwiftUI semantic colour (system
    /// colours only), mirroring `SessionRow.color`.
    static func color(_ style: CodexSessionDisplayStyle) -> Color {
        switch style {
        case .working: .green
        case .idle: .blue
        case .done: .secondary
        case .inactive: Color.secondary.opacity(0.6)
        }
    }
}

/// The opt-in Claude usage-limits section (docs/decisions/0016-claude-usage-limits.md).
///
/// Compact rows matching the app style: the window label on the left; the reset text + percent on the
/// right; a thin, severity-tinted bar underneath — mirroring the attached usage-bars design. Honesty
/// first: it draws the real captured percentages when fresh, appends an "as of Xm ago" note when the
/// capture is stale (the reset countdown stays correct regardless, being derived from the absolute
/// reset time), and shows a short guidance line — never a fabricated bar — when no data is available.
/// A `TimelineView` re-derives the countdowns/staleness from the absolute timestamps while the menu
/// is open.
struct ClaudeLimitsView: View {
    var usage: ClaudeUsageLimitModel
    /// The user's per-row hide/show choices; hidden rows are filtered out before rendering. The parent
    /// only draws this section when at least one row is visible (or there is no data), so an all-hidden
    /// snapshot never reaches the row branch here.
    var visibility: ClaudeUsageLimitVisibility
    /// Opens Settings (to set up capture / learn more) from the empty-state hint.
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Claude Limits")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                // No "Experimental" badge: the section's honesty comes from what it says, not from a
                // classification chip. The source, freshness/"as of" note, and unavailable state below
                // (plus the Settings disclosure) still state plainly that this is best-effort,
                // version-fragile, local-only data.
                Spacer(minLength: 0)
            }

            TimelineView(.periodic(from: .now, by: 30)) { context in
                let snapshot = usage.snapshot
                // Apply the per-row visibility preference: hidden rows are still parsed and stored in
                // the snapshot, they are just not drawn (task B/E).
                let visibleLimits = visibility.visibleLimits(in: snapshot)
                if !visibleLimits.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        // Keyed by the stable per-row id (kind + group), so multiple weekly rows
                        // (all-models + per-model) never collide the way `kind` alone would.
                        ForEach(visibleLimits) { limit in
                            UsageLimitRow(limit: limit, now: context.date)
                        }
                        if let note = snapshot.ageNote(now: context.date) {
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else if snapshot.hasData {
                    // Every detected row is hidden. The parent normally hides the whole section in this
                    // case; render nothing as a defensive fallback so no empty box appears.
                    EmptyView()
                } else {
                    // No fabricated bars — a quiet, honest unavailable state plus a way into Settings.
                    Button(action: openSettings) {
                        Text("No Claude usage data yet — choose a source in Settings")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("VibeMenu reads Claude usage limits locally — from Claude Desktop's own cache "
                        + "or an opt-in Claude Code status-line capture. No network, no cookies, no API "
                        + "keys. Pick a source in Settings.")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One usage-limit row: window label on the left, reset text + right-aligned percent on the right,
/// and a thin severity-tinted bar underneath.
struct UsageLimitRow: View {
    let limit: ClaudeUsageLimit
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Left: the window label. Given layout priority so the (short, fixed) label keeps its
                // width and the variable reset text is what truncates when space is tight.
                Text(limit.displayLabel)
                    .font(.callout)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                // Middle/right: the reset countdown, occupying the space the old duplicate label used
                // to take. Tail-truncates before the percent if the row is narrow.
                Text(limit.resetText(now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Far right: the used-percent in a fixed, trailing-aligned column so every row's
                // percent lines up on the same edge regardless of reset-text length.
                Text(limit.percentText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(UsageLimitRow.color(limit.severity))
                    .frame(minWidth: 38, alignment: .trailing)
            }
            UsageBar(fraction: limit.fraction, color: UsageLimitRow.color(limit.severity))
        }
    }

    /// Restrained severity tint (system colours only): blue when normal, orange ≥75%, red ≥90%.
    static func color(_ severity: ClaudeUsageLimitSeverity) -> Color {
        switch severity {
        case .normal: .blue
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// A thin (~4 pt) horizontal usage bar: a faint track with a filled capsule at `fraction` (0…1) of the
/// width. No text; the row supplies the percent. `fraction` is clamped so a bad value can never
/// overflow the track.
struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(Color.primary.opacity(0.10))
                Capsule(style: .continuous).fill(color)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("Used \(Int((max(0, min(1, fraction)) * 100).rounded())) percent")
    }
}

/// The opt-in **ChatGPT limits** section (docs/decisions/0017-codex-session-support.md): the real
/// `rate_limits` the ChatGPT desktop app writes to its rollout files, shared by its Work and Codex
/// modes. Mirrors `ClaudeLimitsView` — a labelled section of `CodexUsageLimitRow`s with an honest
/// stale/"as of" note, and a quiet unavailable state (never a fabricated bar) with a way into
/// Settings. Kept as its own view and type so ChatGPT and Claude usage never entangle.
struct CodexLimitsView: View {
    var usage: CodexUsageLimitModel
    /// The user's per-row hide/show choices; hidden rows are filtered before rendering. The parent
    /// only draws this section when at least one row is visible (or there is no data).
    var visibility: CodexUsageLimitVisibility
    /// Opens Settings (to learn more / enable) from the empty-state hint.
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(CodexUsageLimitsMenuCopy.sectionTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                // No "Experimental" badge — same reasoning as `ClaudeLimitsView`. The shared-allowance
                // note, the turn-bound freshness copy, and the honest empty state carry the caveats.
                Spacer(minLength: 0)
            }

            TimelineView(.periodic(from: .now, by: 30)) { context in
                let snapshot = usage.snapshot
                let visibleLimits = visibility.visibleLimits(in: snapshot)
                if !visibleLimits.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(visibleLimits) { limit in
                            CodexUsageLimitRow(limit: limit, now: context.date)
                        }
                        if let note = snapshot.ageNote(now: context.date) {
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else if snapshot.hasData {
                    // Every detected row hidden — the parent normally hides the whole section; render
                    // nothing as a defensive fallback so no empty box appears.
                    EmptyView()
                } else {
                    // No fabricated bars — a quiet, honest unavailable state plus a way into Settings.
                    // The copy lives in `VibeMenuCore` (`CodexUsageLimitsMenuCopy`) so it is unit-tested
                    // and stays truthful: only a Codex *turn* writes a new local reading, and VibeMenu
                    // can never fetch the allowance itself.
                    Button(action: openSettings) {
                        Text(CodexUsageLimitsMenuCopy.emptyState)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(CodexUsageLimitsMenuCopy.emptyStateHelp)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One Codex usage-limit row: window label on the left, reset text + right-aligned percent on the
/// right, and a thin severity-tinted bar underneath. Reuses `UsageBar`; mirrors `UsageLimitRow`.
struct CodexUsageLimitRow: View {
    let limit: CodexUsageLimit
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(limit.displayLabel)
                    .font(.callout)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Text(limit.resetText(now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(limit.percentText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(CodexUsageLimitRow.color(limit.severity))
                    .frame(minWidth: 38, alignment: .trailing)
            }
            UsageBar(fraction: limit.fraction, color: CodexUsageLimitRow.color(limit.severity))
        }
    }

    /// Restrained severity tint (system colours only): blue when normal, orange ≥75%, red ≥90%.
    static func color(_ severity: CodexUsageLimitSeverity) -> Color {
        switch severity {
        case .normal: .blue
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// A compact Settings group. The system control background and separator adapt to appearance and
/// accessibility settings without adding another translucent layer to the window.
private struct SettingsGroup<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
        }
    }
}

/// One full-width Boolean setting with a compact macOS switch aligned to the trailing edge.
private struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
            Spacer(minLength: 16)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(title)
        }
        .frame(minHeight: 28)
    }
}

/// A compact label/value row used by provider-specific controls. Supplemental status belongs inside
/// `value`, immediately beneath the control it describes, so it never floats in the centre of a group.
private struct SettingsValueRow<Value: View>: View {
    let title: String
    let value: Value

    init(_ title: String, @ViewBuilder value: () -> Value) {
        self.title = title
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .frame(width: 112, alignment: .leading)
            Spacer(minLength: 8)
            value
        }
        .frame(minHeight: 28)
    }
}

private struct SettingsRowDivider: View {
    var body: some View {
        Divider()
            .padding(.vertical, 5)
    }
}

/// Focused single-pane Settings window. It reads/writes the same keys as the menu and providers, so
/// every change remains live and persists exactly as before; this view only changes presentation.
struct SettingsView: View {
    // Reflects the actual `SMAppService.mainApp` login-item status; the source of truth
    // is the system, not a persisted bool. Refreshed on appear so external changes made in
    // macOS System Settings → General → Login Items show up here.
    var loginItem: LoginItemModel

    /// Performs the opt-in, preview-gated statusLine install for usage capture (ADR 0016).
    var install: ClaudeUsageInstallModel

    /// Owns the single Attention v1 notification toggle and its permission request.
    var attention: AttentionNotificationModel

    @AppStorage(PreferenceKey.showClaudeStatus) private var showClaudeStatus = true
    @AppStorage(PreferenceKey.showThermalStatus) private var showThermalStatus = true
    // Opt-in enhanced titles; default off (see PreferenceKey.useDesktopTitles / ADR 0014).
    @AppStorage(PreferenceKey.useDesktopTitles) private var useDesktopTitles = false
    // Opt-in Codex Desktop session detection; default off (see PreferenceKey.showCodexSessions / ADR 0017).
    @AppStorage(PreferenceKey.showCodexSessions) private var showCodexSessions = false
    // Opt-in usage limits; default off (see PreferenceKey.showClaudeLimits / ADR 0016).
    @AppStorage(PreferenceKey.showClaudeLimits) private var showClaudeLimits = false
    // Which local source feeds the section; default Auto (see PreferenceKey.claudeLimitsSource / ADR 0016).
    @AppStorage(PreferenceKey.claudeLimitsSource) private var sourceModeRaw = ClaudeUsageLimitSourceMode.auto.rawValue
    // Per-row visibility: newline-joined hidden stable ids. Shared with the menu, so a toggle here
    // updates the popover live (see PreferenceKey.claudeLimitsHiddenIDs / ADR 0016).
    @AppStorage(PreferenceKey.claudeLimitsHiddenIDs) private var claudeLimitsHiddenIDs = ""
    // Whether the Claude provider is expanded; persisted under the existing key.
    @AppStorage(PreferenceKey.claudeLimitsSectionExpanded) private var usageSectionExpanded = false
    // Opt-in Codex usage limits; default off (see PreferenceKey.showCodexLimits / ADR 0017).
    @AppStorage(PreferenceKey.showCodexLimits) private var showCodexLimits = false
    // Per-row visibility for the Codex usage section; separate from Claude (see PreferenceKey.codexLimitsHiddenIDs).
    @AppStorage(PreferenceKey.codexLimitsHiddenIDs) private var codexLimitsHiddenIDs = ""
    // Whether the Codex provider is expanded; the key already exists and remains unchanged.
    @AppStorage(PreferenceKey.codexLimitsSectionExpanded) private var codexSectionExpanded = false

    /// Drives the install confirmation dialog (preview shown before any settings.json write).
    @State private var showingInstallPreview = false
    /// Whether Claude's advanced controls are expanded (ephemeral; default folded).
    @State private var captureAdvancedExpanded = false

    /// "Detected" text + Claude Code "capture status" text, computed **off the main thread** (both read
    /// files / scan the cache) and published back for the view to display. Refreshed when Settings
    /// appears, when the source picker changes, and after an install/uninstall — never inside `body`.
    @State private var detectedText = "Waiting for data"
    @State private var captureStatus = "…"
    /// The currently detected rows (stable id + label) driving the per-limit visibility toggles.
    /// Recomputed alongside `detectedText`; empty when no source has data yet.
    @State private var detectedLimits: [DetectedUsageLimit] = []

    /// One detected row surfaced to the per-limit visibility toggles. `id` is the stable
    /// `ClaudeUsageLimit.visibilityID`, so the toggle binds to the same key the menu filters on.
    private struct DetectedUsageLimit: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
    }

    /// Honest "Detected" line + detected rows for the **Codex** usage section, computed off the main
    /// thread (reads Codex rollout files) and published back for the view. Refreshed on appear and
    /// whenever the Codex-limits toggle changes.
    @State private var codexDetectedText = "Waiting for data"
    @State private var codexDetectedLimits: [DetectedUsageLimit] = []

    /// Two-way binding of the persisted raw string to the source enum for the picker.
    private var sourceMode: Binding<ClaudeUsageLimitSourceMode> {
        Binding(
            get: { ClaudeUsageLimitSourceMode(rawValue: sourceModeRaw) ?? .auto },
            set: { sourceModeRaw = $0.rawValue; refreshDetection() }
        )
    }

    /// A provider setting change is an explicit enablement/reset boundary for Attention v1. Keep
    /// this separate from ordinary empty Codex snapshots so a later new session can notify.
    private var codexSessionsBinding: Binding<Bool> {
        Binding(
            get: { showCodexSessions },
            set: { requested in
                guard requested != showCodexSessions else { return }
                attention.resetProviderBaseline(.codex)
                showCodexSessions = requested
            }
        )
    }

    /// Whether a detected row is currently shown (not hidden).
    private func isRowVisible(_ id: String) -> Bool {
        !ClaudeUsageLimitVisibility(persisted: claudeLimitsHiddenIDs).isHidden(id: id)
    }

    /// Persist a per-row show/hide choice by re-encoding the hidden set.
    private func setRowVisible(_ visible: Bool, id: String) {
        var visibility = ClaudeUsageLimitVisibility(persisted: claudeLimitsHiddenIDs)
        visibility.setHidden(!visible, id: id)
        claudeLimitsHiddenIDs = visibility.persisted
    }

    /// Whether a Codex detected row is currently shown (not hidden).
    private func isCodexRowVisible(_ id: String) -> Bool {
        !CodexUsageLimitVisibility(persisted: codexLimitsHiddenIDs).isHidden(id: id)
    }

    /// Persist a per-row show/hide choice for the Codex section.
    private func setCodexRowVisible(_ visible: Bool, id: String) {
        var visibility = CodexUsageLimitVisibility(persisted: codexLimitsHiddenIDs)
        visibility.setHidden(!visible, id: id)
        codexLimitsHiddenIDs = visibility.persisted
    }

    /// Recompute the Codex "Detected" line + detected-rows list off the main thread (reads Codex
    /// rollout files) and publish back. One-shot; never runs inside `body`.
    private func refreshCodexDetection() {
        let enabled = showCodexLimits
        Task {
            let (line, rows) = await Task.detached(priority: .utility) {
                () -> (String, [DetectedUsageLimit]) in
                guard enabled else { return ("Waiting for data", []) }
                let snapshot = CodexUsageLimitReader().readSnapshot()
                let rows = snapshot.limits.map {
                    DetectedUsageLimit(id: $0.visibilityID, label: $0.displayLabel)
                }
                return (Self.codexDetectionText(from: snapshot), rows)
            }.value
            codexDetectedText = line
            codexDetectedLimits = rows
        }
    }

    /// Honest "Detected" text for the Codex section from an already-read snapshot.
    nonisolated private static func codexDetectionText(from snapshot: CodexUsageLimitSnapshot) -> String {
        guard snapshot.hasData else { return "Waiting for data" }
        let now = Date()
        switch snapshot.status(now: now) {
        case .fresh: return "live"
        case .stale: return snapshot.ageNote(now: now) ?? "stale"
        case .unavailable: return "Waiting for data"
        }
    }

    /// Recompute the "Detected" + "capture status" lines **and** the detected-rows list off the main
    /// thread (all touch the filesystem) and publish the results back to the view. One-shot; never
    /// runs inside `body`.
    private func refreshDetection() {
        let mode = ClaudeUsageLimitSourceMode(rawValue: sourceModeRaw) ?? .auto
        let installed = install.isInstalled
        Task {
            let (detectedLine, captureLine, rows) = await Task.detached(priority: .utility) {
                () -> (String, String, [DetectedUsageLimit]) in
                let detected = CompositeClaudeUsageLimitReader(mode: { mode }).readSnapshot()
                let rows = detected.limits.map {
                    DetectedUsageLimit(id: $0.visibilityID, label: $0.displayLabel)
                }
                return (Self.detectionText(from: detected), Self.captureStatusText(installed: installed), rows)
            }.value
            detectedText = detectedLine
            captureStatus = captureLine
            detectedLimits = rows
        }
    }

    /// Honest "Detected" text: which source produced data and how fresh it is, from an already-read
    /// composite snapshot (the read happens once in `refreshDetection`).
    nonisolated private static func detectionText(from detected: ClaudeUsageLimitSnapshot) -> String {
        guard detected.hasData else { return "Waiting for data" }
        let name = detected.source.displayName
        let now = Date()
        switch detected.status(now: now) {
        case .fresh: return "\(name) · live"
        case .stale: return detected.ageNote(now: now).map { "\(name) · \($0)" } ?? "\(name) · stale"
        case .unavailable: return "Waiting for data"
        }
    }

    /// Honest status of the Claude Code status-line capture, read from VibeMenu's usage file (off the
    /// main thread via `refreshDetection`).
    nonisolated private static func captureStatusText(installed: Bool) -> String {
        guard installed else { return "Not installed" }
        let snapshot = FileClaudeUsageLimitReader().readSnapshot()
        let now = Date()
        switch snapshot.status(now: now) {
        case .fresh: return "Installed · detected"
        case .stale: return snapshot.ageNote(now: now).map { "Installed · stale (\($0))" } ?? "Installed · stale"
        case .unavailable: return "Installed · waiting for a Claude Code session"
        }
    }

    /// Compact row-visibility menu. Its checkmarked items keep the existing hidden-ID encoding while
    /// avoiding a dynamic stack of implementation-looking checkboxes in the window.
    private var claudeRowsMenu: some View {
        Menu {
            ForEach(detectedLimits) { row in
                Toggle(row.label, isOn: Binding(
                    get: { isRowVisible(row.id) },
                    set: { setRowVisible($0, id: row.id) }
                ))
            }
        } label: {
            Text("\(detectedLimits.filter { isRowVisible($0.id) }.count) of \(detectedLimits.count) shown")
        }
        .controlSize(.small)
        .fixedSize()
    }

    private var codexRowsMenu: some View {
        Menu {
            ForEach(codexDetectedLimits) { row in
                Toggle(row.label, isOn: Binding(
                    get: { isCodexRowVisible(row.id) },
                    set: { setCodexRowVisible($0, id: row.id) }
                ))
            }
        } label: {
            Text("\(codexDetectedLimits.filter { isCodexRowVisible($0.id) }.count) of "
                + "\(codexDetectedLimits.count) shown")
        }
        .controlSize(.small)
        .fixedSize()
    }

    @ViewBuilder private var claudeAdvancedControls: some View {
        SettingsToggleRow(title: "Use Claude Desktop session titles", isOn: $useDesktopTitles)

        // Desktop cache mode needs no CLI capture. Automatic and Claude Code keep the existing
        // preview-gated setup/remove path, now presented as one compact action with local status.
        if sourceMode.wrappedValue != .desktopCache {
            SettingsRowDivider()
            SettingsValueRow("Claude Code capture") {
                VStack(alignment: .trailing, spacing: 3) {
                    if install.isInstalled {
                        Button("Remove") { install.uninstall(); refreshDetection() }
                    } else {
                        Button("Set Up…") { showingInstallPreview = true }
                    }
                    Text(captureStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = install.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var generalSettings: some View {
        SettingsGroup {
            Text("General")
                .font(.headline)
                .padding(.bottom, 5)

            // The binding still reflects `SMAppService.mainApp`'s actual status after every change.
            SettingsToggleRow(title: "Launch at login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            SettingsRowDivider()
            SettingsToggleRow(title: "Agent notifications", isOn: Binding(
                get: { attention.isEnabled },
                set: { attention.setEnabled($0) }
            ))
            SettingsRowDivider()
            SettingsToggleRow(title: "Thermal status", isOn: $showThermalStatus)
            SettingsRowDivider()
            // The stored key remains `showClaudeStatus` for backward compatibility (ADR 0017).
            SettingsToggleRow(title: "Show session rows", isOn: $showClaudeStatus)
        }
    }

    private var claudeSettings: some View {
        SettingsGroup {
            DisclosureGroup(isExpanded: $usageSectionExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsRowDivider()
                    SettingsToggleRow(title: "Show usage", isOn: $showClaudeLimits)

                    if showClaudeLimits {
                        SettingsRowDivider()
                        SettingsValueRow("Source") {
                            VStack(alignment: .trailing, spacing: 2) {
                                Picker("Source", selection: sourceMode) {
                                    ForEach(ClaudeUsageLimitSourceMode.allCases, id: \.self) { mode in
                                        Text(mode.displayName).tag(mode)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .controlSize(.small)
                                .fixedSize()
                                Text(detectedText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        if !detectedLimits.isEmpty {
                            SettingsRowDivider()
                            SettingsValueRow("Rows") {
                                claudeRowsMenu
                            }
                        }
                    }

                    SettingsRowDivider()
                    DisclosureGroup(isExpanded: $captureAdvancedExpanded) {
                        VStack(alignment: .leading, spacing: 0) {
                            SettingsRowDivider()
                            claudeAdvancedControls
                        }
                    } label: {
                        Text("Advanced")
                            .font(.callout.weight(.medium))
                    }
                }
                .padding(.top, 1)
            } label: {
                Text("Claude")
                    .font(.headline)
            }
        }
    }

    private var codexSettings: some View {
        SettingsGroup {
            DisclosureGroup(isExpanded: $codexSectionExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsRowDivider()
                    SettingsToggleRow(
                        title: CodexUsageLimitsMenuCopy.settingsTrackSessionsTitle,
                        isOn: codexSessionsBinding
                    )
                    SettingsRowDivider()
                    SettingsToggleRow(title: "Show usage", isOn: $showCodexLimits)

                    if showCodexLimits {
                        SettingsRowDivider()
                        SettingsValueRow("Source") {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(CodexUsageLimitsMenuCopy.settingsSourceName)
                                Text(codexDetectedText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        // One shared allowance, refreshed only by a real turn — stated here so the
                        // user never reads an unchanged row as a stuck or broken reading. The copy is
                        // unit-tested in `VibeMenuCore` (ADR 0017, Amendment 6).
                        SettingsRowDivider()
                        Text(CodexUsageLimitsMenuCopy.sharedAllowanceNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)

                        if !codexDetectedLimits.isEmpty {
                            SettingsRowDivider()
                            SettingsValueRow("Rows") {
                                codexRowsMenu
                            }
                        }
                    }
                }
                .padding(.top, 1)
            } label: {
                Text(CodexUsageLimitsMenuCopy.settingsGroupTitle)
                    .font(.headline)
            }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            generalSettings
            claudeSettings
            codexSettings
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 17)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        // Re-read the real status whenever Settings appears, so a change made in macOS
        // System Settings while VibeMenu was running is reflected the next time it opens.
        // Also refresh the usage-capture install state from ~/.claude/settings.json.
        .onAppear {
            loginItem.refresh()
            install.refresh()
            refreshDetection()
            refreshCodexDetection()
        }
        .onChange(of: showClaudeLimits) { _, enabled in
            if enabled { refreshDetection() }
        }
        // Re-read Codex detection when the Codex-limits toggle flips, so the freshness line and the
        // per-row visibility toggles appear/update without reopening Settings.
        .onChange(of: showCodexLimits) { _, _ in refreshCodexDetection() }
        // Preview-gated install: show exactly what will change (including any wrapped status line)
        // before writing settings.json. A backup is written first by the installer.
        .alert("Set up Claude usage capture?", isPresented: $showingInstallPreview) {
            Button("Set Up") { install.install(); refreshDetection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(install.previewText)
        }
        .navigationTitle("VibeMenu Settings")
    }
}
