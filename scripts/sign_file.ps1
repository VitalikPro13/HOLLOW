<#
.SYNOPSIS
    Code-sign a single file (e.g. the Inno Setup setup.exe) with the Certum
    Open Source Code Signing certificate (cryptoCertum3.7 USB card, CNG/minidriver).

.DESCRIPTION
    Same signing path as scripts\sign_release.ps1, for one file. SHA-256 digest +
    RFC3161 timestamp. Contains NO secrets (key stays on card, PIN typed live,
    thumbprint is public) => safe to commit.

.PARAMETER File
    Path to the file to sign. Required.

.PARAMETER Thumbprint
    SHA-1 thumbprint of the signing cert. Defaults to the Hollow Certum cert.

.EXAMPLE
    .\sign_file.ps1 -File "installer\Output\hollow-0.5.0-win64-setup.exe"
#>

param(
    [Parameter(Mandatory = $true)][string]$File,
    [string]$Thumbprint = '6330CDE02590CD9503CDD96F124B6656947F4D9C'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $File)) { throw "File not found: $File" }

# --- Locate signtool (newest x64 Windows SDK) ---
$signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter 'signtool.exe' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -like '*\x64\*' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $signtool) { throw 'signtool.exe (x64) not found. Install the Windows 10/11 SDK.' }

# --- Verify the cert is key-linked; self-heal the CNG binding if needed ---
$cert = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
    Where-Object { $_.Thumbprint -eq $Thumbprint }
if (-not $cert) {
    throw "Cert $Thumbprint not in CurrentUser\My. Import the public cert (CardManager > Install Certificate or a .cer/.pem), then re-run."
}
if (-not $cert.HasPrivateKey) {
    Write-Host 'Cert has no private-key link yet -> binding to CNG Smart Card Key Storage Provider (minidriver)...' -ForegroundColor Yellow
    certutil -user -csp 'Microsoft Smart Card Key Storage Provider' -repairstore My $Thumbprint | Out-Null
    $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Thumbprint -eq $Thumbprint }
    if (-not $cert.HasPrivateKey) {
        throw 'repairstore did not produce a usable key link. If it failed with CRYPT_E_EXISTS, delete the cert from the store, re-import, and run again.'
    }
}

Write-Host "Signing: $File" -ForegroundColor Cyan
Write-Host '(You will be prompted for the card PIN.)' -ForegroundColor Cyan

& $signtool sign `
    /sha1 $Thumbprint `
    /fd sha256 `
    /tr http://time.certum.pl `
    /td sha256 `
    /v `
    $File
if ($LASTEXITCODE -ne 0) { throw "signtool sign failed (exit $LASTEXITCODE)." }

& $signtool verify /pa /v $File
if ($LASTEXITCODE -ne 0) { throw "signtool verify failed (exit $LASTEXITCODE)." }

Write-Host "`nSigned and verified: $File" -ForegroundColor Green
