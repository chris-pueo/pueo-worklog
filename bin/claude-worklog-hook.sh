#!/usr/bin/env bash
# claude-worklog-hook.sh — Linux SessionStart/SessionEnd + UserPromptSubmit hook
# (mirror of the .ps1). SessionStart/End mark session boundaries; UserPromptSubmit fires
# once per prompt as an ACTIVITY HEARTBEAT — the signal /timecard clusters into active time.
# Event-generic (records .hook_event_name), so all three land in the same ndjson.
# Appends a deterministic wall-clock record to raw/<host>-YYYY-MM.ndjson in the repo
# (fallback ~/.claude/worklog). Reads the hook payload JSON on stdin.
#
# TIME BASIS = LOCAL (date, not date -u), with the numeric offset kept (%z) so records stay
# unambiguous across TZ/DST. This deliberately matches the LOCAL-dated narrative heading
# (## YYYY-MM-DD) so /timecard joins clock<->narrative on the SAME day/month key. (Changed
# from UTC 2026-07-01 — UTC vs local split evening work across different day/month buckets.)
#
# SessionEnd GAP BACKSTOP: the narrative line is a MANUAL end-of-session step, so a session
# that ends via /clear, context exhaustion or a closed terminal loses its billable
# description+charge-code (the clock survives, the narrative does not). On SessionEnd, if this
# sid was never described — a real narrative line carries an [sid:<id>] tag — and it had real
# activity, we append a PENDING stub under today's heading so the gap is VISIBLE to /timecard
# and to bin/reconcile-narrative.sh instead of silently vanishing.
#
# stdout-silent (a UserPromptSubmit hook's stdout is injected into the model context on
# exit 0 — this writes ONLY to the ndjson/narrative). .prompt is never read (no prompt text logged).
# Fail-safe: swallows all errors, always exits 0 — never disrupt a Claude session.
# Requires: jq (recommended). Without jq it stores the raw payload defensively.

{
  payload="$(cat)"
  [ -z "$payload" ] && exit 0

  repo="$HOME/git/pueo-worklog"
  raw_dir="$repo/raw"
  narr_dir="$repo/narrative"
  if [ ! -d "$raw_dir" ]; then raw_dir="$HOME/.claude/worklog"; narr_dir="$raw_dir"; fi
  mkdir -p "$raw_dir" 2>/dev/null || true

  host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
  now="$(date +%Y-%m-%dT%H:%M:%S%z)"   # LOCAL time + offset (see header)
  ymd="$(date +%Y-%m-%d)"              # LOCAL date — matches the narrative heading
  ym="$(date +%Y-%m)"                  # LOCAL month — matches the narrative file
  file="$raw_dir/${host}-${ym}.ndjson"

  event=""; sid=""; cwd=""
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -c --arg ts "$now" --arg host "$host" \
      '{ts:$ts, event:.hook_event_name, sid:.session_id, host:$host, cwd:.cwd, model:.model, title:.session_title, source:.source, reason:.reason}' \
      >> "$file" 2>/dev/null || true
    event="$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null)"
    sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
    cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
  else
    # jq absent: install-linux.sh mandates jq, so this should not happen. Write a LOUD,
    # clusterable sentinel (greppable, valid JSON WITH an `event`) rather than an event-less
    # {ts,host,raw} record that /timecard would silently drop — makes the gap visible in rollups.
    printf '{"ts":"%s","event":"CAPTURE_ERROR_NO_JQ","host":"%s"}\n' "$now" "$host" >> "$file" 2>/dev/null || true
  fi

  # --- SessionEnd narrative-gap backstop -------------------------------------------------
  if [ "$event" = "SessionEnd" ] && [ -n "$sid" ] && command -v jq >/dev/null 2>&1; then
    narr="$narr_dir/${host}-${ym}.md"
    # Already described (real line tagged [sid:...]) or already stubbed? then do nothing.
    if ! { [ -f "$narr" ] && grep -qF "[sid:$sid]" "$narr" 2>/dev/null; }; then
      prompts="$(grep -F "\"sid\":\"$sid\"" "$file" 2>/dev/null | grep -cF '"event":"UserPromptSubmit"')"
      if [ "${prompts:-0}" -ge 1 ]; then
        span_ts="$(grep -F "\"sid\":\"$sid\"" "$file" 2>/dev/null | jq -r '.ts' 2>/dev/null | sort)"
        first="$(printf '%s\n' "$span_ts" | head -1)"
        last="$(printf '%s\n' "$span_ts" | tail -1)"
        base="$(basename "${cwd:-unknown}")"
        stub="Technology_MGMT ?hr: [PENDING — narrative not written this session; reconcile] cwd=${base} prompts=${prompts} span=${first}..${last} [sid:$sid]"
        (
          exec 8>"$narr.lock" 2>/dev/null
          command -v flock >/dev/null 2>&1 && flock -w 5 8 2>/dev/null
          touch "$narr" 2>/dev/null
          # never glue onto a file that doesn't end in a newline (append-safe)
          if [ -s "$narr" ] && [ "$(tail -c1 "$narr" 2>/dev/null | wc -l)" -eq 0 ]; then printf '\n' >> "$narr"; fi
          last_head="$(grep '^## ' "$narr" 2>/dev/null | tail -1)"
          [ "$last_head" = "## $ymd" ] || printf '\n## %s\n' "$ymd" >> "$narr"
          printf '%s\n' "$stub" >> "$narr"
        ) 2>/dev/null || true
      fi
    fi
  fi
} 2>/dev/null || true

exit 0
