#!/usr/bin/env bash
# install-linux.sh — wire a remote Linux box into the pueo-worklog system.
# Idempotent. Run once per Linux machine AFTER you can clone/push the repo
# (i.e. git auth to github.com/chris-pueo/pueo-worklog is already working).
#
#   bash ~/git/pueo-worklog/bin/install-linux.sh [push_interval_minutes]
#
# Does: clone repo if missing -> chmod scripts -> merge SessionStart/SessionEnd +
# UserPromptSubmit (activity heartbeat) hooks into ~/.claude/settings.json (jq) ->
# install a cron job to push the clock. Idempotent: re-run to upgrade existing installs.
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

wlcmd="bash $repo/bin/claude-worklog-hook.sh"
# Stop hook runs with --noprofile --norc so a chatty ~/.bashrc can't corrupt the decision JSON.
obcmd="bash --noprofile --norc $repo/bin/session-obligations.sh"
tmp="$(mktemp)"
# APPEND-AND-DEDUPE (never clobber a teammate's existing hooks): for each event, strip only
# OUR prior entry (matched by script basename), drop groups left empty, then append ours.
jq --arg wl "$wlcmd" --arg wlkey "claude-worklog-hook.sh" \
   --arg ob "$obcmd" --arg obkey "session-obligations.sh" '
  def clean(event; key):
    (.hooks[event] // [])
    | map(.hooks |= map(select((.command // "") | contains(key) | not)))
    | map(select((.hooks | length) > 0));
  def upsert(event; key; cmd; to):
    .hooks[event] = ( clean(event; key) + [ { hooks: [ { type:"command", command:cmd, timeout:to } ] } ] );
  .hooks = (.hooks // {})
  | upsert("SessionStart";     $wlkey; $wl; 15)
  | upsert("SessionEnd";       $wlkey; $wl; 15)
  | upsert("UserPromptSubmit"; $wlkey; $wl; 10)
  | upsert("Stop";             $obkey; $ob; 30)
' "$settings" > "$tmp" && mv "$tmp" "$settings"
echo "Updated $settings (backup kept). Hooks:"
jq '.hooks | keys' "$settings"
# NOTE: Stop-hook obligations default to PUEO_OBLIG_MODE=remind (soft, non-blocking soak).
# Set PUEO_OBLIG_MODE=block in your shell/env to enforce; PUEO_OBLIG=0 disables entirely.

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

# 4. Install/refresh worklog instructions into ~/.claude/CLAUDE.md
mkdir -p "$repo/narrative" "$repo/obligations"
bash "$repo/bin/apply-instructions.sh" && echo "Installed worklog instructions into ~/.claude/CLAUDE.md (managed block)."

echo "DONE. New Claude Code sessions on $(hostname -s) log clock + follow the worklog ritual; cron pushes on '$sched'."
