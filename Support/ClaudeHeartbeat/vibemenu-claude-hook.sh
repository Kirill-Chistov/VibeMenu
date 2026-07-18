#!/bin/sh
# VibeMenu — Claude Code heartbeat hook (production, observation-only).
#
# WHAT THIS IS
#   A tiny, dependency-light hook that Claude Code runs on lifecycle events. It records a
#   per-session "heartbeat" so VibeMenu can tell whether Claude is actively working or has
#   stopped and is waiting for you — more reliably than guessing from file mtimes.
#
# PRIVACY CONTRACT (hard rules — see docs/PRIVACY.md / docs/SECURITY.md / AGENTS.md §6)
#   This script reads the hook JSON on stdin and extracts ONLY three scalar fields, and ONLY
#   from the TOP LEVEL of the JSON object:
#       * hook_event_name   (a fixed identifier, e.g. "PreToolUse")
#       * session_id        (an opaque session UUID)
#       * cwd               (the session's working directory) — from which it derives and
#                           keeps ONLY the final path component (the project FOLDER NAME,
#                           e.g. "VibeMenu"). The full path and every parent directory are
#                           dropped inside the parser and never written or logged.
#   It NEVER reads, stores, or logs: prompt text, response text, transcript path/contents,
#   the full cwd path, tool input, tool output, full argv, or environment. Everything else on
#   stdin is ignored. Crucially, nested keys inside objects like `tool_input` / `tool_response`
#   (which can contain attacker- or file-controlled data) are IGNORED even if they are
#   themselves named `hook_event_name`, `session_id`, or `cwd`: only the outermost object's
#   own fields are used, so payload *shape* can never redirect the event or the filename.
#   The only thing it writes is a heartbeat file containing five safe fields
#   (schemaVersion, updatedAt, event, sessionID, project) — `project` being the folder name
#   only. (schemaVersion 2 adds `project`; readers tolerate its absence for older files.)
#
# WHY PYTHON (structural JSON), NOT A REGEX
#   A regex/sed scan over the flattened payload cannot tell a top-level key from a nested
#   one — a `"session_id"` buried inside `tool_input` could win and steer the output
#   filename. We therefore parse the JSON *structurally* with the Python 3 that ships with
#   macOS at the fixed path /usr/bin/python3 (Command Line Tools / Xcode both provide it)
#   and read only the top object's own two fields. We use ONLY /usr/bin/python3 — never any
#   other python3 on PATH — so it stays a system interpreter, not a third-party dependency
#   (AGENTS.md §5), and cannot be shadowed via PATH; no `jq` is required. If /usr/bin/python3
#   is missing or not executable, the script degrades to a SAFE no-parse mode (event from $1
#   if any, else "unknown"; session "unknown-session") rather than falling back to an unsafe
#   regex — it never reintroduces the nested-override problem and never touches the payload body.
#
# ROBUSTNESS
#   * No jq or any third-party dependency — POSIX sh + system python3 + sed/tr/date/mv/mkdir.
#   * Writes atomically (temp file + mv) so VibeMenu never reads a half-written file.
#   * ALWAYS exits 0, even on parse/IO failure, so it can never block or break a Claude
#     Code session.
#
# INSTALL / REMOVE
#   This script is NOT installed automatically. See Support/ClaudeHeartbeat/README.md for
#   manual setup, verification, and removal. VibeMenu never edits ~/.claude/settings.json.

set -u

SCHEMA_VERSION=2

# Where per-session heartbeat files go. Overridable via VIBEMENU_HEARTBEAT_DIR (used by
# the test suite to write into a temp dir instead of the real Application Support tree).
BASE_DIR="${VIBEMENU_HEARTBEAT_DIR:-$HOME/Library/Application Support/VibeMenu/ClaudeHeartbeat/sessions}"

# Read the raw hook JSON from stdin (may be empty for some invocations). Kept as-is (no
# flattening): the structural parser below needs the real JSON, and we never scan it.
input="$(cat 2>/dev/null)"

# Use ONLY the system python3 at its fixed macOS path (Command Line Tools / Xcode both
# provide /usr/bin/python3). We deliberately do NOT fall back to any other python3 on PATH:
# a third-party interpreter would be an unvetted dependency (AGENTS.md §5) and could be
# shadowed by an attacker-controlled PATH. If it is missing or not executable, PYTHON stays
# empty and the script degrades to the SAFE no-parse mode below. Never a regex fallback.
PYTHON=""
if [ -x /usr/bin/python3 ]; then
    PYTHON=/usr/bin/python3
fi

event=""
session=""
project=""

# Parse structurally and read ONLY the three top-level fields. The Python program prints
# exactly three lines — the top-level hook_event_name, session_id, and the FINAL PATH
# COMPONENT of cwd (each with any embedded CR/LF stripped, empty if absent or non-string) —
# and nothing else. It computes os.path.basename(cwd) *inside the parser* and emits only that
# folder name, so the full path never leaves Python. It never echoes any other payload field
# (or the parent directories), so nothing sensitive can reach stdout. On invalid JSON, a
# non-object payload, or any error it exits non-zero and prints nothing, leaving the fields empty.
if [ -n "$PYTHON" ]; then
    parsed="$(printf '%s' "$input" | "$PYTHON" -c '
