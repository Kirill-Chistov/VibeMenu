# VibeMenu — Privacy

VibeMenu is built for privacy-sensitive developers. Its privacy model is simple, and
these are hard invariants, not aspirations.

## The promise

- **VibeMenu runs entirely locally on your Mac.**
- **No backend.** There is no server VibeMenu talks to for its features.
- **No account.** There is no sign-in, no user identity, no cloud profile.
- **No analytics.**
- **No telemetry.**
- **No transcript-content reading.** VibeMenu never reads the contents of your prompts,
  responses, tool calls, or any message body in your agent transcripts. The **one** narrow
  exception is the session *title*: to show the same session names Claude Code shows, VibeMenu
  may read only the transcript's title record (`custom-title` / `ai-title`) — nothing else
  (see [Session Radar](#session-radar--session-names-and-manual-hide) below).
- **Optional enhanced titles (off by default).** Claude Code often doesn't write its visible
  title into the transcript. An **opt-in** setting, *"Use Claude Desktop session titles,"* lets
  VibeMenu read those titles from the Claude Desktop app's **local session index** instead. Even
  then it reads **only title metadata** (the title, its source, a session id, a last-activity
  timestamp, and an archived flag) — **never** prompts, responses, tool output, `promptSuggestion`,
  or `lastPrompt`. It is **off unless you turn it on**, and when off VibeMenu never touches those
  files (see [Session Radar](#session-radar--session-names-and-manual-hide) below).

## What VibeMenu may inspect

To decide whether to keep your Mac awake, VibeMenu may inspect **metadata only**:

- Whether a coding-agent process (e.g. `claude`) is currently running.
- The **existence and modification times** (mtime) of local agent session files under
  locations such as `~/.claude/…` — **not their contents**.
- VibeMenu's **own** heartbeat files (if you install the opt-in hook, see below), which
  contain only a schema version, a timestamp, a hook event name, a session id, and the
  project **folder name** (the final path component of the working directory — never the
  full path).
- System status via public Apple APIs. Today this is **only** the coarse thermal *state*
  (Nominal / Fair / Serious / Critical) from `ProcessInfo.thermalState` — no exact
  temperatures. VibeMenu does **not** currently read CPU, memory, or battery; if that ever
  changes, it would be public APIs only and this page would say so first.

It watches file *metadata* and *append events*; it does **not** open, parse, copy, or
store the message bodies of any transcript.

> **Claude detection (L1), now live.** VibeMenu's first Claude-detection layer reads
> **only** (a) whether a process named `claude` is running (its process *name*, via
> public process inspection — never its arguments or command line) and (b) the
> *existence and modification times* of session files under `~/.claude` (e.g.
> `~/.claude/projects`, `~/.claude/history.jsonl`). It never opens or parses those files,
> and logs no project-specific paths. Detection feeds a metadata-only keep-awake decision
> that can temporarily request sleep prevention (held while working, plus a bounded
> quiet-work hold through long silent phases) and releases it when Claude finishes — all
> from event names, timestamps, and process presence, never from any message contents.

## What VibeMenu must never do

- **Never upload** prompts, responses, code, transcript contents, or file contents —
  anywhere, ever.
- Never read transcript **message** contents — prompts, responses, `lastPrompt`, tool
  input/output, or any message body. (VibeMenu reads file existence + mtime for detection, and
  the transcript's **title record only** for the session name — never message content.)
- Never access the Keychain or scrape browser cookies.
- Never make network requests. VibeMenu contains **no networking code today** and makes zero
  requests of any kind. The invariant reserves exactly one hypothetical exception — a software
  update check ([`decisions/0004`](decisions/0004-direct-distribution.md)) — which is **not
  built and not planned for the current phase**; adding it would need its own decision, a signed
  and pinned channel, and would be announced here first.

## What is stored

Everything below is local. Nothing is uploaded, and there is no database.

**Your settings, in `UserDefaults`.** Which rows to show, whether Codex sessions are enabled,
whether each usage-limits section is on and which source it uses, whether to use Claude Desktop
titles, which limit rows you've hidden, and which sections are expanded. Launch at Login is
*not* stored here — it's read live from the system (`SMAppService`), so there's no duplicate
copy of that state to drift.

**Files VibeMenu owns, under `~/Library/Application Support/VibeMenu/`:**

- `ClaudeHeartbeat/sessions/<session_id>.json` — written by the **opt-in hook script you
  install**, not by the app; VibeMenu only reads them. Five safe fields (see below).
- `ClaudeUsage/usage.json` — written by the **opt-in status-line shim**, if you set that up.
- `ClaudeUsage/desktop-snapshot.json` — the one file the app itself persists (see next).
- `ClaudeUsage/vibemenu-usage-statusline.sh` — the shim itself, written only when you press
  the install button in Settings.

**The persisted usage snapshot is normalized, not raw.** When Claude limits are on with the
Desktop source, VibeMenu saves the **already-reduced** reading — a list of
`{window kind, used percent, reset time, optional model group}` plus a capture timestamp, an
opaque session id, and which source it came from. Raw cache bytes, organisation identifiers,
and cost data are **never** persisted; the reduction happens before the write, not at display
time. It's skipped entirely when there's nothing to save or nothing changed.

**Transient, in memory only.** The session list itself, resolved session titles, and which rows
you've hidden are never written to disk — restarting VibeMenu clears the hides and re-derives
everything else.

> **Claude-detection diagnostics (DEBUG builds only).** Developer builds log a compact
> diagnostic summary of the Claude-detection signals — the process flag; the hook-heartbeat
> aggregate state, its newest *age in seconds*, and a *count* of live sessions; the newest
> session-file *age in seconds*; the active threshold; and the resulting state (e.g.
> `process=true, heartbeat=Active age=1s sessions=1, newestAge=none, threshold=10s,
> result=Active`) — via the local `os.Logger`. By construction it carries
> **only** that metadata: no prompt or response text, no transcript contents, **no session
> ids**, and **no file or project paths**. It never leaves your Mac and is compiled out of
> Release builds entirely, so a release build emits none of it.

## Hook heartbeat (L2) — opt-in, now available

VibeMenu ships an **optional** Claude Code hook that gives more reliable working/waiting
detection ([`Support/ClaudeHeartbeat/`](../Support/ClaudeHeartbeat/)). It is **opt-in and you
install it yourself** — VibeMenu **never** installs it automatically and **never** edits
`~/.claude/settings.json`.

When installed, the hook runs a small script on each Claude Code lifecycle event. The
script parses the hook JSON on stdin **structurally** (via the system `python3`) and
extracts **only three fields, and only from the top level of the payload** — the event name
(`hook_event_name`), the session id (`session_id`), and the working directory (`cwd`), from
which it keeps **only the final path component (the project folder name)** — ignoring
everything else. Nested fields inside objects like `tool_input`/`tool_response` are never
read, so payload shape can never redirect which event, session id, or folder name is
recorded. It writes a tiny per-session file under
`~/Library/Application Support/VibeMenu/ClaudeHeartbeat/sessions/<session_id>.json`
containing **only** five safe fields (schema 2):

```json
{"schemaVersion":2,"updatedAt":1783033591,"event":"PreToolUse","sessionID":"<uuid>","project":"VibeMenu"}
```

- **`project` is the folder name only** — the last component of your working directory (e.g.
  `VibeMenu`), computed inside the parser via `basename(cwd)`. The **full path and every
  parent directory are discarded and never written or logged.** It is empty (`""`) when the
  working directory is missing or unusable.
- The hook still **never** reads or writes prompt text, response text, tool inputs/outputs,
  transcript paths or contents, or the **full** working-directory path — and nothing ever
  leaves your Mac.

VibeMenu reads *its own* heartbeat files (not your Claude transcripts) to derive each session's
state and to label each Session Radar row. The setup guide lists exactly what the script reads
and why, and how to remove it. See
[`Support/ClaudeHeartbeat/README.md`](../Support/ClaudeHeartbeat/README.md).

### "Needs approval" — an event name, never the request

If you register the `PermissionRequest` event, the hook records that Claude asked for
permission — as the **event name only**, exactly like every other lifecycle event. VibeMenu uses
it to sort that session to the top and time how long it has been blocked
([`decisions/0018`](decisions/0018-needs-approval.md)).

It does **not** read *what* is being requested: not the tool, not the command, not the file, not
the arguments — none of that leaves the payload, because the parser only ever takes the three
top-level fields listed above. "Needs approval" means *a* request happened, nothing more.

## Session Radar — session names and manual hide

The Session Radar (the per-session list in the menu) is a **display-only view of the opt-in hook
heartbeat files** described above, plus the **session title** read narrowly from each session's
transcript so the radar shows the same names Claude Code shows
([`decisions/0013`](decisions/0013-session-title-and-dismiss.md)). It makes no network calls and
does not change the keep-awake behavior.

- **What each row shows:** the session's state (Working / Quiet / Needs approval / Done /
  Stale), the session **name**, and elapsed time. The name is, in order: Claude Code's own
  **session title** when
  safely readable, else the **project folder name** from the heartbeat's `project` field (e.g.
  `VibeMenu`), else a generic `Claude session`.
- **The one transcript read — title only.** To get the title, VibeMenu opens the single
  transcript file that matches the session id (`~/.claude/projects/<encoded-cwd>/<session_id>.jsonl`)
  and reads **only** its title record — `custom-title` (a title you set by renaming the session)
  or `ai-title` (Claude Code's auto-generated title). It reads **no** prompt text, **no** assistant
  responses, **no** `lastPrompt`, **no** tool input/output, **no** `cwd` or `gitBranch`, and **no**
  other message content. The title is held in memory only (not written to disk) and is **never
  logged**. A line that isn't a title record is never even parsed.
- **Folder name, never a path.** When it falls back to the folder name, the radar shows only the
  final folder name captured by the hook — never the full path, never a parent directory, never the
  session id.
- **Optional: Claude Desktop titles (opt-in, off by default).** Because Claude Code frequently
  does **not** write its visible title into the transcript, an opt-in setting — *Settings →
  Session titles → "Use Claude Desktop session titles"* — lets VibeMenu read those names from the
  Claude Desktop app's **local session index**
  (`~/Library/Application Support/Claude/claude-code-sessions/*/*/local_*.json`) instead. When it
  is on, VibeMenu reads **only** whitelisted title fields from each index file — the `title`, its
  `titleSource`, the `cliSessionId` (to match the session), a `lastActivityAt` timestamp, and an
  `isArchived` flag — and **nothing else**: not `promptSuggestion`, not `alwaysAllowedReasons`, not
  `cwd`, not any prompt, response, tool output, or message body. When it is **off** (the default),
  VibeMenu never opens, reads, or stats those files at all. This source is another app's private,
  undocumented cache, so it is **best-effort** and may stop working if Claude Desktop changes its
  format — in which case VibeMenu silently falls back to the transcript title and then the folder
  name. Titles are held in memory only, never written to disk, and never logged. See
  [`decisions/0014-enhanced-desktop-titles.md`](decisions/0014-enhanced-desktop-titles.md).
- **Session ids are hidden from the UI** and remain out of logs (the diagnostics/log invariant
  above is unchanged). If two visible sessions share a name, a small numeric suffix (`Greeting 1`,
  `Greeting 2`) disambiguates them — derived from ordering, not from any id or content.
- **Bounded list.** At most 5 rows are shown (at most 2 recently-finished); finished sessions
  older than 5 minutes and quiet/stale ones older than 2 minutes drop off, and any remaining
  older sessions are pruned after 30 minutes.
- **Manual hide (dismiss).** You can remove a session from VibeMenu's list by dragging its row to
  the right, or via its right-click menu → **Hide from VibeMenu**. This only hides the row in
  VibeMenu — it does **not** delete any Claude data, does **not** stop or kill the Claude session,
  and writes no file. A hidden row reappears on its own if the session becomes active again; hiding
  is in-memory, so restarting VibeMenu also clears it.

### What is and isn't read (Session Radar)

| Question | Answer |
| --- | --- |
| Is your working directory / project name read? | The hook reads `cwd` and keeps **only the folder name**; VibeMenu stores/displays that folder name. The full path is never stored or shown. |
| Is the session **title** read? | **Yes — and only the title.** VibeMenu opens the matching transcript and reads only its `custom-title` / `ai-title` record, to show the same name Claude Code shows. It is held in memory, never written to disk, never logged. |
| Are **Claude Desktop** titles read? | **Only if you opt in** (*"Use Claude Desktop session titles,"* off by default). When on, VibeMenu reads only whitelisted title fields (`title`, `titleSource`, `cliSessionId`, `lastActivityAt`, `isArchived`) from the Desktop app's local session index. When off, those files are never touched. |
| From the Desktop index, is `promptSuggestion` / `lastPrompt` / `cwd` / message content read? | **Never.** The parser decodes only the five whitelisted fields; every other key (including `promptSuggestion`, `alwaysAllowedReasons`, `cwd`) is ignored. |
| Is other transcript content (git branch, last prompt, tool I/O, messages) read? | **No.** Only the title record is read; every other record type is ignored. |
| Are prompt/response contents read? | **Never.** |
| Is `lastPrompt` read? | **Never.** |
| Are full paths stored or displayed? | **No** — folder name only. |
| Does hiding a row affect Claude? | **No.** Dismiss only hides the row in VibeMenu; it never deletes Claude data or stops the session. |
| Does VibeMenu send anything over the network? | **Never.** No network, no backend, no telemetry. |

## Claude usage limits — opt-in, experimental

VibeMenu can show your **real** Claude usage limits (the 5-hour and weekly windows, and per-model
weekly rows) in a compact **Claude Limits** section, from either of two **local** sources you pick in
Settings. This is **opt-in, off by default, and clearly labelled Experimental**
([`decisions/0016`](decisions/0016-claude-usage-limits.md)).

- **Source is local and real — never network.** VibeMenu **never** contacts Claude servers, reads
  browser cookies, reads API keys, extracts auth tokens, scrapes the web, or estimates usage from token
  counts. It reads only data Claude already stored on your Mac:
  - **Claude Desktop** — the Desktop app caches its own usage screen locally (a zstd-compressed HTTP
    cache entry). VibeMenu reads that cache **read-only** — it never writes to, or deletes, Claude's
    cache — decodes it with a bundled decoder (no network, no shelling out), and keeps **only** the
    normalised usage rows (each window's used-percent, reset time, and, for a per-model weekly row, the
    model's display name such as "Fable"). It deliberately ignores the payload's cost/spend/billing, the
    model's internal id, and does **not** store your organisation UUID.
  - **Claude Code** — Claude Code hands the real server-side percentages to a `statusLine` command on
    stdin. VibeMenu's opt-in shim ([`Support/ClaudeUsage/`](../Support/ClaudeUsage/)) captures **only**
    `rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}`, `session_id`, and `version` into a
    **VibeMenu-owned** file (`~/Library/Application Support/VibeMenu/ClaudeUsage/usage.json`), which
    VibeMenu then reads.
- **Whitelist only.** For both sources the `Decodable` DTO (and, for Claude Code, the shim's structural
  parser too) reads only the usage fields above; prompt/response text, transcripts, cwd/paths, tool I/O,
  cost, spend, billing, and the org UUID are never read by, stored by, or shown in VibeMenu. Anything
  VibeMenu persists (a last-known-good Desktop snapshot in its own Application Support folder) is the
  normalised usage rows only — never the raw cache payload.
- **One-click install edits `~/.claude/settings.json` — but only with your consent.** Setting up
  capture from Settings adds a `statusLine` command. Unlike the heartbeat hook (which VibeMenu never
  installs for you), this is an explicit, **preview-gated** action: VibeMenu shows the exact change,
  writes a timestamped `settings.json.vibemenu-backup-*` first, **preserves** any existing status line
  by wrapping it, changes only the `statusLine` key, and is fully reversible from Settings. Prefer not
  to let the app touch your config? Install manually instead — see the [Support README](../Support/ClaudeUsage/README.md).
- **Honest about staleness.** VibeMenu shows an "as of Xm ago" note for stale captures and a guidance
  line when there's no data — it never presents stale data as live and never draws a fabricated bar.
- **Off ⇒ zero work.** With the feature off (the default), VibeMenu reads neither the Desktop cache nor
  the Claude Code usage file.

## Codex Desktop sessions — opt-in, local-only

VibeMenu can also show your **Codex Desktop** coding sessions alongside Claude in the menu's shared
session rows (there is no aggregate status line). This is **opt-in, off by
default**, and — like everything else — **entirely local**
([`decisions/0017`](decisions/0017-codex-session-support.md)).

- **Local files only — never network.** VibeMenu reads only files Codex already wrote on your Mac
  (`~/.codex/sessions/**/rollout-*.jsonl`, plus the small `~/.codex/session_index.jsonl` for titles —
  see below). It **never** contacts OpenAI/Codex servers, reads browser cookies, reads API keys,
  extracts auth tokens (it never touches `~/.codex/auth.json`), or scrapes anything.
- **Desktop only.** `~/.codex` is shared between the Codex Desktop app and the Codex **CLI**. VibeMenu
  keeps only sessions whose recorded `originator` is `"Codex Desktop"` and ignores every CLI session.
- **Allowlisted metadata only.** From each rollout it reads a strict allowlist and nothing else: the
  session id (opaque; used for the row identity and never shown), the `originator` (to gate Desktop vs
  CLI), the project **folder name** (the *basename* of the working directory — e.g. `VibeMenu`, never a
  path), per-line activity **timestamps**, and the event *category* of `event_msg` lines solely to spot
  the `task_complete` completion marker.
- **Session titles — safe source only.** To show a nicer session name than the folder, VibeMenu reads
  `~/.codex/session_index.jsonl`, a small index whose lines are `{id, thread_name, updated_at}`. It
  reads **only** `id` (to join to the session) and `thread_name` (the curated short title), and every
  title passes a sanitiser that **drops** anything empty/generic, multi-line, URL- or git-remote-like,
  or path-like (falling back to the folder name), then length-caps what remains. It deliberately does
  **not** read Codex's `state_5.sqlite` `threads.title`, which can contain the raw first user message
  (prompt text), nor the index's other fields. Fallback order for the displayed name: safe title →
  folder name → generic "Codex session".
- **What it never reads or shows.** Prompts, responses, reasoning, tool input/output, command text,
  the **full** working-directory path, repo URLs / git branch / commit (`git.*`), the system prompt
  (`base_instructions`), account ids, tokens, or auth. Reading the *category* of a `user_message`
  event reads only the word `"user_message"`, never the message text. The value types VibeMenu builds
  (`CodexRolloutSummary` / `CodexSession`) structurally cannot hold any of that content, and tests feed
  a rollout (and an index) deliberately stuffed with such fields to prove none of it ever surfaces.
- **Usage limits (opt-in, real numbers only).** VibeMenu **can** show Codex 5-hour + weekly usage
  limits, off by default. The numbers are the real server-side percentages Codex records in a
  structured `rate_limits` object inside its rollout `token_count` events (the same
  `~/.codex/sessions` files session detection reads). VibeMenu extracts **only** the numeric
  `used_percent`, `window_minutes`, and `resets_at` of the two windows — and only after a
  `"rate_limits"`/`"originator"` substring pre-check, so prompt/response/tool lines are never even
  parsed. It never reads Codex's `info` token counts, `plan_type`/account, `limit_name`, the
  `logs_2.sqlite` debug/HTTP log (which *does* intermix prompts and auth), or `auth.json`. Fail-closed:
  if the field is ever absent, VibeMenu shows *no data* rather than fabricating a bar. (An earlier
  investigation wrongly concluded this source was gone; a live re-check found it present in every
  `token_count` event.)
- **Conservative keep-awake input.** When Codex tracking is enabled, only a session currently derived
  as **active** can contribute to VibeMenu's shared keep-awake assertion. Idle, done, stale, unknown,
  missing, or disabled Codex state releases its contribution. This uses the same allowlisted local
  metadata described above; it does not read any additional data. Codex **usage limits** never affect
  sleep prevention.
- **Off ⇒ zero work.** With the feature off (the default), VibeMenu never opens, reads, or stats any
  `~/.codex` file. Nothing about Codex is persisted; the session list is transient in-memory state.
- **Best-effort.** This reads another app's local files, whose format may change; if it does, VibeMenu
  simply shows no Codex rows.

### What is and isn't read (Codex sessions)

| Question | Answer |
| --- | --- |
| Is the Codex **CLI** included? | **No** — only sessions whose `originator` is `"Codex Desktop"`. |
| Is your working directory / project name read? | Only the **folder name** (basename of `cwd`). The full path and every parent directory are discarded and never stored or shown. |
| Are prompts, responses, reasoning, or tool output read? | **Never.** Only event *category* labels and timestamps are read — never any message/tool body. |
| Are repo URLs / git branch / account ids / tokens / auth read? | **Never.** `git.*`, account ids, and `~/.codex/auth.json` are never touched. |
| Does VibeMenu show Codex usage/rate limits? | **Optionally (off by default).** Only the real 5-hour + weekly percentages + reset times from Codex's own `rate_limits` field — never token counts, plan/account, the debug log, or auth. |
| Does a Codex session affect sleep prevention? | **Only an *active* session, when Codex detection is on.** Like Claude activity, an actively-working Codex session can hold VibeMenu's local keep-awake assertion (the shared "VibeMenu Keep Awake" assertion, visible in `pmset -g assertions`); idle/finished/stale sessions do not, and with Codex detection off it never does. This is derived from the same local metadata — it reads no extra data. Codex **usage limits** never affect sleep. |
| Does VibeMenu send anything over the network? | **Never.** No network, no cookies, no API keys, no auth extraction. |

## Why you can trust this

- **It's open source, so don't take our word for it.** Every claim above is a claim about code
  you can read. The parsers are pure and unit-tested, and several tests exist specifically to
  prove a privacy boundary — they feed a transcript, rollout, or hook payload deliberately
  stuffed with prompts, tokens, and secret paths, then assert none of it can surface.
- **You can check the assertion yourself.** VibeMenu shows the real state and owner in the menu;
  `pmset -g assertions` will independently show `VibeMenu Keep Awake` when it's held.
- **Settings discloses each opt-in source** before you enable it.
- **There is no telemetry to opt out of, because there is none.** GitHub issues, discussions,
  and stars are the only feedback signal that exists — which is also why the project has no idea
  who uses it.

> Any change that would weaken these invariants requires a `decisions/` ADR and explicit
> approval from the human product owner — see [`../AGENTS.md`](../AGENTS.md) and
> [`SECURITY.md`](SECURITY.md).
