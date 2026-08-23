<#
.SYNOPSIS
  Where a process's committed memory actually lives: a VirtualQuery region
  walk folded by allocation base, plus the OS-level counters.

.DESCRIPTION
  Answers "the app holds 700 MB, of what?" without a profiler. Walks the whole
  user address space with VirtualQueryEx, classifies every region as
  IMAGE (a mapped DLL), MAPPED (a file/section) or PRIVATE (a heap, a thread
  stack, a GPU staging buffer), and folds regions by AllocationBase so one heap
  reports as one line instead of a thousand.

  PRIVATE+COMMIT is the number that matters: it is what the process is charged
  for and what shows as "Private Bytes". Reserved-not-committed is address
  space, free of charge.

  Needs no elevation for a process the caller owns.

.EXAMPLE
  pwsh scripts\perf_memory.ps1 -Name hollow
  pwsh scripts\perf_memory.ps1 -Name hollow -Samples 12 -IntervalSeconds 10 -Csv ram.csv
#>
param(
  [string]$Name = 'hollow',
  [int]$Top = 20,
  [int]$Samples = 1,
  [int]$IntervalSeconds = 10,
  [string]$Csv = '',
  [switch]$Histogram,
  [switch]$Residency
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class MemWalk {
  [StructLayout(LayoutKind.Sequential)]
  public struct MEMORY_BASIC_INFORMATION {
    public IntPtr BaseAddress;
    public IntPtr AllocationBase;
    public uint   AllocationProtect;
    public uint   Align1;
    public IntPtr RegionSize;
    public uint   State;
    public uint   Protect;
    public uint   Type;
    public uint   Align2;
  }

  [DllImport("kernel32.dll", SetLastError = true)]
  static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern IntPtr VirtualQueryEx(IntPtr h, IntPtr addr, out MEMORY_BASIC_INFORMATION mbi, IntPtr len);

  [StructLayout(LayoutKind.Sequential)]
  struct PSAPI_WORKING_SET_EX_INFORMATION {
    public IntPtr VirtualAddress;
    public IntPtr VirtualAttributes;
  }

  [DllImport("psapi.dll", SetLastError = true)]
  static extern bool QueryWorkingSetEx(IntPtr h, IntPtr info, int cb);

  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);

  const uint QUERY_INFO = 0x0400;
  const uint VM_READ    = 0x0010;

  public const uint MEM_COMMIT  = 0x1000;
  public const uint MEM_FREE    = 0x10000;
  public const uint MEM_IMAGE   = 0x1000000;
  public const uint MEM_MAPPED  = 0x40000;

  public class Region {
    public ulong AllocBase;
    public ulong Size;
    public uint  State;
    public uint  Type;
    public uint  Protect;
  }

  public static List<Region> Walk(int pid) {
    var outp = new List<Region>();
    IntPtr h = OpenProcess(QUERY_INFO | VM_READ, false, pid);
    if (h == IntPtr.Zero) throw new Exception("OpenProcess failed: " + Marshal.GetLastWin32Error());
    try {
      ulong addr = 0;
      ulong max  = 0x7FFFFFFFFFFFUL;
      int sz = Marshal.SizeOf(typeof(MEMORY_BASIC_INFORMATION));
      while (addr < max) {
        MEMORY_BASIC_INFORMATION mbi;
        IntPtr got = VirtualQueryEx(h, (IntPtr)(long)addr, out mbi, (IntPtr)sz);
        if (got == IntPtr.Zero) break;
        ulong rsize = (ulong)mbi.RegionSize.ToInt64();
        if (rsize == 0) break;
        if (mbi.State != MEM_FREE) {
          var r = new Region();
          r.AllocBase = (ulong)mbi.AllocationBase.ToInt64();
          r.Size      = rsize;
          r.State     = mbi.State;
          r.Type      = mbi.Type;
          r.Protect   = mbi.Protect;
          outp.Add(r);
        }
        addr += rsize;
      }
    } finally { CloseHandle(h); }
    return outp;
  }

  // Fraction of a range that is actually RESIDENT (in the working set).
  // Committed-but-never-touched pages are charged to commit but cost no RAM.
  public static double ResidentFraction(int pid, ulong baseAddr, ulong size, int maxSamples) {
    IntPtr h = OpenProcess(QUERY_INFO | VM_READ, false, pid);
    if (h == IntPtr.Zero) return -1;
    try {
      ulong pages = size / 4096UL;
      if (pages == 0) return 0;
      int n = (int)Math.Min(pages, (ulong)maxSamples);
      ulong stride = pages / (ulong)n;
      if (stride == 0) stride = 1;

      int sz = Marshal.SizeOf(typeof(PSAPI_WORKING_SET_EX_INFORMATION));
      IntPtr buf = Marshal.AllocHGlobal(sz * n);
      try {
        for (int i = 0; i < n; i++) {
          var e = new PSAPI_WORKING_SET_EX_INFORMATION();
          e.VirtualAddress = (IntPtr)(long)(baseAddr + (ulong)i * stride * 4096UL);
          e.VirtualAttributes = IntPtr.Zero;
          Marshal.StructureToPtr(e, (IntPtr)(buf.ToInt64() + i * sz), false);
        }
        if (!QueryWorkingSetEx(h, buf, sz * n)) return -1;
        int valid = 0;
        for (int i = 0; i < n; i++) {
          var e = (PSAPI_WORKING_SET_EX_INFORMATION)Marshal.PtrToStructure(
            (IntPtr)(buf.ToInt64() + i * sz), typeof(PSAPI_WORKING_SET_EX_INFORMATION));
          if ((e.VirtualAttributes.ToInt64() & 1L) != 0) valid++;
        }
        return (double)valid / (double)n;
      } finally { Marshal.FreeHGlobal(buf); }
    } finally { CloseHandle(h); }
  }

  // A page that was never written reads back as zeros. A page that was written
  // and then trimmed out of the working set reads back its data. So sampling
  // content is what separates "committed and never used" (waste, costs no RAM)
  // from "in use but paged out" (real memory pressure) -- QueryWorkingSetEx
  // alone reports both as not-resident.
  public static double ZeroFraction(int pid, ulong baseAddr, ulong size, int samples) {
    IntPtr h = OpenProcess(QUERY_INFO | VM_READ, false, pid);
    if (h == IntPtr.Zero) return -1;
    try {
      int zero = 0, read = 0;
      byte[] b = new byte[64];
      for (int i = 0; i < samples; i++) {
        ulong off = (size / (ulong)samples) * (ulong)i;
        off = off & ~4095UL;
        IntPtr got;
        if (!ReadProcessMemory(h, (IntPtr)(long)(baseAddr + off), b, (IntPtr)64, out got)) continue;
        if (got.ToInt32() < 64) continue;
        read++;
        bool allZero = true;
        for (int k = 0; k < 64; k++) { if (b[k] != 0) { allZero = false; break; } }
        if (allZero) zero++;
      }
      if (read == 0) return -1;
      return (double)zero / (double)read;
    } finally { CloseHandle(h); }
  }

  // First bytes of a range, so a block can be identified by what is in it.
  public static byte[] Peek(int pid, ulong addr, int len) {
    IntPtr h = OpenProcess(QUERY_INFO | VM_READ, false, pid);
    if (h == IntPtr.Zero) return new byte[0];
    try {
      byte[] b = new byte[len];
      IntPtr read;
      if (!ReadProcessMemory(h, (IntPtr)(long)addr, b, (IntPtr)len, out read)) return new byte[0];
      int got = read.ToInt32();
      if (got < len) Array.Resize(ref b, got);
      return b;
    } finally { CloseHandle(h); }
  }
}
'@

