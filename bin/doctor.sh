#!/usr/bin/env bash
# doctor.sh - read-only health check of the worklog pipeline (mirror of doctor.ps1).
# Per host (current month): newest record ts, newest ts PER event-type (a never-seen
# UserPromptSubmit stream = heartbeat not enabled), push age; plus this box's hook wiring +
# sync cron. Freshness derived from MAX raw ts (format-independent), in UTC. Requires jq. exit 0.
repo="$HOME/git/pueo-worklog"
ym="$(date -u +%Y-%m)"
now=$(date -u +%s)
echo "# worklog doctor - $(date -u +%Y-%m-%dT%H:%MZ) (UTC)"

for f in "$repo"/raw/*-"$ym".ndjson; do
  [ -e "$f" ] || continue
  host="$(basename "$f" | sed -E 's/-[0-9]{4}-[0-9]{2}\.ndjson$//')"
  echo; echo "## $host   ($(basename "$f"))"
  if command -v jq >/dev/null 2>&1; then
    maxall=$(jq -rs 'map(.ts)|max // empty' "$f")
    ss=$(jq -rs '[.[]|select(.event=="SessionStart").ts]|max // empty' "$f")
    se=$(jq -rs '[.[]|select(.event=="SessionEnd").ts]|max // empty' "$f")
    hb=$(jq -rs '[.[]|select(.event=="UserPromptSubmit").ts]|max // empty' "$f")
    nojq=$(jq -rs '[.[]|select(.event=="CAPTURE_ERROR_NO_JQ")]|length' "$f")
    if [ -n "$maxall" ]; then
      age=$(( (now - $(date -u -d "$maxall" +%s)) / 3600 ))
      st=""; [ "$age" -gt 2 ] && st="   [STALE >2h]"
      echo "   last record:           $maxall  (${age}h ago)$st"
      echo "   last SessionStart:     ${ss:-(none)}"
      echo "   last SessionEnd:       ${se:-(none)}"
      if [ -n "$hb" ]; then echo "   last UserPromptSubmit: $hb"; else echo "   last UserPromptSubmit: [NONE - heartbeat not enabled; re-run install-linux.sh]"; fi
      [ "${nojq:-0}" -gt 0 ] && echo "   [!] CAPTURE_ERROR_NO_JQ records present - a jq-less host logged blind"
    else echo "   (no records this month)"; fi
  else echo "   [!] jq not installed - cannot parse"; fi
done

echo; echo "## this box ($(hostname -s 2>/dev/null || hostname))"
if [ -f "$HOME/.claude/settings.json" ] && command -v jq >/dev/null 2>&1; then
  echo "   hooks wired: $(jq -r '.hooks|keys|join(", ")' "$HOME/.claude/settings.json")"
else echo "   [!] no ~/.claude/settings.json (or jq missing)"; fi
if crontab -l 2>/dev/null | grep -q sync-push.sh; then echo "   sync-push cron: present"; else echo "   sync-push cron: [MISSING]"; fi
exit 0
