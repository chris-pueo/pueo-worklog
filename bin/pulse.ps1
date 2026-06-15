# pulse.ps1 — hourly DETERMINISTIC "pulse" of today's Claude time. No model, no tokens.
# (1) syncs the repo (pull others' clock, push this machine's raw), (2) computes today's
# DISTINCT wall-clock (union of session intervals — parallel sessions are NOT double-counted),
# (3) writes a quick summary to OneDrive\Claude\timekeeping\today-pulse.md.
#
# This is a pulse, not the timecard: hours are wall-clock session spans (approximate),
# charge code defaults to Technology_MGMT, and there is no narrative. The rich rollups
# come from the /timecard skill. Fail-safe: swallows errors, exits 0.

try {
    $repo = Join-Path $env:USERPROFILE 'git\pueo-worklog'
    Set-Location $repo

    # --- sync: get other machines, push ours ---
    git pull --rebase --autostash --quiet 2>$null
    git add raw/ 2>$null | Out-Null
    if (git diff --cached --name-only 2>$null) {
        $msg = "pulse: {0} clock sync {1}" -f $env:COMPUTERNAME, (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mmZ')
        git -c user.name=chris -c user.email=chris@pueo.com commit -m $msg --quiet 2>$null
        git push --quiet 2>$null
    }

    # --- load this month's events across all machines ---
    $ym = (Get-Date).ToString('yyyy-MM')
    $events = @()
    Get-ChildItem (Join-Path $repo 'raw') -Filter ("*-{0}.ndjson" -f $ym) -ErrorAction SilentlyContinue | ForEach-Object {
        Get-Content $_.FullName | Where-Object { $_ } | ForEach-Object { try { $events += ($_ | ConvertFrom-Json) } catch {} }
    }

    # --- build active segments per session (pair Start->End; open => now) ---
    $today = (Get-Date).Date
    $now   = Get-Date
    $segs  = New-Object System.Collections.ArrayList
    foreach ($g in ($events | Where-Object { $_.sid } | Group-Object sid)) {
        $evs = $g.Group | Sort-Object { [datetime]::Parse($_.ts) }
        $open = $null; $repoName = '(unknown)'
        foreach ($e in $evs) {
            $t = [datetime]::Parse($e.ts).ToLocalTime()
            if ($e.cwd) { $repoName = Split-Path $e.cwd -Leaf }
            if ($e.event -eq 'SessionStart') { if ($null -eq $open) { $open = $t; $segRepo = $repoName } }
            elseif ($e.event -eq 'SessionEnd') { if ($open) { [void]$segs.Add([pscustomobject]@{ start=$open; end=$t; repo=$segRepo }); $open = $null } }
        }
        if ($open) { [void]$segs.Add([pscustomobject]@{ start=$open; end=$now; repo=$segRepo }) }  # in-progress
    }

    # today only
    $todaySegs = @($segs | Where-Object { $_.start.Date -eq $today -and $_.end -gt $_.start })

    function Union-Hours($list) {
        $s = @($list | Sort-Object start); if ($s.Count -eq 0) { return 0.0 }
        $tot = 0.0; $cs = $s[0].start; $ce = $s[0].end
        for ($i=1; $i -lt $s.Count; $i++) {
            if ($s[$i].start -le $ce) { if ($s[$i].end -gt $ce) { $ce = $s[$i].end } }
            else { $tot += ($ce - $cs).TotalHours; $cs = $s[$i].start; $ce = $s[$i].end }
        }
        $tot += ($ce - $cs).TotalHours; return $tot
    }
    function R025($h) { [math]::Round($h * 4) / 4 }

    $totalDistinct = Union-Hours $todaySegs

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# Today's pulse — $($today.ToString('ddd yyyy-MM-dd'))")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("_Auto / deterministic clock. Updated $($now.ToString('HH:mm')) local. Default code Technology_MGMT._")
    [void]$sb.AppendLine("_Distinct = union of session intervals (parallel sessions not double-counted). Wall-clock, approximate — the timecard is the source of truth._")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## Distinct time today: **$(R025 $totalDistinct)hr**")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("### By repo (per-repo union; may overlap across repos when running in parallel)")
    $byRepo = $todaySegs | Group-Object repo | ForEach-Object {
        [pscustomobject]@{ repo = $_.Name; hrs = (Union-Hours $_.Group) }
    } | Sort-Object hrs -Descending
    if ($byRepo) { foreach ($r in $byRepo) { [void]$sb.AppendLine("- $(R025 $r.hrs)hr — $($r.repo)") } }
    else { [void]$sb.AppendLine("- (no sessions captured yet today)") }

    $out = Join-Path $env:USERPROFILE 'OneDrive - Pueo Business Solutions, LLC\Claude\timekeeping\today-pulse.md'
    Set-Content -Path $out -Value $sb.ToString() -Encoding utf8
}
catch { }
exit 0
