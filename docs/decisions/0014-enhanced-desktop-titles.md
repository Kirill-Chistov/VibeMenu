# 0014 — Session Radar: opt-in Claude Desktop session titles

- **Status:** Accepted — v0.2 refinement (Claude Code / Claude Desktop only)
- **Date:** 2026-07-06
- **Deciders:** Kirill Chistov (product owner; requested the enhanced title source and the opt-in
  requirement). Researched & implemented by Claude Code under the owner's authorization.
- **Builds on / refines:** [`0013`](0013-session-title-and-dismiss.md) (transcript title +
  dismiss), [`0011`](0011-session-radar.md) (Session Radar),
  [`0012`](0012-session-name-from-cwd.md) (folder-name identity).
- **Extends, does not supersede:** [`0013`](0013-session-title-and-dismiss.md) — the transcript
  title path stays exactly as-is and remains the default; this adds an *optional* higher-priority
  source in front of it.

## Context

[`0013`](0013-session-title-and-dismiss.md) reads Claude Code's session title from the transcript's
`custom-title` / `ai-title` records. Manual testing found that **Claude Code does not reliably write
that title to the transcript**: sessions Claude Code shows as *GMT time query* or *Public repository
audit* have **no** title record on disk, so the radar falls back to the folder name (`VibeMenu 1`,
`VibeMenu 2`) even though Claude Code clearly knows a better name. ADR 0013's own follow-up noted
this and deferred it to "a new ADR + data source + privacy review — do not read it silently."

Research (metadata/keys/title-strings only, no message bodies) located the reliable source. The
**Claude Desktop app** — not the CLI — keeps a private, per-session index:

```
~/Library/Application Support/Claude/claude-code-sessions/<account>/<workspace>/local_<uuid>.json
```

One JSON object per session. It carries the exact visible title plus a clean join key:

- `title` — the exact human-readable string Claude Code shows.
- `titleSource` — e.g. `"auto"` (AI-generated) or a user-set source.
- `cliSessionId` — the Claude **CLI** session id = VibeMenu's session id = the transcript
  `<id>.jsonl` stem. A direct join to a `ClaudeSession`.
- `sessionId` — the Desktop app's own `local_<uuid>` id (matches the filename).
- `lastActivityAt` (epoch ms), `isArchived` — used to pick the freshest of duplicate records.
- Also present but **never read**: `promptSuggestion`, `alwaysAllowedReasons`, `cwd`, `originCwd`,
  `model`, and any future field.

All three titles the transcript path missed are present here, and the live session's file updates in
real time.

## Decision

Add an **opt-in** setting, **"Use Claude Desktop session titles"**, default **OFF**. When enabled,
VibeMenu reads the Desktop session index and uses its title as the **highest-priority** display name.
The fallback chain becomes:

1. **Claude Desktop session-index title** — only when the setting is on and a title is found;
2. transcript `custom-title` / `ai-title` (ADR 0013);
3. project **folder name** from the heartbeat (ADR 0012);
4. `"Claude session"`.

When the setting is **off** (the default), behavior is **byte-for-byte today's**: the Desktop
resolver returns `nil` without touching any file, and the chain falls through to the transcript title.

### Why opt-in and default OFF

This reads **another app's private, undocumented cache**. That is a different privacy posture than
reading the user's own CLI transcripts (title record only) or VibeMenu's own heartbeat files. It is
best-effort and may break silently if Claude Desktop changes its internal format. Making it explicit
and off-by-default keeps VibeMenu's baseline promise intact and puts the choice in the user's hands,
consistent with the opt-in hook heartbeat (ADR 0008) and the "human owns product decisions" rule.

### Shape (mirrors ADR 0013's pure-parser + adapter split)

- **`ClaudeDesktopTitleIndex`** (pure, I/O-free, unit-tested): decodes one index file to a
  whitelisted `DesktopSessionRecord` and reduces a set of records to a `cliSessionID → title` map.
  The `Decodable` DTO declares **only** the five whitelisted keys, so forbidden fields are never even
  decoded. Dedup: a **non-archived** record beats an archived one; among equal archived-ness the
  **latest `lastActivityAt`** wins.
