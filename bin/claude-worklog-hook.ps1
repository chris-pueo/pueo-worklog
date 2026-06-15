# claude-worklog-hook.ps1 — REFERENCE COPY (the live one is ~/.claude/worklog/claude-worklog-hook.ps1)
# Windows SessionStart/SessionEnd hook for the Pueo worklog system. Appends a
# deterministic wall-clock record to raw/<COMPUTERNAME>-YYYY-MM.ndjson in this repo
# (fallback ~/.claude/worklog). Fail-safe: swallows all errors, always exits 0.
# See README.md. Keep this copy in sync with the installed one if you edit either.

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

    $p   = $raw | ConvertFrom-Json
    $now = (Get-Date).ToUniversalTime()

    $repoRaw = Join-Path $env:USERPROFILE 'git\pueo-worklog\raw'
    $dir = if (Test-Path $repoRaw) { $repoRaw } else { Join-Path $env:USERPROFILE '.claude\worklog' }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $host_ = $env:COMPUTERNAME
    $file  = Join-Path $dir ("{0}-{1}.ndjson" -f $host_, $now.ToString('yyyy-MM'))

    $rec = [ordered]@{
        ts = $now.ToString("yyyy-MM-ddTHH:mm:ssZ"); event = $p.hook_event_name; sid = $p.session_id
        host = $host_; cwd = $p.cwd; model = $p.model; title = $p.session_title
        source = $p.source; reason = $p.reason
    }
    $line = ($rec | ConvertTo-Json -Compress)
    for ($i = 0; $i -lt 3; $i++) {
        try { Add-Content -Path $file -Value $line -Encoding utf8; break } catch { Start-Sleep -Milliseconds 40 }
    }
}
catch { }
exit 0
