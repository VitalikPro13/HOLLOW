# build_shoes.ps1 — Build the `shoes` REALITY tunnel client for Windows.
#
# `shoes` (github.com/cfal/shoes, MIT) is the anti-censorship transport: the
# Hollow node spawns it as a local SOCKS5 proxy that tunnels the relay WSS
# connection through VLESS+REALITY, so the traffic looks like ordinary HTTPS to
# a censor (Russia/TSPU, China/GFW). See HOLLOW_PLAN.md "Fight Government
# Censorship" + reports/ANTI_CENSORSHIP_TRANSPORT_2026.md.
#
# Output: vendor/shoes/shoes-win-x64.exe (+ VERSION.txt, LICENSE.shoes.txt)
# Bundled next to hollow.exe by windows/CMakeLists.txt.
#
# Prereqs: Rust (stable, edition 2024 → 1.85+), plus NASM + CMake on PATH for
# aws-lc-rs (Strawberry Perl ships both; or install nasm + cmake separately).
#
# Usage: from the repo root, `.\scripts\build_shoes.ps1`
#        `-Ref <tag/branch/sha>` to pin a specific shoes revision (default: master).

param(
    [string]$Ref = "master"
)

$ErrorActionPreference = "Stop"

$ShoesRepo = "https://github.com/cfal/shoes.git"
$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$VendorDir = Join-Path $RepoRoot "vendor\shoes"
$BuildDir = Join-Path $env:TEMP "hollow_shoes_build"

Write-Host "==> Hollow shoes builder (Windows x64), ref=$Ref"
Write-Host ""

# Sanity: toolchain present.
foreach ($tool in @("cargo", "git", "nasm", "cmake")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool not found on PATH. shoes needs Rust + git + NASM + CMake (aws-lc-rs). Install and retry."
    }
}

if (-not (Test-Path $VendorDir)) {
    New-Item -ItemType Directory -Path $VendorDir -Force | Out-Null
}

# Fresh clone into a temp dir.
if (Test-Path $BuildDir) {
    Remove-Item -Recurse -Force $BuildDir
}
Write-Host "==> Cloning $ShoesRepo ($Ref)..."
git clone --depth 1 --branch $Ref $ShoesRepo $BuildDir 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    # --branch doesn't accept arbitrary SHAs; fall back to full clone + checkout.
    Remove-Item -Recurse -Force $BuildDir -ErrorAction SilentlyContinue
    git clone $ShoesRepo $BuildDir 2>&1 | Out-Null
    Push-Location $BuildDir
    git checkout $Ref 2>&1 | Out-Null
    Pop-Location
}

Push-Location $BuildDir
try {
    $ver = (Select-String -Path "Cargo.toml" -Pattern '^version\s*=\s*"(.+)"').Matches.Groups[1].Value
    Write-Host "==> Building shoes v$ver --release (bin only)... (this takes several minutes)"
    cargo build --release --bin shoes
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
} finally {
    Pop-Location
}

$builtExe = Join-Path $BuildDir "target\release\shoes.exe"
if (-not (Test-Path $builtExe)) { throw "Build succeeded but shoes.exe not found at $builtExe" }

$dstExe = Join-Path $VendorDir "shoes-win-x64.exe"
Copy-Item $builtExe $dstExe -Force
Write-Host "==> Copied -> $dstExe"

# License + version note (kept in git; the .exe is gitignored).
$srcLicense = Join-Path $BuildDir "LICENSE"
if (Test-Path $srcLicense) {
    Copy-Item $srcLicense (Join-Path $VendorDir "LICENSE.shoes.txt") -Force
}
$stamp = (Get-Date -Format "yyyy-MM-dd")
"shoes v$ver (cfal/shoes, MIT) ref=$Ref — built from source $stamp" |
    Out-File -FilePath (Join-Path $VendorDir "VERSION.txt") -Encoding utf8

$sizeMb = [math]::Round((Get-Item $dstExe).Length / 1MB, 1)
Write-Host ""
Write-Host "==> Done. vendor/shoes/shoes-win-x64.exe ($sizeMb MB), shoes v$ver."
Write-Host "    It will be bundled next to hollow.exe on the next Windows build."