import sys, json, os
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(data, dict):
    sys.exit(1)
def top(key):
    value = data.get(key)
    return value if isinstance(value, str) else ""
event = top("hook_event_name").replace("\n", "").replace("\r", "")
session = top("session_id").replace("\n", "").replace("\r", "")
# Keep ONLY the final path component of cwd — the project folder name. The full path and
# every parent directory are discarded here and never emitted.
cwd = top("cwd")
project = os.path.basename(cwd.rstrip("/")) if cwd else ""
project = project.replace("\n", "").replace("\r", "")
sys.stdout.write(event + "\n" + session + "\n" + project + "\n")
' 2>/dev/null)"
    if [ -n "$parsed" ]; then
        event="$(printf '%s' "$parsed" | sed -n '1p')"
        session="$(printf '%s' "$parsed" | sed -n '2p')"
        project="$(printf '%s' "$parsed" | sed -n '3p')"
    fi
fi

# Fallback: some hook configs pass the event name as $1. Never invent data beyond that.
[ -z "$event" ] && event="${1:-unknown}"

# Sanitize both fields before they touch the filesystem or the JSON body. Even though the
# structural parser already limited us to two top-level strings, we still constrain them:
#   * event: hook names are alphanumeric; strip anything else (also blocks JSON injection).
#   * session: used as a FILENAME, so strip anything that isn't a safe filename char. This
#     defends against path traversal (e.g. a "../" in a malformed session_id).
safe_event="$(printf '%s' "$event" | tr -cd 'A-Za-z0-9_')"
[ -z "$safe_event" ] && safe_event="unknown"

safe_session="$(printf '%s' "$session" | tr -cd 'A-Za-z0-9._-')"
# Documented behavior when session_id is missing/empty (or sanitizes away): write to a
# single shared "unknown-session" file rather than silently no-op'ing, so the event is
# still observed. VibeMenu treats it like any other session.
[ -z "$safe_session" ] && safe_session="unknown-session"

# project: the project FOLDER NAME ONLY (never a path — Python already took basename). Allow
# a conservative, JSON-safe set — letters, digits, space, dot, underscore, dash — so a
# crafted folder name can't break the JSON string or inject fields; anything else (quotes,
# backslashes, any residual slash, control/non-ASCII bytes) is stripped. Trim surrounding
# spaces and cap the length so the menu row stays compact. May be empty (missing/odd cwd),
# in which case VibeMenu shows a generic "Claude session" label instead of a folder name.
safe_project="$(printf '%s' "$project" | tr -cd 'A-Za-z0-9 ._-' | sed 's/^ *//; s/ *$//' | cut -c1-64)"

# Create the sessions directory as needed; bail (exit 0) if we can't.
mkdir -p "$BASE_DIR" 2>/dev/null || exit 0

# A Stop/StopFailure is a completed turn, not a session-wide terminal state. Claude Code can still
# deliver a late lifecycle/work hook for that turn (notably SubagentStop), and replacing the finish
# heartbeat would make VibeMenu reclassify the same turn as a new Working/Quiet turn. Read only the
# previous VibeMenu-owned safe `event` field as a completion latch. A new user prompt or a fresh
# approval request is the only reliable reused-session boundary; SessionEnd remains terminal.
target="$BASE_DIR/$safe_session.json"
previous_event=""
if [ -n "$PYTHON" ] && [ -f "$target" ]; then
    previous_event="$($PYTHON -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        data = json.load(handle)
    event = data.get("event")
    if isinstance(event, str):
        print(event)
except Exception:
    pass
' "$target" 2>/dev/null)"
fi

if [ "$previous_event" = "Stop" ] || [ "$previous_event" = "StopFailure" ]; then
    case "$safe_event" in
        UserPromptSubmit|PermissionRequest|SessionEnd)
            # Reliable new-turn/terminal boundaries replace the latched finish record.
            ;;
        *)
            # Repeated or trailing events belong to the completed turn; leave its finish and
            # timestamp untouched so polling cannot manufacture a new timer or notification.
            exit 0
            ;;
    esac
fi

updated_at="$(date +%s)"
tmp="$BASE_DIR/.$safe_session.$$.tmp"

# Write the five privacy-safe fields, then atomically move into place. `project` is the
# folder name only (may be an empty string when cwd was missing/unusable).
printf '{"schemaVersion":%s,"updatedAt":%s,"event":"%s","sessionID":"%s","project":"%s"}\n' \
    "$SCHEMA_VERSION" "$updated_at" "$safe_event" "$safe_session" "$safe_project" > "$tmp" 2>/dev/null || exit 0
mv -f "$tmp" "$target" 2>/dev/null || rm -f "$tmp" 2>/dev/null

exit 0
