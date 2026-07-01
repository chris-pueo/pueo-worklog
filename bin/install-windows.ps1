#!/usr/bin/env pwsh
# install-windows.ps1 - wire THIS Windows box into the pueo-worklog system (mirror of
# install-linux.sh). Idempotent. Run from PowerShell 7. Requires git auth to the repo.
#
#   pwsh -NoProfile -File "$HOME\git\pueo-worklog\bin\install-windows.ps1"
#
# Does: (1) APPEND-AND-DEDUPE merge of SessionStart/SessionEnd + UserPromptSubmit + Stop hooks
# into ~/.claude/settings.json (backs up first) - NEVER clobbers a teammate's existing hooks;
# points the clock hooks AT THE REPO bin\claude-worklog-hook.ps1 and the Stop hook AT THE REPO
# bin\session-obligations.ps1 so `git pull` auto-updates them (parity with Linux - no hand-placed
# copy to drift); (2) register the hourly ClaudeWorklogPulse scheduled task -> bin\pulse.ps1
# (at :30, staggered off the Linux :00 cron); (3) ensure the obligations\ ledger dir exists;
# (4) set repo git config for linear pulls. Reversible: drop the hooks block + Unregister-ScheduledTask.

$ErrorActionPreference = 'Stop'
$repo = Join-Path $env:USERPROFILE 'git\pueo-worklog'
if (-not (Test-Path (Join-Path $repo '.git'))) { Write-Error "Repo not found at $repo (clone it first)"; exit 1 }
$hook  = Join-Path $repo 'bin\claude-worklog-hook.ps1'
$oblig = Join-Path $repo 'bin\session-obligations.ps1'
$pulse = Join-Path $repo 'bin\pulse.ps1'
$wlcmd = 'pwsh -NoProfile -File "{0}"' -f $hook
# Stop hook runs -NoProfile so a chatty profile can't corrupt the decision JSON on stdout.
$obcmd = 'pwsh -NoProfile -File "{0}"' -f $oblig

# 1. settings.json hooks — APPEND-AND-DEDUPE (mirror install-linux.sh's jq clean/upsert).
#    For each event: keep every existing group, but strip only OUR prior entry (matched by
#    script basename in the command), drop groups left with no hooks, then append ours.
#    Never assign the whole array (that clobbers a teammate's hooks).
$claudeDir = Join-Path $env:USERPROFILE '.claude'
New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
$sf = Join-Path $claudeDir 'settings.json'
if (Test-Path $sf) { Copy-Item $sf ("{0}.bak.{1}" -f $sf, (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')) }
$h = if (Test-Path $sf) { Get-Content $sf -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
if ($null -eq $h) { $h = @{} }
if (-not $h.ContainsKey('hooks') -or $null -eq $h.hooks) { $h['hooks'] = @{} }

function Get-CmdString($entry) {
    # An entry command may be a string or (defensively) something else; coerce to string.
    if ($null -eq $entry) { return '' }
    if ($entry.ContainsKey('command')) { return [string]$entry['command'] }
    return ''
}

function Upsert-Hook {
    param(
        [hashtable]$Hooks,   # the .hooks hashtable (mutated in place)
        [string]$Event,      # e.g. 'SessionStart'
        [string]$Key,        # script basename to match OUR prior entry, e.g. 'claude-worklog-hook.ps1'
        [string]$Cmd,        # full command to install
        [int]$Timeout
    )
    # existing groups for this event (may be absent)
    $existing = @()
    if ($Hooks.ContainsKey($Event) -and $null -ne $Hooks[$Event]) { $existing = @($Hooks[$Event]) }

    $cleaned = New-Object System.Collections.ArrayList
    foreach ($group in $existing) {
        # each group is @{ hooks = @(@{ type=...; command=...; timeout=... }, ...) }
        $groupHooks = @()
        if ($group -and $group.ContainsKey('hooks') -and $null -ne $group['hooks']) { $groupHooks = @($group['hooks']) }
        $kept = New-Object System.Collections.ArrayList
        foreach ($entry in $groupHooks) {
            $c = Get-CmdString $entry
            if (-not ($c.Contains($Key))) { [void]$kept.Add($entry) }   # strip only OUR prior entry
        }
        if ($kept.Count -gt 0) {
            $group['hooks'] = @($kept)
            [void]$cleaned.Add($group)                                   # drop groups left empty
        }
    }
    # append our fresh group
    [void]$cleaned.Add(@{ hooks = @(@{ type = 'command'; command = $Cmd; timeout = $Timeout }) })
    $Hooks[$Event] = @($cleaned)
}

Upsert-Hook -Hooks $h.hooks -Event 'SessionStart'     -Key 'claude-worklog-hook.ps1' -Cmd $wlcmd -Timeout 15
Upsert-Hook -Hooks $h.hooks -Event 'SessionEnd'       -Key 'claude-worklog-hook.ps1' -Cmd $wlcmd -Timeout 15
Upsert-Hook -Hooks $h.hooks -Event 'UserPromptSubmit' -Key 'claude-worklog-hook.ps1' -Cmd $wlcmd -Timeout 10
Upsert-Hook -Hooks $h.hooks -Event 'Stop'             -Key 'session-obligations.ps1' -Cmd $obcmd -Timeout 30

# BOM-less UTF-8 on BOTH PowerShell 7 and Windows PowerShell 5.1 (Set-Content -Encoding utf8
# emits a BOM on 5.1, which can break the CLI's settings.json parse) — write via .NET.
$json = ($h | ConvertTo-Json -Depth 12)
[System.IO.File]::WriteAllText($sf, $json, (New-Object System.Text.UTF8Encoding $false))
Write-Host ("settings.json hooks -> {0}" -f (($h.hooks.Keys | Sort-Object) -join ', '))
# NOTE: Stop-hook obligations default to PUEO_OBLIG_MODE=remind (soft, non-blocking soak).
# Set PUEO_OBLIG_MODE=block in your env to enforce; PUEO_OBLIG=0 disables entirely.

# 2. hourly scheduled task -> pulse.ps1 (staggered at :30 vs the Linux :00 cron)
$action  = New-ScheduledTaskAction -Execute 'pwsh' -Argument ('-NoProfile -WindowStyle Hidden -File "{0}"' -f $pulse)
$at      = Get-Date -Hour 0 -Minute 30 -Second 0
$trigger = New-ScheduledTaskTrigger -Once -At $at -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration ([TimeSpan]::FromDays(3650))
$set     = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'ClaudeWorklogPulse' -Action $action -Trigger $trigger -Settings $set -Description 'Hourly Pueo worklog clock sync + today-pulse (pueo-worklog/bin/pulse.ps1)' -Force | Out-Null
Write-Host "ClaudeWorklogPulse task registered (hourly @ :30)"

# 3. ensure the obligations ledger dir exists (unmet ClickUp/Obsidian/TIME debts land here;
#    it is committed by pulse.ps1 so nothing is silently lost). Mirror install-linux.sh mkdir.
New-Item -ItemType Directory -Force -Path (Join-Path $repo 'obligations') | Out-Null

# 4. repo git config (linear pulls; matches install-linux.sh)
git -C $repo config pull.rebase true
git -C $repo config rebase.autoStash true

Write-Host ("DONE. New Claude Code sessions on {0} capture clock + heartbeat + obligations; pulse pushes hourly." -f $env:COMPUTERNAME)
Write-Host "Verify:  pwsh -File `"$repo\bin\doctor.ps1`""
