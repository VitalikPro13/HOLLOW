<#
.SYNOPSIS
    One-shot Hollow Windows release pipeline:
    build, sign binaries, build installer, sign installer, zip portable.

.DESCRIPTION
    Steps (each can be skipped via switches):
      1. flutter build windows --release
      2. scripts\sign_release.ps1   (sign all .exe/.dll in the Release folder)
      3. Inno Setup compile installer\hollow.iss into setup.exe
      4. scripts\sign_file.ps1      (sign the setup.exe)
      5. Compress the Release folder into hollow-<ver>-win64.zip (portable)

    You will be prompted for the card PIN (typically once, cached for the session).

    No secrets in this script (key stays on card, PIN typed live, thumbprint public),
    so it is safe to commit.

.PARAMETER Version
    Version string for output filenames + installer. Defaults to the version in pubspec.yaml.

.PARAMETER SkipBuild
    Skip 'flutter build windows' (use the existing Release folder as-is).

.PARAMETER SkipInstaller
    Skip Inno Setup + installer signing (produce only the signed ZIP).

.PARAMETER SkipZip
    Skip the portable ZIP (produce only the installer).

.EXAMPLE
    .\scripts\build_release.ps1
    .\scripts\build_release.ps1 -SkipBuild
    .\scripts\build_release.ps1 -Version 0.5.1
#>

param(
    [string]$Version,
    [switch]$SkipBuild,
    [switch]$SkipInstaller,
    [switch]$SkipZip
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$releaseDir = Join-Path $repo 'build\windows\x64\runner\Release'

function Step($n, $msg) { Write-Host "`n==== [$n] $msg ====" -ForegroundColor Cyan }

# --- Resolve version from pubspec if not given ---
if (-not $Version) {
    $line = Get-Content (Join-Path $repo 'pubspec.yaml') | Where-Object { $_ -match '^version:' } | Select-Object -First 1
    if ($line -match '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)') { $Version = $Matches[1] }
    else { throw 'Could not parse version from pubspec.yaml; pass -Version explicitly.' }
}
Write-Host "Hollow release pipeline - version $Version" -ForegroundColor Green

# --- 1. Build ---
if (-not $SkipBuild) {
    Step 1 'flutter build windows --release'
    Push-Location $repo
    try {
        & flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw "flutter build failed with exit code $LASTEXITCODE" }
    } finally { Pop-Location }
} else { Step 1 'flutter build (SKIPPED)' }

if (-not (Test-Path $releaseDir)) { throw "Release folder not found: $releaseDir" }

# --- 2. Sign payload binaries ---
Step 2 'Sign Release binaries'
& (Join-Path $PSScriptRoot 'sign_release.ps1') -Path $releaseDir

# --- 3 + 4. Installer ---
$setupExe = $null
if (-not $SkipInstaller) {
    Step 3 'Build installer (Inno Setup)'
    $isccCandidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
    )
    $iscc = $isccCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $iscc) {
        $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
        if ($cmd) { $iscc = $cmd.Source }
    }
    if (-not $iscc) { throw 'Inno Setup compiler (ISCC.exe) not found. Install Inno Setup 6.' }

    $iss = Join-Path $repo 'installer\hollow.iss'
    & $iscc "/DAppVersion=$Version" $iss
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup compile failed with exit code $LASTEXITCODE" }

    $setupExe = Join-Path $repo "installer\Output\hollow-$Version-win64-setup.exe"
    if (-not (Test-Path $setupExe)) { throw "Expected installer not produced: $setupExe" }

    Step 4 'Sign installer'
    & (Join-Path $PSScriptRoot 'sign_file.ps1') -File $setupExe
} else { Step '3-4' 'Installer (SKIPPED)' }

# --- 5. Portable ZIP ---
$zipPath = $null
if (-not $SkipZip) {
    Step 5 'Zip portable Release folder'
    $outDir = Join-Path $repo 'installer\Output'
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $zipPath = Join-Path $outDir "hollow-$Version-win64.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    # Exclude build/link artifacts and local logs so the portable ZIP matches the installer payload.
    $excludeExt = '.lib', '.exp', '.pdb', '.log'
    $zipItems = Get-ChildItem $releaseDir -Force |
        Where-Object { $excludeExt -notcontains $_.Extension }
    Compress-Archive -Path $zipItems.FullName -DestinationPath $zipPath -CompressionLevel Optimal
} else { Step 5 'Zip (SKIPPED)' }

# --- Summary ---
Write-Host "`n==== DONE - version $Version ====" -ForegroundColor Green
if ($setupExe) { Write-Host "  Installer: $setupExe" -ForegroundColor Green }
if ($zipPath)  { Write-Host "  Portable:  $zipPath"  -ForegroundColor Green }
Write-Host '  (Both signed binaries inside; installer itself signed.)' -ForegroundColor Green
