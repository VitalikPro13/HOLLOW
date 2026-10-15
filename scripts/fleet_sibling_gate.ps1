# The sibling-sync gate as a release runs it: scripts\fleet_md_sibling.ps1 with the
# mini reachable at -MiniHost, its whole output and wall time in one log. A release
# runs the desktop pair with -Quick (~12 min); a multi-device change runs the full
# gate on a desktop pair and on a phone in both directions (~35-40 min each).
#
#   powershell -File scripts\fleet_sibling_gate.ps1 -Holder win:s -Linked win:t -Friend win:u -Other win:v -Quick
#   powershell -File scripts\fleet_sibling_gate.ps1 -Holder win:s -Linked android:w -Friend win:u -Other win:v -Build
#
# -Build first rebuilds the Windows peers here and, for a phone or Mac peer, ships
# this worktree to the mini as ~/wt/<MiniName> (`scripts/mini_sync.sh`) and builds it
# there. The mini's address is -MiniHost, else FLEET_MINI_SSH, else its LAN address.

param(
    [string]$Holder = 'win:s',
    [string]$Linked = 'win:t',
    [string]$Friend = 'win:u',
    [string]$Other = 'win:v',
    [switch]$Quick,
    [switch]$SkipLostDb,
    [switch]$Build,
    [string]$Log = '',
    [string]$MiniName = '',
    [string]$MiniHost = $(if ($env:FLEET_MINI_SSH) { $env:FLEET_MINI_SSH } else { 'jabun@192.168.18.36' })
)

if ($args.Count -gt 0) { throw "unrecognised argument(s): $($args -join ' ')" }
# Continue: a child's stderr (ssh, gradle) must never end the gate; failures throw explicitly.
$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot
if (-not $MiniName) { $MiniName = Split-Path -Leaf $repoRoot }
$env:FLEET_MINI_SSH = $MiniHost
$env:MINI_HOST = $MiniHost
if (-not $env:FLEET_MINI_TREE) { $env:FLEET_MINI_TREE = "~/wt/$MiniName" }
$miniSsh = @('-o', 'HostKeyAlias=192.168.18.39', '-o', 'ConnectTimeout=20', '-o', 'BatchMode=yes', $MiniHost)
if (-not $Log) {
    $dir = Join-Path $repoRoot 'build\fleet_out\kept\md_sibling'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $Log = Join-Path $dir ("gate-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$started = Get-Date

$peers = @($Holder, $Linked, $Friend, $Other) | ForEach-Object {
    if ($_ -notmatch '^(?:(win|android|ios|macos|linux):)?([a-z])$') { throw "a peer is <platform>:<letter> (got '$_')" }
    [pscustomobject]@{ Platform = $(if ($Matches[1]) { $Matches[1] } else { 'win' }); Letter = $Matches[2] }
}
function Get-Letters($platform) { return (@($peers | Where-Object Platform -eq $platform | ForEach-Object Letter) -join ',') }

function Invoke-Mini($command) {
    # Out-Host: anything ssh prints would otherwise join the return value.
    & ssh @miniSsh "zsh -lc '$command'" | Out-Host
    return $LASTEXITCODE
}

if ($Build) {
    $win = Get-Letters 'win'
    if ($win) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'fleet.ps1') -Build -Peers $win
        if ($LASTEXITCODE -ne 0) { throw 'the Windows build failed' }
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'fleet.ps1') -Stop -Peers $win
    }
    $remote = @($peers | Where-Object { $_.Platform -in @('android', 'ios', 'macos') })
    if ($remote.Count -gt 0) {
        $bash = @("$env:ProgramFiles\Git\bin\bash.exe", "$env:ProgramFiles\Git\usr\bin\bash.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $bash) { throw 'Git bash not found' }
        & $bash (Join-Path $PSScriptRoot 'mini_sync.sh') $MiniName ($repoRoot -replace '\\', '/')
        if ($LASTEXITCODE -ne 0) { throw 'mini_sync failed' }
        foreach ($platform in @('android', 'ios', 'macos')) {
            $letters = Get-Letters $platform
            if (-not $letters) { continue }
            $backend = if ($platform -eq 'ios') { '' } else { "FLEET_BACKEND=$platform " }
            $built = Invoke-Mini "cd ~/wt/$MiniName && ${backend}pwsh scripts/fleet.ps1 -Build -Peers $letters && ${backend}pwsh scripts/fleet.ps1 -Stop -Peers $letters"
            if ($built -ne 0) { throw "the $platform build failed" }
        }
        $names = (@($remote | ForEach-Object { "hollow-$($_.Letter)" }) -join ' ')
        $down = ((Join-Path $PSScriptRoot 'mini_devices_down.sh') -replace '\\', '/')
        & $bash -c "ssh $($miniSsh -join ' ') 'bash -s -- $names' < '$down'" | Out-Null
    }
}

$extra = @()
if ($Quick) { $extra += '-Quick' }
if ($SkipLostDb) { $extra += '-SkipLostDb' }
# UTF-8 line by line: Windows PowerShell's Tee-Object writes UTF-16, which grep cannot read.
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'fleet_md_sibling.ps1') -Holder $Holder -Linked $Linked -Friend $Friend -Other $Other @extra *>&1 |
    ForEach-Object { "$_" } | ForEach-Object { $_; Add-Content -Path $Log -Value $_ -Encoding UTF8 }
$code = $LASTEXITCODE
$wall = [int]((Get-Date) - $started).TotalSeconds
$end = "EXIT=$code WALL=$wall"
$end
Add-Content -Path $Log -Value $end -Encoding UTF8
exit $code
