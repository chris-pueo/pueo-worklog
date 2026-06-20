# Wiring a Windows box into pueo-worklog

The Windows counterpart to `INSTALL-LINUX.md`. Goal: Claude Code sessions on a Windows box
auto-capture wall-clock + the per-prompt activity heartbeat, and an hourly scheduled task
pushes the clock + writes a glance-only `today-pulse.md`. `/timecard` (this primary box only)
consolidates everything into the Unanet rollups.

## What gets captured
- `SessionStart` / `SessionEnd` — session boundaries.
- **`UserPromptSubmit`** — a per-prompt activity heartbeat (since 2026-06-20); the signal
  `/timecard` clusters into real active time. All three reuse the same event-generic hook.

## Prerequisites
- **PowerShell 7** (`pwsh`) — the hooks + pulse + installer run under it.
- `git` with auth to `github.com/chris-pueo/pueo-worklog` (the repo cloned to
  `C:\Users\<you>\git\pueo-worklog`).
- Claude Code installed (reads `~/.claude/settings.json`).

## One-shot install / upgrade
```powershell
pwsh -NoProfile -File "$HOME\git\pueo-worklog\bin\install-windows.ps1"
```
**Idempotent** — re-run any time. It:
1. Backs up `~/.claude/settings.json`, then wires `SessionStart`/`SessionEnd` (timeout 15) +
   `UserPromptSubmit` (timeout 10) **pointing directly at the repo** `bin\claude-worklog-hook.ps1`
   — so `git pull` auto-updates the hook (parity with Linux; no hand-placed copy to drift).
3. Registers the hourly **`ClaudeWorklogPulse`** scheduled task → `bin\pulse.ps1` (at :30,
   staggered off the Linux :00 cron).
4. Sets repo `git config pull.rebase true` + `rebase.autoStash true`.

## Verify
```powershell
pwsh -File "$HOME\git\pueo-worklog\bin\doctor.ps1"          # health report (per-host clock, push age, hooks, task)
(Get-Content "$HOME\.claude\settings.json" | ConvertFrom-Json).hooks.PSObject.Properties.Name   # -> SessionStart, SessionEnd, UserPromptSubmit
Get-ScheduledTask ClaudeWorklogPulse                        # -> State Ready
# start a NEW Claude Code session, submit a prompt, then:
Get-Content "$HOME\git\pueo-worklog\raw\$env:COMPUTERNAME-$(Get-Date -Format yyyy-MM).ndjson" -Tail 1   # -> "event":"UserPromptSubmit"
```

## Notes / caveats
- **stdout MUST stay silent** in the hook (a `UserPromptSubmit` hook's stdout is injected into
  the model context on exit 0). The hook writes only to the ndjson. It runs synchronously
  before each prompt, so it must stay fast (local append, no network) — expect small latency.
- **No prompt text** is ever logged. Fail-safe: swallows errors, always exits 0.
- The hook is run **from the repo** (`bin\claude-worklog-hook.ps1`); a `git pull` updates it.
  Trade-off: if the repo is absent the hook is unresolvable and capture stops — but the repo is
  already a hard dependency (pulse + raw both need it).
- `/timecard` runs **only on this primary box** (it writes the OneDrive copy; `rollups/` is not
  machine-namespaced). Other boxes only capture + push.
- To remove: delete the `hooks` block from `~/.claude/settings.json` and
  `Unregister-ScheduledTask ClaudeWorklogPulse`.

## Change record
- **2026-06-20** — Windows install scripted + documented (was a manual hook copy + hand-made
  task). Hook now runs from the repo (eliminates the copy/drift). Part of the worklog-process scrub.
