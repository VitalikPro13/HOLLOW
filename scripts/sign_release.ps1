<#
.SYNOPSIS
    Code-sign all Hollow release binaries with the Certum Open Source Code Signing
    certificate (cryptoCertum3.7 USB card, minidriver / CNG mode).

.DESCRIPTION
    Signs every .exe and .dll in the target folder in a single signtool batch call,
    with SHA-256 digest + RFC3161 timestamp from Certum (so signatures survive cert expiry).

    Contains NO secrets:
      - the private key never leaves the card
      - the PIN is typed into the card's own prompt at sign time
      - the thumbprint is a public hash (printed inside every signed binary)
    => safe to commit to git.

.PARAMETER Path
    Folder containing the binaries to sign. Defaults to the Flutter Windows
    release output: <repo>\build\windows\x64\runner\Release (this script lives
    in <repo>\scripts, so the default is resolved relative to it).

.PARAMETER Thumbprint
    SHA-1 thumbprint of the signing cert. Defaults to the Hollow Certum cert.

.EXAMPLE
    .\sign_release.ps1
    .\sign_release.ps1 -Path "C:\path\to\build\windows\x64\runner\Release"
#>

param(
    [string]$Path = (Join-Path (Split-Path $PSScriptRoot -Parent) 'build\windows\x64\runner\Release'),
    [string]$Thumbprint = '6330CDE02590CD9503CDD96F124B6656947F4D9C'
)

$ErrorActionPreference = 'Stop'

# --- Locate signtool (newest x64 Windows SDK) ---
$signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter 'signtool.exe' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -like '*\x64\*' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $signtool) { throw 'signtool.exe (x64) not found. Install the Windows 10/11 SDK.' }

# --- Verify the cert is present and key-linked; self-heal the CNG binding if needed ---
$cert = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
    Where-Object { $_.Thumbprint -eq $Thumbprint }
if (-not $cert) {
    throw "Cert $Thumbprint not in CurrentUser\My. Import the public cert (CardManager > Install Certificate or a .cer/.pem), then re-run."
}
if (-not $cert.HasPrivateKey) {
    Write-Host 'Cert has no private-key link yet -> binding to CNG Smart Card Key Storage Provider (minidriver)...' -ForegroundColor Yellow
    # THE critical step for cryptoCertum3.7 in minidriver mode (see reference_certum_signing_procedure memory)
    certutil -user -csp 'Microsoft Smart Card Key Storage Provider' -repairstore My $Thumbprint | Out-Null
    $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Thumbprint -eq $Thumbprint }
    if (-not $cert.HasPrivateKey) {
        throw 'repairstore did not produce a usable key link. If it failed with CRYPT_E_EXISTS, delete the cert from the store, re-import, and run again.'
    }
}

# --- Gather binaries ---
if (-not (Test-Path $Path)) { throw "Path not found: $Path" }
$files = Get-ChildItem $Path -Recurse -Include *.exe, *.dll |
    Select-Object -ExpandProperty FullName
if (-not $files) { throw "No .exe/.dll files found under $Path" }

Write-Host "Signing $($files.Count) file(s) in '$Path'" -ForegroundColor Cyan
Write-Host '(You will be prompted for the card PIN.)' -ForegroundColor Cyan

# --- Sign (single batch call; one PIN prompt) ---
& $signtool sign `
    /sha1 $Thumbprint `
    /fd sha256 `
    /tr http://time.certum.pl `
    /td sha256 `
    /v `
    @files
if ($LASTEXITCODE -ne 0) { throw "signtool sign failed (exit $LASTEXITCODE)." }

# --- Verify ---
Write-Host "`nVerifying signatures..." -ForegroundColor Cyan
& $signtool verify /pa @files
if ($LASTEXITCODE -ne 0) { throw "signtool verify failed (exit $LASTEXITCODE)." }

Write-Host "`nAll files signed and verified successfully." -ForegroundColor Green
