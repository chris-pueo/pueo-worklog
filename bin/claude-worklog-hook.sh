#!/usr/bin/env bash
# claude-worklog-hook.sh — Linux SessionStart/SessionEnd + UserPromptSubmit hook
# (mirror of the .ps1). SessionStart/End mark session boundaries; UserPromptSubmit fires
# once per prompt as an ACTIVITY HEARTBEAT — the signal /timecard clusters into active time.
# Event-generic (records .hook_event_name), so all three land in the same ndjson.
# Appends a deterministic wall-clock record to raw/<host>-YYYY-MM.ndjson in the repo
# (fallback ~/.claude/worklog). Reads the hook payload JSON on stdin.
# stdout-silent (a UserPromptSubmit hook's stdout is injected into the model context on
# exit 0 — this writes ONLY to the ndjson). .prompt is never read (no prompt text logged).
# Fail-safe: swallows all errors, always exits 0 — never disrupt a Claude session.
# Requires: jq (recommended). Without jq it stores the raw payload defensively.

{
  payload="$(cat)"
  [ -z "$payload" ] && exit 0

  raw_dir="$HOME/git/pueo-worklog/raw"
  [ -d "$raw_dir" ] || raw_dir="$HOME/.claude/worklog"
  mkdir -p "$raw_dir" 2>/dev/null || true

  host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ym="$(date -u +%Y-%m)"
  file="$raw_dir/${host}-${ym}.ndjson"

  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -c --arg ts "$now" --arg host "$host" \
      '{ts:$ts, event:.hook_event_name, sid:.session_id, host:$host, cwd:.cwd, model:.model, title:.session_title, source:.source, reason:.reason}' \
      >> "$file" 2>/dev/null || true
  else
    printf '{"ts":"%s","host":"%s","raw":%s}\n' "$now" "$host" "$(printf '%s' "$payload" | tr -d '\n')" >> "$file" 2>/dev/null || true
  fi
} 2>/dev/null || true

exit 0
