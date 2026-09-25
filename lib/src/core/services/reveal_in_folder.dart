import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

/// Shows [path] selected in the OS file manager and brings that window to the
/// front. Throws when the file manager cannot be started.
Future<void> revealInFolder(String path) async {
  if (Platform.isWindows) {
    await Process.start('explorer.exe', ['/select,$path']);
    // `explorer.exe` alone reuses an existing window without focusing it, and
    // Windows blocks SetForegroundWindow from a background process (the yellow
    // taskbar flash). A synthetic Alt keypress reads as user intent and
    // releases that lock. See
    // https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow
    const activateScript = r'''
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte v, byte s, uint f, UIntPtr e);
}
"@
Start-Sleep -Milliseconds 150
$p = Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Sort-Object StartTime -Descending | Select-Object -First 1
if ($p) {
  $hwnd = $p.MainWindowHandle
  # Release the foreground lock by simulating an Alt tap on our own thread.
  [W]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
  [W]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
  # Attach our input queue to the current foreground window's thread so
  # SetForegroundWindow is permitted.
  $fg = [W]::GetForegroundWindow()
  $pid2 = 0
  $fgTid = [W]::GetWindowThreadProcessId($fg, [ref]$pid2)
  $ourTid = [W]::GetCurrentThreadId()
  [W]::AttachThreadInput($ourTid, $fgTid, $true) | Out-Null
  [W]::ShowWindow($hwnd, 9) | Out-Null
  [W]::BringWindowToTop($hwnd) | Out-Null
  [W]::SetForegroundWindow($hwnd) | Out-Null
  [W]::AttachThreadInput($ourTid, $fgTid, $false) | Out-Null
}
''';
    await Process.run(
      'powershell',
      ['-NoProfile', '-Command', activateScript],
    );
  } else if (Platform.isMacOS) {
    await Process.run('open', ['-R', path]);
  } else {
    if (!await launchUrl(Uri.file(File(path).parent.path))) {
      throw StateError('no file manager opened $path');
    }
  }
}
