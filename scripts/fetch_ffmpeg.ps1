# fetch_ffmpeg.ps1 — Download the minimal Hollow ffmpeg build for Windows.
#
# Primary source: our own GitHub release (minimal build, ~5-8 MB).
# Fallback: gyan.dev essentials build (~80 MB).
#
# Output: vendor/ffmpeg/ffmpeg-win-x64.exe + VERSION.txt
#
# Usage: From the repo root, run `.\scripts\fetch_ffmpeg.ps1` in PowerShell.

$ErrorActionPreference = "Stop"

$HollowRelease = "https://github.com/VitalikPro13/HOLLOW/releases/download/ffmpeg-minimal-v1/ffmpeg-win-x64.exe"
$GyanFallback = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"

$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$VendorDir = Join-Path $RepoRoot "vendor\ffmpeg"
$TempDir = Join-Path $env:TEMP "hollow_ffmpeg_fetch"

Write-Host "==> Hollow ffmpeg fetcher (Windows x64)"
Write-Host ""

if (-not (Test-Path $VendorDir)) {
    New-Item -ItemType Directory -Path $VendorDir -Force | Out-Null
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

$dstFfmpeg = Join-Path $VendorDir "ffmpeg-win-x64.exe"
$dstVersion = Join-Path $VendorDir "VERSION.txt"
$source = ""

# --- Try our minimal build first ---
Write-Host "==> Trying Hollow minimal build..."
try {
    Invoke-WebRequest -Uri $HollowRelease -OutFile $dstFfmpeg -UseBasicParsing
    $source = "Hollow minimal build"
    Write-Host "    Downloaded from Hollow releases"
} catch {
    Write-Host "    Hollow release not available, falling back to gyan.dev essentials..."

    # --- Fallback: gyan.dev essentials ---
    if (Test-Path $TempDir) { Remove-Item -Recurse -Force $TempDir }
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    $ZipPath = Join-Path $TempDir "ffmpeg-essentials.zip"

    try {
        Invoke-WebRequest -Uri $GyanFallback -OutFile $ZipPath -UseBasicParsing
    } catch {
        Write-Error "Failed to download ffmpeg: $_"
        exit 1
    }

    $ExtractDir = Join-Path $TempDir "extract"
    New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $ExtractDir -Force

    $inner = Get-ChildItem -Path $ExtractDir -Directory | Select-Object -First 1
    $srcFfmpeg = Join-Path $inner.FullName "bin\ffmpeg.exe"
    if (-not (Test-Path $srcFfmpeg)) {
        Write-Error "ffmpeg.exe not found in extracted archive"
        exit 1
    }
    Copy-Item -LiteralPath $srcFfmpeg -Destination $dstFfmpeg -Force
    $source = "gyan.dev essentials"

    Remove-Item -Recurse -Force $TempDir
}

# --- Verify ---
$ffmpegSize = (Get-Item $dstFfmpeg).Length
Write-Host ""
Write-Host "==> Verifying ffmpeg binary..."
try {
    $versionOutput = & $dstFfmpeg -hide_banner -version 2>&1 | Select-Object -First 1
    Write-Host "    $versionOutput"
} catch {
    Write-Error "ffmpeg binary failed to execute: $_"
    exit 1
}

# Check for libopus + libwebp
$encoders = & $dstFfmpeg -hide_banner -encoders 2>&1 | Out-String
$hasOpus = $encoders -match "libopus"
$hasWebp = $encoders -match "libwebp"
if (-not $hasOpus) { Write-Warning "libopus encoder not found" }
if (-not $hasWebp) { Write-Warning "libwebp encoder not found" }
if ($hasOpus -and $hasWebp) { Write-Host "    libopus + libwebp: OK" }

# --- Write VERSION.txt ---
$versionInfo = @"
Source: $source
Fetched: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
License: LGPL (subprocess invocation only — no linking)
Size: $([math]::Round($ffmpegSize / 1MB, 1)) MB
"@
Set-Content -LiteralPath $dstVersion -Value $versionInfo -Encoding utf8
Write-Host "    Wrote -> $dstVersion"

Write-Host ""
Write-Host "==> Done. ffmpeg ready at:"
Write-Host "    $dstFfmpeg"
Write-Host "    Size: $([math]::Round($ffmpegSize / 1MB, 1)) MB"
