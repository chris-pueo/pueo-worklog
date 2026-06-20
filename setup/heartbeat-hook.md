# Worklog activity heartbeat — `UserPromptSubmit` hook

**Added 2026-06-20.** The worklog clock originally captured only `SessionStart` /
`SessionEnd`. Those mark *session lifecycle*, not *activity*, so they can't measure active
hours: a session left open inflates a Start→End span to ~24h, while a single long focused
session emits no event in between. The fix is a **`UserPromptSubmit`** hook — it fires once
per prompt, giving a real per-prompt **activity heartbeat**. `/timecard` clusters heartbeats
(bridge gaps ≤ 15 min, +2 min tail per burst) into distinct active wall-clock, unioned
across parallel sessions and across machines.

The hook **reuses the same worklog script** as SessionStart/End — that script records
`hook_event_name` generically, so heartbeats land as `{"event":"UserPromptSubmit",…}` lines
in the same `raw/<machine>-YYYY-MM.ndjson`. No new file, no change to the sync/push path.

## Caveats (both platforms — important)
- **stdout MUST be silent.** A `UserPromptSubmit` hook's stdout is injected into the model's
  context on exit 0. The script must write ONLY to the ndjson and print nothing.
- **Runs on every prompt, synchronously** → keep it fast (local file append only, no
  network) and give it a modest timeout. Expect a small per-prompt latency.
- **No prompt text.** The payload carries a `.prompt` field — do NOT capture it.
- **Fail-safe:** swallow all errors, always `exit 0`.

## Windows (`P25-FX28GG4`) — DONE 2026-06-20
- Script: `~/.claude/worklog/claude-worklog-hook.ps1` (canonical copy in this `setup/` dir).
- `~/.claude/settings.json` → `hooks.UserPromptSubmit` runs the same `pwsh` command as
  `SessionStart`/`SessionEnd` (timeout 10).

## Linux (`linprodans001`) — TO APPLY
1. `git -C ~/git/pueo-worklog pull --rebase --autostash` (gets this doc).
2. Open `~/.claude/settings.json` and find the worklog hook command already wired to
   `SessionStart`. Confirm the script it calls **(a)** records the event generically from
   the payload's `hook_event_name`, and **(b)** prints NOTHING to stdout (writes only to the
   ndjson). If it hardcodes the event name, generalize it; if it echoes anything, silence it.
3. Add a `UserPromptSubmit` entry to `hooks` pointing at that SAME command, ~10s timeout:
   ```json
   "UserPromptSubmit": [
     { "hooks": [ { "type": "command", "command": "<your existing worklog hook command>", "timeout": 10 } ] }
   ]
   ```
4. **Verify:** submit one prompt in any Claude Code session, then
   `tail -1 ~/git/pueo-worklog/raw/linprodans001-$(date -u +%Y-%m).ndjson` — you should see a
   line with `"event":"UserPromptSubmit"`. Confirm nothing odd was injected into the session
   (proves stdout is clean).
5. The hourly cron will push it (or push manually).

### Reference Linux hook — ONLY if you don't already have a generic worklog hook
A minimal POSIX equivalent of the Windows script: machine-namespaced, stdout-silent,
fail-safe. Wire it to `SessionStart`, `SessionEnd`, AND `UserPromptSubmit`. Requires `jq`.
```bash
#!/usr/bin/env bash
# claude-worklog-hook.sh — append-only worklog heartbeat. Silent on stdout. Always exit 0.
{
  raw="$(cat)"; [ -z "$raw" ] && exit 0
  host="$(hostname -s)"
  repo="$HOME/git/pueo-worklog/raw"
  dir="$repo"; [ -d "$repo" ] || dir="$HOME/.claude/worklog"; mkdir -p "$dir" 2>/dev/null
  file="$dir/${host}-$(date -u +%Y-%m).ndjson"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # .prompt is intentionally never read — no prompt text is logged.
  printf '%s' "$raw" | jq -c --arg ts "$ts" --arg host "$host" \
    '{ts:$ts,event:.hook_event_name,sid:.session_id,host:$host,cwd:.cwd,model:.model,title:.session_title,source:.source,reason:.reason}' \
    >> "$file"
} >/dev/null 2>&1
exit 0
```

## Change record
- **2026-06-20** — Added the `UserPromptSubmit` activity heartbeat to the worklog hook
  (Windows live; Linux per above). `/timecard` SKILL.md updated to cluster heartbeats into
  distinct active wall-clock as the primary hours source; per-session effort estimates
  demoted to the pre-heartbeat fallback. **Reversible:** drop the `UserPromptSubmit` block
  from `settings.json` on each box.
