# Installing VibeMenu

VibeMenu is a menu-bar-only macOS app distributed directly via **GitHub Releases**. Builds are
**unsigned and not notarized**, so macOS will warn you the first time you open it. That's
expected, and it's the plan for now rather than an oversight — the steps below include the
one-time workaround. You can also [build from source](#alternative-build-from-source).

**Requirements:** macOS 15+ on Apple Silicon.

---

## Install

1. **Download** the latest release zip from the
   [Releases page](../../releases/latest) — the asset is named
   `VibeMenu-v<version>-macos-arm64.zip`. The zip is only the download package.
2. **Unzip** it (double-click in Finder). You'll get **VibeMenu.app**.
3. **Move** `VibeMenu.app` to **/Applications** (drag it into your Applications folder).
   From now on you launch VibeMenu from Applications, not from the unzipped download.
4. **Open it (first time — unsigned build):**
   - Double-clicking shows a warning such as *"Apple could not verify VibeMenu is free of
     malware"* (or *"VibeMenu can't be opened because it is from an unidentified
     developer"*). This is expected for a build that isn't notarized.
   - Open **System Settings → Privacy & Security**, scroll down to the **Security** section,
     and click **Open Anyway** next to the VibeMenu message. Confirm (and authenticate) when
     prompted, then click **Open**.
   - You only need to do this the first time. After that, it opens normally by double-click.
   - This warning means Apple hasn't vetted the binary — see
     [SECURITY.md](SECURITY.md#distribution-what-unsigned-actually-means-for-you) for what
     you're actually accepting.
5. VibeMenu runs as a **menu-bar-only app** — look for the **VibeMenu icon in the menu bar**.
   There is **no Dock icon** and no main window; the only window it opens is **Settings…**.

## Alternative: build from source

Same app, built by you from source you can read, and you get exactly what's on `master`.
Requires a Swift 6 toolchain (full Xcode for the `.app`):

```sh
git clone https://github.com/Kirill-Chistov/VibeMenu.git
cd VibeMenu
scripts/package-github-release.sh 0.2   # → dist/VibeMenu-v0.2-macos-arm64.zip
```

Unzip that and drag `VibeMenu.app` to `/Applications`.

What this does and doesn't change: it means you're **not** trusting a binary someone else built
and uploaded — the supply chain is your own machine. It does **not** make the app signed. A
locally-built app is still unsigned, and depending on how you move it around, macOS may or may
not prompt you. See [CONTRIBUTING.md](../CONTRIBUTING.md).

## Enable Launch at Login (optional)

1. Click the VibeMenu **bolt icon** in the menu bar → **Settings…**.
2. Under **General**, turn on **Launch VibeMenu at login**.

> On unsigned/ad-hoc builds this toggle may behave inconsistently — reliable Launch at Login
> needs a signed build, which VibeMenu doesn't currently have
> ([roadmap](ROADMAP.md#distribution)). As a manual fallback, add VibeMenu under **System
> Settings → General → Login Items → +** — that works regardless. See
> [FAQ.md](FAQ.md#why-does-launch-at-login-not-work-in-debugunsigned-builds).

## Optional: Codex Desktop sessions

VibeMenu can show **Codex Desktop** sessions next to Claude in the same list, and an actively-
working Codex session holds sleep prevention too. It is **off by default** — turn on Codex
sessions in **Settings…**.

One difference worth knowing: Codex gets **no quiet-work hold**. Claude's optional hook emits
lifecycle events, so VibeMenu can hold through a silent build for up to 15 minutes. Codex
exposes no per-session heartbeat, so a quiet Codex session is genuinely ambiguous and the hold
drops after roughly a minute of quiet rather than guessing. Use the manual switch for a long
silent Codex run — see [FAQ.md](FAQ.md#why-doesnt-codex-get-the-15-minute-quiet-work-hold).

It reads only allowlisted metadata (timestamps, an opaque session id, the project folder name,
event *category* labels, and a curated title) from the rollout files Codex already writes under
`~/.codex`. No network, no `auth.json`, no prompts or tool output. While the setting is off,
VibeMenu never opens a single `~/.codex` file.

**Codex CLI sessions are ignored** — `~/.codex` is shared between the Desktop app and the CLI,
and VibeMenu keeps only Desktop sessions. See
[`decisions/0017`](decisions/0017-codex-session-support.md).

## Optional: reliable Claude detection (heartbeat hook)

VibeMenu's baseline Claude detection works out of the box (process presence + file
modification times, metadata only). Without a working hook you still get **coarse automatic
keep-awake**: VibeMenu holds sleep prevention while a `claude` process is running *and* files
under `~/.claude` are actively changing, and releases about ten seconds after that stops. What
the baseline can't do is tell a silent build from a finished turn — so there is **no quiet-work
hold**, and the Session Radar shows **no Claude rows** (baseline metadata carries no session
identity, and VibeMenu won't invent one). The baseline also takes over on its own if you install
the hook and it later stops working, once its last heartbeat is more than ten minutes old.

For a **more reliable working/waiting signal** — per-session rows, the bounded 15-minute
quiet-work hold, and **Needs approval** — you can manually install the opt-in Claude Code
**heartbeat hook**. Setup is a manual, reversible copy-paste you do yourself — VibeMenu never
edits `~/.claude/settings.json` for you.

The hook is also what powers **Needs approval**: register the `PermissionRequest` event and a
session blocked on a permission prompt sorts to the top of the list with a timer. VibeMenu
records only *that* a request happened — never what was requested. Note that Claude Desktop
fires no hook event when you **deny**, so a denied row can linger until that session's next
event (see [`decisions/0018`](decisions/0018-needs-approval.md)).

Full instructions: [`Support/ClaudeHeartbeat/README.md`](../Support/ClaudeHeartbeat/README.md).

## Optional: agent notifications

In **Settings…**, enable **Agent notifications** to receive local macOS notifications when a
Claude session enters **Needs approval** or **Done**. macOS will ask for notification permission.
VibeMenu requests alerts and the system default sound; actual delivery and playback remain under
macOS Notification, Focus, volume, and sound settings.

Notifications contain no prompt, response, command, tool, or approval-request content. Clicking a
notification or session row brings the owning provider app forward when public macOS APIs allow it;
selecting an exact conversation remains best-effort.

While a Claude approval is pending, the menu-bar glyph turns orange independently of the
notification setting. It returns to the normal adaptive icon when the approval state clears.

## Optional: usage limits (experimental)

VibeMenu can show your **real** Claude and Codex usage limits, read **locally** — no network,
cookies, API keys, or token estimation. Both are **opt-in and off by default**, display-only,
and never affect sleep prevention.

### Claude limits

Your real 5-hour and weekly usage (the same figures as the in-app `/usage` view, including
per-model weekly rows). Turn it on in **Settings… → Claude usage limits** and pick a **Source**:

- **Claude Desktop** *(no setup)* — if you use the Claude Desktop app, VibeMenu reads its local usage
  cache directly. Nothing to install; open Claude Desktop's Settings → Usage once so it refreshes the
  cache, and VibeMenu will detect it. Read-only — VibeMenu never modifies Claude's data.
- **Claude Code** — click **Set up Claude Code usage capture…**. That shows a preview, backs up
  `~/.claude/settings.json` first, and wraps any existing status line so yours keeps working (fully
  reversible from the same panel). Prefer to do it by hand? See
  [`Support/ClaudeUsage/README.md`](../Support/ClaudeUsage/README.md). Usage only appears for Claude.ai
  Pro/Max, after the first response in an interactive session.
- **Automatic** *(default)* — a fresh Claude Desktop reading when available, otherwise Claude Code.

### Codex limits

Requires **Codex sessions** to be on (above); enable Codex usage limits in **Settings…**. There
is nothing to install: VibeMenu reads the real `rate_limits` numbers Codex already records in
its own rollout files. Each row is labelled from the window's own reported duration, so it shows
whatever windows Codex actually reports rather than assuming a fixed pair — and a window that
Codex stops reporting simply disappears rather than going stale.

If a number isn't there, VibeMenu shows no data rather than estimating one.

---

## Uninstall

1. **Quit VibeMenu** — click the bolt icon → **Quit VibeMenu**.
2. **Disable Launch at Login** — if you enabled it, turn it off in **Settings… → General**
   before removing the app (or remove VibeMenu from **System Settings → General →
   Login Items**).
3. **Remove the app** — delete `VibeMenu.app` from **/Applications** (drag to Trash).
4. **(Optional) Remove app support data** — VibeMenu stores a little local state (e.g. the
   optional heartbeat files). If you want it gone too:

   ```sh
   rm -rf ~/Library/Application\ Support/VibeMenu
   ```

5. **(Optional) Remove the Claude hook** — if you installed the heartbeat hook, remove the
   VibeMenu entries from `~/.claude/settings.json` (or restore your backup). See the
   [heartbeat README](../Support/ClaudeHeartbeat/README.md#5-remove-it).
6. **(Optional) Remove the usage capture** — if you set up Claude usage limits, click **Remove usage
   capture from Claude Code** in Settings first (it restores any wrapped status line), or delete the
   `statusLine` entry from `~/.claude/settings.json` / restore a `settings.json.vibemenu-backup-*`.

That's the complete list. For reference, everything VibeMenu can touch outside its own app bundle:

- **`~/.claude/settings.json`** — only ever via the two **opt-in** setups above, and only with
  your action. The **usage status-line** setup is the one thing the app itself writes: it
  previews the change, backs the file up to `settings.json.vibemenu-backup-*` first, touches only
  the `statusLine` key, and is reversible from Settings. The **heartbeat hook** is copy-paste you
  do yourself — VibeMenu never edits that file for the hook.
- **`~/Library/Application Support/VibeMenu/`** — the heartbeat files (written by the hook
  script), the usage capture (`usage.json` plus the shim itself), and a normalized snapshot of
  your Claude usage reading. Step 4 removes all of it.
- **Preferences in `UserDefaults`** — your VibeMenu settings, under the app's own domain.
  Removed with the app support data via `defaults delete com.kirillchistov.VibeMenu` if you want
  a truly clean slate.
- **A login item**, only if you turned on Launch at Login (step 2 removes it).

The current release installs **no** privileged helper, adds no `sudoers` rule, and leaves
nothing running once the app is quit. It may request standard macOS notification permission if
you enable Agent notifications. Closed-lid support is not installed or enabled today; any future
version would require a separate, explicit helper-install and security decision.
