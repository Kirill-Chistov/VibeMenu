# VibeMenu — Security

VibeMenu is a local-first macOS utility. Its security posture follows from that: minimal
surface, no secrets, no unnecessary egress, and risky capabilities quarantined behind
explicit review.

## Core rules

- **No secrets in the repo.** No API keys, signing certificates, notarization
  credentials, or provisioning profiles are ever committed. CI secrets live only in the
  platform's secret store. `.gitignore` covers `*.p12`, provisioning profiles, and any
  real-data agent fixtures.
- **No unnecessary network calls.** VibeMenu makes **no** network requests, and contains no
  networking code. The only egress the invariant would ever permit is a software-update check to
  the project's own appcast host — **not built, and not planned for the current phase**. A
  no-network invariant test should guard this if networking-capable code ever exists.
- **No transcript-content logging.** Logs (local-only, `os.Logger` categories) must never
  contain transcript contents or paths that could leak project names. A redaction switch
  is planned.
- **Opt-in hook heartbeat is user-installed and side-effect-safe.** The Claude detection
  L2 hook (`Support/ClaudeHeartbeat/vibemenu-claude-hook.sh`) is **never** installed by
  VibeMenu and VibeMenu **never** edits `~/.claude/settings.json`; the user installs it
  manually (backup + merge) and can remove it by restoring the backup. The script parses the
  hook JSON **structurally** with the system `python3` at the fixed path `/usr/bin/python3`
  (a macOS-provided interpreter, used exclusively — never any other `python3` on `PATH` — so
  it is not a third-party dependency and can't be shadowed; no `jq`) and extracts only three
  **top-level** fields: `hook_event_name`, `session_id`, and `cwd` — and from `cwd` it keeps
  **only the final path component** (the project folder name), reducing it with `basename`
  *inside the parser*, so the full path and every parent directory are discarded before
  anything is written. Reading only the outermost object's own fields is deliberate: a nested
  key of the same name inside `tool_input`/`tool_response` (which can carry attacker- or
  file-controlled data) **cannot** override the event, the folder name, or the output filename
  — closing a hole a flat regex scan would leave open. It then **sanitizes the session id
  before using it as a filename** (stripping anything but `[A-Za-z0-9._-]`, so a malformed id
  cannot path-traverse), writes atomically (temp + rename), and **always exits 0** so it can
  never block or break a Claude session (invalid JSON or a missing/non-executable
  `/usr/bin/python3` degrades to a safe `unknown` record, never an unsafe parse). It
  reads/writes no prompt/response/tool/transcript contents, and never a full `cwd`.
- **The heartbeat reader never opens a transcript.** VibeMenu reads back only its **own**
  heartbeat files (`{schemaVersion, updatedAt, event, sessionID, project}`) to derive session
  state. Transcript access is a **separate component** — the title resolver — with one narrow,
  ADR-approved job: open the matching transcript and read *only* its session-title record
  (`custom-title` / `ai-title`) so a row can be named, never message content
  ([`decisions/0013`](decisions/0013-session-title-and-dismiss.md), [`PRIVACY.md`](PRIVACY.md)).
  The two paths are independent: the heartbeat path never opens a transcript, and the title
  path never reads a heartbeat file. Widening the title read requires its own ADR.
- **No privileged helper in the current app.** VibeMenu currently uses only public, non-root
  power APIs. There is no root helper, no `sudoers` rule, and no `pmset disablesleep`. The only
  standard permission it may request today is macOS notification authorization when the user
  enables Agent notifications.
- **No private Apple APIs.** Only public, documented, sandbox-tolerable APIs.
- **Opt-in readers are read-only and fail closed.** The Claude Desktop cache/title index and the
  Codex rollout/index files belong to other apps: VibeMenu opens them read-only, never writes to
  or deletes them, parses only an allowlist, bounds how much it reads, and shows nothing rather
  than guessing when a format changes. The one exception that *writes* is the Claude Code
  status-line setup, which is preview-gated, backs up `~/.claude/settings.json` first, changes
  only the `statusLine` key, and is reversible from Settings.
- **Headless closed-lid work remains separately gated.** Two short owner-run tests on the current
  Apple Silicon Mac showed one-second user-space logging continuing while `SleepDisabled=1`, with
  restoration to `0` afterward. This is feasibility evidence only—not a shipped feature or a
  security approval. Any implementation still requires its own ADR, signing/notarization and
  administrator-consent decisions, a minimal authenticated helper, independent security review,
  battery/thermal limits, and a crash-safe expiring watchdog that restores ordinary sleep.
- **There is no update channel.** VibeMenu does not check for, download, or install updates.
  You get new versions by downloading a release or rebuilding. If an updater is ever added it
  must use an EdDSA-signed appcast over HTTPS with a pinned public key — but none exists today,
  and none is planned for the current phase.

## Distribution: what unsigned actually means for you

VibeMenu ships **unsigned and un-notarized** — a deliberate cost decision for the project's
current validation phase, revisitable if adoption or funding justifies a Developer ID
([`ROADMAP.md`](ROADMAP.md#distribution),
[`decisions/0004` Amendment 1](decisions/0004-direct-distribution.md#amendment-1-2026-07-15--stay-unsigned-for-the-current-validation-phase)).
Be clear-eyed about the tradeoff:

- **Apple has not vetted the binary,** and there is no signature binding the download to this
  project. Gatekeeper's warning is correct, and "Open Anyway" is you overriding it.
- **A release zip is only as trustworthy as the GitHub account that published it.** There is no
  cryptographic check that the zip you downloaded is the one that was built from this source.
- **Building it yourself removes one link, not all of them.** The source is here and the build is
  two commands, so you're trusting code you can read rather than a binary you can't — that closes
  the "did the published zip match the source?" gap. It does **not** produce a signed app, and it
  doesn't vouch for the source itself; that's what reading it is for.
- **Nothing here is a substitute for signing.** Staying unsigned is a cost decision, not a
  security claim, and it is the honest reason the app can't offer a verified update path.

## Threat model (local macOS utility)

- **Supply chain** — a compromised dependency or build. *Mitigation:* minimal dependencies (one
  vendored C decoder, no package dependencies), and an ADR for every new one. **Not** mitigated
  by signing or notarization — see above.
- **Malicious/lookalike distribution** — someone reposts a trojaned "VibeMenu.app". *Mitigation:*
  weak while unsigned; download only from this project's releases, or build from source.
- **Data exfiltration** — accidental logging or upload of code/transcript content.
  *Mitigation:* metadata-only design by construction (the value types cannot hold message
  content), allowlist parsers, no session ids or paths in logs, and the no-network invariant.
- **Hostile file content** — another app's file (or a hook payload) carries attacker-controlled
  data. *Mitigation:* structural top-level-only parsing, allowlists, session-id sanitising before
  filename use, bounded reads, and fail-closed behavior on anything malformed.
- **Privilege escalation via a future helper** — an over-broad helper or `sudoers` rule.
  *Mitigation (only if clamshell is ever built):* the helper does *only* enable/disable
  `disablesleep`, with no arbitrary-argument passthrough; minimal, signed, auditable.
- **Stuck `disablesleep`** — a crash leaves sleep disabled. *Not applicable today* (VibeMenu uses
  only a process-scoped `IOPMAssertion`, which the OS releases if the app dies). It would become
  real only with clamshell; mitigation then: watchdog + startup reconciliation + visible state.

## macOS hardening (as the app matures)

App Sandbox decisions documented; hardened runtime; no secrets embedded in the app bundle; safe
local logging; clear per-permission explanations (what / why / what happens if you decline).
Tracked in [`RELEASE_CHECKLIST.md`](RELEASE_CHECKLIST.md). Note that hardened runtime and
notarization are gated on signing, which is not planned for the current phase.

## Reporting a vulnerability

This is an early-stage project with a single maintainer, so there is no formal disclosure
process or response SLA. Please report suspected security issues **privately** — via a
[GitHub security advisory](../../security/advisories/new) on this repository — rather than a
public issue, and please don't open a public issue for anything exploitable.

Include what you'd need to reproduce it, but **do not include private data**: no real transcript
contents, prompts, tokens, or credentials.
