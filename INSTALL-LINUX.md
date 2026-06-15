# Wiring a remote Linux box into pueo-worklog

Goal: Claude Code sessions on a Linux machine auto-log their wall-clock and a cron job
pushes it here, so the Windows `/timecard` run sees that machine's work too.

## Prerequisites
- `git` and `jq` installed.
- Git auth to `github.com/chris-pueo/pueo-worklog` working (SSH key or PAT / credential
  helper) — test with: `git clone https://github.com/chris-pueo/pueo-worklog.git ~/git/pueo-worklog`
- Claude Code installed (it reads `~/.claude/settings.json`).

## One-shot install
```bash
# (clone first if you haven't — the installer will also do it)
bash ~/git/pueo-worklog/bin/install-linux.sh         # default: hourly push
# bash ~/git/pueo-worklog/bin/install-linux.sh 30    # or pass minutes for a different cadence
```
That merges the SessionStart/SessionEnd hook into `~/.claude/settings.json` (backing it
up first), installs a crontab line running `bin/sync-push.sh`, and injects the worklog
instructions (charge codes + ritual) into `~/.claude/CLAUDE.md` as a managed block.

## Verify
```bash
jq '.hooks | keys' ~/.claude/settings.json       # -> ["SessionEnd","SessionStart"]
crontab -l | grep sync-push                       # -> the "0 * * * *" hourly line
grep -c 'BEGIN pueo-worklog' ~/.claude/CLAUDE.md  # -> 1 (instructions installed)
# start + exit a Claude Code session, then:
ls ~/git/pueo-worklog/raw/                         # -> <host>-YYYY-MM.ndjson
bash ~/git/pueo-worklog/bin/sync-push.sh           # manual push; then check GitHub
```

## Notes
- Raw files are **machine-namespaced** (`<host>-YYYY-MM.ndjson`) so machines never
  conflict on merge.
- The hook never blocks a session (swallows errors, exits 0). If the repo dir is missing
  it falls back to `~/.claude/worklog/`.
- To remove: delete the `.hooks` block from `~/.claude/settings.json` and
  `crontab -e` out the sync line.
