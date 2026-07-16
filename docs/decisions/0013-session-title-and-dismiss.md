# 0013 — Session Radar: Claude Code session title + manual dismiss

- **Status:** Accepted — v0.2 refinement (Claude Code only)
- **Date:** 2026-07-05
- **Deciders:** Kirill Chistov (product owner; approved reading the transcript **title only**, and chose
  the dismiss behaviour). Researched & implemented by Claude Code under the owner's authorization.
- **Builds on / refines:** [`0011`](0011-session-radar.md) (Session Radar),
  [`0012`](0012-session-name-from-cwd.md) (folder-name identity),
  [`0008`](0008-claude-heartbeat-detection.md) (hook heartbeat).
- **Supersedes:** the "we deliberately do not read the title" stance of
  [`0012`](0012-session-name-from-cwd.md) — narrowly, for the title field only.

## Context

[`0012`](0012-session-name-from-cwd.md) labelled each radar row with the project **folder name**
(from the hook's `cwd` capture) and explicitly *rejected* reading Claude Code's own session title,
because the title lives inside the transcript and reading transcripts was out of scope. Manual
testing confirmed the folder name is not enough: many Claude sessions run in the **same repo**, so
every row read `VibeMenu 1 / VibeMenu 2 / …` — indistinguishable from Claude Code's list, which
shows real names like *Greeting*, *Session Radar identity and visibility*, *VibeMenu local launch
setup*. The product requirement is now to **display Claude Code's own human-readable title when it
can be read safely.**

### What the transcript actually stores (researched — record types & field keys only)

Inspecting the *structure* of `~/.claude/projects/<encoded-cwd>/<session_id>.jsonl` (record
`type`s and field **keys**, never message text) across this project's 63 transcripts:

- Two dedicated **title records**, each a single title field:
  - `{"type":"custom-title","customTitle":"…","sessionId":"…"}` — the title the **user set** by
    renaming the session (may appear several times as it is renamed; the **last** wins).
  - `{"type":"ai-title","aiTitle":"…","sessionId":"…"}` — the title Claude Code
    **auto-generates**; this is what un-renamed sessions (e.g. *Greeting*) display.
- Claude Code shows the **custom title if present, else the AI title**.
- Every title record's `sessionId` **equals the transcript filename stem**, so VibeMenu's existing
  heartbeat session id *is* the filename — the file is found by name, no content parsing needed to
  locate it.
- Other record types (`assistant`, `user`, `last-prompt`, `attachment`, `tool*`, …) carry the
  prompt/response/tool content and are **never** consulted.

## Decision

### A. Read the session title — and only the title

Add `TranscriptTitleResolver`, the **one** place VibeMenu opens a Claude transcript. It:

1. **Locates** the transcript by session id: a shallow search for
   `~/.claude/projects/*/<session_id>.jsonl` (existence check only — no directory name is parsed
   or displayed). The session id is validated against `[A-Za-z0-9._-]` first, so a malformed id
   can never traverse out of the projects tree.
2. **Reads** the file and hands the bytes to the pure `ClaudeSessionTitle` parser, which:
   - decodes a line **only if it is literally a title record** (a `"custom-title"` / `"ai-title"`
     substring pre-filter), so prompt/response/`last-prompt`/tool/attachment lines are never even
     JSON-parsed;
   - keeps **only** the `customTitle` / `aiTitle` string (trimmed, non-empty, length-capped);
   - returns the **last** custom title, else the **last** AI title.
3. **Caches** the result per session id keyed by the transcript's mtime, so the ~2s detection tick
   re-reads a transcript only when it actually changed (otherwise one `stat`).

`ClaudeSession` gains `title: String?`; `displayName` becomes **`title ?? projectName ??
"Claude session"`**. Same-title collisions reuse 0012's stable numeric suffix (*Greeting 1 /
Greeting 2*). The pure store stays I/O-free — the provider attaches titles *after* the store builds
each (title-free) session, outside its lock.

**Fallback order (as required):** `customTitle`/`aiTitle` from the transcript → project folder name
(schema-2 heartbeat) → `"Claude session"`. Never a raw session id in the main UI.

