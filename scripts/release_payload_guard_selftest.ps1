# Self-test for release_payload_guard.ps1: every kind of profile data or portable
# marker in a Release folder is refused and named, a clean folder passes.
#   pwsh scripts/release_payload_guard_selftest.ps1                 # macOS, Linux
#   powershell -File scripts\release_payload_guard_selftest.ps1     # Windows
# Windows PowerShell 5.1: no pwsh-only syntax.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release_payload_guard.ps1')

$script:Passed = 0
$script:Failed = @()
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:Passed++; Write-Host "PASS $name" -ForegroundColor Green }
    else { $script:Failed += $name; Write-Host "FAIL $name $detail" -ForegroundColor Red }
}

function New-Release([string[]]$extra) {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("hollow-release-guard-" + [guid]::NewGuid().ToString('N'))
    foreach ($f in @('hollow.exe', 'hollow_core.dll', 'data/app.so', 'data/flutter_assets/AssetManifest.bin', 'data/flutter_assets/assets/db_icon.png') + $extra) {
        $p = Join-Path $dir $f
        New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
        if ($f.EndsWith('/')) { New-Item -ItemType Directory -Force $p | Out-Null } else { [System.IO.File]::WriteAllText($p, 'x') }
    }
    return $dir
}

function Refusal([string]$dir) {
    try { Assert-ReleasePayloadClean $dir; return '' } catch { return "$($_.Exception.Message)" }
}

$clean = New-Release @()
Check 'a clean Release folder passes' ((Refusal $clean) -eq '') (Refusal $clean)
Remove-Item -LiteralPath $clean -Recurse -Force

$cases = @(
    @{ name = 'the 0.14.1 stray data folder'; files = @('hollow_data/messages.db', 'hollow_data/hollow.lock'); expect = 'hollow_data' },
    @{ name = 'an empty data folder'; files = @('hollow_data/'); expect = 'hollow_data' },
    @{ name = 'a data folder in another case'; files = @('Hollow_Data/x.txt'); expect = 'Hollow_Data' },
    @{ name = 'portable.txt'; files = @('portable.txt'); expect = 'portable.txt' },
    @{ name = 'portable.txt.txt'; files = @('portable.txt.txt'); expect = 'portable.txt.txt' },
    @{ name = 'a bare portable marker'; files = @('portable'); expect = 'portable' },
    @{ name = 'a database anywhere'; files = @('data/old.db'); expect = 'old.db' },
    @{ name = 'a write-ahead log'; files = @('messages.db-wal'); expect = 'messages.db-wal' },
    @{ name = 'a shared-memory file'; files = @('messages.db-shm'); expect = 'messages.db-shm' },
    @{ name = 'a lock file'; files = @('hollow.lock'); expect = 'hollow.lock' },
    @{ name = 'an identity key'; files = @('identity.key'); expect = 'identity.key' },
    @{ name = 'an identity device file'; files = @('identity.device'); expect = 'identity.device' }
)
foreach ($c in $cases) {
    $dir = New-Release $c.files
    $why = Refusal $dir
    Check "refuses $($c.name)" ($why -ne '' -and $why.Contains($c.expect)) $why
    Remove-Item -LiteralPath $dir -Recurse -Force
}

$both = New-Release @('hollow_data/messages.db', 'portable.txt')
$why = Refusal $both
Check 'names every intruder' ($why.Contains('hollow_data') -and $why.Contains('portable.txt') -and -not $why.Contains('messages.db')) $why
Remove-Item -LiteralPath $both -Recurse -Force

Write-Host "$($script:Passed) passed, $($script:Failed.Count) failed"
if ($script:Failed.Count -gt 0) { exit 1 }
