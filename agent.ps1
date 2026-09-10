# FGI worker agent - holds ONE persistent shell and serves it over HTTP.
# Routes:  GET  /ping  -> liveness info
#          POST /exec  -> body = command text, runs in the persistent shell
# Auth:    header X-FGI-Token must match -Token (when set)
# NOTE: the exit code is read on a SEPARATE line after the command, because
#       cmd.exe expands %errorlevel% when a line is parsed (a one-liner
#       'cmd & echo %errorlevel%' would report the PREVIOUS command's code).
param(
    [string]$Token = '',
    [int]$Port = 8442,
    [string]$ShellPath = '',
    [string]$ShellArgs = '',
    [string]$ErrVar = '%errorlevel%'
)
$ErrorActionPreference = 'Continue'
if (-not $ShellPath) { $ShellPath = $env:ComSpec; $ShellArgs = '/q' }

# ---- listener (retry once with URL ACL in case http.sys refused) ----
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add('http://+:' + $Port + '/')
try {
    $listener.Start()
} catch {
    Write-Host ('FGI agent: first bind failed (' + $_.Exception.Message + ') - adding URL ACL and retrying')
    netsh http add urlacl url='http://+:' + $Port + '/' sddl='D:(A;;GX;;;WD)' | Out-Null
    Start-Sleep -Seconds 1
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add('http://+:' + $Port + '/')
    $listener.Start()
}
Write-Host ('FGI agent listening on port ' + $Port)

# ---- the persistent shell process ----
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $ShellPath
$psi.Arguments = $ShellArgs
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.WorkingDirectory = $env:USERPROFILE
if (-not $psi.WorkingDirectory) { $psi.WorkingDirectory = (Get-Location).Path }
$proc = [System.Diagnostics.Process]::Start($psi)
if ($ErrVar -eq '%errorlevel%') { [void]$proc.StandardInput.WriteLine('@echo off') }

# ---- async output capture via dedicated reader runspaces (thread-safe;
#      avoids Register-ObjectEvent, whose actions are NOT pumped while
#      the request loop runs synchronously) ----
$outQ = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
$errQ = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
$readerScript = {
    param($proc, $q, $which)
    $reader = if ($which -eq 'out') { $proc.StandardOutput } else { $proc.StandardError }
    try { while ($null -ne ($line = $reader.ReadLine())) { $q.Enqueue($line) } } catch {}
}
foreach ($which in 'out', 'err') {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    # Direct assignment - routing the queue through if-output would let the
    # pipeline ENUMERATE (and empty) the ConcurrentQueue before binding it.
    $target = $outQ; if ($which -eq 'err') { $target = $errQ }
    [void]$ps.AddScript($readerScript).AddArgument($proc).AddArgument($target).AddArgument($which)
    [void]$ps.BeginInvoke()
}

function Invoke-FgiCommand([string]$userCmd) {
    $id = [guid]::NewGuid().ToString('N')
    $marker = '__FGI_DONE_' + $id + '_'
    [void]$proc.StandardInput.WriteLine($userCmd)
    [void]$proc.StandardInput.WriteLine('echo ' + $marker + $ErrVar + '__')
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    $lines = New-Object System.Collections.Generic.List[string]
    $code = ''
    $done = $false
    while ((-not $done) -and ([DateTime]::UtcNow -lt $deadline)) {
        $m = $null
        while ($outQ.TryDequeue([ref]$m)) {
            if ($m.Contains($marker)) {
                if ($m -match '_(\d+)__\s*$') { $code = $Matches[1] }
                $done = $true
                break
            }
            [void]$lines.Add($m)
        }
        if ($done) { break }
        $e = $null
        while ($errQ.TryDequeue([ref]$e)) { [void]$lines.Add('[stderr] ' + $e) }
        Start-Sleep -Milliseconds 50
    }
    if (-not $done) { $code = 'timeout' }
    $body = ($lines -join [Environment]::NewLine)
    if ($body.Length -gt 60000) { $body = '... (truncated) ...' + $body.Substring($body.Length - 60000) }
    return '=== output ===' + [Environment]::NewLine + $body + [Environment]::NewLine + '=== FGI_EXIT=' + $code + ' ==='
}

# ---- request loop (serial by design: one shell, commands queue up) ----
while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $res = $ctx.Response
    try {
        $req = $ctx.Request
        $tok = $req.Headers['X-FGI-Token']
        if ($Token -and ($tok -ne $Token)) {
            $res.StatusCode = 401
            $res.StatusDescription = 'bad token'
        }
        elseif ($req.HttpMethod -eq 'GET' -and $req.Url.AbsolutePath -eq '/ping') {
            $res.StatusCode = 200
            $body = 'host=' + $env:COMPUTERNAME + ' agent=ok port=' + $Port
            $bytes = [Text.Encoding]::UTF8.GetBytes($body)
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        elseif ($req.HttpMethod -eq 'POST' -and $req.Url.AbsolutePath -eq '/exec') {
            $res.StatusCode = 200
            $reader = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
            $userCmd = $reader.ReadToEnd()
            $out = Invoke-FgiCommand $userCmd
            $bytes = [Text.Encoding]::UTF8.GetBytes($out)
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        else {
            $res.StatusCode = 404
            $res.StatusDescription = 'not found'
        }
    } catch {
        try {
            $res.StatusCode = 500
            $msg = [Text.Encoding]::UTF8.GetBytes('agent error: ' + $_.Exception.Message)
            $res.ContentLength64 = $msg.Length
            $res.OutputStream.Write($msg, 0, $msg.Length)
        } catch {}
    } finally {
        try { $res.Close() } catch {}
    }
}
