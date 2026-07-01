# claude-worklog-hook.ps1 — REFERENCE COPY (the live one is ~/.claude/worklog/claude-worklog-hook.ps1)
# Windows SessionStart/SessionEnd + UserPromptSubmit hook for the Pueo worklog system.
# SessionStart/End mark boundaries; UserPromptSubmit fires once per prompt as an ACTIVITY
# HEARTBEAT (the signal /timecard clusters into active time). Event-generic via
# .hook_event_name; appends a wall-clock record to raw/<COMPUTERNAME>-YYYY-MM.ndjson in this
# repo (fallback ~/.claude/worklog). stdout-silent (a UserPromptSubmit hook's stdout is
# injected into the model context on exit 0 — writes only to the ndjson); .prompt never logged.
# Fail-safe: swallows all errors, always exits 0. See README.md / INSTALL-LINUX.md.
# Keep this copy in sync with the installed one if you edit either.
#
# TIME BASIS = LOCAL (matches the LOCAL-dated narrative heading so /timecard joins clock<->
# narrative on the same day/month key; changed from UTC 2026-07-01 to stop evening work
# splitting across day/month buckets). NOTE: the Linux .sh also drops a SessionEnd PENDING
# stub into the repo narrative when a session ends undescribed — NOT ported here because the
# Windows narrative lives in OneDrive (Claude\timekeeping\), not the repo. Wire that path +
# /timecard reconcile before adding the Windows stub backstop (follow-up).

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

    $p   = $raw | ConvertFrom-Json
    $now = Get-Date                                  # LOCAL time (see header)

    $repoRaw = Join-Path $env:USERPROFILE 'git\pueo-worklog\raw'
    $dir = if (Test-Path $repoRaw) { $repoRaw } else { Join-Path $env:USERPROFILE '.claude\worklog' }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $host_ = $env:COMPUTERNAME
    $file  = Join-Path $dir ("{0}-{1}.ndjson" -f $host_, $now.ToString('yyyy-MM'))

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
}
catch { }
exit 0
