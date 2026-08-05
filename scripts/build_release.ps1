<#
.SYNOPSIS
    One-shot Hollow Windows release pipeline:
    build, sign binaries, build installer, sign installer, zip portable.

.DESCRIPTION
    The release ORCHESTRATOR. Builds + signs the Windows artifacts and the
    Android APK locally, then scp-pulls the macOS and Linux artifacts (built on
    their own machines by build_macos_release.sh / build_linux_release.sh) into
    installer\Output\ so every platform's release files land in one folder.

    Steps (each can be skipped via switches):
      1. flutter build windows --release
      2. scripts\sign_release.ps1   (sign all .exe/.dll in the Release folder)
      3. Inno Setup compile installer\hollow.iss into setup.exe
      4. scripts\sign_file.ps1      (sign the setup.exe)
      5. Compress the Release folder into hollow-<ver>-win64.zip (portable)
      6. flutter build apk --release -> rename -> installer\Output\
      7. scp-pull macOS dmg + zip from the Mac     (MAC_SSH)
      8. scp-pull Linux flatpak + tarball from VM  (LINUX_SSH)

    Run the Mac + Linux scripts FIRST (they finish before you run this); steps
    7-8 just fetch their finished artifacts. A missing remote artifact is a
    WARNING, not a failure.

    You will be prompted for the card PIN (typically once, cached for the session).

    No secrets in this script (key stays on card, PIN typed live, thumbprint
    public, paths/SSH targets come from the gitignored scripts\release.local.env),
    so it is safe to commit.

.PARAMETER Version
    Version string for output filenames + installer. Defaults to the version in pubspec.yaml.

.PARAMETER SkipBuild
    Skip 'flutter build windows' (use the existing Release folder as-is).

.PARAMETER SkipInstaller
    Skip Inno Setup + installer signing (produce only the signed ZIP).

.PARAMETER SkipZip
    Skip the portable ZIP (produce only the installer).

.PARAMETER SkipAndroid
    Skip the Android APK build.

.PARAMETER SkipMacPull
    Skip pulling the macOS dmg + zip from the Mac.

.PARAMETER SkipLinuxPull
    Skip pulling the Linux flatpak + tarball from the VM.

.PARAMETER OnlyPull
    Do ONLY the remote pulls (skip all Windows + Android building). Equivalent to
    -SkipBuild -SkipInstaller -SkipZip -SkipAndroid. Combine with -SkipMacPull /
    -SkipLinuxPull to pull just one (e.g. "-OnlyPull -SkipMacPull" = Linux only).

.EXAMPLE
    .\scripts\build_release.ps1                       # everything
    .\scripts\build_release.ps1 -SkipMacPull          # mac not built yet
    .\scripts\build_release.ps1 -OnlyPull -SkipMacPull  # just pull Linux
    .\scripts\build_release.ps1 -Version 0.5.1
#>

