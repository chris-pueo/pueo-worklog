# claude-worklog-hook.ps1  (canonical copy — live copy lives at ~/.claude/worklog/)
# -----------------------------------------------------------------------------
# Part of the Pueo cross-surface Claude worklog / timecard system.
# Registered as SessionStart + SessionEnd + UserPromptSubmit hooks in
# ~/.claude/settings.json so it runs for EVERY Claude Code (CLI/IDE) session on
# this machine. SessionStart/End mark session BOUNDARIES; UserPromptSubmit fires
# once per prompt as an ACTIVITY HEARTBEAT — the signal /timecard clusters into
# real active time (lifecycle spans alone over/under-count: an open session
# inflates a Start->End span to ~24h, a single long session emits nothing between).
#
# What it does: appends a deterministic, append-only wall-clock record to a
# MACHINE-NAMESPACED monthly NDJSON file in the shared pueo-worklog git repo
# (raw/<COMPUTERNAME>-YYYY-MM.ndjson). Machine-namespaced => multiple machines
# never content-conflict on git merge. No secrets, no network (the git push is a
# separate step: /timecard on Windows, cron on Linux).
#
# IMPORTANT (UserPromptSubmit): write ONLY to the ndjson and emit NOTHING on
# stdout — a UserPromptSubmit hook's stdout is injected into the model context on
# exit 0. It also runs synchronously before each prompt, so it must stay fast
# (local file append only, no network). The payload's .prompt field is
# deliberately NOT captured — no prompt text is ever logged.
#
# Falls back to ~/.claude/worklog if the repo isn't present, so data is never lost.
#
# Fail-safe: any error is swallowed and the script always exits 0 — a logging
# failure must NEVER disrupt a Claude session.
#
# To disable: remove the relevant block(s) from ~/.claude/settings.json. Reversible.
# -----------------------------------------------------------------------------

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

    $p   = $raw | ConvertFrom-Json
    $now = (Get-Date).ToUniversalTime()

    # Prefer the shared repo's raw/ dir; fall back to the local worklog dir.
    $repoRaw = Join-Path $env:USERPROFILE 'git\pueo-worklog\raw'
    $dir = if (Test-Path $repoRaw) { $repoRaw } else { Join-Path $env:USERPROFILE '.claude\worklog' }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $host_ = $env:COMPUTERNAME
    $file  = Join-Path $dir ("{0}-{1}.ndjson" -f $host_, $now.ToString('yyyy-MM'))

    # NOTE: .prompt is intentionally omitted — heartbeats record timing + surface only.
    $rec = [ordered]@{
        ts     = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")
        event  = $p.hook_event_name
        sid    = $p.session_id
        host   = $host_
        cwd    = $p.cwd
        model  = $p.model
        title  = $p.session_title
        source = $p.source
        reason = $p.reason
    }
    $line = ($rec | ConvertTo-Json -Compress)

    for ($i = 0; $i -lt 3; $i++) {
        try { Add-Content -Path $file -Value $line -Encoding utf8; break }
        catch { Start-Sleep -Milliseconds 40 }
    }
}
catch { }

exit 0
