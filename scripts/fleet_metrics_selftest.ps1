# Checks the pure parts of fleet_metrics.ps1 (the soak's loss counter, the
# percentiles, the range formatting) without a fleet. Exit 1 on any failure.
#
#   powershell -File scripts\fleet_metrics_selftest.ps1
#   pwsh scripts/fleet_metrics_selftest.ps1

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fleet_metrics.ps1')

$script:failed = 0
function Check($name, $actual, $expected) {
    $a = ($actual | ConvertTo-Json -Compress)
    $e = ($expected | ConvertTo-Json -Compress)
    # Numbers by value: pwsh 7 writes a double 50 as 50.0, Windows PowerShell as 50.
    $same = $a -eq $e
    if ($actual -is [ValueType] -and $expected -is [ValueType]) { $same = [double]$actual -eq [double]$expected }
    if (-not $same) {
        Write-Host "FAIL $name`: got $a, want $e" -ForegroundColor Red
        $script:failed++
    } else {
        Write-Host "  ok $name"
    }
}

$loss = Get-StreamLoss (1..10) (@(1..6) + @(8..10))
Check 'one frame missing is one lost' $loss.lost 1
Check 'the missing frame is named' @($loss.missing) @(7)
Check 'sent counts every frame' $loss.sent 10

$loss = Get-StreamLoss @(1, 2, 3) @(1, 1, 2)
Check 'a duplicate never hides a gap' $loss.lost 1
Check 'the gap behind a duplicate is named' @($loss.missing) @(3)

$loss = Get-StreamLoss @(1, 2) @(1, 2, 3, 4)
Check 'frames held but never reported sent are not losses' $loss.lost 0

$loss = Get-StreamLoss @(1, 2, 3) $null
Check 'nothing held loses everything' $loss.lost 3

$loss = Get-StreamLoss @() @()
Check 'an empty stream loses nothing' $loss.lost 0

$loss = Get-StreamLoss @(5, 3, 4) @(3, 4, 5)
Check 'order does not matter' $loss.lost 0

Check 'p50 of 1..100' (Get-Percentile (100..1) 50) 50
Check 'p95 of 1..100' (Get-Percentile (1..100) 95) 95
Check 'p95 of 1..10' (Get-Percentile (1..10) 95) 10
Check 'p50 of one value' (Get-Percentile @(1234) 50) 1234
Check 'nulls are skipped' (Get-Percentile @($null, 3, $null, 1, 2) 50) 2
Check 'no values, no percentile' (Get-Percentile @() 50) $null

Check 'ranges' (Format-SeqRanges @(10, 1, 2, 3, 7, 9)) '1-3,7,9-10'
Check 'one value' (Format-SeqRanges @(4)) '4'
Check 'no values' (Format-SeqRanges @()) ''

if ($script:failed -gt 0) {
    Write-Host "$($script:failed) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
