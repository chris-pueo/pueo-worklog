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
# SessionEnd TIME FLOOR: the narrative line is a MANUAL end-of-session step; a session that
# ends via /clear, context exhaustion or a closed terminal loses its billable description
# (the clock survives, the narrative does not). On SessionEnd we call wl_ensure_time_stub to
# auto-write a PENDING [sid:] stub if the session had activity and was never described — so
# the gap is VISIBLE (reconcile-narrative.sh) instead of silently lost. The Stop-hook forcing
# function (session-obligations.sh) handles the conditional ClickUp/Obsidian obligations.
#
# stdout-silent (a UserPromptSubmit hook's stdout is injected into the model context on
# exit 0 — this writes ONLY to the ndjson/narrative). .prompt is never read (no prompt text logged).
# Fail-safe: swallows all errors, always exits 0 — never disrupt a Claude session.
# Requires: jq (recommended). Without jq it stores the raw payload defensively.

{
  payload="$(cat)"
  [ -z "$payload" ] && exit 0

  repo="${PUEO_WORKLOG_REPO:-$HOME/git/pueo-worklog}"
  # shellcheck source=lib-worklog.sh
  [ -f "$repo/bin/lib-worklog.sh" ] && . "$repo/bin/lib-worklog.sh" 2>/dev/null || true

  raw_dir="$repo/raw"
  if [ ! -d "$raw_dir" ]; then raw_dir="$HOME/.claude/worklog"; fi
  mkdir -p "$raw_dir" 2>/dev/null || true

  host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
  now="$(date +%Y-%m-%dT%H:%M:%S%z)"   # LOCAL time + offset (see header)
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

  # --- SessionEnd TIME floor (auto-stub if undescribed) ----------------------------------
  if [ "$event" = "SessionEnd" ] && [ -n "$sid" ] && command -v jq >/dev/null 2>&1; then
    if type wl_ensure_time_stub >/dev/null 2>&1; then
      # only stub sessions that actually did something (>=1 prompt this month for the sid)
      _p="$(grep -F "\"sid\":\"$sid\"" "$file" 2>/dev/null | grep -cF '"event":"UserPromptSubmit"')"
      [ "${_p:-0}" -ge 1 ] && wl_ensure_time_stub "$sid" "$cwd"
    fi
  fi
} 2>/dev/null || true

exit 0
