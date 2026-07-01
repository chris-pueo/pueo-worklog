#!/usr/bin/env pwsh
# doctor.ps1 - read-only health check of the worklog pipeline (mirror of doctor.sh).
# Per host (current month): newest record ts, newest ts PER event-type (a never-seen
# UserPromptSubmit stream = heartbeat not enabled), push age; plus this box's hook wiring +
# scheduled task. Freshness is derived from the MAX raw ts (format-independent), in UTC.
# /timecard runs this at step 1 and folds the flags into its step-8 report. No writes, exit 0.

$ErrorActionPreference = 'SilentlyContinue'
$repo = Join-Path $env:USERPROFILE 'git\pueo-worklog'
$ym   = (Get-Date).ToString('yyyy-MM')
$nowU = (Get-Date).ToUniversalTime()
# ConvertFrom-Json yields ts as a Kind=Utc DateTime; use it directly (re-Parse drops the Kind -> +offset bug).
function ToUtc($v) { if ($v -is [datetime]) { $v.ToUniversalTime() } else { ([datetimeoffset]$v).UtcDateTime } }
Write-Output ("# worklog doctor - {0} (UTC)" -f $nowU.ToString('yyyy-MM-ddTHH:mmZ'))

Get-ChildItem (Join-Path $repo 'raw') -Filter ("*-{0}.ndjson" -f $ym) -ErrorAction SilentlyContinue | ForEach-Object {
    $host_ = ($_.BaseName -replace '-\d{4}-\d{2}$', '')
    $ev = @{}; $maxAll = $null
    Get-Content $_.FullName | Where-Object { $_ } | ForEach-Object {
        try { $r = $_ | ConvertFrom-Json } catch { return }
        if (-not $r.ts) { return }
        $t = ToUtc $r.ts
        if ($null -eq $maxAll -or $t -gt $maxAll) { $maxAll = $t }
        if ($r.event) { if ($null -eq $ev[$r.event] -or $t -gt $ev[$r.event]) { $ev[$r.event] = $t } }
    }
    Write-Output ""
    Write-Output ("## {0}   ({1})" -f $host_, $_.Name)
    if ($maxAll) {
        $ageH  = [math]::Round(($nowU - $maxAll).TotalHours, 1)
        $stale = if ($ageH -gt 2) { "   [STALE >2h]" } else { "" }
        $hbTxt = if ($ev['UserPromptSubmit']) { $ev['UserPromptSubmit'].ToString('MM-dd HH:mmZ') } else { "[NONE - heartbeat not enabled; re-run installer]" }
        Write-Output ("   last record:           {0}  ({1}h ago){2}" -f $maxAll.ToString('MM-dd HH:mmZ'), $ageH, $stale)
        Write-Output ("   last SessionStart:     {0}" -f $(if ($ev['SessionStart']) { $ev['SessionStart'].ToString('MM-dd HH:mmZ') } else { '(none)' }))
        Write-Output ("   last SessionEnd:       {0}" -f $(if ($ev['SessionEnd']) { $ev['SessionEnd'].ToString('MM-dd HH:mmZ') } else { '(none)' }))
        Write-Output ("   last UserPromptSubmit: {0}" -f $hbTxt)
        if ($ev['CAPTURE_ERROR_NO_JQ']) { Write-Output "   [!] CAPTURE_ERROR_NO_JQ records present - a jq-less host logged blind" }
    } else { Write-Output "   (no records this month)" }
}

Write-Output ""
Write-Output ("## this box ({0})" -f $env:COMPUTERNAME)
$sf = Join-Path $env:USERPROFILE '.claude\settings.json'
if (Test-Path $sf) {
    $keys = (Get-Content $sf -Raw | ConvertFrom-Json).hooks.PSObject.Properties.Name
    $miss = @('SessionStart', 'SessionEnd', 'UserPromptSubmit') | Where-Object { $_ -notin $keys }
    Write-Output ("   hooks wired: {0}{1}" -f ($keys -join ', '), $(if ($miss) { "   [MISSING: $($miss -join ', ')]" } else { "" }))
} else { Write-Output "   [!] no ~/.claude/settings.json" }
$task = Get-ScheduledTask -TaskName 'ClaudeWorklogPulse' -ErrorAction SilentlyContinue
Write-Output ("   ClaudeWorklogPulse task: {0}" -f $(if ($task) { $task.State } else { '[NOT REGISTERED]' }))

# Stop-hook obligations forcing function: verify wired + script present. If MISSING, ALSO
# self-report to the committed ledger so 'enforcement off on host X' is visible team-side.
if (Test-Path $sf) {
    $stopcmd = $null
    try {
        $stopHooks = (Get-Content $sf -Raw | ConvertFrom-Json).hooks.Stop
        foreach ($grp in @($stopHooks)) {
            foreach ($hk in @($grp.hooks)) {
                if ($hk.command -and ($hk.command -match 'session-obligations\.ps1')) { $stopcmd = $hk.command; break }
            }
            if ($stopcmd) { break }
        }
    } catch { }
    $script = Join-Path $repo 'bin\session-obligations.ps1'
    if ($stopcmd -and (Test-Path $script)) {
        $ver = ''
        $vm = Select-String -Path $script -Pattern '^\$?WL_OBLIG_VERSION\s*=' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($vm) { $m = [regex]::Match($vm.Line, '"([^"]+)"'); if ($m.Success) { $ver = $m.Groups[1].Value } }
        $mode = if ($env:PUEO_OBLIG_MODE) { $env:PUEO_OBLIG_MODE } else { 'remind' }
        Write-Output ("   obligations Stop hook: wired (v{0}, mode={1})" -f $(if ($ver) { $ver } else { '?' }), $mode)
    } else {
        Write-Output "   obligations Stop hook: [MISSING - run bin\install-windows.ps1 to enforce capture]"
        $obDir = Join-Path $repo 'obligations'
        if (-not (Test-Path $obDir)) { New-Item -ItemType Directory -Force -Path $obDir | Out-Null }
        $of  = Join-Path $obDir ("{0}-{1}.ndjson" -f $env:COMPUTERNAME, (Get-Date).ToString('yyyy-MM'))
        $now = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        $rec = [ordered]@{ ts = $now; host = $env:COMPUTERNAME; sid = '-'; cwd = '-'; obligation = 'ENFORCEMENT'; state = 'off'; source = 'doctor' }
        $enc = New-Object System.Text.UTF8Encoding $false
        try { [System.IO.File]::AppendAllText($of, ($rec | ConvertTo-Json -Compress) + "`n", $enc) } catch { }
    }
}
exit 0
