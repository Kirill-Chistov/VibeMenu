#!/bin/sh
# VibeMenu — Claude Code usage-limit capture (opt-in statusLine command).
#
# WHAT THIS IS
#   A tiny statusLine command that Claude Code runs to render your terminal status line. On each
#   run Claude Code pipes a JSON object on stdin that (for Claude.ai Pro/Max sessions, after the
#   first API response) includes a `rate_limits` object with the REAL server-side usage windows.
#   This script captures ONLY those usage numbers into a VibeMenu-owned file so the VibeMenu menu
#   bar can show your 5-hour and weekly limits — the same figures the in-app /usage view shows,
#   with no network call, no cookies, no API keys, and no token-count estimation.
#
# PRIVACY CONTRACT (hard rules — docs/PRIVACY.md / docs/SECURITY.md / AGENTS.md §6,
#                   docs/decisions/0016-claude-usage-limits.md)
#   Using the system Python at the FIXED path /usr/bin/python3, it structurally parses the stdin
#   JSON and extracts ONLY, and only from the TOP LEVEL:
#       * rate_limits.five_hour.{used_percentage, resets_at}
#       * rate_limits.seven_day.{used_percentage, resets_at}
#       * session_id   (opaque session UUID)
#       * version      (the Claude CLI version string)
#   It writes ONLY those to the usage file (schemaVersion, capturedAt, sessionID, cliVersion,
#   fiveHour, sevenDay). It NEVER reads, stores, or logs: prompt/response text, transcript
#   path/contents, cwd/paths, tool input/output, cost, spend, billing, or any other field — the
#   parser has no path to them, and nested keys inside other objects are ignored. The usage file
#   is VibeMenu's own (like the heartbeat files), NOT a Claude transcript.
#
#   The visible status-line text it prints (model · folder, or your wrapped status line) is shown
#   back to YOU in YOUR terminal and is never written to the usage file or sent anywhere.
#
# COMPOSES WITH YOUR STATUS LINE
#   There is only one statusLine slot. If you already have a statusLine command, VibeMenu's
#   in-app installer wraps it: this script is invoked as
#       vibemenu-usage-statusline.sh --wrap <base64-of-your-original-command>
#   and it runs your original command with the same stdin and prints its output verbatim, so your
#   status line is unchanged. With no --wrap it prints a minimal "model · folder" line.
#
# ROBUSTNESS
#   * No jq / no third-party dependency — POSIX sh + system python3 + base64/mkdir/mv.
#   * Writes the usage file atomically (temp + mv); only writes when a window is present, so a
#     transient render without rate_limits never wipes the last-known-good snapshot.
#   * ALWAYS exits 0 and always prints a status line, so it can never block or break a session.
#
# INSTALL / REMOVE
#   Install from VibeMenu → Settings (one-click, with preview + backup), or manually — see
#   Support/ClaudeUsage/README.md. Removal is reversible (restores any wrapped command).

set -u

SCHEMA_VERSION=1

# Where the usage snapshot goes. Overridable via VIBEMENU_USAGE_FILE (used by the test suite to
# write into a temp path instead of the real Application Support tree).
USAGE_FILE="${VIBEMENU_USAGE_FILE:-$HOME/Library/Application Support/VibeMenu/ClaudeUsage/usage.json}"

# Parse a leading `--wrap <base64>` argument (the original status line command to run), if present.
WRAP_B64=""
if [ "${1:-}" = "--wrap" ] && [ -n "${2:-}" ]; then
    WRAP_B64="$2"
fi

# Read the raw statusLine JSON from stdin (kept as-is; the structural parser needs real JSON and
# we never scan it). May be empty for some invocations.
input="$(cat 2>/dev/null)"

# Use ONLY the system python3 at its fixed macOS path — never any other python3 on PATH (an
# unvetted dependency that could be shadowed). If missing, PYTHON stays empty and capture is
# skipped; the status line is still produced below.
PYTHON=""
if [ -x /usr/bin/python3 ]; then
    PYTHON=/usr/bin/python3
fi

# Structurally extract ONLY the whitelisted usage fields, write the usage file atomically (only
# when at least one window is present), and print a minimal "model · folder" default status line.
# The Python program does its own atomic write (temp + os.replace) so JSON escaping is correct and
# no half-written file is ever observed. It prints ONLY the default status-line text to stdout;
# nothing sensitive is emitted. On any error it prints nothing and exits non-zero (capture skipped).
default_line=""
if [ -n "$PYTHON" ]; then
    default_line="$(printf '%s' "$input" | VIBEMENU_USAGE_FILE="$USAGE_FILE" \
        VIBEMENU_SCHEMA_VERSION="$SCHEMA_VERSION" "$PYTHON" -c '
import sys, os, json, time, tempfile

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(data, dict):
    sys.exit(1)

def top_str(key, cap):
    v = data.get(key)
    return v[:cap] if isinstance(v, str) else None

def window(w):
    if not isinstance(w, dict):
        return None
    out = {}
    up = w.get("used_percentage")
    if isinstance(up, (int, float)) and not isinstance(up, bool):
        out["usedPercent"] = float(up)
    ra = w.get("resets_at")
    if isinstance(ra, (int, float)) and not isinstance(ra, bool):
        out["resetsAt"] = int(ra)
    # A window with no percentage is not useful.
    return out if "usedPercent" in out else None

rate_limits = data.get("rate_limits")
five = window(rate_limits.get("five_hour")) if isinstance(rate_limits, dict) else None
seven = window(rate_limits.get("seven_day")) if isinstance(rate_limits, dict) else None

if five is not None or seven is not None:
    out = {
        "schemaVersion": int(os.environ.get("VIBEMENU_SCHEMA_VERSION", "1")),
        "capturedAt": int(time.time()),
    }
    sid = top_str("session_id", 128)
    if sid:
        out["sessionID"] = sid
    ver = top_str("version", 32)
    if ver:
        out["cliVersion"] = ver
    if five is not None:
        out["fiveHour"] = five
    if seven is not None:
        out["sevenDay"] = seven

    path = os.environ["VIBEMENU_USAGE_FILE"]
    d = os.path.dirname(path)
    try:
        if d:
            os.makedirs(d, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=d or ".", prefix=".usage.", suffix=".tmp")
        with os.fdopen(fd, "w") as fh:
            fh.write(json.dumps(out))
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        # Capture failure must not break the status line; fall through to printing it.

# Minimal default status line (shown only when this script is NOT wrapping your own command).
# Derived from the payload for YOUR terminal; never written to the usage file.
def display(obj, *keys):
    for k in keys:
        if not isinstance(obj, dict):
            return None
        obj = obj.get(k)
    return obj if isinstance(obj, str) else None

model = display(data, "model", "display_name") or "Claude"
cwd = display(data, "workspace", "current_dir") or display(data, "cwd") or ""
folder = os.path.basename(cwd.rstrip("/")) if cwd else ""
line = model + (" · " + folder if folder else "")
sys.stdout.write(line)
' 2>/dev/null)"
fi

# Produce the status line. If wrapping an existing command, decode and run it with the same stdin
# and print its output verbatim (your status line is unchanged). Otherwise print our default line.
if [ -n "$WRAP_B64" ]; then
    original="$(printf '%s' "$WRAP_B64" | base64 --decode 2>/dev/null || printf '%s' "$WRAP_B64" | base64 -d 2>/dev/null)"
    if [ -n "$original" ]; then
        printf '%s' "$input" | sh -c "$original" 2>/dev/null
    fi
else
    printf '%s' "$default_line"
fi

exit 0
