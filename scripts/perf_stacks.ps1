<#
.SYNOPSIS
  Sampled CALL STACKS from a running Hollow, via cdb. No admin rights needed.

.DESCRIPTION
  `perf_sample.ps1` says which MODULE the CPU is in. This says which FUNCTION,
  and how it got there, by taking N non-invasive stack snapshots of every
  thread and folding them into a count per unique stack.

  Non-invasive attach freezes the process for the length of each snapshot
  (tens of milliseconds), so this is for diagnosing an IDLE app, not for
  measuring one during a call. Do not run it while voice is up: freezing the
  audio thread will glitch it.

  Symbols: Microsoft's public server covers Windows DLLs. `hollow_core.dll`
  resolves because `[profile.release] debug = "line-tables-only"` is set in
  rust/hollow_core/Cargo.toml. `flutter_windows.dll` has no public PDB, so
  engine frames read as `flutter_windows+0x...` — still enough to tell the
  engine apart from our code.

.EXAMPLE
  pwsh scripts\perf_stacks.ps1 -Snapshots 30
  pwsh scripts\perf_stacks.ps1 -Name hollow -Snapshots 40 -Out stacks.txt
#>
param(
  [string]$Name = 'hollow',
  [int]$Snapshots = 25,
  [int]$IntervalMs = 250,
  [int]$Depth = 24,
  [int]$Top = 20,
  [switch]$IncludeWaiting,
  [string]$Out = ''
)

# A parked thread's leaf frame is whatever it blocked in, and an idle app is
# mostly parked threads — so by default those are dropped. What is left is
# where the process is actually spending itself.
$waitLeaves = @(
  'NtWaitForSingleObject', 'NtWaitForMultipleObjects', 'NtWaitForWorkViaWorkerFactory',
  'NtWaitForAlertByThreadId', 'NtDelayExecution', 'NtRemoveIoCompletion',
  'NtRemoveIoCompletionEx', 'NtUserMsgWaitForMultipleObjectsEx', 'NtUserGetMessage',
  'NtUserWaitMessage', 'NtSignalAndWaitForSingleObject', 'NtWaitForDebugEvent',
  'RtlUserThreadStart', 'ZwWaitForSingleObject', 'ZwWaitForMultipleObjects'
)
function Test-Waiting([string]$sym) {
  foreach ($w in $waitLeaves) { if ($sym -like "*!$w*" -or $sym -like "$w*") { return $true } }
  return $false
}

$ErrorActionPreference = 'Stop'

$cdb = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\Microsoft.WinDbg_8wekyb3d8bbwe\cdbX64.exe'
if (-not (Test-Path $cdb)) {
  $cdb = 'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe'
}
if (-not (Test-Path $cdb)) {
  Write-Host "cdb not found. Install it with:  winget install Microsoft.WinDbg"
  exit 1
}

if (-not $env:_NT_SYMBOL_PATH) {
  $env:_NT_SYMBOL_PATH = 'srv*C:\symbols*https://msdl.microsoft.com/download/symbols'
}

$proc = Get-Process -Name $Name -ErrorAction SilentlyContinue
if (-not $proc) { Write-Host "No process named '$Name' is running."; exit 1 }
if ($proc -is [array]) { $proc = $proc[0] }
Write-Host "Attaching to $Name (pid $($proc.Id)), $Snapshots snapshots ..."
Write-Host "Symbols: $env:_NT_SYMBOL_PATH"

# One cdb invocation per snapshot: a non-invasive attach cannot resume the
# target, so each snapshot attaches, dumps, and quits.
$frames = @{}     # "module!function" -> count, leaf frames only
$stacks = @{}     # folded stack        -> count
for ($i = 1; $i -le $Snapshots; $i++) {
  $raw = & $cdb -pv -p $proc.Id -c "~*k $Depth; q" 2>&1 | Out-String
  $cur = @()
  $isLeaf = $true
  foreach ($line in ($raw -split "`r?`n")) {
    if ($line -match '^\s*\d+\s+Id:.*Suspend') {           # thread header
      if ($cur.Count -and $cur[0] -ne '(parked)') { $key = ($cur -join ' <- '); $stacks[$key] = 1 + $stacks[$key] }
      $cur = @(); $isLeaf = $true
      continue
    }
    # "00000000`0016f8a8 00007ffc`... module!symbol+0x14"
    if ($line -match '^[0-9a-f`]+\s+[0-9a-f`]+\s+(\S+[!+]\S*)') {
      $sym = $Matches[1]
      $cur += $sym
      if ($isLeaf) {
        $isLeaf = $false
        if ($IncludeWaiting -or -not (Test-Waiting $sym)) {
          $frames[$sym] = 1 + $frames[$sym]
        } else {
          $cur = @('(parked)')   # drop this thread's stack from the fold too
        }
      }
    }
  }
  if ($cur.Count -and $cur[0] -ne '(parked)') { $key = ($cur -join ' <- '); $stacks[$key] = 1 + $stacks[$key] }
  Write-Host -NoNewline "."
  Start-Sleep -Milliseconds $IntervalMs
}
Write-Host ""

$report = New-Object System.Text.StringBuilder
function Emit($t) { [void]$report.AppendLine($t); Write-Host $t }

Emit ""
Emit "=== hottest LEAF frames (parked threads excluded; -IncludeWaiting to keep them) ==="
$frames.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $Top | ForEach-Object {
  Emit ("{0,6}  {1}" -f $_.Value, $_.Key)
}

Emit ""
Emit "=== leaf frames by MODULE ==="
$frames.GetEnumerator() | Group-Object { ($_.Key -split '!')[0] } | ForEach-Object {
  [pscustomobject]@{ Module = $_.Name; Samples = ($_.Group | Measure-Object Value -Sum).Sum }
} | Sort-Object Samples -Descending | ForEach-Object {
  Emit ("{0,6}  {1}" -f $_.Samples, $_.Module)
}

Emit ""
Emit "=== most common full stacks ==="
$stacks.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10 | ForEach-Object {
  Emit ("{0,6}  {1}" -f $_.Value, ($_.Key -replace ' <- ', "`n         <- "))
  Emit ""
}

if ($Out) { $report.ToString() | Set-Content -Encoding utf8 $Out; Write-Host "wrote $Out" }
