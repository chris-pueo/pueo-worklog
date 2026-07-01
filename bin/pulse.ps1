# pulse.ps1 — hourly DETERMINISTIC "pulse" of today's Claude ACTIVE time. No model, no tokens.
# (1) syncs the repo (pull others' clock, push this machine's raw, with bounded push-retry),
# (2) computes today's ACTIVE wall-clock with the SAME heartbeat-clustering method as /timecard
#     (UserPromptSubmit heartbeats, IDLE=15min/TAIL=2min, distinct union pooled across machines),
# (3) writes a quick summary to OneDrive\Claude\timekeeping\today-pulse.md.
#
# Glance-only, NOT the timecard: shows MEASURED ACTIVE time and EXCLUDES autonomous/agent
# runtime (no heartbeats fire while you are away). Billing source of truth = /timecard
# (heartbeat-active + the blend policy). Charge code defaults to Technology_MGMT.
# Fallback: if a day has zero heartbeats anywhere (e.g. a box not yet on the heartbeat hook),
# it falls back to APPROXIMATE lifecycle spans, clearly labeled, with an open-session guard.
# Fail-safe: swallows errors, exits 0.

$ErrorActionPreference = 'SilentlyContinue'
try {
    $repo = Join-Path $env:USERPROFILE 'git\pueo-worklog'
    Set-Location $repo

    # --- sync: pull others, push ours, bounded retry on non-fast-forward ---
    # Stage raw/ (clock ndjson) AND obligations/ (unmet ClickUp/Obsidian/TIME debt ledger).
    # NOT narrative/ — on Windows the narrative lives in OneDrive (Claude\timekeeping\), not the repo.
    git pull --rebase --autostash --quiet 2>$null
    git add raw/ obligations/ 2>$null | Out-Null
    if (git diff --cached --name-only 2>$null) {
        $msg = "pulse: {0} clock sync {1}" -f $env:COMPUTERNAME, (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mmZ')
        git -c user.name='Chris Garrett' -c user.email='chris@pueo.com' commit -m $msg --quiet 2>$null
        for ($i = 0; $i -lt 3; $i++) {
            git push --quiet 2>$null
            if ($LASTEXITCODE -eq 0) { break }
            git pull --rebase --autostash --quiet 2>$null
        }
    }

    # --- load this month's events across all machines ---
    $ym = (Get-Date).ToString('yyyy-MM')
    $events = @()
    Get-ChildItem (Join-Path $repo 'raw') -Filter ("*-{0}.ndjson" -f $ym) -ErrorAction SilentlyContinue | ForEach-Object {
        Get-Content $_.FullName | Where-Object { $_ } | ForEach-Object { try { $events += ($_ | ConvertFrom-Json) } catch {} }
    }

    $today = (Get-Date).Date
    $now   = Get-Date          # local; box is Eastern -> ToLocalTime auto-handles EDT/EST
    $IDLE  = 15.0              # minutes — bridge gaps <= this; longer = idle/away
    $TAIL  = 2.0               # minutes — post-prompt work credited at a burst end / last heartbeat
    function R025($h) { [math]::Round($h * 4) / 4 }
    function Leaf($p) { if (-not $p) { return '(unknown)' } ($p -replace '\\', '/').TrimEnd('/').Split('/')[-1] }
    # ConvertFrom-Json yields ts as a Kind=Utc DateTime; use it directly (re-Parse drops the Kind -> +offset bug).
    function ToUtc($v) { if ($v -is [datetime]) { $v.ToUniversalTime() } else { ([datetimeoffset]$v).UtcDateTime } }

    # --- PRIMARY: heartbeat clustering (UserPromptSubmit), local-day, pooled across machines ---
    $hb = @($events | Where-Object { $_.event -eq 'UserPromptSubmit' -and $_.ts } | ForEach-Object {
        [pscustomobject]@{ t = (ToUtc $_.ts).ToLocalTime(); repo = (Leaf $_.cwd) }
    } | Where-Object { $_.t.Date -eq $today } | Sort-Object t)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# Today's pulse - $($today.ToString('ddd yyyy-MM-dd'))")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("_Auto / deterministic. Updated $($now.ToString('HH:mm')) local. Default code Technology_MGMT._")

    if ($hb.Count -gt 0) {
        # per-heartbeat contribution: gap-to-next if <= IDLE else TAIL; last heartbeat = TAIL
        $byRepo = @{}
        $totMin = 0.0
        for ($i = 0; $i -lt $hb.Count; $i++) {
            if ($i -lt $hb.Count - 1) {
                $g = ($hb[$i + 1].t - $hb[$i].t).TotalMinutes
                $c = if ($g -le $IDLE) { $g } else { $TAIL }
            } else { $c = $TAIL }
            $totMin += $c
            $r = $hb[$i].repo
            if (-not $byRepo.ContainsKey($r)) { $byRepo[$r] = 0.0 }
            $byRepo[$r] += $c
        }
        [void]$sb.AppendLine("_ACTIVE time = UserPromptSubmit heartbeats clustered (IDLE=$([int]$IDLE)min, TAIL=$([int]$TAIL)min), pooled across machines. EXCLUDES autonomous/agent runtime - **/timecard** is the billing source (heartbeat-active + blend)._")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("## Active time today: **$(R025 ($totMin / 60.0))hr**")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("### By repo (heartbeat-attributed)")
        foreach ($kv in ($byRepo.GetEnumerator() | Sort-Object Value -Descending)) {
            [void]$sb.AppendLine("- $(R025 ($kv.Value / 60.0))hr - $($kv.Key)")
        }
    } else {
        # FALLBACK: no heartbeats today anywhere -> approximate lifecycle spans (labeled),
        # with open-session guard: extend an open (no-End) session to 'now' ONLY if its last
        # event was within IDLE of now; otherwise cap at that last event (no 24h inflation).
        $segs = New-Object System.Collections.ArrayList
        foreach ($g in ($events | Where-Object { $_.sid } | Group-Object sid)) {
            $evs = $g.Group | Sort-Object { ToUtc $_.ts }
            $open = $null; $segRepo = '(unknown)'; $lastT = $null
            foreach ($e in $evs) {
                $t = (ToUtc $e.ts).ToLocalTime()
                if ($e.cwd) { $segRepo = Leaf $e.cwd }
                if ($e.event -eq 'SessionStart') { if ($null -eq $open) { $open = $t } }
                elseif ($e.event -eq 'SessionEnd') { if ($open) { [void]$segs.Add([pscustomobject]@{ start = $open; end = $t; repo = $segRepo }); $open = $null } }
                $lastT = $t
            }
            if ($open) {
                $end = if (($now - $lastT).TotalMinutes -le $IDLE) { $now } else { $lastT }
                if ($end -gt $open) { [void]$segs.Add([pscustomobject]@{ start = $open; end = $end; repo = $segRepo }) }
            }
        }
        $todaySegs = @($segs | Where-Object { $_.start.Date -eq $today -and $_.end -gt $_.start })
        function Union-Hours($list) {
            $s = @($list | Sort-Object start); if ($s.Count -eq 0) { return 0.0 }
            $tot = 0.0; $cs = $s[0].start; $ce = $s[0].end
            for ($i = 1; $i -lt $s.Count; $i++) {
                if ($s[$i].start -le $ce) { if ($s[$i].end -gt $ce) { $ce = $s[$i].end } }
                else { $tot += ($ce - $cs).TotalHours; $cs = $s[$i].start; $ce = $s[$i].end }
            }
            $tot += ($ce - $cs).TotalHours; return $tot
        }
        [void]$sb.AppendLine("_No UserPromptSubmit heartbeats captured today - falling back to APPROXIMATE lifecycle spans (over/under-counts; re-run the installer to enable heartbeats). **/timecard** is the billing source._")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("## Approx time today (lifecycle spans): **$(R025 (Union-Hours $todaySegs))hr**")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("### By repo (approx)")
        $byRepo = $todaySegs | Group-Object repo | ForEach-Object { [pscustomobject]@{ repo = $_.Name; hrs = (Union-Hours $_.Group) } } | Sort-Object hrs -Descending
        if ($byRepo) { foreach ($r in $byRepo) { [void]$sb.AppendLine("- $(R025 $r.hrs)hr - $($r.repo)") } }
        else { [void]$sb.AppendLine("- (no sessions captured yet today)") }
    }

    $out = Join-Path $env:USERPROFILE 'OneDrive - Pueo Business Solutions, LLC\Claude\timekeeping\today-pulse.md'
    Set-Content -Path $out -Value $sb.ToString() -Encoding utf8
}
catch { }
exit 0
