# Dot-sourced by sign_release.ps1 and sign_file.ps1.
# Certum's timestamp server drops a request now and then, and a file whose
# signing failed keeps the signature it had, so only the files that missed are
# signed again.

function Test-OurTimestampedSignature([string]$File, [string]$Thumbprint) {
    $s = Get-AuthenticodeSignature -FilePath $File
    return $s.Status -eq 'Valid' -and
        $s.SignerCertificate.Thumbprint -eq $Thumbprint -and
        $null -ne $s.TimeStamperCertificate
}

function Invoke-SigntoolWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Signtool,
        [Parameter(Mandatory = $true)][string]$Thumbprint,
        [Parameter(Mandatory = $true)][string[]]$Files,
        [int]$MaxAttempts = 5,
        [int]$DelaySeconds = 15
    )
    $pending = $Files
    for ($attempt = 1; ; $attempt++) {
        # Under 'Stop', PowerShell 5.1 turns a redirected native stderr line
        # into a terminating error, so the capture runs under 'Continue'.
        $eap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = & $Signtool sign /sha1 $Thumbprint /fd sha256 /tr http://time.certum.pl /td sha256 /v @pending 2>&1 |
                ForEach-Object { "$_" }
            $code = $LASTEXITCODE
        } finally { $ErrorActionPreference = $eap }
        $out | ForEach-Object { Write-Host $_ }
        if ($code -eq 0) { return }

        $pending = @($pending | Where-Object { -not (Test-OurTimestampedSignature $_ $Thumbprint) })
        if ($pending.Count -eq 0) { return }
        # Only the timestamp server is retried: every attempt asks the card for
        # its PIN again, and the card locks after too many wrong ones.
        if (-not ($out -match 'timestamp server')) {
            throw "signtool sign failed (exit $code); not signed: $($pending -join ', ')"
        }
        if ($attempt -ge $MaxAttempts) {
            throw "signtool sign failed $attempt times; not signed: $($pending -join ', ')"
        }
        Write-Host "Timestamp server missed $($pending.Count) file(s); signing them again in $DelaySeconds s (attempt $($attempt + 1) of $MaxAttempts)" -ForegroundColor Yellow
        Start-Sleep -Seconds $DelaySeconds
    }
}
