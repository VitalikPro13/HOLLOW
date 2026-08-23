<#
.SYNOPSIS
  ETW CPU capture of the whole machine, then a CSV summary. NEEDS ADMIN.

.DESCRIPTION
  The escalation past perf_threads / perf_sample / perf_stacks, none of which
  need admin. This is what sees things a same-process sampler cannot: kernel
  time, DPCs and interrupts, the GPU driver's own threads, and precise CPU
  attribution across every process at once.

  Kernel ETW sessions require elevation, which is why this is a separate
  script you run from an elevated prompt rather than something the assistant
  can start. It writes an .etl plus xperf's CSV summary next to it; the CSVs
  are plain text and can be read and analysed without admin.

.EXAMPLE
  # From an ELEVATED PowerShell:
  powershell -ExecutionPolicy Bypass -File scripts\perf_etw.ps1 -Seconds 30

.NOTES
  Have Hollow running and idle (visible and focused) before starting, and do
  not touch the machine while it records.
#>
param(
  [int]$Seconds = 30,
  [string]$OutDir = "$env:USERPROFILE\Desktop\hollow-perf"
)

$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
      [Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host "This one needs an ELEVATED PowerShell (ETW kernel sessions require admin)."
  Write-Host "Right-click PowerShell > Run as administrator, then re-run this script."
  exit 1
}

$wpr   = 'C:\Windows\System32\wpr.exe'
$xperf = 'C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\xperf.exe'
if (-not (Test-Path $xperf)) { Write-Host "xperf not found at $xperf"; exit 1 }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$etl = Join-Path $OutDir 'cpu.etl'

# A capture already running would make -start fail with a confusing message.
& $wpr -cancel 2>&1 | Out-Null

Write-Host "Recording CPU + DiskIO for $Seconds s. Leave the machine alone."
& $wpr -start CPU -start DiskIO -filemode
if ($LASTEXITCODE -ne 0) { Write-Host "wpr -start failed ($LASTEXITCODE)"; exit 1 }
Start-Sleep -Seconds $Seconds
& $wpr -stop $etl
if ($LASTEXITCODE -ne 0) { Write-Host "wpr -stop failed ($LASTEXITCODE)"; exit 1 }
Write-Host "wrote $etl"

Write-Host "Summarising with xperf ..."
& $xperf -i $etl -o (Join-Path $OutDir 'profile.csv') -a profile 2>&1 | Out-Null
& $xperf -i $etl -o (Join-Path $OutDir 'stacks.txt')  -a stack   2>&1 | Out-Null

Get-ChildItem $OutDir | Select-Object Name, @{n='MB';e={[math]::Round($_.Length/1MB,1)}} | Format-Table -AutoSize
Write-Host ""
Write-Host "Done. The .etl and the CSVs are in $OutDir — hand that path over."
