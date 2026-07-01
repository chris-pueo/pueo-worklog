#!/usr/bin/env bash
# session-obligations.sh — Stop-hook FORCING FUNCTION for the Pueo capture obligations.
# WIRE ONLY to the "Stop" event (never SubagentStop — subagent turns live in a separate
# transcript and must not trigger a block). Invoke as:
#     bash --noprofile --norc <repo>/bin/session-obligations.sh
# so a chatty ~/.bashrc can't prepend noise to the decision:block JSON on stdout.
#
# WHAT IT DOES, per assistant turn (Stop fires once at the end of every turn):
#   TIME     — NEVER blocks. Auto-writes a PENDING [sid:] narrative stub (guaranteed floor)
#              if the session did work and was never described. (Same stub the SessionEnd
#              hook writes; shared via lib-worklog.sh.)
#   CLICKUP  — conditional. If the session did task-worthy PROJECT work and no ClickUp write
#              is seen in the transcript (and no NO-CLICKUP: marker), BLOCK once (fulfill-or-
#              justify). In remind mode, emit a soft reminder instead of blocking.
#   OBSIDIAN — conditional, tightened. Only when a KM/docs artifact was warranted (new .md,
#              ledger/ADR edit, or a docs/|runbooks/ path) and no vault write is seen.
#
# Blocks AT MOST ONCE per turn (guarded by stop_hook_active) — never loops. On the guard
# re-fire it records any still-unmet conditional obligation to the committed debt ledger
# (obligations/<host>-YYYY-MM.ndjson) so nothing is silently lost.
#
# Fail-OPEN by design (missing jq/transcript, parse error -> exit 0): under-enforce rather
# than ever wedge a session. Kill switches: PUEO_OBLIG=0 (all off), PUEO_OBLIG_CLICKUP=0,
# PUEO_OBLIG_KM=0; per-repo opt-out file $CWD/.no-obligations; mode PUEO_OBLIG_MODE=block|remind.
WL_OBLIG_VERSION="1.0.0"

