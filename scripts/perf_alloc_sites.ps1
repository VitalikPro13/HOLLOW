<#
.SYNOPSIS
  Who allocates the LARGE blocks: call stacks captured at NtAllocateVirtualMemory.

.DESCRIPTION
  `perf_memory.ps1` says a process holds N MB of private commit and in what
  shape. It cannot say who asked for it. This does: it attaches cdb, breaks on
  every NtAllocateVirtualMemory whose requested size is >= -MinMb, prints the
  stack, and continues — then detaches itself after -Hits captures so nothing
  has to kill the debugger (killing an attached cdb would kill Hollow).

  This is an INVASIVE attach. Every large allocation stops the process for the
  length of a stack walk. Fine for an idle app; do not run it during a call.

  Symbols: hollow_core.dll resolves (line-tables-only in Cargo.toml).
  flutter_windows.dll has no public PDB, so engine frames read as
  flutter_windows+0x... which is still enough to tell whose allocation it is.

.EXAMPLE
  pwsh scripts\perf_alloc_sites.ps1 -MinMb 4 -Hits 14
#>
param(
  [string]$Name = 'hollow',
  [int]$MinMb = 4,
  [int]$MinKb = 0,
  [int]$Hits = 14,
  [string]$Out = '',
  [string]$Launch = '',
  [switch]$CommitOnly,
  [int]$Depth = 16
)

$ErrorActionPreference = 'Stop'

$cdb = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\Microsoft.WinDbg_8wekyb3d8bbwe\cdbX64.exe'
if (-not (Test-Path $cdb)) {
  $cdb = 'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe'
}
if (-not (Test-Path $cdb)) {
  Write-Host 'cdb not found. Install it with:  winget install Microsoft.WinDbg'
  exit 1
}

if (-not $env:_NT_SYMBOL_PATH) {
  $env:_NT_SYMBOL_PATH = 'srv*C:\symbols*https://msdl.microsoft.com/download/symbols'
}

# Attaching catches only what a running app allocates from now on. Large
# allocations often happen once, during startup, so -Launch starts the app
# under the debugger instead and catches those too.
$proc = $null
if ($Launch -eq '') {
  $proc = Get-Process -Name $Name -ErrorAction SilentlyContinue
  if (-not $proc) { Write-Host ("No process named '" + $Name + "' is running."); exit 1 }
  if ($proc -is [array]) { $proc = $proc[0] }
}

$minBytes = $MinMb * 1MB
if ($MinKb -gt 0) { $minBytes = $MinKb * 1KB }

# x64 NtAllocateVirtualMemory(rcx=hProcess, rdx=&Base, r8=ZeroBits, r9=&RegionSize,
#                             [rsp+28]=AllocationType, [rsp+30]=Protect)
# poi(@r9) is the requested size; 0x1000 in AllocationType is MEM_COMMIT.
# One double-quoted command, nested BRACES only. Nested quotes are what cdb's
# parser chokes on, and a bp that fails to set looks exactly like a bp that
# never hits: the target just runs forever with a debugger attached.
# 0x1000 in AllocationType is MEM_COMMIT. Without this filter a pure address
# space RESERVE (the graphics driver takes a 1 GB one) burns a capture slot
# while costing no memory at all.
$test = '(poi(@r9) >= 0x{0:X})' -f $minBytes
# NOTE the "!= 0". cdb's MASM & is BITWISE, so writing the flag test as
# (size >= N) & (type & 0x1000) evaluates 1 & 0x1000 == 0 and the breakpoint
# silently never fires -- which looks exactly like "the app never does this".
if ($CommitOnly) { $test = '((poi(@r9) >= 0x{0:X}) & ((poi(@rsp+0x28) & 0x1000) != 0))' -f $minBytes }
$cmd = '.if {0} {{ .echo ===ALLOC===; .echo size:; ? poi(@r9); k {2}; r $t0 = @$t0 + 1; .if (@$t0 >= {1}) {{ .echo ===ENOUGH===; bc *; qd }} .else {{ gc }} }} .else {{ gc }}' -f $test, $Hits, $Depth

$script = @()
$script += 'r $t0 = 0'
$script += ('bp ntdll!NtAllocateVirtualMemory "' + $cmd + '"')
$script += '.echo ===BREAKPOINTS==='
$script += 'bl'
$script += '.echo ===RUNNING==='
$script += 'g'

