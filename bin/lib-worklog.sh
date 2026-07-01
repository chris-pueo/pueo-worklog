#!/usr/bin/env bash
# lib-worklog.sh — shared helpers for the pueo-worklog hooks (sourced, not executed).
# Sourcing has NO side effects. Used by claude-worklog-hook.sh (SessionEnd time stub) and
# session-obligations.sh (Stop-hook forcing function) so the narrative/stub/debt formats are
# defined in exactly ONE place. All functions are fail-safe (never abort the caller).

wl_repo()          { echo "${PUEO_WORKLOG_REPO:-$HOME/git/pueo-worklog}"; }
wl_host()          { hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown; }
wl_narrative_dir() { local r; r="$(wl_repo)"; if [ -d "$r/narrative" ]; then echo "$r/narrative"; else echo "$HOME/.claude/worklog"; fi; }
wl_raw_dir()       { local r; r="$(wl_repo)"; if [ -d "$r/raw" ];       then echo "$r/raw";       else echo "$HOME/.claude/worklog"; fi; }
wl_oblig_dir()     { local r; r="$(wl_repo)"; if [ -d "$r/obligations" ]; then echo "$r/obligations"; else echo "$HOME/.claude/worklog"; fi; }
wl_narrative_file(){ echo "$(wl_narrative_dir)/$(wl_host)-$(date +%Y-%m).md"; }
wl_raw_file()      { echo "$(wl_raw_dir)/$(wl_host)-$(date +%Y-%m).ndjson"; }
wl_oblig_file()    { echo "$(wl_oblig_dir)/$(wl_host)-$(date +%Y-%m).ndjson"; }

# The literal PENDING-stub prefix. Match this exact string to tell a stub from a real line —
# NEVER the bare word "PENDING" (a real narrative line may legitimately contain it).
WL_STUB_PREFIX='?hr: [PENDING —'

# wl_time_met SID  -> 0 if a REAL (non-stub) narrative line tagged [sid:SID] exists.
wl_time_met() {
  local sid="$1" narr; narr="$(wl_narrative_file)"
  [ -f "$narr" ] || return 1
  grep -F "[sid:$sid]" "$narr" 2>/dev/null | grep -vqF "$WL_STUB_PREFIX"
}

# wl_has_stub SID  -> 0 if a PENDING stub line tagged [sid:SID] already exists.
wl_has_stub() {
  local sid="$1" narr; narr="$(wl_narrative_file)"
  [ -f "$narr" ] || return 1
  grep -F "[sid:$sid]" "$narr" 2>/dev/null | grep -qF "$WL_STUB_PREFIX"
}

# wl_ensure_time_stub SID CWD  -> writes a PENDING stub under today's heading iff there is no
# real line AND no stub yet for SID. prompts/span derived from this month's raw. Append-safe
# (guarantees a trailing newline) and flock-guarded for concurrent sessions. Never duplicates.
wl_ensure_time_stub() {
  local sid="$1" cwd="$2"
  [ -n "$sid" ] || return 0
  wl_time_met "$sid" && return 0
  wl_has_stub  "$sid" && return 0
  local narr raw ymd base prompts span first last stub
  narr="$(wl_narrative_file)"; raw="$(wl_raw_file)"; ymd="$(date +%Y-%m-%d)"
  base="$(basename "${cwd:-unknown}")"; prompts="?"; first=""; last=""
  if command -v jq >/dev/null 2>&1 && [ -f "$raw" ]; then
    prompts="$(grep -F "\"sid\":\"$sid\"" "$raw" 2>/dev/null | grep -cF '"event":"UserPromptSubmit"')"
    span="$(grep -F "\"sid\":\"$sid\"" "$raw" 2>/dev/null | jq -r '.ts' 2>/dev/null | sort)"
    first="$(printf '%s\n' "$span" | head -1)"; last="$(printf '%s\n' "$span" | tail -1)"
  fi
  stub="Technology_MGMT ${WL_STUB_PREFIX} narrative not written this session; reconcile] cwd=${base} prompts=${prompts:-?} span=${first}..${last} [sid:$sid]"
  (
    exec 8>"$narr.lock" 2>/dev/null
    command -v flock >/dev/null 2>&1 && flock -w 5 8 2>/dev/null
    touch "$narr" 2>/dev/null
    if [ -s "$narr" ] && [ "$(tail -c1 "$narr" 2>/dev/null | wc -l)" -eq 0 ]; then printf '\n' >> "$narr"; fi
    local last_head; last_head="$(grep '^## ' "$narr" 2>/dev/null | tail -1)"
    [ "$last_head" = "## $ymd" ] || printf '\n## %s\n' "$ymd" >> "$narr"
    printf '%s\n' "$stub" >> "$narr"
  ) 2>/dev/null || true
}

# wl_append_debt SID CWD OBLIGATION SOURCE  -> append one unmet-obligation record to the ledger.
# Idempotent per (sid,obligation): skip if an unresolved record for this pair already exists.
wl_append_debt() {
  local sid="$1" cwd="$2" ob="$3" src="${4:-unknown}" f now
  [ -n "$sid" ] && [ -n "$ob" ] || return 0
  f="$(wl_oblig_file)"; now="$(date +%Y-%m-%dT%H:%M:%S%z)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  # already recorded (unresolved) for this sid+obligation? then don't duplicate.
  if [ -f "$f" ] && grep -F "\"sid\":\"$sid\"" "$f" 2>/dev/null | grep -F "\"obligation\":\"$ob\"" | grep -qvF '"resolved":true'; then
    return 0
  fi
  (
    exec 9>"$f.lock" 2>/dev/null
    command -v flock >/dev/null 2>&1 && flock -w 5 9 2>/dev/null
    printf '{"ts":"%s","host":"%s","sid":"%s","cwd":"%s","obligation":"%s","state":"unmet","source":"%s"}\n' \
      "$now" "$(wl_host)" "$sid" "${cwd:-}" "$ob" "$src" >> "$f"
  ) 2>/dev/null || true
}
