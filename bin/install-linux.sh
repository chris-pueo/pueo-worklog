#!/usr/bin/env bash
# install-linux.sh — wire a remote Linux box into the pueo-worklog system.
# Idempotent. Run once per Linux machine AFTER you can clone/push the repo
# (i.e. git auth to github.com/chris-pueo/pueo-worklog is already working).
#
#   bash ~/git/pueo-worklog/bin/install-linux.sh [push_interval_minutes]
#
# Does: clone repo if missing -> chmod scripts -> merge SessionStart/SessionEnd
# hook into ~/.claude/settings.json (jq) -> install a cron job to push the clock.
# Default push interval: 60 min (hourly). Requires: git, jq.

set -u
interval="${1:-60}"
repo="$HOME/git/pueo-worklog"

command -v git >/dev/null 2>&1 || { echo "ERROR: git not found"; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "ERROR: jq not found (needed to edit settings.json safely)"; exit 1; }

# 1. Clone if missing
if [ ! -d "$repo/.git" ]; then
  mkdir -p "$HOME/git"
  git clone https://github.com/chris-pueo/pueo-worklog.git "$repo" || { echo "ERROR: clone failed (check git auth)"; exit 1; }
fi
chmod +x "$repo/bin/"*.sh 2>/dev/null || true

# 2. Merge hooks into ~/.claude/settings.json
mkdir -p "$HOME/.claude"
settings="$HOME/.claude/settings.json"
[ -f "$settings" ] || echo '{}' > "$settings"
cp "$settings" "$settings.bak.$(date -u +%Y%m%d%H%M%S)"

hookcmd="bash $repo/bin/claude-worklog-hook.sh"
tmp="$(mktemp)"
jq --arg cmd "$hookcmd" '
  .hooks = (.hooks // {}) |
  .hooks.SessionStart = [ { hooks: [ { type: "command", command: $cmd, timeout: 15 } ] } ] |
  .hooks.SessionEnd   = [ { hooks: [ { type: "command", command: $cmd, timeout: 15 } ] } ]
' "$settings" > "$tmp" && mv "$tmp" "$settings"
echo "Updated $settings (backup kept). Hooks:"
jq '.hooks | keys' "$settings"

# 3. Install cron push (idempotent: drop any prior line first)
# Build an idiomatic schedule: whole-hour multiples -> "0 [*/h] * * *"; else "*/m * * * *".
if [ "$interval" -ge 60 ] && [ $((interval % 60)) -eq 0 ]; then
  hours=$((interval / 60))
  if [ "$hours" -eq 1 ]; then sched="0 * * * *"; else sched="0 */$hours * * *"; fi
else
  sched="*/$interval * * * *"
fi
cronline="$sched $repo/bin/sync-push.sh >/dev/null 2>&1"
( crontab -l 2>/dev/null | grep -v 'pueo-worklog/bin/sync-push.sh' ; echo "$cronline" ) | crontab -
echo "Installed cron ('$sched'):"
crontab -l | grep sync-push.sh

echo "DONE. New Claude Code sessions on $(hostname -s) will log clock; cron pushes on '$sched'."
