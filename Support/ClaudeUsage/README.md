# VibeMenu — Claude usage-limit capture (statusLine)

This is the opt-in **experimental** capture that feeds VibeMenu's **Claude Limits** menu section with
your **real** Claude usage limits — the 5-hour and weekly windows, the same figures the in-app
`/usage` view shows. See [`docs/decisions/0016-claude-usage-limits.md`](../../docs/decisions/0016-claude-usage-limits.md).

> **Only needed for the Claude Code source.** VibeMenu has two sources for the Claude Limits section
> (pick one in **Settings → Claude usage limits → Source**). If you use the **Claude Desktop** app, the
> **Claude Desktop** source reads its local usage cache directly and needs **no** setup — this script is
> not required. This capture is for the **Claude Code** CLI source (or **Automatic** mode's fallback).

**How it works.** Claude Code (v2.1.80+) pipes a `rate_limits` object to your `statusLine` command on
stdin. This tiny script captures **only** those usage numbers into a VibeMenu-owned file
(`~/Library/Application Support/VibeMenu/ClaudeUsage/usage.json`) and prints your status line. VibeMenu
reads its own file — **no network, no cookies, no API keys, no token estimation, no telemetry.**

**What it reads / never reads.** Only `rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}`,
`session_id`, and `version`. It never reads or writes prompt/response text, transcripts, cwd/paths,
tool I/O, cost, spend, or billing.

**Availability.** `rate_limits` is present only for Claude.ai **Pro/Max** subscribers, only **after the
first API response** of an **interactive** session (not `-p`/headless), never for raw API keys, and it
is version-fragile. When it is absent VibeMenu simply shows "waiting for a Claude Code session".

---

## Easiest: install from VibeMenu

VibeMenu → **Settings… → Claude usage limits → Set up usage capture…**. It shows a preview of the exact
change, writes a timestamped backup of `~/.claude/settings.json` first, and **wraps** any existing
status line so yours keeps working. Removal (same panel) restores it. You do not need the steps below.

## Manual install (if you prefer not to let the app edit settings.json)

There is only **one** `statusLine` slot in `~/.claude/settings.json`.

**If you have no status line yet**, add:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/absolute/path/to/vibemenu-usage-statusline.sh"
  }
}
```

**If you already have a `statusLine` command**, wrap it so yours still renders — base64-encode your
existing command and pass it via `--wrap`:

```sh
printf '%s' 'YOUR EXISTING COMMAND' | base64
# then:
#   "command": "/absolute/path/to/vibemenu-usage-statusline.sh --wrap <that-base64>"
```

Make the script executable: `chmod +x /absolute/path/to/vibemenu-usage-statusline.sh`.

## Verify

Open (or continue) an interactive Claude Code session in a Pro/Max account, send a message, then check:

```sh
cat "$HOME/Library/Application Support/VibeMenu/ClaudeUsage/usage.json"
```

You should see `fiveHour` / `sevenDay` with `usedPercent` + `resetsAt`. VibeMenu → **Settings** shows
the capture status, and the **Claude Limits** section appears once enabled and data exists.

## Remove it

Delete the `statusLine` entry from `~/.claude/settings.json` (or restore a
`settings.json.vibemenu-backup-*` file), and optionally delete
`~/Library/Application Support/VibeMenu/ClaudeUsage/`.

## Robustness / safety

- No `jq`/third-party dependency — POSIX `sh` + the system `/usr/bin/python3` + `base64`.
- Writes the usage file **atomically** and only when a window is present, so a transient render never
  wipes your last-known-good snapshot.
- **Always exits 0** and always prints a status line, so it can never block or break a session.
