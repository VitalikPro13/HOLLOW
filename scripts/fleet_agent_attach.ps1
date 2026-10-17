# One ssh connection's end of a fleet agent on WINDOWS, the twin of
# fleet_agent_attach.sh (same protocol, same req/ -> run/ -> ans/ files). Run
# in-process by the ssh login shell (Windows PowerShell 5.1 or PowerShell 7), so
# its console streams ARE the connection.
#
#   & scripts\fleet_agent_attach.ps1 <agent> <session>
#
# The server (fleet_remote_agent.ps1 -Serve, under Windows PowerShell) must outlive
# the connection, and OpenSSH for Windows kills every process of a session when it
# ends. So it starts through a one-shot scheduled task in the owner's own desktop
# session, hidden (wscript, window style 0): never a window, never the foreground,
# and the same session a fleet started at the PC itself runs in. Not meant to be
# run by hand.

param(
    [Parameter(Mandatory = $true)][string]$Agent,
    [Parameter(Mandatory = $true)][string]$Session
)

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot
if ($Agent -notmatch '^[a-z-]+$' -or $Session -notmatch '^[A-Za-z0-9]+$') { [Console]::Out.Write("bad agent or session`n"); exit 2 }
$dir = Join-Path $repoRoot ".team\agent-$Agent"
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)

# Non-ASCII goes as \u escapes: the console codepage of this pipe is not UTF-8.
function Send-Proto($json) {
    $ascii = [regex]::Replace($json, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
    [Console]::Out.Write('@@FLEET@@ ' + $ascii + "`n")
    [Console]::Out.Flush()
}
function Send-Fail($id, $why) {
    $text = "$why (see .team\agent-$Agent.log on $([System.Net.Dns]::GetHostName()))" -replace '[\\"]', ''
    Send-Proto ('{"id":"' + $id + '","ok":false,"error":"' + $text + '"}')
}
function Get-ServerPid {
    $file = Join-Path $dir 'pid'
    if (-not (Test-Path $file)) { return 0 }
    $text = "$(Get-Content -Raw $file -ErrorAction SilentlyContinue)".Trim()
    if ($text -notmatch '^\d+$') { return 0 }
    return [int]$text
}
function Test-ServerAlive {
    $id = Get-ServerPid
    if ($id -eq 0) { return $false }
    $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
    return [bool]($proc -and $proc.ProcessName -eq 'powershell')
}
function Read-Text($path) { return [System.IO.File]::ReadAllText($path, $utf8).Trim() }

# Another driver's server: a new driver starts clean, as a fresh agent always did.
$sessionFile = Join-Path $dir 'session'
if ((Test-ServerAlive) -and ((Test-Path $sessionFile) -and (Read-Text $sessionFile) -ne $Session)) {
    New-Item -ItemType File -Path (Join-Path $dir 'quit') -Force | Out-Null
    for ($i = 0; $i -lt 100 -and (Test-ServerAlive); $i++) { Start-Sleep -Milliseconds 100 }
    if (Test-ServerAlive) { Stop-Process -Id (Get-ServerPid) -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 300
}
if (-not (Test-ServerAlive)) {
    foreach ($name in 'req', 'run', 'ans', 'quit', 'hello.json', 'pid') {
        $path = Join-Path $dir $name
        if (Test-Path $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
    foreach ($name in 'req', 'run', 'ans') { New-Item -ItemType Directory -Path (Join-Path $dir $name) -Force | Out-Null }
    [System.IO.File]::WriteAllText($sessionFile, $Session, $utf8)
    # The task carries none of this connection's environment: FLEET_* goes in a file.
    $envLines = @(Get-ChildItem Env: | Where-Object { $_.Name -like 'FLEET_*' } | ForEach-Object { "$($_.Name)=$($_.Value)" })
    [System.IO.File]::WriteAllText((Join-Path $dir 'env.txt'), (($envLines -join "`n") + "`n"), $utf8)
    $log = Join-Path $repoRoot ".team\agent-$Agent.log"
    $server = Join-Path $PSScriptRoot 'fleet_remote_agent.ps1'
    $command = "cmd.exe /c powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$server"" -Serve ""$dir"" -WritePid -EnvFile ""$dir\env.txt"" >> ""$log"" 2>&1"
    $vbs = Join-Path $dir 'start.vbs'
    [System.IO.File]::WriteAllText($vbs, ('CreateObject("WScript.Shell").Run "' + $command.Replace('"', '""') + '", 0, False' + "`r`n"), [System.Text.Encoding]::ASCII)
    $task = "HollowFleet-$Agent-$((Split-Path -Leaf $repoRoot) -replace '[^A-Za-z0-9-]', '')"
    $made = & schtasks.exe /create /tn $task /tr "wscript.exe //B //Nologo ""$vbs""" /sc once /st 23:59 /it /f 2>&1
    if ($LASTEXITCODE -ne 0) { Send-Fail 0 "schtasks create failed: $made"; exit 1 }
    $ran = & schtasks.exe /run /tn $task 2>&1
    $runCode = $LASTEXITCODE
    & schtasks.exe /delete /tn $task /f 2>&1 | Out-Null
    if ($runCode -ne 0) { Send-Fail 0 "schtasks run failed: $ran"; exit 1 }
}

$hello = Join-Path $dir 'hello.json'
for ($i = 0; $i -lt 1200 -and -not (Test-Path $hello); $i++) { Start-Sleep -Milliseconds 100 }
if (-not (Test-Path $hello)) { Send-Fail 0 'agent server did not start'; exit 1 }
Send-Proto (Read-Text $hello)

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    # A BOM (as any codepage reads it) or a CR around the request.
    $line = ($line -replace '^[^A-Za-z0-9]+', '').TrimEnd("`r")
    $at = $line.IndexOf(' ')
    if ($at -lt 1) { Send-Fail -1 'bad request'; continue }
    $key = $line.Substring(0, $at)
    $json = $line.Substring($at + 1)
    if ($key -notmatch '^[A-Za-z0-9]+-[0-9]+$') { Send-Fail -1 'bad request key'; continue }
    if ($json -eq 'quit') {
        New-Item -ItemType File -Path (Join-Path $dir 'quit') -Force | Out-Null
        exit 0
    }
    $answer = Join-Path $dir "ans\$key.json"
    if (-not (Test-Path $answer) -and -not (Test-Path (Join-Path $dir "run\$key.json")) -and -not (Test-Path (Join-Path $dir "req\$key.json"))) {
        $tmp = Join-Path $dir "req\.$key.tmp"
        [System.IO.File]::WriteAllText($tmp, $json, $utf8)
        Move-Item -LiteralPath $tmp -Destination (Join-Path $dir "req\$key.json") -Force
    }
    while (-not (Test-Path $answer)) {
        if (-not (Test-ServerAlive)) { Send-Fail $key 'agent server ended'; exit 1 }
        Start-Sleep -Milliseconds 100
    }
    Send-Proto (Read-Text $answer)
}
