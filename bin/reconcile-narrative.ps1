#!/usr/bin/env pwsh
# reconcile-narrative.ps1 - show worklog CAPTURE gaps for a local day (read-only).
# Mirror of reconcile-narrative.sh, adapted for Windows: the raw clock lives in the repo
# (raw\<COMPUTERNAME>-YYYY-MM.ndjson) but the NARRATIVE lives in OneDrive
# (Claude\timekeeping\<COMPUTERNAME>-YYYY-MM.md), NOT the repo. This is the human/Claude-facing
# view: for a given LOCAL day on THIS host it lists every Claude session from the raw clock
# (sid, cwd, prompt count, wall-clock span) and flags which have NO narrative line - i.e. work
# whose billable description+charge-code is still missing. Run it at end of day (or before a
# timecard) to turn silent loss into a worklist. Matching is by the [sid:<id>] tag a real
# narrative line carries (meaningful only for lines written on/after the tag was introduced;
# older lines show as GAP - expected, already reconciled). No jq needed (native ConvertFrom-Json).
#
# Usage:  pwsh -File reconcile-narrative.ps1 [YYYY-MM-DD]   (default: today, local)

param([string]$Day = (Get-Date).ToString('yyyy-MM-dd'))

$ErrorActionPreference = 'SilentlyContinue'
$repo = if ($env:PUEO_WORKLOG_REPO) { $env:PUEO_WORKLOG_REPO } else { Join-Path $env:USERPROFILE 'git\pueo-worklog' }
$host_ = $env:COMPUTERNAME
$ym    = $Day.Substring(0, 7)                     # YYYY-MM
$raw   = Join-Path $repo ("raw\{0}-{1}.ndjson" -f $host_, $ym)

# --- resolve the OneDrive narrative dir robustly (mirror the SessionEnd stub writer) ---
function Resolve-NarrativeFile {
    param([string]$Host_, [string]$Ym)
    $file = "{0}-{1}.md" -f $Host_, $Ym
    $roots = @()
    if ($env:OneDriveCommercial) { $roots += $env:OneDriveCommercial }
    if ($env:OneDrive)           { $roots += $env:OneDrive }
    # USERPROFILE\OneDrive* (e.g. "OneDrive - Pueo Business Solutions, LLC")
    Get-ChildItem -Path $env:USERPROFILE -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue |
        ForEach-Object { $roots += $_.FullName }
    foreach ($r in ($roots | Select-Object -Unique)) {
        $tk = Join-Path $r 'Claude\timekeeping'
        if (Test-Path $tk) { return (Join-Path $tk $file) }
    }
    # nothing resolvable: return best-guess path (may not exist) so the report can still say GAP
    if ($roots.Count -gt 0) { return (Join-Path (Join-Path ($roots | Select-Object -First 1) 'Claude\timekeeping') $file) }
    return $null
}

$WL_STUB_PREFIX = '?hr: [PENDING ' + [char]0x2014     # '?hr: [PENDING —' (em dash), matches lib-worklog.sh

$narr = Resolve-NarrativeFile -Host_ $host_ -Ym $ym
$narrLines = @()
if ($narr -and (Test-Path $narr)) { $narrLines = @(Get-Content $narr) }

Write-Output ("== worklog reconcile - {0} - {1} ==" -f $host_, $Day)
if ($narr) { Write-Output ("   narrative: {0}{1}" -f $narr, $(if (Test-Path $narr) { '' } else { '  [not found]' })) }
else       { Write-Output "   narrative: [OneDrive unresolved - cannot check narrative coverage]" }

if (-not (Test-Path $raw)) { Write-Output ("reconcile: no raw file for {0} ({1})" -f $ym, $raw); exit 0 }

# --- load this month's raw records, keep only this local day ---
$recs = @()
Get-Content $raw | Where-Object { $_ } | ForEach-Object {
    try { $o = $_ | ConvertFrom-Json } catch { return }
    if (-not $o.ts) { return }
    if (([string]$o.ts).StartsWith($Day)) { $recs += $o }
}
if ($recs.Count -eq 0) { Write-Output ("no sessions recorded for {0}" -f $Day); exit 0 }

$sids = @($recs | Where-Object { $_.sid } | ForEach-Object { [string]$_.sid } | Sort-Object -Unique)
if ($sids.Count -eq 0) { Write-Output ("no sessions recorded for {0}" -f $Day); exit 0 }

function NarrHasSid([string]$sid) {
    if ($narrLines.Count -eq 0) { return $false }
    foreach ($l in $narrLines) { if ($l -like "*[sid:$sid]*") { return $true } }
    return $false
}
function NarrSidIsStub([string]$sid) {
    foreach ($l in $narrLines) {
        if ($l -like "*[sid:$sid]*" -and $l -like "*$WL_STUB_PREFIX*") { return $true }
    }
    return $false
}

$gaps = 0; $total = 0
Write-Output ("{0,-10} {1,7}  {2,-13}  {3}" -f 'SID', 'PROMPTS', 'SPAN(local)', 'CWD  ·  STATUS')
Write-Output ("{0,-10} {1,7}  {2,-13}  {3}" -f '----------', '-------', '-------------', '------------------------')

foreach ($sid in $sids) {
    $sr = @($recs | Where-Object { [string]$_.sid -eq $sid })
    $pc = @($sr | Where-Object { $_.event -eq 'UserPromptSubmit' }).Count
    if ($pc -lt 1) { continue }                    # skip no-activity sessions (opened + closed)
    $total++
    $ts = @($sr | ForEach-Object { [string]$_.ts } | Sort-Object)
    # ts field is yyyy-MM-ddTHH:mm:sszzz - chars 12..16 (0-based 11) are HH:mm
    $first = if ($ts.Count -ge 1) { $ts[0].Substring(11, 5) } else { '?' }
    $last  = if ($ts.Count -ge 1) { $ts[-1].Substring(11, 5) } else { '?' }
    $cwd = ''
    foreach ($r in $sr) { if ($r.cwd) { $cwd = [string]$r.cwd } }   # last non-empty
    $leaf = if ($cwd) { ($cwd -replace '\\', '/').TrimEnd('/').Split('/')[-1] } else { '?' }

    if (NarrHasSid $sid) {
        if (NarrSidIsStub $sid) { $status = 'PENDING stub - needs a real line'; $gaps++ }
        else { $status = 'described' }
    } else {
        $status = '*** GAP - no narrative line ***'; $gaps++
    }
    $sidShort = if ($sid.Length -gt 10) { $sid.Substring(0, 10) } else { $sid }
    Write-Output ("{0,-10} {1,7}  {2,-13}  {3}  ·  {4}" -f $sidShort, $pc, ("{0}-{1}" -f $first, $last), $leaf, $status)
}

Write-Output ""
Write-Output ("{0} active session(s); {1} still need a narrative line for {2}." -f $total, $gaps, $Day)
if ($gaps -gt 0 -and $narr) {
    Write-Output ("Write a line per gap in {0} ending with its [sid:<id>] tag, then re-run." -f $narr)
}

# --- open ClickUp/Obsidian obligation debts for the month (from the Stop-hook ledger) ---
$oblig = Join-Path $repo ("obligations\{0}-{1}.ndjson" -f $host_, $ym)
if (Test-Path $oblig) {
    Write-Output ""
    Write-Output ("-- open capture obligations ({0}) --" -f $ym)
    $od = Join-Path $repo 'bin\obligations-doctor.ps1'
    if (Test-Path $od) {
        & pwsh -NoProfile -File $od $ym 2>$null | Where-Object { $_ -match '^\s\s' }
    }
}
exit 0
