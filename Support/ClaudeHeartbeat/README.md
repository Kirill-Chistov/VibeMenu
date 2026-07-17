# VibeMenu — Claude heartbeat hook (manual setup)

This is the **optional, opt-in** hook that upgrades VibeMenu's Claude detection from L1
(guessing from process presence + file mtimes) to **L2** (a reliable working/waiting
signal driven by Claude Code's own lifecycle hooks).

VibeMenu **never installs this for you** and **never edits `~/.claude/settings.json`**.
Setup is a manual, reversible, three-minute copy-paste you do yourself.

- Script: [`vibemenu-claude-hook.sh`](vibemenu-claude-hook.sh)
- Sample config: [`settings-snippet.json`](settings-snippet.json)

---

## What it does (and what it never does)

Each time Claude Code fires a lifecycle hook, it runs the script and passes a JSON blob on
stdin. The script parses that JSON **structurally** with the system `python3` and extracts
**only three fields, and only from the top level** — `hook_event_name`, `session_id`, and
`cwd` (from which it keeps **only the final path component**, i.e. the project folder name) —
and writes a small per-session heartbeat file:

```
~/Library/Application Support/VibeMenu/ClaudeHeartbeat/sessions/<session_id>.json
```

Each file contains exactly five privacy-safe fields (schema 2):

```json
{"schemaVersion":2,"updatedAt":1783033591,"event":"PreToolUse","sessionID":"<uuid>","project":"VibeMenu"}
```

`project` is the **folder name only** — the last component of `cwd` (e.g. `VibeMenu`),
computed with `basename(cwd)` **inside the parser** so the full path and every parent
directory are dropped before anything is written. It is an empty string when `cwd` is missing
or unusable. VibeMenu shows this folder name as each Session Radar row's label (falling back
to a generic `Claude session` when it's empty).

The script **never** reads or writes prompt text, response text, tool inputs/outputs,
transcript paths or contents, or the **full** working-directory path — only the final folder
name. Everything else on stdin is ignored — including any nested
`hook_event_name`/`session_id`/`cwd` buried inside `tool_input` or `tool_response`, which can
never override the top-level values. It always exits `0`, so it can never block or break a
Claude session (on invalid JSON — or if `/usr/bin/python3` is missing or not executable — it
records a safe `unknown` event rather than guessing).

> **Upgrading from an earlier (schema-1) hook?** Just re-copy this script over your old copy
> — no settings change is needed. Sessions started before the upgrade have no `project` field
> and show as `Claude session` until they run again under the new script.

> **Requires `/usr/bin/python3`.** macOS ships one at that fixed path (Command Line Tools or
> Xcode), which the script uses only as a JSON parser — it is a system interpreter, **not**
> a third-party dependency, and no `jq` is needed. The script uses **only** `/usr/bin/python3`
> and never any other `python3` on `PATH`, so it can't be shadowed by an untrusted interpreter.
> If `/usr/bin/python3` is missing or not executable the script still runs and still exits
> `0`, but records `unknown`/`unknown-session` rather than parsing the payload.

VibeMenu reads these files — **its own** files, not your transcripts — to derive each Session
Radar row's state (**Working** / **Quiet** / **Needs approval** / **Done** / **Stale**) and to
drive the automatic keep-awake decision, falling back to L1 when no heartbeat files are present.
See [`../../docs/PRIVACY.md`](../../docs/PRIVACY.md).

---

## 1. Pick a stable location for the script

Use it straight from the repo, or copy it somewhere stable — for example:

```sh
mkdir -p ~/Library/Application\ Support/VibeMenu/ClaudeHeartbeat
cp Support/ClaudeHeartbeat/vibemenu-claude-hook.sh \
   ~/Library/Application\ Support/VibeMenu/ClaudeHeartbeat/vibemenu-claude-hook.sh
chmod +x ~/Library/Application\ Support/VibeMenu/ClaudeHeartbeat/vibemenu-claude-hook.sh
```

Note the **absolute path** you chose — you'll paste it into the settings below.

## 2. Back up your Claude settings first

```sh
cp ~/.claude/settings.json ~/.claude/settings.json.bak
```

If `~/.claude/settings.json` doesn't exist yet, you'll create it in the next step with just
the `hooks` block from the snippet.

## 3. Add the VibeMenu hook block

Open [`settings-snippet.json`](settings-snippet.json). **Merge** its `hooks` block into your
existing `~/.claude/settings.json` — do not overwrite the whole file, or you'll lose your
other settings. Replace every `/ABSOLUTE/PATH/TO/vibemenu-claude-hook.sh` with the absolute
path from step 1 (keep the surrounding single quotes so a path with spaces works).

The block wires the observed lifecycle events: `SessionStart`, `UserPromptSubmit`,
`PreToolUse` (matcher `"*"`), `PostToolUse` (matcher `"*"`), `SubagentStart`,
`SubagentStop`, `Notification`, `PermissionRequest` (matcher `"*"`), `Stop`, `StopFailure`,
`SessionEnd`.

> **Why `PermissionRequest`?** It is Claude Code's documented hook that fires the moment a
> tool-use Allow/Deny prompt is presented — **before** you respond. VibeMenu records it as the
> session's heartbeat `event` and surfaces that session as **Needs approval** (sorted to the top,
> with a timer counting from the request), so you can tell at a glance that a session is blocked
> waiting on you. It clears automatically when the next event (`PostToolUse`/`Stop`/…) overwrites
> the heartbeat after you **Allow** it. Verified live in the Claude Desktop **Code** tab
> (docs/decisions/0018-needs-approval.md). Like every other event, only the safe `{event name,
> session id, folder}` is recorded — never the tool, its input/output, or any conversation text.
>
> **Note on Deny.** Claude Desktop's Code tab fires *no* hook event when you **Deny** a prompt
> (verified live — not `Stop`, `PostToolUse`, or the CLI's `PermissionDenied`). So a *denied*
> session keeps showing **Needs approval** until its next event (`SessionEnd` when you close it, or
> your next prompt) or the 30-minute prune. An **Allowed** prompt clears sooner only because Claude
> carries on and promptly fires a next event — it is still that event, not the click, that clears
> the row.

> **Why `SubagentStart` / `SubagentStop`?** They keep the heartbeat fresh during a
> subagent/Task run so VibeMenu's automatic keep-awake holds through it. `SubagentStop`
> means *one* subagent finished and the parent turn keeps working, so VibeMenu treats it as
> "still working," never as a finish (see
> [`../../docs/decisions/0010-quiet-work-hold.md`](../../docs/decisions/0010-quiet-work-hold.md)).
> They are optional — without them an aged active event still holds within the bounded cap —
> but wiring them gives a longer, more accurate hold across subagent gaps.

> **Why `StopFailure`?** Claude Code fires `Stop` when a turn finishes normally, but
> `StopFailure` when the turn ends because of an **API error** (rate limit, overloaded, server
> error, auth/billing failure, …) — and on that error path **only `StopFailure` fires, never
> `Stop`**. So if you don't wire it, a session that errored out leaves its last *work* event
> (`PreToolUse`/`PostToolUse`/…) as the newest heartbeat, and VibeMenu keeps showing that
> finished session as **Quiet** (holding sleep prevention) until it ages out ~15 minutes later.
> Wiring `StopFailure` records the finish immediately, so the row flips to **Done** and automatic
> keep-awake releases — exactly like a normal `Stop`. It needs **no matcher** (the block above
> omits it, which matches every error type, including future ones). Only the safe `{event name,
> session id, folder}` is recorded — never the error, the tool, or any conversation text
> (docs/decisions/0019-stopfailure-heartbeat.md).

> **Already have hooks for some of these events?** Don't replace them — add the VibeMenu
> command as an *additional* entry in that event's array. Claude Code runs every configured
> hook. The script is side-effect-free (it only writes its own heartbeat file), so it
> composes safely with your existing hooks.

## 4. Verify events are being written

Restart Claude Code (so it re-reads settings), then send a prompt. In another terminal:

```sh
ls -la ~/Library/Application\ Support/VibeMenu/ClaudeHeartbeat/sessions/
cat ~/Library/Application\ Support/VibeMenu/ClaudeHeartbeat/sessions/*.json
```

You should see a file per active session, its `event` changing as you work
(`UserPromptSubmit`/`PreToolUse`/`PostToolUse` while Claude works → `Stop` when it
finishes and waits), and a `project` set to the session's folder name (e.g. `VibeMenu`).

In VibeMenu's menu, the Session Radar shows one row per live session, labelled with that folder
name (or the session's title when one is readable) and reading **Working** while Claude works,
then **Done** shortly after it stops. There is **no aggregate status row** — sessions are shown
directly, and the section is absent entirely when no rows are live. Beneath the **Sleep
prevention** switch, the status line shows the real assertion state and its owners, e.g.
`On · Claude` while automation holds it, or `On · Manual and Claude` when you've also flipped
the switch. It reads `Off` when nothing is held.

> **DEBUG builds** log a compact detection summary to Console.app via `os.Logger` (subsystem
> `com.kirillchistov.VibeMenu`, category `claude-detect`) — metadata only. There is no
> diagnostics row in the menu, in any build.

### Verifying the quiet-work hold (v0.1.1)

The point of the quiet-work hold is that a **long silent phase** (a long build/test, a long
single tool call, or a subagent/Task run — during which no hook fires for minutes) keeps
the Mac awake, even though the session row falls back to **Quiet**. To see it end-to-end:

1. In Claude Code, kick off something long and silent — e.g. a build/test that runs for a
   few minutes in one `Bash` call, or a subagent/Task.
2. Watch the heartbeat file — its `event` stays on the last active event (e.g. `PreToolUse`)
   and its `updatedAt` stops advancing while the tool runs:

   ```sh
   watch -n2 cat ~/Library/Application\ Support/VibeMenu/ClaudeHeartbeat/sessions/*.json
   ```
3. After a couple of minutes the session row reads **Quiet** — but the status line under the
   **Sleep prevention** switch still reads `On · Claude`, because the hold is still in effect.
4. Confirm the real power assertion is still held:

   ```sh
   pmset -g assertions | grep -i PreventUserIdleSystemSleep
   ```

   You should see VibeMenu's `PreventUserIdleSystemSleep` assertion held throughout the
   silent phase (up to the 15-minute cap), then released shortly after Claude's `Stop`
   fires. (In a DEBUG build, Console.app shows `Claude automation: intent=hold` during the
   hold and `intent=release` when it finally releases.)

## 5. Remove it

Restore your backup:

```sh
mv ~/.claude/settings.json.bak ~/.claude/settings.json
```

…or manually delete the VibeMenu `hooks` entries you added. Optionally delete the state:

```sh
rm -rf ~/Library/Application\ Support/VibeMenu/ClaudeHeartbeat
```

Detection falls back to L1 automatically when no heartbeat files are present.

---

## Privacy note

The script ignores **all** hook payload fields except the **top-level** event name, session
id, and `cwd` — and from `cwd` it keeps **only the final folder name** (nested same-named
keys are never read). It writes only
`{schemaVersion, updatedAt, event, sessionID, project}`, where `project` is that folder name.
No prompt/response text, no tool inputs/outputs, no transcript path or contents, and **no full
path** (never a parent directory) — and nothing leaves your Mac.

**This script never touches your transcripts at all.** Separately from it, VibeMenu has one
narrow, ADR-approved transcript read: to name a Session Radar row, it opens the matching
transcript and reads *only* its session-title record (`custom-title` / `ai-title`), never
message content — see [`../../docs/PRIVACY.md`](../../docs/PRIVACY.md) and
[`../../docs/decisions/0013-session-title-and-dismiss.md`](../../docs/decisions/0013-session-title-and-dismiss.md).
That is a different component from the heartbeat reader, which only ever reads VibeMenu's own
files above. See also [`../../docs/SECURITY.md`](../../docs/SECURITY.md).