{
  payload="$(cat)"
  [ -z "$payload" ] && exit 0
  command -v jq >/dev/null 2>&1 || exit 0                 # fail-open
  [ "${PUEO_OBLIG:-1}" = "0" ] && exit 0                  # global kill switch

  repo="${PUEO_WORKLOG_REPO:-$HOME/git/pueo-worklog}"
  [ -f "$repo/bin/lib-worklog.sh" ] && . "$repo/bin/lib-worklog.sh" 2>/dev/null || true
  mode="${PUEO_OBLIG_MODE:-remind}"                       # block | remind (soak default)

  sid="$(printf '%s' "$payload"  | jq -r '.session_id // empty' 2>/dev/null)"
  cwd="$(printf '%s' "$payload"  | jq -r '.cwd // empty' 2>/dev/null)"
  tx="$(printf '%s'  "$payload"  | jq -r '.transcript_path // empty' 2>/dev/null)"
  active="$(printf '%s' "$payload" | jq -r '.stop_hook_active // false' 2>/dev/null)"
  [ -n "$sid" ] || exit 0

  # per-repo opt-out
  [ -n "$cwd" ] && [ -f "$cwd/.no-obligations" ] && exit 0

  # resolve the transcript (slug fallback: cwd with / -> - , then ~/.claude/projects/<slug>/<sid>.jsonl)
  if [ -z "$tx" ] || [ ! -f "$tx" ]; then
    slug="$(printf '%s' "$cwd" | sed 's#/#-#g')"
    tx="$HOME/.claude/projects/${slug}/${sid}.jsonl"
  fi
  [ -f "$tx" ] || exit 0                                  # can't inspect -> fail open

  # ---- ONE jq pass: tab-separated tagged lines (tabs/newlines stripped from fields) ----
  data="$(jq -r '
    select(.type=="assistant" and (.isSidechain!=true)) | .message.content[]? |
    if .type=="tool_use" then
      "T\t" + .name
        + "\t" + ((.input.file_path // "")|tostring|gsub("[\t\n]";" "))
        + "\t" + ((.input.command   // "")|tostring|gsub("[\t\n]";" "))
    elif .type=="text" then "X\t" + (.text|gsub("[\t\n]";" "))
    else empty end' "$tx" 2>/dev/null)"
  [ -n "$data" ] || exit 0

  tools="$(printf '%s\n' "$data" | grep '^T')"
  text="$( printf '%s\n' "$data" | grep '^X')"
  names="$( printf '%s\n' "$tools" | cut -f2)"
  fpaths="$(printf '%s\n' "$tools" | awk -F'\t' '$3!="" {print $3}')"
  cmds="$(  printf '%s\n' "$tools" | awk -F'\t' '$4!="" {print $4}')"

  # ---- substantive-work classification ----
  edits=$(  printf '%s\n' "$names" | grep -cE '^(Edit|Write|MultiEdit)$')
  bashn=$(  printf '%s\n' "$names" | grep -cxF 'Bash')
  nonread=$(printf '%s\n' "$names" | grep -cvE '^(Read|Glob|Grep|TodoWrite|AskUserQuestion|Task|Agent|Workflow|ToolSearch)$')
  deploy=0; printf '%s\n' "$cmds" | grep -qE 'ansible-playbook|terraform apply|kubectl apply|docker stack deploy|systemctl (restart|start|stop)|(^| )git push' && deploy=1
  substantive=0
  { [ "$edits" -ge 1 ] || [ "$bashn" -ge 2 ] || [ "$nonread" -ge 3 ] || [ "$deploy" = 1 ]; } && substantive=1
  [ "$substantive" = 1 ] || exit 0

  # ---- TIME floor (never blocks) ----
  type wl_ensure_time_stub >/dev/null 2>&1 && wl_ensure_time_stub "$sid" "$cwd"

  # ---- detectors ----
  cu_seen=0
  { printf '%s\n' "$names" | grep -qE '^mcp__.*[Cc]lick[Uu]p.*clickup_(create|update|delete|move|merge|add|remove|attach|start|stop)' \
    || printf '%s\n' "$cmds" | grep -q 'api\.clickup\.com'; } && cu_seen=1

  km_pat='[\\/](pueo-km-vault|vaults)[\\/]'
  [ -n "${PUEO_VAULT_ROOT:-}" ] && km_pat="$km_pat|$(printf '%s' "$PUEO_VAULT_ROOT" | sed 's/[][\\.*^$/(){}+?|]/\\&/g')"
  km_seen=0; printf '%s\n' "$fpaths" "$cmds" | grep -qiE "$km_pat" && km_seen=1

  cu_mark=0; printf '%s\n' "$text" | grep -qiE 'NO[- ]CLICKUP'            && cu_mark=1
  km_mark=0; printf '%s\n' "$text" | grep -qiE 'NO[- ](KM|OBSIDIAN)'      && km_mark=1

  # ---- warrant ----
  # project edits = Edit/Write/MultiEdit to a path NOT under the worklog repo or ~/.claude self-bookkeeping
  proj_edits="$(printf '%s\n' "$tools" | awk -F'\t' '$2 ~ /^(Edit|Write|MultiEdit)$/ && $3!="" {print $3}' | grep -vE 'pueo-worklog|/\.claude/')"
  proj_edit_n=$(printf '%s\n' "$proj_edits" | grep -c .)
  cu_warrant=0; { [ "$proj_edit_n" -ge 1 ] || [ "$deploy" = 1 ]; } && cu_warrant=1

  km_warrant=0
  if printf '%s\n' "$proj_edits" | grep -qiE '(/docs/|/runbooks/|decisions\.md|changelog\.md|CHANGELOG|/ADR|ADR-|\.adr$)'; then
    km_warrant=1
  elif printf '%s\n' "$tools" | awk -F'\t' '$2=="Write" && $3!="" {print $3}' | grep -vE 'pueo-worklog|/\.claude/' | grep -qiE '\.md$'; then
    km_warrant=1
  fi

  # compute unmet conditional obligations (honoring kill switches + markers + detectors)
  unmet=""
  [ "${PUEO_OBLIG_CLICKUP:-1}" != "0" ] && [ "$cu_warrant" = 1 ] && [ "$cu_seen" = 0 ] && [ "$cu_mark" = 0 ] && unmet="$unmet CLICKUP"
  [ "${PUEO_OBLIG_KM:-1}"      != "0" ] && [ "$km_warrant" = 1 ] && [ "$km_seen" = 0 ] && [ "$km_mark" = 0 ] && unmet="$unmet OBSIDIAN"
  unmet="$(printf '%s' "$unmet" | sed 's/^ //')"

  # ---- guard re-fire: never block twice; record still-unmet debt, then allow the stop ----
  if [ "$active" = "true" ]; then
    if [ -n "$unmet" ] && type wl_append_debt >/dev/null 2>&1; then
      for ob in $unmet; do wl_append_debt "$sid" "$cwd" "$ob" "stop-guard"; done
    fi
    exit 0
  fi

  [ -z "$unmet" ] && exit 0

  # ---- first firing: block once (block mode) or soft-remind (soak mode) ----
  human=""; for ob in $unmet; do human="$human ${ob}"; done; human="$(printf '%s' "$human" | sed 's/^ //')"
  sysmsg="[obligations] unmet: ${human} (session did work but no matching update was recorded)"
  reason="SESSION OBLIGATIONS — before this session ends, ${human} still needs an on-the-record update. "
  case " $unmet " in
    *" CLICKUP "*) reason="${reason}CLICKUP: update the relevant ClickUp task now (status/comment/CHG link), assigned to yourself; or, if genuinely not warranted, write \`NO-CLICKUP: <one-line reason>\` in your reply. " ;;
  esac
  case " $unmet " in
    *" OBSIDIAN "*) reason="${reason}OBSIDIAN: capture the change in the KM vault (or the appropriate docs/runbook/ADR/changelog); or write \`NO-KM: <one-line reason>\` if the change carries no durable knowledge. " ;;
  esac
  reason="${reason}(This check runs once per turn; do the update or state the NO-* justification and you'll stop cleanly.)"

  if [ "$mode" = "block" ]; then
    jq -cn --arg r "$reason" --arg s "$sysmsg" '{decision:"block", reason:$r, systemMessage:$s, suppressOutput:true}'
  else
    jq -cn --arg s "$sysmsg  [reminder-only soak; set PUEO_OBLIG_MODE=block to enforce]" '{systemMessage:$s, suppressOutput:true}'
  fi
  exit 0
} 2>/dev/null || exit 0
