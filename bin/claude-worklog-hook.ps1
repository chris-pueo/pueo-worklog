# claude-worklog-hook.ps1 — REFERENCE COPY (the live one is ~/.claude/worklog/claude-worklog-hook.ps1)
# Windows SessionStart/SessionEnd + UserPromptSubmit hook for the Pueo worklog system.
# SessionStart/End mark boundaries; UserPromptSubmit fires once per prompt as an ACTIVITY
# HEARTBEAT (the signal /timecard clusters into active time). Event-generic via
# .hook_event_name; appends a wall-clock record to raw/<COMPUTERNAME>-YYYY-MM.ndjson in this
# repo (fallback ~/.claude/worklog). stdout-silent (a UserPromptSubmit hook's stdout is
# injected into the model context on exit 0 — writes only to the ndjson/narrative); .prompt
# never logged. Fail-safe: swallows all errors, always exits 0. See README.md / INSTALL-LINUX.md.
# Keep this copy in sync with the installed one if you edit either.
#
# TIME BASIS = LOCAL (matches the LOCAL-dated narrative heading so /timecard joins clock<->
# narrative on the same day/month key; changed from UTC 2026-07-01 to stop evening work
# splitting across day/month buckets).
#
# SessionEnd TIME FLOOR (ported from claude-worklog-hook.sh / lib-worklog.sh 2026-07-01):
# the narrative line is a MANUAL end-of-session step; a session that ends via /clear, context
# exhaustion or a closed terminal loses its billable description (the clock survives, the
# narrative does not). On SessionEnd, if the session had activity (>=1 UserPromptSubmit this
# month for the sid) and was never described, we auto-write a PENDING [sid:] stub — SAME
# format as the Linux side — so the gap is VISIBLE (reconcile) instead of silently lost.
# On Windows the narrative lives in OneDrive (Claude\timekeeping\<host>-YYYY-MM.md), NOT the
# repo. If OneDrive is unmounted/unresolvable at SessionEnd we can't write the stub, so we
# enqueue a TIME debt record to the repo obligations/ dir (always present) instead, so the
# reconcile step still surfaces the undescribed session.
#
# The stub PENDING-prefix "?hr: [PENDING —" (em dash) is the exact marker that tells a stub
# from a real narrative line — matched literally, never the bare word "PENDING".

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

    $p   = $raw | ConvertFrom-Json
    $now = Get-Date                                  # LOCAL time (see header)

    $repoRoot = Join-Path $env:USERPROFILE 'git\pueo-worklog'
    $repoRaw  = Join-Path $repoRoot 'raw'
    $dir = if (Test-Path $repoRaw) { $repoRaw } else { Join-Path $env:USERPROFILE '.claude\worklog' }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $host_ = $env:COMPUTERNAME
    $ym    = $now.ToString('yyyy-MM')
    $file  = Join-Path $dir ("{0}-{1}.ndjson" -f $host_, $ym)

    $rec = [ordered]@{
        ts = $now.ToString("yyyy-MM-ddTHH:mm:sszzz"); event = $p.hook_event_name; sid = $p.session_id
        host = $host_; cwd = $p.cwd; model = $p.model; title = $p.session_title
        source = $p.source; reason = $p.reason
    }
    $line = ($rec | ConvertTo-Json -Compress)
    $enc  = New-Object System.Text.UTF8Encoding $false   # BOM-less; bare LF to match .gitattributes (*.ndjson eol=lf)
    for ($i = 0; $i -lt 3; $i++) {
        try { [System.IO.File]::AppendAllText($file, $line + "`n", $enc); break } catch { Start-Sleep -Milliseconds 40 }
    }

    # ================= SessionEnd TIME floor (auto-stub if undescribed) =====================
    # Mirror of claude-worklog-hook.sh + lib-worklog.sh: only stub sessions that actually did
    # something (>=1 UserPromptSubmit this month for the sid); never duplicate a stub; never
    # overwrite a real line. If the OneDrive narrative can't be resolved, enqueue a repo TIME debt.
    if ($p.hook_event_name -eq 'SessionEnd' -and -not [string]::IsNullOrWhiteSpace($p.session_id)) {
        $sid = [string]$p.session_id
        $cwd = [string]$p.cwd

        # --- did this session do work? count UserPromptSubmit heartbeats for the sid this month ---
        $prompts = 0
        $first = ''; $last = ''
        if (Test-Path $file) {
            $spanTs = New-Object System.Collections.Generic.List[string]
            foreach ($ln in [System.IO.File]::ReadLines($file)) {
                if ([string]::IsNullOrWhiteSpace($ln)) { continue }
                $obj = $null
                try { $obj = $ln | ConvertFrom-Json } catch { continue }
                if ([string]$obj.sid -ne $sid) { continue }
                if ($obj.event -eq 'UserPromptSubmit') { $prompts++ }
                if (-not [string]::IsNullOrWhiteSpace([string]$obj.ts)) { $spanTs.Add([string]$obj.ts) }
            }
            if ($spanTs.Count -gt 0) {
                $sorted = $spanTs | Sort-Object
                $first = $sorted | Select-Object -First 1
                $last  = $sorted | Select-Object -Last 1
            }
        }

        if ($prompts -ge 1) {
            # --- stub content (EXACT format from lib-worklog.sh wl_ensure_time_stub) ---
            $ymd = $now.ToString('yyyy-MM-dd')
            $base = if ([string]::IsNullOrWhiteSpace($cwd)) { 'unknown' } else { Split-Path -Leaf $cwd.TrimEnd('\','/') }
            if ([string]::IsNullOrWhiteSpace($base)) { $base = 'unknown' }
            $stubPrefix = '?hr: [PENDING —'    # literal marker (em dash) — must match lib-worklog.sh WL_STUB_PREFIX
            $stub = "Technology_MGMT $stubPrefix narrative not written this session; reconcile] cwd=$base prompts=$prompts span=$first..$last [sid:$sid]"

            # --- resolve the OneDrive narrative file: Claude\timekeeping\<host>-YYYY-MM.md ---
            $narr = $null
            $oneDriveRoots = @()
            foreach ($cand in @($env:OneDriveCommercial, $env:OneDrive)) {
                if (-not [string]::IsNullOrWhiteSpace($cand)) { $oneDriveRoots += $cand }
            }
            # also probe USERPROFILE\OneDrive* (e.g. "OneDrive - Pueo Business Solutions, LLC")
            try {
                Get-ChildItem -Path $env:USERPROFILE -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue |
                    ForEach-Object { $oneDriveRoots += $_.FullName }
            } catch { }
            $seen = @{}
            foreach ($root in $oneDriveRoots) {
                if ([string]::IsNullOrWhiteSpace($root)) { continue }
                if ($seen.ContainsKey($root)) { continue }
                $seen[$root] = $true
                $tk = Join-Path $root 'Claude\timekeeping'
                if (Test-Path $tk) {
                    $narr = Join-Path $tk ("{0}-{1}.md" -f $host_, $ym)
                    break
                }
            }

            if ($narr) {
                # --- narrative resolved: append the stub iff no real line AND no stub yet for the sid ---
                $needStub = $true
                if (Test-Path $narr) {
                    foreach ($ln in [System.IO.File]::ReadLines($narr)) {
                        if ($ln -notlike "*[sid:$sid]*") { continue }
                        if ($ln -like "*$stubPrefix*") { $needStub = $false; break }   # stub already present
                        else { $needStub = $false; break }                             # a REAL line exists -> described
                    }
                }
                if ($needStub) {
                    # ensure trailing newline, then a "## YYYY-MM-DD" heading if today's isn't the last one
                    $existing = ''
                    if (Test-Path $narr) { $existing = [System.IO.File]::ReadAllText($narr) }
                    else { New-Item -ItemType File -Path $narr -Force | Out-Null }

                    $toAppend = ''
                    if ($existing.Length -gt 0 -and -not $existing.EndsWith("`n")) { $toAppend += "`n" }

                    # find the last "## " heading; add today's if it isn't already the last one
                    $lastHead = $null
                    foreach ($ln in ($existing -split "`n")) {
                        if ($ln -match '^## ') { $lastHead = $ln.TrimEnd("`r") }
                    }
                    if ($lastHead -ne "## $ymd") { $toAppend += "`n## $ymd`n" }
                    $toAppend += "$stub`n"

                    for ($i = 0; $i -lt 3; $i++) {
                        try { [System.IO.File]::AppendAllText($narr, $toAppend, $enc); break } catch { Start-Sleep -Milliseconds 40 }
                    }
                }
            }
            else {
                # --- OneDrive unresolvable: enqueue a TIME debt to the repo obligations/ dir ---
                # (mirror of lib-worklog.sh wl_append_debt: idempotent per (sid, obligation=TIME)).
                $obDir = Join-Path $repoRoot 'obligations'
                if (-not (Test-Path $obDir)) {
                    $obDir = Join-Path $env:USERPROFILE '.claude\worklog'
                    if (-not (Test-Path $obDir)) { New-Item -ItemType Directory -Path $obDir -Force | Out-Null }
                }
                $obFile = Join-Path $obDir ("{0}-{1}.ndjson" -f $host_, $ym)

                # already recorded (unresolved) for this sid+TIME? then don't duplicate.
                $dup = $false
                if (Test-Path $obFile) {
                    foreach ($ln in [System.IO.File]::ReadLines($obFile)) {
                        if ($ln -like "*`"sid`":`"$sid`"*" -and $ln -like '*"obligation":"TIME"*' -and $ln -notlike '*"resolved":true*') {
                            $dup = $true; break
                        }
                    }
                }
                if (-not $dup) {
                    $obRec = [ordered]@{
                        ts = $now.ToString("yyyy-MM-ddTHH:mm:sszzz"); host = $host_; sid = $sid
                        cwd = $cwd; obligation = 'TIME'; state = 'unmet'; source = 'sessionend-onedrive-unresolved'
                    }
                    $obLine = ($obRec | ConvertTo-Json -Compress)
                    for ($i = 0; $i -lt 3; $i++) {
                        try { [System.IO.File]::AppendAllText($obFile, $obLine + "`n", $enc); break } catch { Start-Sleep -Milliseconds 40 }
                    }
                }
            }
        }
    }
}
catch { }
exit 0
