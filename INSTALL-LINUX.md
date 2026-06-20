# Wiring a remote Linux box into pueo-worklog

Goal: Claude Code sessions on a Linux machine auto-log their wall-clock + per-prompt
activity, and a cron job pushes it here, so the Windows `/timecard` run sees that machine's
work too.

## What gets captured
- `SessionStart` / `SessionEnd` — session boundaries.
- **`UserPromptSubmit` — a per-prompt activity heartbeat** (added 2026-06-20). Session
  lifecycle alone can't measure active hours (an open session inflates a Start→End span to
  ~24h; a single long session emits nothing in between), so `/timecard` clusters heartbeats
  into distinct active wall-clock. All three reuse the same event-generic hook.

## Prerequisites
- `git` and `jq` installed.
- Git auth to `github.com/chris-pueo/pueo-worklog` working (SSH key or PAT / credential
  helper) — test with: `git clone https://github.com/chris-pueo/pueo-worklog.git ~/git/pueo-worklog`
- Claude Code installed (it reads `~/.claude/settings.json`).

## One-shot install / upgrade
```bash
# (clone first if you haven't — the installer will also do it)
bash ~/git/pueo-worklog/bin/install-linux.sh         # default: hourly push
# bash ~/git/pueo-worklog/bin/install-linux.sh 30    # or pass minutes for a different cadence
```
**Idempotent** — re-run any time to upgrade an existing install (e.g. to pick up the new
`UserPromptSubmit` heartbeat). It merges the SessionStart/SessionEnd + UserPromptSubmit hooks
into `~/.claude/settings.json` (backing it up first), installs the `bin/sync-push.sh` crontab
line, and injects the worklog instructions into `~/.claude/CLAUDE.md` as a managed block.

## Verify
```bash
jq '.hooks | keys' ~/.claude/settings.json   # -> ["SessionEnd","SessionStart","UserPromptSubmit"]
crontab -l | grep sync-push                   # -> the "0 * * * *" hourly line
grep -c 'BEGIN pueo-worklog' ~/.claude/CLAUDE.md  # -> 1 (instructions installed)
# Submit ONE prompt in any Claude Code session, then confirm a heartbeat landed:
tail -1 ~/git/pueo-worklog/raw/"$(hostname -s)-$(date -u +%Y-%m)".ndjson  # -> "event":"UserPromptSubmit"
bash ~/git/pueo-worklog/bin/sync-push.sh      # manual push; then check GitHub
```
Also confirm nothing odd was injected into your session when you submitted that prompt —
that proves the hook's stdout is clean (see caveat below).

## Notes / caveats
- **stdout MUST be silent.** A `UserPromptSubmit` hook's stdout is injected into the model
  context on exit 0. `bin/claude-worklog-hook.sh` writes only to the ndjson — keep it that way.
- **Runs on every prompt, synchronously** → it's a tiny local file append (fast); never add
  network calls to it. A small per-prompt latency is expected.
- **No prompt text** is logged (the payload's `.prompt` is never read).
- Raw files are **machine-namespaced** (`<host>-YYYY-MM.ndjson`) so machines never conflict.
- The hook never blocks a session (swallows errors, exits 0). If the repo dir is missing it
  falls back to `~/.claude/worklog/`.
- To remove: delete the `.hooks` block from `~/.claude/settings.json` and `crontab -e` out
  the sync line.

## Change record
- **2026-06-20** — Added the `UserPromptSubmit` activity heartbeat. `/timecard` now clusters
  heartbeats into active time as the primary hours source (per-session effort estimates are
  the pre-heartbeat fallback). Reversible: drop the `UserPromptSubmit` block from settings.json.
