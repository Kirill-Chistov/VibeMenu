# 0012 — Session Radar identity: project folder name from cwd

- **Status:** Accepted — v0.2 refinement (Claude Code only)
- **Date:** 2026-07-05
- **Deciders:** Kirill Chistov (product owner; chose the identity source explicitly). Researched &
  implemented by Claude Code under the owner's authorization to build the smallest safe version.
- **Builds on / refines:** [`0011`](0011-session-radar.md) (Session Radar),
  [`0008`](0008-claude-heartbeat-detection.md) (hook heartbeat).

## Context

The first Session Radar ([`0011`](0011-session-radar.md)) shipped with each row disambiguated
only by a **6-character fragment of the opaque session id** (e.g. `Waiting · Claude · 6a188c ·
2m`). Manual testing confirmed the obvious: a random id fragment is not human-useful — you
cannot tell which session is which. The product requirement is to show the **same
human-readable session/task name Claude Code shows** (e.g. `fix auth bug`), or the closest
**safe** equivalent.

### What Claude Code actually stores (researched, metadata/structure only)

Inspecting the *structure* of Claude Code's on-disk files (record `type`s and field **keys**
only — never message text):

- **A human-readable title exists, but only inside the transcript.** Session transcripts
  (`~/.claude/projects/<encoded-cwd>/<session_id>.jsonl`) contain a `customTitle`
  (record `type: "custom-title"`) and a `lastPrompt` (`type: "last-prompt"`), plus `cwd` and
  `gitBranch` on records. `customTitle` is exactly the desired title — **but it lives inside
  the transcript file.** Extracting it requires opening and parsing the transcript, which
  violates the hard invariant AGENTS.md §6 / [`PRIVACY.md`](../PRIVACY.md) ("never read
  transcript contents"). So there is **no safe *title* field.** We deliberately do not read it.
- **VibeMenu's own heartbeat files** carried only `{schemaVersion, updatedAt, event,
  sessionID}` — no name, no cwd. That is why the radar had nothing but the id to show.
- **The one safe human-readable identity is the project folder name**, derivable from the
  session's `cwd`.

### The `cwd` is available to the hook

Claude Code hook payloads include a **top-level `cwd`** string. The opt-in heartbeat hook
already parses top-level fields structurally with the system `python3`.

## Decision

**Capture the project folder name in the opt-in hook and display it as each radar row's
label. Do not read any session title, and do not expand what VibeMenu reads under
`~/.claude`.**

The product owner chose this source explicitly over two alternatives (below).

1. **Hook (schema 2) captures `cwd` → writes only `basename(cwd)`.** The hook reads the
   top-level `cwd` and, **inside the parser**, keeps only the final path component (the folder
   name, e.g. `VibeMenu`). The full path and every parent directory are dropped before
   anything is written. Heartbeat files gain a fifth field:

   ```json
   {"schemaVersion":2,"updatedAt":1783033591,"event":"PreToolUse","sessionID":"<uuid>","project":"VibeMenu"}
   ```

   The folder name is sanitised to a conservative JSON-safe allowlist
   (`[A-Za-z0-9 ._-]`, trimmed, ≤64 chars), so a crafted folder name cannot break the JSON or
   inject fields. Empty when `cwd` is missing/unusable.

2. **VibeMenu keeps reading only its own files.** The reader gains an optional `project`
   field (schema 1 files decode to `nil`). No new read under `~/.claude` — the existing
   mtime-only walk is unchanged. `ClaudeSession.projectName` carries the folder name;
   `displayName` is `projectName ?? "Claude session"`.

3. **Visibility rules** (pure, in `SessionRadar.present`): at most **5** rows; at most **2**
   `done`; hide `done` older than **5 min** and `stale` older than **2 min**; never show
   `unknown`; overflow summarised as "+N more recent sessions". Attention-first order is
   inherited from the store; this layer only filters/caps.

4. **UI copy & id hiding.** Rows are single-line — `state · folder name · elapsed` (e.g.
   `Waiting · VibeMenu · 2m`). Labels shortened: **Working / Quiet / Waiting / Done**. The raw
   session-id fragment and the `Claude` capsule are **removed** from the row. When two visible
   rows share a folder name, a stable numeric suffix (`VibeMenu 1/2`, by first-seen order)
   disambiguates them — never an id or content.

**Invariants preserved.** No network, no telemetry, no backend. VibeMenu still reads only its
own heartbeat files + process presence + `~/.claude` **mtime**; it never opens or parses a
Claude transcript. The keep-awake decision is untouched (the `sessionsKeepAwakeIntent ==
automationIntent` equivalence test still holds — `projectName` is display-only).

## Privacy impact

- **cwd/project name is read** by the hook, but only the **final folder name** is ever
  written or displayed — never the full path, never a parent directory.
- **Transcript metadata is *not* read.** `customTitle`, `lastPrompt`, `gitBranch`, and the
  full `cwd` all live in the transcript; VibeMenu never opens it.
- **Prompt/response contents are never read.**
- **Full paths are never stored or displayed** — folder name only.
- **VibeMenu stores no session titles** — only the folder name (in its own heartbeat files)
  and your settings.
- This **reverses the earlier hook promise** that it "never reads your working directory": the
  hook now reads `cwd` but discards everything except the folder name. Documented in
  [`PRIVACY.md`](../PRIVACY.md) and [`Support/ClaudeHeartbeat/README.md`](../../Support/ClaudeHeartbeat/README.md).

## Consequences

- The radar answers "which session is which?" with a real project name for hook-v2 users.
- **Same-project sessions still share a name** (developers often run several sessions in one
  repo). The numeric suffix is the honest disambiguator; a session title would be better but
  is not safely available.
- **Schema bump requires re-copying the hook.** Sessions started under the old (schema-1) hook
  have no `project` and show as `Claude session` until they run again under the new script.
  No `~/.claude/settings.json` change is needed — just overwrite the script file.
- Lossy edge: unusual folder names with non-ASCII characters are reduced by the allowlist
  (documented). The full path is never exposed, which is the point.

## Alternatives considered

- **Read `~/.claude/projects` directory names in VibeMenu** (map `sessionID → <encoded-cwd>`
  by matching the `<sessionID>.jsonl` filename, decode the dir name to a folder name).
  Metadata-only (names, no file open), no hook change, works for existing sessions. **Rejected
  by the owner** because it expands VibeMenu's `~/.claude` reading from "mtime only" to "also
  directory names," and the dir-name encoding is lossy (folder names with `-` decode
  ambiguously). The chosen hook approach keeps VibeMenu reading only its own files and yields
  the exact folder name.
- **Read `customTitle` from the transcript.** Gives the true human title, but requires
  parsing transcript contents — a hard-invariant violation. **Rejected**; not built.
- **No new reads; show `Claude session N`.** Fully within today's invariants but not
  project-specific. **Rejected** as too weak for the product requirement; kept as the fallback
  label when no folder name is available.

## Non-goals (unchanged from 0011)

Multi-agent; real permission Allow/Deny; terminal/window jump; notch/pill presentation;
Accessibility/AppleScript; network/backend/telemetry; reading any transcript title/summary or
prompt/response text.
