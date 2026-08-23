<#
.SYNOPSIS
  Per-thread CPU inside a running process, with each thread's NAME and the
  module its start address lives in.

.DESCRIPTION
  Answers "which thread is burning the CPU, and whose code is it" without a
  profiler install. Samples ProcessThread.TotalProcessorTime over a window,
  resolves each thread's name via GetThreadDescription (Flutter, Dart and
  tokio all name their threads) and its StartAddress against the loaded
  module list.

.EXAMPLE
  pwsh scripts\thread_cpu.ps1 -Name hollow -Seconds 20
#>
param(
  [string]$Name = 'hollow',
  [int]$Seconds = 15,
  [int]$Top = 25,
  [string]$Csv = ''
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ThreadInfo {
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern IntPtr OpenThread(uint access, bool inherit, uint tid);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
  static extern int GetThreadDescription(IntPtr h, out IntPtr desc);
  [DllImport("kernel32.dll")]
  static extern IntPtr LocalFree(IntPtr p);
  [DllImport("ntdll.dll")]
  static extern int NtQueryInformationThread(IntPtr h, int cls, out IntPtr info, int len, IntPtr ret);

  const uint QUERY_LIMITED = 0x0800;
  const uint QUERY_INFO    = 0x0040;

  /// The name the app gave the thread. Flutter, Dart and tokio all set one.
  public static string Name(uint tid) {
    IntPtr h = OpenThread(QUERY_LIMITED, false, tid);
    if (h == IntPtr.Zero) return "";
    try {
      IntPtr p;
      if (GetThreadDescription(h, out p) < 0 || p == IntPtr.Zero) return "";
      try { return Marshal.PtrToStringUni(p); } finally { LocalFree(p); }
    } finally { CloseHandle(h); }
  }

  /// ThreadQuerySetWin32StartAddress (9). .NET's ProcessThread.StartAddress
  /// reports ntdll's RtlUserThreadStart for nearly everything, which
  /// attributes every thread to ntdll and tells you nothing.
  public static ulong StartAddress(uint tid) {
    IntPtr h = OpenThread(QUERY_INFO | QUERY_LIMITED, false, tid);
    if (h == IntPtr.Zero) return 0;
    try {
      IntPtr addr;
      if (NtQueryInformationThread(h, 9, out addr, IntPtr.Size, IntPtr.Zero) != 0) return 0;
      return (ulong)addr.ToInt64();
    } finally { CloseHandle(h); }
  }
}
'@

$proc = Get-Process -Name $Name -ErrorAction SilentlyContinue
if (-not $proc) { Write-Host "No process named '$Name' is running."; exit 1 }
if ($proc -is [array]) { $proc = $proc[0] }

# Module map: base address + size -> file name, so a thread start address
# can be attributed without symbols. Module-level is the question that
# matters first (engine vs our Rust vs the GPU driver).
$mods = @()
foreach ($m in $proc.Modules) {
  $mods += [pscustomobject]@{
    Base = [uint64]$m.BaseAddress.ToInt64()
    End  = [uint64]$m.BaseAddress.ToInt64() + [uint64]$m.ModuleMemorySize
    File = [System.IO.Path]::GetFileName($m.FileName)
  }
}
function Resolve-Module([uint64]$addr) {
  foreach ($m in $mods) { if ($addr -ge $m.Base -and $addr -lt $m.End) { return $m.File } }
  return '?'
}

function Snapshot($p) {
  $p.Refresh()
  $h = @{}
  foreach ($t in $p.Threads) {
    try {
      $state = "$($t.ThreadState)"
      $wait = ''
      if ($state -eq 'Wait') { $wait = "$($t.WaitReason)" }
      $h[[int]$t.Id] = @{ Cpu   = $t.TotalProcessorTime.TotalMilliseconds
                          Start = [ThreadInfo]::StartAddress([uint32]$t.Id)
                          State = $state
                          Wait  = $wait }
    } catch {}   # a thread can exit between enumeration and read
  }
  $h
}

Write-Host "Sampling '$Name' (pid $($proc.Id)) for $Seconds s ..."
$a = Snapshot $proc
$t0 = Get-Date
Start-Sleep -Seconds $Seconds
$b = Snapshot $proc
$wall = ((Get-Date) - $t0).TotalMilliseconds

$rows = @()
foreach ($id in $b.Keys) {
  if (-not $a.ContainsKey($id)) { continue }
  $d = $b[$id].Cpu - $a[$id].Cpu
  $rows += [pscustomobject]@{
    Tid     = $id
    CpuMs   = [math]::Round($d, 1)
    'Pct'   = [math]::Round(100.0 * $d / $wall, 2)
    Name    = [ThreadInfo]::Name([uint32]$id)
    Module  = Resolve-Module $b[$id].Start
    State   = $b[$id].State
    Wait    = $b[$id].Wait
  }
}

$total = ($rows | Measure-Object -Property CpuMs -Sum).Sum
$cores = [Environment]::ProcessorCount
Write-Host ""
Write-Host ("Process total: {0} ms CPU over {1} ms wall = {2}% of one core ({3}% of the machine, {4} cores)" -f `
  [math]::Round($total,1), [math]::Round($wall,0), [math]::Round(100*$total/$wall,1), [math]::Round(100*$total/$wall/$cores,1), $cores)
Write-Host ("Threads: {0}" -f $rows.Count)
Write-Host ""

$rows | Sort-Object CpuMs -Descending | Select-Object -First $Top |
  Format-Table Tid, CpuMs, Pct, Name, Module, State, Wait -AutoSize

Write-Host "--- by module ---"
$rows | Group-Object Module | ForEach-Object {
  [pscustomobject]@{ Module = $_.Name
                     CpuMs  = [math]::Round(($_.Group | Measure-Object CpuMs -Sum).Sum, 1)
                     Threads= $_.Count }
} | Sort-Object CpuMs -Descending | Format-Table -AutoSize

if ($Csv) { $rows | Sort-Object CpuMs -Descending | Export-Csv -NoTypeInformation -Encoding utf8 $Csv; Write-Host "wrote $Csv" }
