# session-obligations.ps1 — Stop-hook FORCING FUNCTION for the Pueo capture obligations (Windows).
# PowerShell port of session-obligations.sh (WL_OBLIG_VERSION must match the .sh). Invoke as:
#     pwsh -NoProfile -File <repo>\bin\session-obligations.ps1
# so a chatty profile can't prepend noise to the decision:block JSON on stdout (-NoProfile assumed).
#
# WIRE ONLY to the "Stop" event (NEVER SubagentStop — a subagent turn lives in a separate
# transcript and must not trigger a block).
#
# WHAT IT DOES, per assistant turn (Stop fires once at the end of every turn):
#   TIME     — DISABLED on this Windows hook. There is historically no [sid:] tag in the
#              OneDrive narrative, so the Stop hook neither auto-stubs nor blocks on TIME.
#              TIME is handled ONLY by the SessionEnd stub writer in claude-worklog-hook.ps1.
#   CLICKUP  — conditional. If the session did task-worthy PROJECT work and no ClickUp write
#              is seen in the transcript (and no NO-CLICKUP: marker), BLOCK once (fulfill-or-
#              justify). In remind mode, emit a soft reminder instead of blocking.
#   OBSIDIAN — conditional, tightened. Only when a KM/docs artifact was warranted (new .md,
#              ledger/ADR edit, or a docs/|runbooks/ path) and no vault write is seen.
#
# Blocks AT MOST ONCE per turn (guarded by stop_hook_active) — never loops. On the guard
# re-fire it records any still-unmet conditional obligation to the committed debt ledger
# (obligations\<host>-YYYY-MM.ndjson) so nothing is silently lost.
#
# Block mechanism mirrors the .sh: exit 0 + a JSON decision object on stdout.
#   block  -> {decision:"block", reason:..., systemMessage:..., suppressOutput:true}
#   remind -> {systemMessage:..., suppressOutput:true}   (does NOT block)
#
# Fail-OPEN by design (missing/unreadable transcript, parse error -> exit 0 with no output):
# under-enforce rather than ever wedge a session. Kill switches: $env:PUEO_OBLIG=0 (all off),
# $env:PUEO_OBLIG_CLICKUP=0, $env:PUEO_OBLIG_KM=0; per-repo opt-out file <cwd>\.no-obligations;
# mode $env:PUEO_OBLIG_MODE=block|remind (default remind — soft, non-blocking soak).

$WL_OBLIG_VERSION = '1.0.0'

# Add-ObligationDebt — append one unmet-obligation record to the committed debt ledger
# (obligations\<host>-YYYY-MM.ndjson in the repo; fallback ~\.claude\worklog). Mirrors the
# Linux lib-worklog.sh wl_append_debt: same NDJSON schema, idempotent per (sid,obligation)
# (skip if an unresolved record for the pair already exists), BOM-less bare-LF append with a
# bounded retry, and fully fail-safe (never throws back to the caller). Local-time ts + offset.
function Add-ObligationDebt {
    param(
        [string]$Repo,
        [string]$Sid,
        [string]$Cwd,
        [string]$Obligation,
        [string]$Source = 'unknown'
    )
    try {
        if ([string]::IsNullOrWhiteSpace($Sid) -or [string]::IsNullOrWhiteSpace($Obligation)) { return }
        $obDir = Join-Path $Repo 'obligations'
        if (-not (Test-Path $obDir)) {
            $repoObExists = Test-Path (Join-Path $Repo '.git')
            $obDir = if ($repoObExists) { $obDir } else { Join-Path $env:USERPROFILE '.claude\worklog' }
        }
        if (-not (Test-Path $obDir)) { New-Item -ItemType Directory -Path $obDir -Force | Out-Null }

        $host_ = $env:COMPUTERNAME
        $now   = Get-Date                                    # LOCAL time (matches the .ndjson clock)
        $file  = Join-Path $obDir ("{0}-{1}.ndjson" -f $host_, $now.ToString('yyyy-MM'))

        # idempotency: skip if an UNRESOLVED record for this sid+obligation already exists.
        if (Test-Path $file) {
            foreach ($ln in [System.IO.File]::ReadLines($file)) {
                if ([string]::IsNullOrWhiteSpace($ln)) { continue }
                $r = $null; try { $r = $ln | ConvertFrom-Json } catch { continue }
                if ($r.sid -eq $Sid -and $r.obligation -eq $Obligation -and $r.resolved -ne $true) { return }
            }
        }

        $rec = [ordered]@{
            ts         = $now.ToString('yyyy-MM-ddTHH:mm:sszzz')
            host       = $host_
            sid        = $Sid
            cwd        = if ($Cwd) { $Cwd } else { '' }
            obligation = $Obligation
            state      = 'unmet'
            source     = $Source
        }
        $line = ($rec | ConvertTo-Json -Compress)
        $enc  = New-Object System.Text.UTF8Encoding $false   # BOM-less; bare LF for .gitattributes (*.ndjson eol=lf)
        for ($i = 0; $i -lt 3; $i++) {
            try { [System.IO.File]::AppendAllText($file, $line + "`n", $enc); break } catch { Start-Sleep -Milliseconds 40 }
        }
    }
    catch { }   # fail-safe: a debt-write failure must never disrupt the Stop hook
}