### B. Manual dismiss / hide a row

A user can remove a session from VibeMenu's list by **dragging the row to the right** past a
threshold (it slides out + fades), or via its **right-click context menu → "Hide from VibeMenu"**
(the reliable fallback if the drag gesture is flaky inside the `MenuBarExtra` window). This is a
**VibeMenu-only view control**: it hides the row and nothing else — it does **not** delete any
Claude data, **not** stop or kill the session, and writes no file.

The logic is a pure `DismissedSessionRegistry` (unit-tested), owned by `ClaudeActivityModel`, which
exposes `visibleSessions` (= raw `sessions` minus hidden rows) to the UI.

**Chosen behaviour — Option 2 (hide until a newer event).** Dismissing records the session's
current `lastEventAt`; the row stays hidden while that is still its newest event, and **reappears
automatically the instant a newer heartbeat arrives** (the hook only writes on real activity). So
dismissing a *finished* session clears it for good (nothing new is written until it's pruned),
while dismissing a *live* session just defers it to its next action. This was preferred over
Option 1 (hide-until-restart) because it is strictly more useful at no extra complexity, and over
Option 3 (clear-in-settings) because no settings surface or persistence is needed. State is
in-memory, so an app restart also clears all dismissals (satisfying "hidden at least until app
restart").

## Privacy impact

- **VibeMenu now opens the matching transcript**, but reads **only** the `custom-title` / `ai-title`
  title field. It never reads or stores prompt text, assistant responses, `lastPrompt`, tool
  input/output, `cwd`, `gitBranch`, or any other message content. No title, path, or session id is
  logged. Nothing is copied to disk; nothing leaves the Mac.
- This is a **narrow, documented reversal** of the invariant "never open a Claude transcript"
  ([`PRIVACY.md`](../PRIVACY.md), AGENTS.md §6): the invariant becomes "never read prompt/response
  or message **content** — the session title record is the sole exception." No-network, no-backend,
  no-telemetry, and no-transcript-**content** invariants are all fully preserved.
- **Dismiss** touches no files at all — it only filters what the menu draws.
- The keep-awake decision is untouched: `title` and dismiss are display-only, so the
  `sessionsKeepAwakeIntent == automationIntent` equivalence test still holds.

## Consequences

- The radar answers "which session is which?" with the **same name Claude Code shows** for titled
  sessions; folder name remains the honest fallback for untitled/short sessions.
- One transcript file per recent session is opened per change (mtime-cached; an unchanged
  transcript costs one `stat`), a bounded read on the detection tick. A runaway backstop skips
  re-reading transcripts over ~12 MB (keeping the last known title), so a long, actively-appending
  session can't trigger a multi-MB read every ~2s. Locating a not-yet-found transcript
  re-enumerates the (few) project directories each tick until the file exists — acceptable at v0.2
  scale. **TODO(event-driven):** move title refresh to FSEvents/tail reads alongside the detection
  timer's eventual retirement (docs/decisions/0006/0008).
- Users can declutter the list without affecting Claude; a dismissed live session politely returns
  when it next acts.

## Alternatives considered

- **customTitle only** (the task's literal privacy list). Rejected: most sessions have only an
  `ai-title`, so the radar would still fall back to the folder name and *not* match Claude Code's
  displayed names. Reading `aiTitle` is exactly as safe (a short title record, not message
  content), so both are read.
- **Hide-until-restart (Option 1) / clear-in-settings (Option 3).** Rejected in favour of Option 2
  (above); Option 1 is an acceptable fallback but strictly less useful.
- **AppKit swipe-to-delete / Accessibility.** Rejected: the dismiss uses a native SwiftUI
  `DragGesture` + `contextMenu` only — no Accessibility, no AppKit hacks.

## Non-goals (unchanged from 0011 / 0012)

Multi-agent; real permission Allow/Deny; terminal/window jump; notch/pill presentation;
Accessibility/AppleScript; network/backend/telemetry; reading any prompt/response/`lastPrompt`,
tool, or other transcript **content** beyond the title record.
