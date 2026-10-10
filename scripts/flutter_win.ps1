# Runs flutter with a PATH that webcrypto's native-asset hook can build under.
#
#   powershell -File scripts\flutter_win.ps1 build windows
#   powershell -File scripts\flutter_win.ps1 run -d windows
#   powershell -File scripts\flutter_win.ps1 test test/
#
# Strawberry Perl puts its own cmake and ninja ahead of Visual Studio on the
# system PATH. webcrypto builds BoringSSL through CMake before any Hollow code
# compiles, picks Strawberry's Ninja while still passing -A x64, and fails with
# "CMAKE_C_COMPILER not set". BoringSSL still needs nasm, and Strawberry's is
# the only one on the machine, so it rides in alone from a directory of its own.
# The PATH change lives only in this process; the system PATH is untouched.
# Memory: feedback_flutter_test_native_assets_cmake.
#
# DEBUG builds also share one Rust build and one Firebase C++ SDK across every
# worktree, under the dev cache (HOLLOW_DEV_CACHE, else D:\dev\cache when D:\dev
# exists; scripts\dev_cache.ps1 shows, seeds and clears it). Release and profile
# builds never do: the variable is removed for them and cargokit ignores it
# anyway. Set HOLLOW_CARGOKIT_SHARED_DIR=off to build a debug tree on its own.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$vsRoot = 'C:\Program Files\Microsoft Visual Studio\2022\Community'
$vsCmake = "$vsRoot\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"
if (-not (Test-Path "$vsCmake\cmake.exe")) {
    throw "Visual Studio's cmake not found at $vsCmake"
}

$nasmDir = Join-Path $env:LOCALAPPDATA 'hollow-build\nasm'
if (-not (Test-Path "$nasmDir\nasm.exe")) {
    $strawberryNasm = 'C:\Strawberry\c\bin\nasm.exe'
    if (-not (Test-Path $strawberryNasm)) { throw "no nasm.exe at $strawberryNasm" }
    New-Item -ItemType Directory -Force $nasmDir | Out-Null
    Copy-Item $strawberryNasm $nasmDir
}

# A failed run leaves a CMakeCache that pins the Ninja generator, and CMake
# reuses it forever, so a poisoned cache has to go before the next attempt.
# Android builds use Ninja on purpose; their caches stay.
$caches = Get-ChildItem '.dart_tool\hooks_runner' -Recurse -Filter CMakeCache.txt -ErrorAction SilentlyContinue
foreach ($cache in $caches) {
    if ((Select-String -Path $cache.FullName -Pattern '^CMAKE_GENERATOR:INTERNAL=Ninja$' -Quiet) -and
        -not (Select-String -Path $cache.FullName -Pattern '^ANDROID_ABI:' -Quiet)) {
        Write-Host "[flutter_win] removing a Ninja-pinned hook cache: $($cache.DirectoryName)"
        Remove-Item -Recurse -Force $cache.DirectoryName
    }
}

$clean = ($env:PATH -split ';' | Where-Object { $_ -and $_ -notlike '*Strawberry*' }) -join ';'
$env:PATH = "$vsCmake;$nasmDir;$clean"

# `flutter build` defaults to release, `run` and `test` to debug.
$mode = if ($args -contains '--release') { 'release' }
        elseif ($args -contains '--profile') { 'profile' }
        elseif ($args -contains '--debug') { 'debug' }
        elseif ($args.Count -gt 0 -and $args[0] -eq 'build') { 'release' }
        else { 'debug' }
if ($mode -eq 'debug') {
    $devCache = if ($env:HOLLOW_DEV_CACHE) { $env:HOLLOW_DEV_CACHE } elseif (Test-Path 'D:\dev') { 'D:\dev\cache' } else { $null }
    if ($devCache) {
        if (-not $env:HOLLOW_CARGOKIT_SHARED_DIR) { $env:HOLLOW_CARGOKIT_SHARED_DIR = Join-Path $devCache 'hollow-cargokit' }
        $firebase = Join-Path $devCache 'firebase_cpp_sdk_windows'
        if (-not $env:FIREBASE_CPP_SDK_DIR -and (Test-Path "$firebase\include\firebase\version.h")) {
            $env:FIREBASE_CPP_SDK_DIR = $firebase
        }
    }
    if ($env:HOLLOW_CARGOKIT_SHARED_DIR) { Write-Host "[flutter_win] debug build, shared Rust build: $env:HOLLOW_CARGOKIT_SHARED_DIR" }
    if ($env:FIREBASE_CPP_SDK_DIR) { Write-Host "[flutter_win] Firebase C++ SDK: $env:FIREBASE_CPP_SDK_DIR" }
} else {
    Remove-Item Env:HOLLOW_CARGOKIT_SHARED_DIR -ErrorAction SilentlyContinue
}

& flutter @args
exit $LASTEXITCODE