# --- fail-open wrapper: any unhandled error -> silent exit 0 (never wedge a session) --------
try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

    # global kill switch
    if ($env:PUEO_OBLIG -eq '0') { exit 0 }

    $repo = if ($env:PUEO_WORKLOG_REPO) { $env:PUEO_WORKLOG_REPO } else { Join-Path $env:USERPROFILE 'git\pueo-worklog' }
    $mode = if ($env:PUEO_OBLIG_MODE) { $env:PUEO_OBLIG_MODE } else { 'remind' }   # block | remind

    $p = $raw | ConvertFrom-Json
    $sid    = [string]$p.session_id
    $cwd    = [string]$p.cwd
    $tx     = [string]$p.transcript_path
    $active = ($p.stop_hook_active -eq $true)
    if ([string]::IsNullOrWhiteSpace($sid)) { exit 0 }

    # per-repo opt-out
    if ($cwd -and (Test-Path (Join-Path $cwd '.no-obligations'))) { exit 0 }

    # resolve the transcript (slug fallback: cwd with / and \ -> - , then
    # ~\.claude\projects\<slug>\<sid>.jsonl — mirrors the .sh slug fallback)
    if ([string]::IsNullOrWhiteSpace($tx) -or -not (Test-Path $tx)) {
        $slug = ($cwd -replace '[\\/]', '-')
        $tx   = Join-Path $env:USERPROFILE (".claude\projects\{0}\{1}.jsonl" -f $slug, $sid)
    }
    if (-not (Test-Path $tx)) { exit 0 }   # can't inspect -> fail open

    # ---- ONE transcript pass (native ConvertFrom-Json; NO jq) ------------------------------
    # Read the .jsonl line-by-line; each line -> obj; keep assistant turns that are NOT
    # sidechain (subagent) turns; iterate .message.content items. Collect:
    #   $names  — tool_use names (one per tool_use)
    #   $tools  — [pscustomobject]@{ name; file_path; command } per tool_use
    #   $texts  — assistant text blocks (for NO-* markers)
    $names = New-Object System.Collections.Generic.List[string]
    $tools = New-Object System.Collections.Generic.List[object]
    $texts = New-Object System.Collections.Generic.List[string]

    foreach ($line in [System.IO.File]::ReadLines($tx)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $obj = $null
        try { $obj = $line | ConvertFrom-Json } catch { continue }
        if ($obj.type -ne 'assistant') { continue }
        if ($obj.isSidechain -eq $true) { continue }
        $content = $obj.message.content
        if ($null -eq $content) { continue }
        foreach ($c in @($content)) {
            if ($c.type -eq 'tool_use') {
                $nm = [string]$c.name
                $fp = if ($null -ne $c.input -and $null -ne $c.input.file_path) { [string]$c.input.file_path } else { '' }
                $cm = if ($null -ne $c.input -and $null -ne $c.input.command)   { [string]$c.input.command }   else { '' }
                $names.Add($nm)
                $tools.Add([pscustomobject]@{ name = $nm; file_path = $fp; command = $cm })
            }
            elseif ($c.type -eq 'text') {
                $texts.Add([string]$c.text)
            }
        }
    }
    if ($tools.Count -eq 0 -and $texts.Count -eq 0) { exit 0 }

    $fpaths = @($tools | Where-Object { $_.file_path -ne '' } | ForEach-Object { $_.file_path })
    $cmds   = @($tools | Where-Object { $_.command   -ne '' } | ForEach-Object { $_.command })

    # ---- substantive-work classification (mirror the .sh thresholds) -----------------------
    $edits   = @($names | Where-Object { $_ -match '^(Edit|Write|MultiEdit)$' }).Count
    $bashn   = @($names | Where-Object { $_ -eq 'Bash' }).Count
    $nonread = @($names | Where-Object { $_ -notmatch '^(Read|Glob|Grep|TodoWrite|AskUserQuestion|Task|Agent|Workflow|ToolSearch)$' }).Count
    $deploy  = [bool](@($cmds | Where-Object { $_ -match 'ansible-playbook|terraform apply|kubectl apply|docker stack deploy|systemctl (restart|start|stop)|(^| )git push' }).Count -ge 1)
    $substantive = ($edits -ge 1) -or ($bashn -ge 2) -or ($nonread -ge 3) -or $deploy
    if (-not $substantive) { exit 0 }

    # ---- TIME floor: DISABLED on the Windows Stop hook (no auto-stub, no block) -------------
    # (SessionEnd stub writer in claude-worklog-hook.ps1 owns TIME; see header.)

    # ---- detectors -------------------------------------------------------------------------
    # ClickUp: an MCP ClickUp write tool by name, OR an api.clickup.com call in a command.
    $cu_seen = [bool]( (@($names | Where-Object { $_ -match '^mcp__.*[Cc]lick[Uu]p.*clickup_(create|update|delete|move|merge|add|remove|attach|start|stop)' }).Count -ge 1) `
        -or (@($cmds | Where-Object { $_ -match 'api\.clickup\.com' }).Count -ge 1) )

    # Vault: slash/backslash-agnostic path match (+ optional $env:PUEO_VAULT_ROOT).
    $km_pat = '[\\/](pueo-km-vault|vaults)[\\/]'
    if ($env:PUEO_VAULT_ROOT) { $km_pat = $km_pat + '|' + [regex]::Escape($env:PUEO_VAULT_ROOT) }
    $km_seen = [bool](@(@($fpaths) + @($cmds) | Where-Object { $_ -match $km_pat }).Count -ge 1)

    # NO-* markers in assistant text (case-insensitive; hyphen OR space).
    $cu_mark = [bool](@($texts | Where-Object { $_ -match '(?i)NO[- ]CLICKUP' }).Count -ge 1)
    $km_mark = [bool](@($texts | Where-Object { $_ -match '(?i)NO[- ](KM|OBSIDIAN)' }).Count -ge 1)

    # ---- warrant ---------------------------------------------------------------------------
    # project edits = Edit/Write/MultiEdit to a path NOT under the worklog repo or .claude self-bookkeeping.
    $proj_edits = @($tools | Where-Object {
            $_.name -match '^(Edit|Write|MultiEdit)$' -and $_.file_path -ne '' -and
            $_.file_path -notmatch 'pueo-worklog' -and $_.file_path -notmatch '[\\/]\.claude[\\/]'
        } | ForEach-Object { $_.file_path })
    $proj_edit_n = @($proj_edits).Count
    $cu_warrant = [bool](($proj_edit_n -ge 1) -or $deploy)

    # KM warrant (tightened): a docs/runbooks/ledger/ADR project edit, OR any new project .md Write.
    $km_warrant = $false
    if (@($proj_edits | Where-Object { $_ -match '(?i)([\\/]docs[\\/]|[\\/]runbooks[\\/]|decisions\.md|changelog\.md|CHANGELOG|[\\/]ADR|ADR-|\.adr$)' }).Count -ge 1) {
        $km_warrant = $true
    }
    elseif (@($tools | Where-Object {
                $_.name -eq 'Write' -and $_.file_path -ne '' -and
                $_.file_path -notmatch 'pueo-worklog' -and $_.file_path -notmatch '[\\/]\.claude[\\/]' -and
                $_.file_path -match '(?i)\.md$'
            }).Count -ge 1) {
        $km_warrant = $true
    }

    # ---- compute unmet conditional obligations (kill switches + markers + detectors) --------
    $unmet = New-Object System.Collections.Generic.List[string]
    if ($env:PUEO_OBLIG_CLICKUP -ne '0' -and $cu_warrant -and -not $cu_seen -and -not $cu_mark) { $unmet.Add('CLICKUP') }
    if ($env:PUEO_OBLIG_KM      -ne '0' -and $km_warrant -and -not $km_seen -and -not $km_mark) { $unmet.Add('OBSIDIAN') }

    # ---- guard re-fire: never block twice; record still-unmet debt, then allow the stop -----
    if ($active) {
        if ($unmet.Count -gt 0) {
            foreach ($ob in $unmet) { Add-ObligationDebt -Repo $repo -Sid $sid -Cwd $cwd -Obligation $ob -Source 'stop-guard' }
        }
        exit 0
    }

    if ($unmet.Count -eq 0) { exit 0 }

    # ---- first firing: block once (block mode) or soft-remind (soak mode) -------------------
    $human  = ($unmet -join ' ')
    $sysmsg = "[obligations] unmet: $human (session did work but no matching update was recorded)"
    $reason = "SESSION OBLIGATIONS — before this session ends, $human still needs an on-the-record update. "
    if ($unmet -contains 'CLICKUP') {
        $reason += "CLICKUP: update the relevant ClickUp task now (status/comment/CHG link), assigned to yourself; or, if genuinely not warranted, write ``NO-CLICKUP: <one-line reason>`` in your reply. "
    }
    if ($unmet -contains 'OBSIDIAN') {
        $reason += "OBSIDIAN: capture the change in the KM vault (or the appropriate docs/runbook/ADR/changelog); or write ``NO-KM: <one-line reason>`` if the change carries no durable knowledge. "
    }
    $reason += "(This check runs once per turn; do the update or state the NO-* justification and you'll stop cleanly.)"

    if ($mode -eq 'block') {
        $out = [ordered]@{ decision = 'block'; reason = $reason; systemMessage = $sysmsg; suppressOutput = $true }
    } else {
        $out = [ordered]@{ systemMessage = "$sysmsg  [reminder-only soak; set PUEO_OBLIG_MODE=block to enforce]"; suppressOutput = $true }
    }
    # Compact single-line JSON on stdout (the -NoProfile invocation guarantees no prepended noise).
    Write-Output ($out | ConvertTo-Json -Compress)
    exit 0
}
catch { exit 0 }   # fail-open: any error -> allow the stop, emit nothing
