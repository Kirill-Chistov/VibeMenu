# VibeMenu — FAQ

Short answers to common questions. See also [INSTALL.md](INSTALL.md),
[PRIVACY.md](PRIVACY.md), and [ROADMAP.md](ROADMAP.md).

### Why did macOS warn me when I opened it?

Because the build is **unsigned and not notarized**. macOS Gatekeeper flags any app without an
Apple Developer ID signature and notarization ticket. Approve it once via **System Settings →
Privacy & Security → Open Anyway**, and it will open normally after that.

This isn't pending work. An Apple Developer ID is a recurring cost, and while the project is
still finding out whether anyone wants it, that cost isn't justified — so **releases stay
unsigned for now** ([roadmap](ROADMAP.md#distribution)). If adoption or funding later makes it
worth carrying, that's a decision the owner can revisit.

You can also build it from source: it's the same app, the source is right here, and the build is
two commands (see the README). That means trusting code you can read rather than a binary you
can't — though what you build is still an unsigned app.

### Which agents does it support?

**Claude Code** and **Codex Desktop**.

- **Claude Code** works out of the box (process + file metadata), and more reliably if you
  install the optional [heartbeat hook](../Support/ClaudeHeartbeat/README.md).
- **Codex Desktop** is **opt-in and off by default** — turn on Codex sessions in Settings.
  VibeMenu reads only allowlisted metadata from the rollout files Codex already writes locally.
  An actively-working Codex session holds sleep prevention — but only while it *looks* active;
  it gets no quiet-work hold (see below).
- **Codex CLI is not supported.** `~/.codex` is shared between the Desktop app and the CLI;
  VibeMenu keeps only sessions marked as Desktop and ignores every CLI session.

Other agents aren't detected. Support is added only where a privacy-safe local signal exists —
never by reading transcript message content.

### What does "Needs approval" mean, and why didn't my row clear when I denied?

When Claude asks permission to run a tool, VibeMenu moves that session to the top of the list
as **Needs approval**, with a timer from when the request arrived. It comes from Claude Code's
`PermissionRequest` hook event, so it needs the optional
[heartbeat hook](../Support/ClaudeHeartbeat/README.md) installed with that event registered.

**The row clears on that session's next lifecycle event, not the moment you click.** When you
**approve**, Claude carries on and its next event (`PostToolUse`, `Stop`, …) overwrites the
heartbeat, which clears the row — usually within a tick, but it's the next event that does it,
not the click itself. When you **deny**, there may be no next event for a while: Claude Desktop
fires no hook on deny, so VibeMenu never learns it happened, and the row lingers until the
session's next event (your next prompt clears it) or the 30-minute prune. Both are upstream
limitations, not bugs we can fix locally; they're documented in
[`decisions/0018`](decisions/0018-needs-approval.md).

VibeMenu never reads *what* is being approved — only that a request happened.

### What notifications does VibeMenu send?

When **Agent notifications** are enabled, VibeMenu can send local macOS notifications for a
Claude session entering **Needs approval** or **Done**. They use the system default notification
sound and contain only safe presentation metadata such as the provider and sanitized session
name—never prompts, commands, tool input/output, responses, or approval details. Foreground banners
and sounds still obey macOS Notification, Focus, volume, and sound settings.

The menu-bar glyph also switches to orange while any raw Claude session genuinely needs approval,
even when its row is hidden or notifications are off. Codex does not trigger that icon because it
has no equally reliable approval signal.

### Does it prevent display sleep?

**No.** VibeMenu keeps the *system* awake (so background work keeps running), but it does not
keep your **display** awake. Your screen can still dim and sleep while a run continues — that
doesn't stop the run.

### Does it work with the lid closed?

**No.** VibeMenu holds only the normal, process-scoped idle-sleep assertion, so closing the lid can
put the Mac to sleep. There is no clamshell/headless support and no privileged helper — v0.3 ships
without a headless setting.

The owner has separately verified twice that the macOS `SleepDisabled` mechanism kept a simple
process executing during a short lid-closed test on the current Apple Silicon Mac, and restored
normal sleep afterward. That's a historical data point: it shows the underlying mechanism can work on
that machine, but it never proved networking, sustained Claude/Codex progress, thermal safety, crash
recovery, or support across Macs. Lid-closed operation is out of scope for the current phase — active
feature development is paused, and it would need its own ADR, product approval, an opt-in privileged
helper, and hard guardrails before any such work. Whether it's ever pursued depends on real user
demand. See the [roadmap](ROADMAP.md).

### Does it read my Claude or Codex conversations?

**No.** VibeMenu never reads transcript **message content** — no prompts, responses,
`lastPrompt`, tool input/output, or any message body. Baseline Claude detection uses only
**process presence** and **file modification times** (metadata) under `~/.claude`. If you
install the optional heartbeat hook, it records only an **event name, session id, and project
folder name** that VibeMenu writes itself — no message text. Codex sessions are read from a
strict allowlist of metadata (timestamps, an opaque session id, the folder name, and event
*category* labels) — never message or tool bodies.

The one exception, so a row can be named: VibeMenu opens the matching Claude transcript to read
its **session-title record** (`custom-title` / `ai-title`) — the title and nothing else. That's
a deliberate, ADR-approved carve-out
([`decisions/0013`](decisions/0013-session-title-and-dismiss.md)), it's the only field read from
the file, and the title stays in memory. See [PRIVACY.md](PRIVACY.md) for the exact field lists.

### Does it send data anywhere?

**No.** VibeMenu makes **no network calls**. There is no backend, no account, no telemetry,
and no analytics — not even opt-in. Everything stays on your Mac.

### When exactly does it release — the moment the agent looks idle?

**For Claude: no — it releases when Claude *finishes*, not the instant it goes quiet.** VibeMenu
keeps the Mac awake while Claude is working and releases when the turn genuinely ends (`Stop`,
the session ending, or the `claude` process going away). In between, a **long silent phase** — a
multi-minute build or test run, one long tool call, or a subagent/Task — keeps sleep prevention
**held**, because no event fires during that stretch and releasing would sleep the Mac mid-run.
This *quiet-work hold* is bounded by a **15-minute cap** since the last sign of activity, so a
hung or forgotten session can't keep your Mac awake forever.

The quiet-work hold needs the optional [heartbeat hook](../Support/ClaudeHeartbeat/README.md) —
only its lifecycle events distinguish "silently working" from "finished". **Without a working
hook** you get a coarser version: VibeMenu keeps the Mac awake while a `claude` process is running
and files under `~/.claude` are actively changing, then releases about ten seconds after that
stops. Because the check runs every couple of seconds, an ongoing conversation stays held
throughout — what it can't cover is a long *silent* stretch; for those, install the hook or flip
the manual switch.

The same coarse behaviour kicks in if you installed the hook and it later stopped working (its
script moved or deleted). VibeMenu waits until the hook's last heartbeat is over ten minutes old
before falling back, so it never overrides a hook that is genuinely still reporting — including one
that just reported that Claude finished.

**For Codex: it releases once the session stops looking active** (about a minute of quiet). See
the next answer for why the two differ.

### Why doesn't Codex get the 15-minute quiet-work hold?

Because VibeMenu can't honestly tell, for Codex, whether a quiet session is mid-build or
finished. Claude's optional hook emits explicit lifecycle events, so a silence *between* a
"working" event and a "finished" event is identifiably work in progress — that's what the
quiet-work hold covers. Codex exposes no per-session heartbeat; VibeMenu only sees rollout
metadata land on disk. Silence there is genuinely ambiguous, and holding your Mac awake for 15
minutes on an ambiguous signal is the kind of guess VibeMenu doesn't make.

So a Codex session holds sleep prevention while it looks **active** — recent activity within
about a minute — and the hold drops shortly after it goes quiet. **If you have a long silent
Codex phase, flip the manual Sleep prevention switch**; manual always wins.

### Why does a Claude row say "Quiet" while sleep prevention is still active?

That's the quiet-work hold working as intended. The row reflects what VibeMenu can *see* right
now — during a long silent tool/subagent phase Claude emits no events for a while, so the row
falls back to **Quiet**. But the work is almost certainly still running, so VibeMenu keeps sleep
prevention held (up to the 15-minute cap) rather than risk sleeping mid-run. It releases shortly
after Claude actually finishes.

If you have a job with a silent stretch **longer than 15 minutes** and don't want any chance
of a release, flip the manual **Sleep prevention** switch — manual keep-awake always wins and
is never overridden by automation.

### Why don't I see any sessions?

When no rows survive, the session section **isn't there at all** — VibeMenu shows no placeholder
and no "nothing here" label; the section and its dividers simply collapse. So an empty-looking
menu means nothing recent was detected. Common reasons:

- The agent isn't running, or hasn't been active recently. Rows age out on their own: finished
  sessions drop off after ~5 minutes, quiet/stale ones after ~2, and anything left is pruned
  at 30.
- **Codex sessions are off by default** — turn them on in Settings.
- **Claude rows require the optional [heartbeat hook](../Support/ClaudeHeartbeat/README.md).**
  The baseline check (a local `claude` process + recent file activity under `~/.claude`) can drive
  coarse keep-awake, but it carries no session identity, so VibeMenu shows no Claude row rather
  than inventing one. If you *did* install the hook and rows vanished, check that its script is
  still where `~/.claude/settings.json` points — a hook pointing at a moved or deleted file fails
  silently ([troubleshooting](../Support/ClaudeHeartbeat/README.md#nothing-appears-check-the-script-is-still-there)).
- You hid the row (drag right / right-click → Hide). Hidden rows come back on their own if the
  session becomes active again, and restarting VibeMenu clears all hides.

Manual sleep prevention works regardless — just flip the switch.

### Does the Sleep prevention switch tell me the truth?

The **switch** shows your *manual* preference only. Underneath it, VibeMenu shows the **actual**
assertion state and who currently owns it (Manual / Claude / Codex), including when acquiring
the assertion failed — so "the switch is off" never means "nothing is holding your Mac awake."

You can verify VibeMenu's claim independently at any time:

```sh
pmset -g assertions   # look for "VibeMenu Keep Awake"
```

Toggling the switch changes only manual ownership; it never fights the automation, and manual
always wins.

### Why does Launch at Login not work in Debug/unsigned builds?

Launch at Login uses the public `SMAppService` API, which registers the app as a login item.
On **unsigned/ad-hoc** builds, macOS may refuse or inconsistently handle that registration — a
stable code signature is what registration keys off, and VibeMenu doesn't currently have one
([roadmap](ROADMAP.md#distribution)). Notarization is a separate thing and isn't what's missing
here. As a manual fallback, add VibeMenu under **System Settings → General → Login Items → +**
— that works regardless.

### How do I fully uninstall it?

Quit VibeMenu, disable Launch at Login, delete `VibeMenu.app` from `/Applications`, and
optionally remove `~/Library/Application Support/VibeMenu`. Full steps:
[INSTALL.md → Uninstall](INSTALL.md#uninstall).

### Does it control fans or read exact temperatures?

**No.** VibeMenu shows only Apple's public **thermal *pressure* state**
(Nominal / Fair / Serious / Critical) via `ProcessInfo.thermalState`. It reads **no exact
temperatures**, **no fan RPM**, controls **no fans**, and uses **no private sensor APIs**.