param(
    [string]$Version,
    [switch]$SkipBuild,
    [switch]$SkipInstaller,
    [switch]$SkipZip,
    [switch]$SkipAndroid,
    [switch]$SkipMacPull,
    [switch]$SkipLinuxPull,
    [switch]$OnlyPull
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$releaseDir = Join-Path $repo 'build\windows\x64\runner\Release'
$outDir = Join-Path $repo 'installer\Output'

# -OnlyPull is shorthand for skipping every local build step.
if ($OnlyPull) { $SkipBuild = $true; $SkipInstaller = $true; $SkipZip = $true; $SkipAndroid = $true }

function Step($n, $msg) { Write-Host "`n==== [$n] $msg ====" -ForegroundColor Cyan }

# --- Load machine config (scripts\release.local.env) ---
function Read-EnvFile($path) {
    $h = @{}
    if (Test-Path $path) {
        foreach ($l in Get-Content $path) {
            $t = $l.Trim()
            if ($t -and -not $t.StartsWith('#') -and $t.Contains('=')) {
                $k, $v = $t.Split('=', 2)
                $h[$k.Trim()] = $v.Trim()
            }
        }
    }
    return $h
}
$cfg = Read-EnvFile (Join-Path $PSScriptRoot 'release.local.env')

# Pull one or more remote files into installer\Output via scp. Missing = warn.
function Pull-Remote($label, $sshTarget, $remoteFiles) {
    if (-not $sshTarget) {
        Write-Host "[WARN] $label - no SSH target in release.local.env, skipping" -ForegroundColor Yellow
        return
    }
    foreach ($rf in $remoteFiles) {
        Write-Host "  pulling $label : $(Split-Path $rf -Leaf)" -ForegroundColor Gray
        & scp "${sshTarget}:`"$rf`"" $outDir
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[WARN] $label - not found / scp failed: $rf (skipped)" -ForegroundColor Yellow
        }
    }
}

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
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
if (-not $SkipZip) {
    Step 5 'Zip portable Release folder'
    $zipPath = Join-Path $outDir "hollow-$Version-win64.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    # Exclude build/link artifacts and local logs so the portable ZIP matches the installer payload.
    $excludeExt = '.lib', '.exp', '.pdb', '.log'
    # NEVER use Compress-Archive here: it writes backslash entry names and
    # trailing-'\' directory entries (a ZIP spec violation) that the in-app
    # updater shipped in <= 0.9.4 fails to extract (issue #52, os error
    # 267/123). .NET ZipArchive with '/' separators extracts on EVERY updater
    # version, old and new.
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
    try {
        $rootLen = $releaseDir.TrimEnd('\').Length + 1
        Get-ChildItem $releaseDir -Recurse -File -Force |
            Where-Object { $excludeExt -notcontains $_.Extension } |
            ForEach-Object {
                $entryName = $_.FullName.Substring($rootLen) -replace '\\', '/'
                [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $zip, $_.FullName, $entryName,
                    [System.IO.Compression.CompressionLevel]::Optimal)
            }
        # Keep empty dirs (e.g. data/flutter_assets/packages/) as explicit
        # '/'-terminated entries, matching what the installer lays down.
        Get-ChildItem $releaseDir -Recurse -Directory -Force | ForEach-Object {
            $hasFiles = Get-ChildItem $_.FullName -Recurse -File -Force |
                Where-Object { $excludeExt -notcontains $_.Extension } |
                Select-Object -First 1
            if (-not $hasFiles) {
                $entryName = ($_.FullName.Substring($rootLen) -replace '\\', '/') + '/'
                [void]$zip.CreateEntry($entryName)
            }
        }
    } finally { $zip.Dispose() }

    # True portable variant: same payload + the portable.txt marker, so identity,
    # DB and downloads live in hollow_data\ next to the exe (USB-stick install).
    # Kept as a SEPARATE artifact — adding the marker to the plain zip would
    # silently detach existing zip users from their %APPDATA% profile.
    $portableZipPath = Join-Path $outDir "hollow-$Version-win64-portable.zip"
    if (Test-Path $portableZipPath) { Remove-Item $portableZipPath -Force }
    $markerPath = Join-Path $env:TEMP 'portable.txt'
    @(
        'Hollow portable mode marker.',
        'While this file sits next to hollow.exe, all data (identity key,',
        'encrypted database, downloaded files) lives in hollow_data\ in this',
        'folder instead of %APPDATA%. Delete this file (and hollow_data\) to',
        'switch back to a normal per-user install.'
    ) | Out-File -FilePath $markerPath -Encoding utf8
    Copy-Item $zipPath $portableZipPath -Force
    $zip = [System.IO.Compression.ZipFile]::Open($portableZipPath, 'Update')
    try {
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $markerPath, 'portable.txt',
            [System.IO.Compression.CompressionLevel]::Optimal)
    } finally { $zip.Dispose() }
    Remove-Item $markerPath -Force
} else { Step 5 'Zip (SKIPPED)' }

# --- 6. Android APK ---
$apkPath = $null
if (-not $SkipAndroid) {
    Step 6 'flutter build apk --release'
    Push-Location $repo
    try {
        & flutter build apk --release
        if ($LASTEXITCODE -ne 0) { throw "flutter build apk failed with exit code $LASTEXITCODE" }
    } finally { Pop-Location }
    $builtApk = Join-Path $repo 'build\app\outputs\flutter-apk\app-release.apk'
    if (Test-Path $builtApk) {
        $apkPath = Join-Path $outDir "hollow-$Version-android.apk"
        Copy-Item $builtApk $apkPath -Force
    } else {
        Write-Host "[WARN] APK not found at $builtApk (skipped)" -ForegroundColor Yellow
    }
} else { Step 6 'Android (SKIPPED)' }

# --- 7. Pull macOS artifacts (built by build_macos_release.sh on the Mac) ---
if (-not $SkipMacPull) {
    Step 7 'Pull macOS artifacts (scp)'
    $macRel = "$($cfg['MAC_REPO'])/build/macos/Build/Products/Release"
    Pull-Remote 'macOS' $cfg['MAC_SSH'] @(
        "$macRel/hollow-$Version.dmg",
        "$macRel/hollow-$Version-macos.zip"
    )
} else { Step 7 'macOS pull (SKIPPED)' }

# --- 8. Pull Linux artifacts (built by build_linux_release.sh on the VM) ---
if (-not $SkipLinuxPull) {
    Step 8 'Pull Linux artifacts (scp)'
    Pull-Remote 'Linux' $cfg['LINUX_SSH'] @(
        "$($cfg['LINUX_REPO'])/flatpak/hollow-$Version-linux-x86_64.flatpak",
        "$($cfg['LINUX_REPO'])/build/linux/x64/release/hollow-$Version-linux.tar.gz"
    )
} else { Step 8 'Linux pull (SKIPPED)' }

# --- Summary ---
Write-Host "`n==== DONE - version $Version ====" -ForegroundColor Green
if ($setupExe) { Write-Host "  Installer: $setupExe" -ForegroundColor Green }
if ($zipPath)  { Write-Host "  Portable:  $zipPath"  -ForegroundColor Green }
if ($apkPath)  { Write-Host "  Android:   $apkPath"  -ForegroundColor Green }
Write-Host "`n  installer\Output\ now holds:" -ForegroundColor Green
Get-ChildItem $outDir -File | Where-Object { $_.Name -like "*$Version*" } |
    Sort-Object Name | ForEach-Object {
        Write-Host ("    {0,-42} {1,8:N1} MB" -f $_.Name, ($_.Length / 1MB)) -ForegroundColor Gray
    }
