#!/usr/bin/env pwsh
# obligations-doctor.ps1 - view / resolve the capture-obligation debt ledger (read-mostly).
# Mirror of obligations-doctor.sh. The Stop hook (session-obligations.ps1) records unmet
# ClickUp/Obsidian obligations to obligations\<COMPUTERNAME>-YYYY-MM.ndjson IN THE REPO;
# the SessionEnd/doctor paths may add TIME/ENFORCEMENT records. This nets unmet vs resolved
# and lists what still owes attention. No jq needed (native ConvertFrom-Json).
#
#   pwsh -File obligations-doctor.ps1 [YYYY-MM]                 # list open debts for the month (default: now)
#   pwsh -File obligations-doctor.ps1 --resolve <sid> <OBLIG>   # mark (sid,OBLIG) resolved (appends a record)

$ErrorActionPreference = 'SilentlyContinue'
$repo  = if ($env:PUEO_WORKLOG_REPO) { $env:PUEO_WORKLOG_REPO } else { Join-Path $env:USERPROFILE 'git\pueo-worklog' }
$host_ = $env:COMPUTERNAME
$obDir = Join-Path $repo 'obligations'

# BOM-less UTF8, bare LF (match .gitattributes *.ndjson eol=lf and the .ps1 hook writer).
function Append-Line([string]$Path, [string]$Line) {
    $enc = New-Object System.Text.UTF8Encoding $false
    for ($i = 0; $i -lt 3; $i++) {
        try { [System.IO.File]::AppendAllText($Path, $Line + "`n", $enc); break } catch { Start-Sleep -Milliseconds 40 }
    }
}

# ---- --resolve <sid> <OBLIGATION> : append a resolved record ----
if ($args.Count -ge 1 -and $args[0] -eq '--resolve') {
    $sid = if ($args.Count -ge 2) { $args[1] } else { '' }
    $ob  = if ($args.Count -ge 3) { $args[2] } else { '' }
    if (-not $sid -or -not $ob) { Write-Output 'usage: --resolve <sid> <OBLIGATION>'; exit 1 }
    if (-not (Test-Path $obDir)) { New-Item -ItemType Directory -Force -Path $obDir | Out-Null }
    $f = Join-Path $obDir ("{0}-{1}.ndjson" -f $host_, (Get-Date).ToString('yyyy-MM'))
    $now = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    $rec = [ordered]@{ ts = $now; host = $host_; sid = $sid; cwd = '-'; obligation = $ob; resolved = $true; source = 'manual' }
    Append-Line $f (($rec | ConvertTo-Json -Compress))
    Write-Output ("resolved: {0} {1}" -f $sid, $ob)
    exit 0
}

# ---- list open debts for a month ----
$ym = if ($args.Count -ge 1 -and $args[0]) { $args[0] } else { (Get-Date).ToString('yyyy-MM') }
$f  = Join-Path $obDir ("{0}-{1}.ndjson" -f $host_, $ym)
Write-Output ("== obligation debts - {0} - {1} ==" -f $host_, $ym)
if (-not (Test-Path $f)) { Write-Output ("(no ledger for {0})" -f $ym); exit 0 }

$recs = @()
Get-Content $f | Where-Object { $_ } | ForEach-Object {
    try { $o = $_ | ConvertFrom-Json } catch { return }
    if ($o.obligation) { $recs += $o }
}

# net: an (sid,obligation) pair is OPEN if it has an unmet record and no resolved record.
$done = @{}
foreach ($r in $recs) {
    if ($r.resolved -eq $true) { $done[("{0}|{1}" -f $r.sid, $r.obligation)] = $true }
}
$open = @($recs | Where-Object {
    ($_.resolved -ne $true) -and (-not $done.ContainsKey(("{0}|{1}" -f $_.sid, $_.obligation)))
})

if ($open.Count -eq 0) {
    Write-Output '  (all obligations met / resolved)'
    exit 0
}

$n = 0
$byOb = $open | Group-Object obligation | Sort-Object Name
foreach ($g in $byOb) {
    $cnt  = $g.Count
    $sids = @($g.Group | ForEach-Object { ([string]$_.sid).Substring(0, [math]::Min(8, ([string]$_.sid).Length)) } | Sort-Object -Unique) -join ','
    Write-Output ("  {0,-12} open={1,-3}  sids: {2}" -f $g.Name, $cnt, $sids)
    $n += $cnt
}
Write-Output ""
Write-Output ("  {0} open obligation(s). Resolve: obligations-doctor.ps1 --resolve <sid> <OBLIGATION>" -f $n)
exit 0
