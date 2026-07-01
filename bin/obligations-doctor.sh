#!/usr/bin/env bash
# obligations-doctor.sh — view / resolve the capture-obligation debt ledger (read-mostly).
# The Stop hook (session-obligations.sh) records unmet ClickUp/Obsidian obligations to
# obligations/<host>-YYYY-MM.ndjson; the SessionEnd/doctor paths may add TIME/ENFORCEMENT
# records. This nets unmet vs resolved and lists what still owes attention.
#
#   obligations-doctor.sh [YYYY-MM]                 # list open debts for the month (default: now)
#   obligations-doctor.sh --resolve <sid> <OBLIG>   # mark (sid,OBLIG) resolved (appends a record)
set -u
repo="${PUEO_WORKLOG_REPO:-$HOME/git/pueo-worklog}"
host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
command -v jq >/dev/null 2>&1 || { echo "obligations-doctor: jq required" >&2; exit 1; }

if [ "${1:-}" = "--resolve" ]; then
  sid="${2:-}"; ob="${3:-}"
  [ -n "$sid" ] && [ -n "$ob" ] || { echo "usage: --resolve <sid> <OBLIGATION>"; exit 1; }
  f="$repo/obligations/${host}-$(date +%Y-%m).ndjson"; mkdir -p "$repo/obligations" 2>/dev/null || true
  printf '{"ts":"%s","host":"%s","sid":"%s","cwd":"-","obligation":"%s","resolved":true,"source":"manual"}\n' \
    "$(date +%Y-%m-%dT%H:%M:%S%z)" "$host" "$sid" "$ob" >> "$f"
  echo "resolved: $sid $ob"; exit 0
fi

ym="${1:-$(date +%Y-%m)}"
f="$repo/obligations/${host}-${ym}.ndjson"
echo "== obligation debts — $host — $ym =="
[ -f "$f" ] || { echo "(no ledger for $ym)"; exit 0; }

# net: an (sid,obligation) pair is OPEN if it has an unmet record and no later resolved record.
jq -rs '
  ( map(select(.resolved==true) | (.sid+"|"+.obligation)) | unique ) as $done
  | map(select((.resolved // false) | not))
  | map(select( (.sid+"|"+.obligation) as $k | ($done | index($k)) | not ))
  | group_by(.obligation)
  | .[] | "\(.[0].obligation)\t\(length)\t" + ( [ .[] | (.sid[0:8]) ] | unique | join(",") )
' "$f" 2>/dev/null | awk -F'\t' 'BEGIN{n=0}
  {printf "  %-12s open=%-3s  sids: %s\n", $1, $2, $3; n+=$2}
  END{ if(n==0) print "  (all obligations met / resolved)"; else printf "\n  %d open obligation(s). Resolve: obligations-doctor.sh --resolve <sid> <OBLIGATION>\n", n }'
exit 0
