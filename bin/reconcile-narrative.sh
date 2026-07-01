#!/usr/bin/env bash
# reconcile-narrative.sh — show worklog CAPTURE gaps for a local day (read-only).
#
# The narrative line is a manual end-of-session step; the SessionEnd hook drops a PENDING
# stub when a session ends undescribed, but this tool is the human/Claude-facing view:
# for a given LOCAL day on THIS host it lists every Claude session from the raw clock
# (sid, cwd, prompt count, wall-clock span) and flags which have NO narrative line — i.e.
# work whose billable description+charge-code is still missing. Run it at end of day (or
# before a timecard) to turn silent loss into a worklist. Matching is by the [sid:<id>]
# tag a real narrative line carries, so it is meaningful only for lines written on/after
# 2026-07-01 (older lines predate the tag and will show as GAP — expected, already reconciled).
#
# Usage: reconcile-narrative.sh [YYYY-MM-DD]   (default: today, local)
set -u
repo="$HOME/git/pueo-worklog"
host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
day="${1:-$(date +%Y-%m-%d)}"
ym="${day%-*}"                         # YYYY-MM
raw="$repo/raw/${host}-${ym}.ndjson"
narr="$repo/narrative/${host}-${ym}.md"

command -v jq >/dev/null 2>&1 || { echo "reconcile: jq required" >&2; exit 1; }
[ -f "$raw" ] || { echo "reconcile: no raw file for $ym ($raw)"; exit 0; }

echo "== worklog reconcile — $host — $day =="
sids="$(jq -r --arg d "$day" 'select((.ts//"")|startswith($d)) | .sid // empty' "$raw" 2>/dev/null | sort -u)"
[ -z "$sids" ] && { echo "no sessions recorded for $day"; exit 0; }

gaps=0; total=0
printf '%-10s %7s  %-13s  %s\n' "SID" "PROMPTS" "SPAN(local)" "CWD  ·  STATUS"
printf '%-10s %7s  %-13s  %s\n' "----------" "-------" "-------------" "------------------------"
for sid in $sids; do
  pc="$(jq -r --arg s "$sid" 'select(.sid==$s and .event=="UserPromptSubmit")|.ts' "$raw" 2>/dev/null | grep -c .)"
  [ "${pc:-0}" -ge 1 ] || continue     # skip no-activity sessions (opened + closed)
  total=$((total+1))
  spans="$(jq -r --arg s "$sid" 'select(.sid==$s)|.ts' "$raw" 2>/dev/null | sort)"
  first="$(printf '%s\n' "$spans" | head -1 | cut -c12-16)"
  last="$(printf '%s\n' "$spans" | tail -1 | cut -c12-16)"
  cwd="$(jq -r --arg s "$sid" 'select(.sid==$s and (.cwd//"")!="")|.cwd' "$raw" 2>/dev/null | tail -1)"
  if [ -f "$narr" ] && grep -qF "[sid:$sid]" "$narr" 2>/dev/null; then
    if grep -F "[sid:$sid]" "$narr" | grep -q 'PENDING'; then status="PENDING stub — needs a real line"; gaps=$((gaps+1))
    else status="described"; fi
  else
    status="*** GAP — no narrative line ***"; gaps=$((gaps+1))
  fi
  printf '%-10.10s %7s  %-13s  %s  ·  %s\n' "$sid" "$pc" "${first:-?}-${last:-?}" "$(basename "${cwd:-?}")" "$status"
done
echo
echo "$total active session(s); $gaps still need a narrative line for $day."
[ "$gaps" -gt 0 ] && echo "Write a line per gap in $narr ending with its [sid:<id>] tag, then re-run."
exit 0