function Format-Mb([double]$bytes) { return ('{0,10:N1}' -f ($bytes / 1MB)) }

# GPU memory is charged to the process but lives outside its address space, so
# a region walk cannot see it. On a texture-heavy app it is often the largest
# real number, and it moves together with the driver's system-memory backing.
function Get-GpuMb([int]$pid_, [string]$counter) {
  try {
    $s = (Get-Counter ('\GPU Process Memory(*)\' + $counter) -ErrorAction Stop).CounterSamples |
      Where-Object { $_.InstanceName -like ('*pid_' + $pid_ + '_*') } |
      Measure-Object -Property CookedValue -Sum
    return [math]::Round($s.Sum / 1MB, 1)
  } catch { return -1 }
}

function Show-Snapshot($proc, [bool]$Detail) {
  $regions = [MemWalk]::Walk($proc.Id)

  $modules = @{}
  foreach ($m in $proc.Modules) {
    $modules[[uint64]$m.BaseAddress.ToInt64()] = [System.IO.Path]::GetFileName($m.FileName)
  }

  $sum = @{}
  foreach ($t in 'IMAGE','MAPPED','PRIVATE') {
    $sum[($t + '/COMMIT')]  = [double]0
    $sum[($t + '/RESERVE')] = [double]0
  }

  $byAlloc = @{}
  foreach ($r in $regions) {
    $type = 'PRIVATE'
    if ($r.Type -eq [MemWalk]::MEM_IMAGE)  { $type = 'IMAGE' }
    if ($r.Type -eq [MemWalk]::MEM_MAPPED) { $type = 'MAPPED' }
    $state = 'RESERVE'
    if ($r.State -eq [MemWalk]::MEM_COMMIT) { $state = 'COMMIT' }
    $sum[($type + '/' + $state)] += $r.Size

    if ($state -eq 'COMMIT') {
      $key = '{0}|{1:X}' -f $type, $r.AllocBase
      if (-not $byAlloc.ContainsKey($key)) {
        $byAlloc[$key] = [pscustomobject]@{
          Type = $type; AllocBase = $r.AllocBase; Bytes = [double]0; Regions = 0; Protect = $r.Protect
        }
      }
      $byAlloc[$key].Bytes   += $r.Size
      $byAlloc[$key].Regions += 1
    }
  }

  $privC = $sum['PRIVATE/COMMIT']
  $imgC  = $sum['IMAGE/COMMIT']
  $mapC  = $sum['MAPPED/COMMIT']
  $resv  = $sum['PRIVATE/RESERVE'] + $sum['IMAGE/RESERVE'] + $sum['MAPPED/RESERVE']

  Write-Output ''
  Write-Output ('=== {0} (pid {1})  up {2}   at {3}' -f $proc.ProcessName, $proc.Id, ((Get-Date) - $proc.StartTime).ToString('hh\:mm\:ss'), (Get-Date).ToString('HH:mm:ss'))
  Write-Output ('  WorkingSet (resident)  {0} MB' -f (Format-Mb $proc.WorkingSet64))
  Write-Output ('  PrivateBytes (commit)  {0} MB' -f (Format-Mb $proc.PrivateMemorySize64))
  Write-Output ('  PeakWorkingSet         {0} MB' -f (Format-Mb $proc.PeakWorkingSet64))
  Write-Output ('  Threads {0}   Handles {1}' -f $proc.Threads.Count, $proc.HandleCount)
  Write-Output ''
  Write-Output '  --- committed address space, by kind ---'
  Write-Output ('  PRIVATE commit {0} MB   heaps, stacks, GPU staging: the real cost' -f (Format-Mb $privC))
  Write-Output ('  IMAGE   commit {0} MB   mapped DLL code+data, mostly shared' -f (Format-Mb $imgC))
  Write-Output ('  MAPPED  commit {0} MB   file/section mappings: app.so, fonts, assets' -f (Format-Mb $mapC))
  Write-Output ('  reserved only  {0} MB   address space, not charged' -f (Format-Mb $resv))

  if (-not $Detail) { return }

  Write-Output ''
  Write-Output ('  --- top {0} committed allocations, folded by AllocationBase ---' -f $Top)
  Write-Output ('  {0,-8} {1,-14} {2,9} {3,8}  {4}' -f 'KIND', 'BASE', 'MB', 'REGIONS', 'MODULE / GUESS')
  $ranked = $byAlloc.Values | Sort-Object -Property Bytes -Descending | Select-Object -First $Top
  foreach ($a in $ranked) {
    $who = ''
    if ($modules.ContainsKey($a.AllocBase)) {
      $who = $modules[$a.AllocBase]
    } elseif ($a.Type -eq 'PRIVATE') {
      if ($a.Regions -ge 3 -and $a.Bytes -ge 4MB) { $who = 'heap / arena' }
      elseif ($a.Bytes -le 1MB) { $who = 'thread stack?' }
      else { $who = 'private block' }
    }
    Write-Output ('  {0,-8} {1,-14} {2,9} {3,8}  {4}' -f $a.Type, ('{0:X}' -f $a.AllocBase), ('{0:N1}' -f ($a.Bytes / 1MB)), $a.Regions, $who)
  }

  if ($Histogram) {
    Write-Output ''
    Write-Output '  --- PRIVATE committed allocations, bucketed by size ---'
    Write-Output ('  {0,-14} {1,7} {2,12}  {3}' -f 'BUCKET', 'COUNT', 'TOTAL MB', 'NOTE')
    $priv = $byAlloc.Values | Where-Object { $_.Type -eq 'PRIVATE' }
    $buckets = @(
      @{ Name = '>= 32 MB';     Min = 32MB;   Max = [double]::MaxValue },
      @{ Name = '15-32 MB';     Min = 15MB;   Max = 32MB },
      @{ Name = '4-15 MB';      Min = 4MB;    Max = 15MB },
      @{ Name = '1-4 MB';       Min = 1MB;    Max = 4MB },
      @{ Name = '128 KB - 1 MB'; Min = 128KB; Max = 1MB },
      @{ Name = '< 128 KB';     Min = 0;      Max = 128KB }
    )
    foreach ($b in $buckets) {
      $hits = $priv | Where-Object { $_.Bytes -ge $b.Min -and $_.Bytes -lt $b.Max }
      $tot = 0
      foreach ($x in $hits) { $tot += $x.Bytes }
      $note = ''
      if ($b.Name -eq '15-32 MB' -and $hits.Count -ge 5) { $note = 'suspicious: uniform large blocks' }
      Write-Output ('  {0,-14} {1,7} {2,12}  {3}' -f $b.Name, $hits.Count, ('{0:N1}' -f ($tot / 1MB)), $note)
    }

    Write-Output ''
    Write-Output '  --- every PRIVATE committed allocation >= 8 MB ---'
    Write-Output ('  {0,-14} {1,9} {2,8} {3,10}  {4}' -f 'BASE', 'MB', 'REGIONS', 'PROTECT', 'SHAPE')
    $big = $priv | Where-Object { $_.Bytes -ge 8MB } | Sort-Object -Property AllocBase
    foreach ($a in $big) {
      $shape = 'multi-region heap'
      if ($a.Regions -eq 1) { $shape = 'ONE flat VirtualAlloc commit' }
      Write-Output ('  {0,-14} {1,9} {2,8} {3,10}  {4}' -f ('{0:X}' -f $a.AllocBase), ('{0:N1}' -f ($a.Bytes / 1MB)), $a.Regions, ('0x{0:X}' -f $a.Protect), $shape)
    }
  }

  if ($Residency) {
    Write-Output ''
    Write-Output '  --- PRIVATE committed: how much is actually RESIDENT ---'
    Write-Output '  committed-but-never-touched pages cost commit charge, not RAM.'
    Write-Output ('  {0,-14} {1,9} {2,9} {3,8} {4,7}  {5}' -f 'BASE', 'COMMIT MB', 'RES MB', 'RES %', 'ZERO %', 'VERDICT')
    $priv = $byAlloc.Values | Where-Object { $_.Type -eq 'PRIVATE' } | Sort-Object -Property Bytes -Descending
    $totCommit = [double]0
    $totRes = [double]0
    foreach ($a in $priv) {
      $f = [MemWalk]::ResidentFraction($proc.Id, $a.AllocBase, [uint64]$a.Bytes, 2048)
      if ($f -lt 0) { $f = 0 }
      $res = $a.Bytes * $f
      $totCommit += $a.Bytes
      $totRes += $res
      if ($a.Bytes -ge 8MB) {
        $z = [MemWalk]::ZeroFraction($proc.Id, $a.AllocBase, [uint64]$a.Bytes, 48)
        $verdict = 'in use'
        if ($z -lt 0) { $verdict = 'unreadable' }
        elseif ($z -ge 0.98) { $verdict = 'NEVER WRITTEN' }
        elseif ($z -ge 0.5) { $verdict = 'mostly unused' }
        elseif ($f -lt 0.2) { $verdict = 'written, paged out' }
        Write-Output ('  {0,-14} {1,9} {2,9} {3,8} {4,7}  {5}' -f ('{0:X}' -f $a.AllocBase), ('{0:N1}' -f ($a.Bytes / 1MB)), ('{0:N1}' -f ($res / 1MB)), ('{0:P0}' -f $f), ('{0:P0}' -f $z), $verdict)
      }
    }
    Write-Output ''
    Write-Output ('  PRIVATE committed total  {0} MB' -f (Format-Mb $totCommit))
    Write-Output ('  PRIVATE resident total   {0} MB   <- the actual RAM cost' -f (Format-Mb $totRes))
    Write-Output ('  never touched            {0} MB   <- commit charge only' -f (Format-Mb ($totCommit - $totRes)))
  }

  Write-Output ''
  Write-Output '  --- largest loaded modules (image, mostly shared) ---'
  $proc.Modules | Sort-Object -Property ModuleMemorySize -Descending | Select-Object -First 10 | ForEach-Object {
    Write-Output ('  {0,9} MB  {1}' -f ('{0:N1}' -f ($_.ModuleMemorySize / 1MB)), [System.IO.Path]::GetFileName($_.FileName))
  }
}

$rows = @()
for ($i = 0; $i -lt $Samples; $i++) {
  $p = Get-Process -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $p) { Write-Output ("no process named '" + $Name + "'"); break }
  $p.Refresh()
  $detail = ($i -eq 0) -or ($i -eq ($Samples - 1))
  Show-Snapshot $p $detail
  $rows += [pscustomobject]@{
    T          = (Get-Date).ToString('HH:mm:ss')
    WorkingSet = [math]::Round($p.WorkingSet64 / 1MB, 1)
    Commit     = [math]::Round($p.PrivateMemorySize64 / 1MB, 1)
    VramMB     = (Get-GpuMb $p.Id 'Local Usage')
    GpuSysMB   = (Get-GpuMb $p.Id 'Non Local Usage')
    Threads    = $p.Threads.Count
    Handles    = $p.HandleCount
  }
  if ($i -lt ($Samples - 1)) { Start-Sleep -Seconds $IntervalSeconds }
}

if ($Samples -gt 1) {
  Write-Output ''
  Write-Output '=== growth ==='
  $rows | Format-Table -AutoSize
}
if ($Csv -ne '' -and $rows.Count -gt 0) { $rows | Export-Csv -NoTypeInformation -Encoding utf8 $Csv }
