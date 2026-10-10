# The shared dev cache that debug builds of every worktree use (see
# scripts\flutter_win.ps1): one cargokit Rust target with its built DLL sets,
# and one extracted Firebase C++ SDK. Release builds never touch it.
#
#   powershell -File scripts\dev_cache.ps1                      # where it is, what it holds
#   powershell -File scripts\dev_cache.ps1 -SeedFirebase        # copy an extracted SDK in once
#   powershell -File scripts\dev_cache.ps1 -Clear               # drop the Rust target and DLL sets
#   powershell -File scripts\dev_cache.ps1 -SeedWorktree D:\dev\wt\x   # a new worktree's configs, runtime binaries and nextest target
#
# -SeedWorktree copies the gitignored configs, the runtime binaries the Windows
# build bundles and rust\hollow_core\target from the tree this script lives in,
# or from -From (incremental left out, timestamps kept), then
# deletes the path crates' fingerprints in the copy: cargo judges a path crate
# fresh by mtimes, and the copy must never pass for the new tree's own build.
param(
    [switch]$SeedFirebase,
    [string]$From = '',
    [switch]$Clear,
    [string]$SeedWorktree = ''
)
if ($args.Count -gt 0) { throw "unrecognised argument(s): $($args -join ' ')" }
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

$devCache = if ($env:HOLLOW_DEV_CACHE) { $env:HOLLOW_DEV_CACHE } elseif (Test-Path 'D:\dev') { 'D:\dev\cache' } else { throw 'no dev cache: set HOLLOW_DEV_CACHE' }
$shared = if ($env:HOLLOW_CARGOKIT_SHARED_DIR -and $env:HOLLOW_CARGOKIT_SHARED_DIR -ne 'off') { $env:HOLLOW_CARGOKIT_SHARED_DIR } else { Join-Path $devCache 'hollow-cargokit' }
$firebase = Join-Path $devCache 'firebase_cpp_sdk_windows'

function Size-GB($p) {
    if (-not (Test-Path $p)) { return 'absent' }
    $b = (Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Sum Length).Sum
    return ('{0:N1} GB' -f ($b / 1GB))
}

function Robo($src, $dst, [string[]]$extra) {
    robocopy $src $dst /E /COPY:DAT /DCOPY:T /MT:16 /NFL /NDL /NJH /NP @extra | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy $src -> $dst failed with $LASTEXITCODE" }
    $global:LASTEXITCODE = 0
}

if ($SeedFirebase) {
    $src = if ($From) { $From } else { Join-Path $repoRoot 'build\windows\x64\extracted\firebase_cpp_sdk_windows' }
    if (-not (Test-Path "$src\include\firebase\version.h")) { throw "no extracted Firebase SDK at $src (build once without the cache, or pass -From)" }
    Write-Host "copying the Firebase C++ SDK from $src to $firebase"
    Robo $src $firebase @()
}

if ($Clear) {
    if (Test-Path $shared) {
        $lock = Join-Path $shared 'build.lock'
        $fs = $null
        if (Test-Path $lock) {
            try { $fs = [IO.File]::Open($lock, 'Open', 'ReadWrite', 'None') }
            catch { throw "a build holds $lock; clear it when no build runs" }
        }
        try {
            foreach ($part in 'target', 'dll', 'state') {
                $p = Join-Path $shared $part
                if (Test-Path $p) { Remove-Item -Recurse -Force $p }
            }
        } finally { if ($fs) { $fs.Close() } }
        Write-Host "cleared $shared"
    }
}

if ($SeedWorktree) {
    $dst = (Resolve-Path $SeedWorktree).Path
    $seedFrom = if ($From) { (Resolve-Path $From).Path } else { $repoRoot }
    foreach ($rel in 'rust\hollow_core\.cargo\config.toml', 'android\app\google-services.json') {
        $s = Join-Path $seedFrom $rel
        $d = Join-Path $dst $rel
        if ((Test-Path $s) -and -not (Test-Path $d)) {
            New-Item -ItemType Directory -Force (Split-Path $d) | Out-Null
            Copy-Item $s $d
            Write-Host "copied $rel"
        }
    }
    # Gitignored binaries the Windows CMake copies next to hollow.exe only if
    # present, so a tree without them builds clean and fails at runtime:
    # voice notes never play without ffmpeg, screen-share audio stays silent
    # without the capturer.
    $runtimeBins = @(
        @{ rel = 'vendor\ffmpeg\ffmpeg-win-x64.exe'; what = 'ffmpeg (voice notes, video thumbnails)'; fetch = 'scripts\fetch_ffmpeg.ps1' },
        @{ rel = 'packages\flutter_webrtc\test_apps\screen_audio_test\build\Release\screen_audio_test.exe'; what = 'screen_audio_capturer.exe (screen-share audio)'; fetch = 'a Release build of packages\flutter_webrtc\test_apps\screen_audio_test' }
    )
    foreach ($bin in $runtimeBins) {
        $s = Join-Path $seedFrom $bin.rel
        $d = Join-Path $dst $bin.rel
        if (Test-Path $d) { continue }
        if (-not (Test-Path $s)) {
            Write-Host "SKIPPED $($bin.rel): $seedFrom has none, so $($bin.what) will be missing (needs $($bin.fetch))"
            continue
        }
        New-Item -ItemType Directory -Force (Split-Path $d) | Out-Null
        Copy-Item (Join-Path (Split-Path $s) '*') (Split-Path $d) -Recurse
        Write-Host "copied $(Split-Path $bin.rel)\"
    }
    $srcTarget = Join-Path $seedFrom 'rust\hollow_core\target'
    $dstTarget = Join-Path $dst 'rust\hollow_core\target'
    if (Test-Path $srcTarget) {
        Write-Host "copying $srcTarget (no incremental) to $dstTarget"
        Robo $srcTarget $dstTarget @('/XD', 'incremental')
        # Path crates are the lock entries without a source.
        $lockText = [IO.File]::ReadAllText((Join-Path $dst 'rust\hollow_core\Cargo.lock'))
        $pathCrates = @($lockText -split '\[\[package\]\]' | Where-Object { $_ -notmatch '(?m)^source = ' -and $_ -match '(?m)^name = "([^"]+)"' } | ForEach-Object { [void]($_ -match '(?m)^name = "([^"]+)"'); $Matches[1] })
        $n = 0
        foreach ($fp in @("$dstTarget\debug\.fingerprint", "$dstTarget\release\.fingerprint")) {
            if (-not (Test-Path $fp)) { continue }
            Get-ChildItem $fp -Directory | Where-Object {
                $name = $_.Name
                @($pathCrates | Where-Object { $name -match ('^' + [regex]::Escape($_) + '-[0-9a-f]{16}$') }).Count -gt 0
            } | ForEach-Object { Remove-Item -Recurse -Force $_.FullName; $n++ }
        }
        Write-Host "reset $n path-crate fingerprints in the copy"
    }
}

Write-Host "dev cache: $devCache"
Write-Host ("  shared Rust target   {0}  {1}" -f (Join-Path $shared 'target'), (Size-GB (Join-Path $shared 'target')))
Write-Host ("  built DLL sets       {0}  {1}" -f (Join-Path $shared 'dll'), (Size-GB (Join-Path $shared 'dll')))
Write-Host ("  Firebase C++ SDK     {0}  {1}" -f $firebase, (Size-GB $firebase))
