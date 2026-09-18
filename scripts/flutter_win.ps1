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
$caches = Get-ChildItem '.dart_tool\hooks_runner' -Recurse -Filter CMakeCache.txt -ErrorAction SilentlyContinue
foreach ($cache in $caches) {
    if (Select-String -Path $cache.FullName -Pattern '^CMAKE_GENERATOR:INTERNAL=Ninja$' -Quiet) {
        Write-Host "[flutter_win] removing a Ninja-pinned hook cache: $($cache.DirectoryName)"
        Remove-Item -Recurse -Force $cache.DirectoryName
    }
}

$clean = ($env:PATH -split ';' | Where-Object { $_ -and $_ -notlike '*Strawberry*' }) -join ';'
$env:PATH = "$vsCmake;$nasmDir;$clean"

& flutter @args
exit $LASTEXITCODE