$tag = 'launch'
if ($null -ne $proc) { $tag = [string]$proc.Id }
$scriptPath = Join-Path $env:TEMP ('hollow_alloc_probe_' + $tag + '.txt')
Set-Content -Path $scriptPath -Value $script -Encoding ascii

Write-Host ("Capturing {0} allocations >= {1} KB ..." -f $Hits, [int]($minBytes / 1KB))
Write-Host 'The app is frozen briefly at each capture. Ctrl+C here would kill it, so let it finish.'

$live = Join-Path $env:TEMP ('hollow_alloc_live_' + $tag + '.txt')
Write-Host ('live cdb output: ' + $live)
# NOTE: no 2>&1 on cdb. Under PowerShell 5.1 that wraps every stderr line in
# an ErrorRecord, which with $ErrorActionPreference='Stop' kills the run before
# a single stack is captured. cdb's useful output is on stdout anyway.
# Windows turns on the DEBUG HEAP for any process started under a debugger,
# which changes allocation sizes and fill patterns and makes every number a
# lie. This turns it off so a launched run measures the same heap the app
# uses normally.
$env:_NO_DEBUG_HEAP = '1'

$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  if ($Launch -ne '') {
    Write-Host ('Launching under cdb: ' + $Launch)
    Push-Location (Split-Path -Parent $Launch)
    try { $raw = & $cdb -cf $scriptPath $Launch | Tee-Object -FilePath $live | Out-String }
    finally { Pop-Location }
  } else {
    Write-Host ('Attaching to pid ' + $proc.Id)
    $raw = & $cdb -p $proc.Id -cf $scriptPath | Tee-Object -FilePath $live | Out-String
  }
} finally { $ErrorActionPreference = $prevEap }
Remove-Item $scriptPath -ErrorAction SilentlyContinue

$still = Get-Process -Name $Name -ErrorAction SilentlyContinue
if ($null -eq $still) { Write-Host 'WARNING: the target process is gone.' }
else { Write-Host 'Detached; target still running.' }

# Fold: one block per ===ALLOC===, keyed by the modules in its stack.
$blocks = @()
$cur = $null
foreach ($line in ($raw -split "`r?`n")) {
  if ($line -match '===ALLOC===') { if ($null -ne $cur) { $blocks += , $cur }; $cur = @(); continue }
  if ($line -match '===ENOUGH===') { if ($null -ne $cur) { $blocks += , $cur }; $cur = $null; continue }
  if ($null -ne $cur) { $cur += $line }
}
if ($null -ne $cur) { $blocks += , $cur }

$report = New-Object System.Text.StringBuilder
function Emit($t) { [void]$report.AppendLine($t); Write-Host $t }

Emit ''
Emit ("=== captured {0} allocations >= {1} MB ===" -f $blocks.Count, $MinMb)

$byOwner = @{}
foreach ($b in $blocks) {
  $size = ''
  $frames = @()
  foreach ($line in $b) {
    if ($line -match 'Evaluate expression:\s+(\d+)') {
      $size = ('{0:N1} MB' -f ([double]$Matches[1] / 1MB))
    }
    if ($line -match '^[0-9a-f`]+\s+[0-9a-f`]+\s+(\S+[!+]\S*)') { $frames += $Matches[1] }
  }
  # The owner is the first frame that is not ntdll/kernelbase plumbing.
  $owner = '(unresolved)'
  foreach ($f in $frames) {
    $m = ($f -split '[!+]')[0]
    if ($m -notmatch '^(ntdll|KERNELBASE|kernel32|msvcrt|ucrtbase)$') { $owner = $m; break }
  }
  Emit ''
  Emit ("--- {0}   owner: {1}" -f $size, $owner)
  $depth = 0
  foreach ($f in $frames) {
    Emit ('    ' + $f)
    $depth++
    if ($depth -ge 14) { break }
  }
  if (-not $byOwner.ContainsKey($owner)) { $byOwner[$owner] = 0 }
  $byOwner[$owner] = $byOwner[$owner] + 1
}

Emit ''
Emit '=== large allocations by owning module ==='
$byOwner.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
  Emit ('{0,6}  {1}' -f $_.Value, $_.Key)
}

if ($Out -ne '') {
  Set-Content -Path $Out -Value ($raw + "`n`n" + $report.ToString()) -Encoding utf8
  Write-Host ''
  Write-Host ("raw + report written to " + $Out)
}