- **`DesktopTitleResolver`** (adapter, `SessionTitleResolving`): gated by an injected
  `isEnabled` closure consulted **before any file access**; globs `*/*/local_*.json` (both UUID
  levels enumerated, never assumed); caches the map keyed by a file signature (paths + mtimes +
  sizes) so an unchanged index costs stats, not reads; fails closed to an empty map on a missing
  directory or schema change.
- **`CompositeTitleResolver`** (`SessionTitleResolving`): consults an ordered list and returns the
  first non-`nil` title. The app wires `[DesktopTitleResolver, TranscriptTitleResolver]` and the
  provider consumes it exactly as before (one `SessionTitleResolving?`).
- **Wiring:** the app builds the composite with `isEnabled` reading
  `UserDefaults.standard.bool(forKey: "useDesktopTitles")`, so flipping the Settings toggle takes
  effect on the next ~2s tick with no restart. Settings shows the toggle plus an in-UI privacy
  caption: *"Reads Claude Desktop's local session index titles only. Does not read prompts or
  responses."*

## Privacy

- **Whitelist only.** `cliSessionId`, `title`, `titleSource`, `lastActivityAt`, `isArchived`. The
  DTO has no property for anything else, so `promptSuggestion`, `alwaysAllowedReasons`, `cwd`,
  `messages`, `lastPrompt`, tool I/O, etc. cannot reach the model. `cwd` is **not** read (folder
  disambiguation was not needed — `cliSessionId` is unique enough).
- **Off ⇒ zero reads.** The enable gate is checked before globbing/stat/opening anything.
- **No logging of titles** outside synthetic tests; titles are held in memory only, never written to
  disk. Session ids stay out of logs (ADR 0013 invariant unchanged).
- **No network, no writes to Claude files.** Read-only; nothing leaves the Mac.
- **Fail-closed.** Missing directory or changed schema → empty map → transcript/folder fallback.

## Risks

- **Format drift.** Undocumented Desktop cache; field names or the path layout could change on a
  Claude Desktop update. Mitigated by defensive decoding, both-levels globbing, fail-closed
  fallback, and the honest in-UI "best-effort" framing.
- **Cross-app coupling perception.** Reading a sibling app's cache. Mitigated by opt-in + default
  OFF + the whitelist + docs.
- **Lightweight budget.** Per tick when enabled: a 3-level directory walk + one `stat` per index
  file (~tens of files), reads only when the signature changes. Negligible and comparable to the
  existing heartbeat/transcript stats; the resolver reads nothing at all when disabled.

## Testing plan (all synthetic / fake data)

- Pure parse: valid record; ignores non-whitelisted fields (a fixture stuffed with
  `promptSuggestion`/`lastPrompt`/`cwd`/`messages` parses to exactly the whitelisted record);
  missing id / empty title → dropped; trim + length cap; malformed JSON → `nil`.
- Map dedup: duplicate id picks latest `lastActivityAt`; non-archived beats archived; archived used
  only when it is the only record; missing timestamp sorts oldest.
- Adapter: resolves when enabled; **returns `nil` and reads nothing when disabled**; missing
  directory → `nil`; globs both UUID levels + applies dedup; honors a live enable-flag flip.
- Composite / chain: Desktop title beats transcript; falls through when Desktop is off/empty; full
  `displayName` fallback into the folder name is unchanged when Desktop is off.

## Status of implementation

Implemented behind the default-off toggle. `swift build`, `scripts/test.sh` (238 tests), and the
`.app` `xcodebuild` all pass. Not verified in a live popover (owner's real VibeMenu runs; a second
instance would duplicate the menu-bar item) — the resolver/parser logic is covered by unit tests
against synthetic fixtures and a temp index tree.
