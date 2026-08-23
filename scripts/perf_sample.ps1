<#
.SYNOPSIS
  A sampling profiler that needs no admin rights and no symbols: repeatedly
  suspends the busiest threads, reads their instruction pointer, and
  attributes it to a loaded module.

.DESCRIPTION
  ETW (wpr/xperf) is the right tool but it needs elevation. This answers the
  question that actually matters first — WHOSE CODE is burning the CPU,
  flutter_windows.dll vs hollow_core.dll vs the GPU driver — from a standard
  user account.

  Leaf instruction pointer only, so it tells you where the CPU IS, not how it
  got there. That is enough to pick the next tool.

  Threads are suspended for microseconds at a time. Do not run this while a
  call is up: suspending a realtime audio thread will glitch it.

.EXAMPLE
  pwsh sample_ip.ps1 -Name hollow -Seconds 20
#>
param(
  [string]$Name = 'hollow',
  [int]$Seconds = 20,
  [int]$IntervalMs = 5,
  [int]$Top = 20,
  [switch]$AllThreads,
  [string]$Csv = ''
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class IpSampler {
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern IntPtr OpenThread(uint access, bool inherit, uint tid);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll")]
  static extern uint SuspendThread(IntPtr h);
  [DllImport("kernel32.dll")]
  static extern int ResumeThread(IntPtr h);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool GetThreadContext(IntPtr h, IntPtr ctx);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
  static extern int GetThreadDescription(IntPtr h, out IntPtr desc);
  [DllImport("kernel32.dll")]
  static extern IntPtr LocalFree(IntPtr p);

  // THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION
  const uint ACCESS = 0x0002 | 0x0008 | 0x0040;
  const int CONTEXT_SIZE   = 1232;   // sizeof(CONTEXT) on x64
  const int CONTEXT_OFFSET = 0x30;   // ContextFlags
  const int RIP_OFFSET     = 0xF8;   // CONTEXT.Rip
  const uint CONTEXT_CONTROL = 0x00100001;

  public static string Name(uint tid) {
    IntPtr h = OpenThread(0x0800, false, tid);
    if (h == IntPtr.Zero) return "";
    try {
      IntPtr p;
      if (GetThreadDescription(h, out p) < 0 || p == IntPtr.Zero) return "";
      try { return Marshal.PtrToStringUni(p); } finally { LocalFree(p); }
    } finally { CloseHandle(h); }
  }

  /// Sample `tid` `count` times, `sleepMs` apart. Returns the instruction
  /// pointer of each successful sample (0 entries are dropped).
  public static ulong[] Sample(uint tid, int count, int sleepMs) {
    IntPtr h = OpenThread(ACCESS, false, tid);
    if (h == IntPtr.Zero) return new ulong[0];
    // CONTEXT must be 16-byte aligned.
    IntPtr raw = Marshal.AllocHGlobal(CONTEXT_SIZE + 16);
    long aligned = (raw.ToInt64() + 15) & ~15L;
    IntPtr ctx = new IntPtr(aligned);
    var outp = new System.Collections.Generic.List<ulong>(count);
    try {
      for (int i = 0; i < count; i++) {
        for (int b = 0; b < CONTEXT_SIZE; b += 8) Marshal.WriteInt64(ctx, b, 0);
        Marshal.WriteInt32(ctx, CONTEXT_OFFSET, unchecked((int)CONTEXT_CONTROL));
        if (SuspendThread(h) != 0xFFFFFFFF) {
          bool ok = GetThreadContext(h, ctx);
          ResumeThread(h);
          if (ok) {
            ulong rip = (ulong)Marshal.ReadInt64(ctx, RIP_OFFSET);
            if (rip != 0) outp.Add(rip);
          }
        }
        if (sleepMs > 0) System.Threading.Thread.Sleep(sleepMs);
      }
    } finally {
      Marshal.FreeHGlobal(raw);
      CloseHandle(h);
    }
    return outp.ToArray();
  }
}
'@

$proc = Get-Process -Name $Name -ErrorAction SilentlyContinue
if (-not $proc) { Write-Host "No process named '$Name' is running."; exit 1 }
if ($proc -is [array]) { $proc = $proc[0] }

$mods = @()
foreach ($m in $proc.Modules) {
  $mods += [pscustomobject]@{
    Base = [uint64]$m.BaseAddress.ToInt64()
    End  = [uint64]$m.BaseAddress.ToInt64() + [uint64]$m.ModuleMemorySize
    File = [System.IO.Path]::GetFileName($m.FileName)
  }
}
$mods = $mods | Sort-Object Base
function Resolve-Module([uint64]$addr) {
  foreach ($m in $mods) { if ($addr -ge $m.Base -and $addr -lt $m.End) { return $m.File } }
  return 'unmapped/JIT'
}

# Pick the threads worth sampling: a 1 s CPU window, busiest first. Sampling
# 100 parked threads wastes the whole budget on threads that are asleep.
Write-Host "Finding busy threads in '$Name' (pid $($proc.Id)) ..."
function Snap($p) { $p.Refresh(); $h=@{}; foreach ($t in $p.Threads) { try { $h[[int]$t.Id] = $t.TotalProcessorTime.TotalMilliseconds } catch {} }; $h }
$a = Snap $proc
Start-Sleep -Seconds 1
$b = Snap $proc
$busy = @()
foreach ($id in $b.Keys) {
  if ($a.ContainsKey($id)) {
    $d = $b[$id] - $a[$id]
    if ($AllThreads -or $d -gt 1.0) { $busy += [pscustomobject]@{ Tid = $id; CpuMs = $d } }
  }
}
$busy = @($busy | Sort-Object CpuMs -Descending | Select-Object -First 6)
if ($busy.Count -eq 0) { Write-Host "No thread used more than 1 ms of CPU in a second. The process is genuinely idle."; exit 0 }

Write-Host ("Sampling {0} thread(s) for {1} s at {2} ms ..." -f $busy.Count, $Seconds, $IntervalMs)
$perThread = [int](($Seconds * 1000) / $IntervalMs / $busy.Count)

$rows = @()
foreach ($t in $busy) {
  $name = [IpSampler]::Name([uint32]$t.Tid)
  $ips  = [IpSampler]::Sample([uint32]$t.Tid, $perThread, $IntervalMs)
  if ($ips.Count -eq 0) { Write-Host ("  tid {0}: no samples (thread exited?)" -f $t.Tid); continue }
  $byMod = @{}
  foreach ($ip in $ips) { $m = Resolve-Module $ip; $byMod[$m] = 1 + $(if ($byMod.ContainsKey($m)) { $byMod[$m] } else { 0 }) }
  foreach ($k in $byMod.Keys) {
    $rows += [pscustomobject]@{
      Tid = $t.Tid; Thread = $name; Module = $k
      Samples = $byMod[$k]
      'PctOfThread' = [math]::Round(100.0 * $byMod[$k] / $ips.Count, 1)
      CpuMsPerSec = [math]::Round($t.CpuMs, 1)
    }
  }
  Write-Host ("  tid {0} '{1}': {2} samples" -f $t.Tid, $name, $ips.Count)
}

Write-Host ""
$rows | Sort-Object Samples -Descending | Select-Object -First $Top | Format-Table -AutoSize
Write-Host "--- module totals across sampled threads ---"
$rows | Group-Object Module | ForEach-Object {
  [pscustomobject]@{ Module = $_.Name; Samples = ($_.Group | Measure-Object Samples -Sum).Sum }
} | Sort-Object Samples -Descending | Format-Table -AutoSize

if ($Csv) { $rows | Export-Csv -NoTypeInformation -Encoding utf8 $Csv; Write-Host "wrote $Csv" }
