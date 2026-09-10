# FGI - run one command on every fleet worker's persistent cmd session.
# Usage (from any cmd window on the cockpit):
#   FGI cd desktop                 run on ALL workers (state persists!)
#   FGI pip install requests       runs in the SAME session, same cwd
#   FGI status                     ping every worker
#   FGI list                       show worker IPs
#   FGI refresh                    rescan the tailnet for fgi-worker-* nodes
#   FGI help                       this help
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
$ErrorActionPreference = 'Continue'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$tsExe = 'C:\Program Files\Tailscale\tailscale.exe'

$token = ''
if (Test-Path "$dir\token.txt") { $token = ((Get-Content "$dir\token.txt") -join '').Trim() }

function Get-Workers {
    $file = "$dir\workers.txt"
    if (-not (Test-Path $file)) { return @() }
    return @(Get-Content $file | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function Update-Workers {
    # Prune: keep only workers that answer /ping right now (works offline
    # inside the RDP session - no GitHub API needed).
    $file = "$dir\workers.txt"
    $alive = @()
    foreach ($ip in (Get-Workers)) {
        try {
            $null = Invoke-WebRequest -Uri ("http://{0}:8442/ping" -f $ip) -Headers @{ 'X-FGI-Token' = $token } -TimeoutSec 4 -UseBasicParsing
            $alive += $ip
        } catch {
            Write-Host ("dropping unresponsive worker " + $ip) -ForegroundColor Yellow
        }
    }
    Set-Content -Path $file -Value $alive -Encoding ascii
    Write-Host ('Alive workers: ' + $alive.Count + ' -> ' + ($alive -join ', ')) -ForegroundColor Green
}

$cmd = ''
if ($Rest) { $cmd = ($Rest -join ' ') }

if ($cmd -eq '' -or $cmd -eq 'help') {
    Write-Host 'FGI - fleet command runner. Usage:'
    Write-Host '  FGI <command>     run <command> on every worker (persistent sessions)'
    Write-Host '  FGI status        ping every worker'
    Write-Host '  FGI list          show worker IPs'
    Write-Host '  FGI refresh       ping all known workers, drop unresponsive ones'
    return
}
if ($cmd -eq 'refresh') { Update-Workers; return }
if ($cmd -eq 'list') {
    $w = Get-Workers
    if ($w.Count -eq 0) { Write-Host 'No workers known. Try: FGI refresh' -ForegroundColor Yellow }
    else { $i = 0; foreach ($ip in $w) { Write-Host ("[{0}] {1}" -f $i, $ip); $i++ } }
    return
}
if ($cmd -eq 'status') {
    $w = Get-Workers
    if ($w.Count -eq 0) { Write-Host 'No workers known. Try: FGI refresh' -ForegroundColor Yellow; return }
    foreach ($ip in $w) {
        try {
            $r = Invoke-WebRequest -Uri ("http://{0}:8442/ping" -f $ip) -Headers @{ 'X-FGI-Token' = $token } -TimeoutSec 8 -UseBasicParsing
            Write-Host ("[{0}] ONLINE  {1}" -f $ip, $r.Content) -ForegroundColor Green
        } catch {
            Write-Host ("[{0}] OFFLINE ({1})" -f $ip, $_.Exception.Message) -ForegroundColor Red
        }
    }
    return
}

# ---- default: broadcast the command to every worker ----
$w = Get-Workers
if ($w.Count -eq 0) {
    Write-Host 'No workers known yet - scanning tailnet...' -ForegroundColor Yellow
    Update-Workers
    $w = Get-Workers
    if ($w.Count -eq 0) { Write-Host 'Still no fgi-worker-* nodes found. Did the fleet start?' -ForegroundColor Red; return }
}
$fail = 0
$i = 0
foreach ($ip in $w) {
    Write-Host ("=== [{0}/{1}] {2} ===" -f ($i + 1), $w.Count, $ip) -ForegroundColor Cyan
    try {
        $r = Invoke-WebRequest -Uri ("http://{0}:8442/exec" -f $ip) -Method Post -Body $cmd -ContentType 'text/plain' -Headers @{ 'X-FGI-Token' = $token } -TimeoutSec 150 -UseBasicParsing
        Write-Host $r.Content
        if ($r.Content -match 'FGI_EXIT=(\d+)') {
            if ([int]$Matches[1] -ne 0) { $fail++ }
        }
    } catch {
        Write-Host ('OFFLINE/ERROR: ' + $_.Exception.Message) -ForegroundColor Red
        $fail++
    }
    $i++
}
Write-Host ('--- done: ' + ($w.Count - $fail) + ' ok, ' + $fail + ' failed/exit-nonzero ---') -ForegroundColor ($fail -eq 0 ? 'Green' : 'Yellow')
