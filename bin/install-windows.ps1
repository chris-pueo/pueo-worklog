#!/usr/bin/env pwsh
# install-windows.ps1 - wire THIS Windows box into the pueo-worklog system (mirror of
# install-linux.sh). Idempotent. Run from PowerShell 7. Requires git auth to the repo.
#
#   pwsh -NoProfile -File "$HOME\git\pueo-worklog\bin\install-windows.ps1"
#
# Does: (1) merge SessionStart/SessionEnd + UserPromptSubmit hooks into ~/.claude/settings.json
# (backs up first), pointing them AT THE REPO bin\claude-worklog-hook.ps1 so `git pull` auto-updates
# the hook (parity with Linux - no hand-placed copy to drift); (2) register the hourly
# ClaudeWorklogPulse scheduled task -> bin\pulse.ps1 (at :30, staggered off the Linux :00 cron);
# (3) set repo git config for linear pulls. Reversible: drop the hooks block + Unregister-ScheduledTask.

$ErrorActionPreference = 'Stop'
$repo = Join-Path $env:USERPROFILE 'git\pueo-worklog'
if (-not (Test-Path (Join-Path $repo '.git'))) { Write-Error "Repo not found at $repo (clone it first)"; exit 1 }
$hook  = Join-Path $repo 'bin\claude-worklog-hook.ps1'
$pulse = Join-Path $repo 'bin\pulse.ps1'
$cmd   = 'pwsh -NoProfile -File "{0}"' -f $hook

# 1. settings.json hooks (point AT the repo hook; back up first)
$claudeDir = Join-Path $env:USERPROFILE '.claude'
New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
$sf = Join-Path $claudeDir 'settings.json'
if (Test-Path $sf) { Copy-Item $sf ("{0}.bak.{1}" -f $sf, (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')) }
$h = if (Test-Path $sf) { Get-Content $sf -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
if (-not $h.ContainsKey('hooks') -or $null -eq $h.hooks) { $h['hooks'] = @{} }
$h.hooks.SessionStart     = @(@{ hooks = @(@{ type = 'command'; command = $cmd; timeout = 15 }) })
$h.hooks.SessionEnd       = @(@{ hooks = @(@{ type = 'command'; command = $cmd; timeout = 15 }) })
$h.hooks.UserPromptSubmit = @(@{ hooks = @(@{ type = 'command'; command = $cmd; timeout = 10 }) })
($h | ConvertTo-Json -Depth 12) | Set-Content -Path $sf -Encoding utf8
Write-Host ("settings.json hooks -> {0}" -f ($h.hooks.Keys -join ', '))

# 2. hourly scheduled task -> pulse.ps1 (staggered at :30 vs the Linux :00 cron)
$action  = New-ScheduledTaskAction -Execute 'pwsh' -Argument ('-NoProfile -WindowStyle Hidden -File "{0}"' -f $pulse)
$at      = Get-Date -Hour 0 -Minute 30 -Second 0
$trigger = New-ScheduledTaskTrigger -Once -At $at -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration ([TimeSpan]::FromDays(3650))
$set     = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'ClaudeWorklogPulse' -Action $action -Trigger $trigger -Settings $set -Description 'Hourly Pueo worklog clock sync + today-pulse (pueo-worklog/bin/pulse.ps1)' -Force | Out-Null
Write-Host "ClaudeWorklogPulse task registered (hourly @ :30)"

# 3. repo git config (linear pulls; matches install-linux.sh)
git -C $repo config pull.rebase true
git -C $repo config rebase.autoStash true

Write-Host ("DONE. New Claude Code sessions on {0} capture clock + heartbeat; pulse pushes hourly." -f $env:COMPUTERNAME)
Write-Host "Verify:  pwsh -File `"$repo\bin\doctor.ps1`""
