import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/download_manager_provider.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/share/share_card.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

/// Shows a download manager popup anchored near the tap position.
void showDownloadManagerPopup({
  required BuildContext context,
  required Offset anchor,
  bool anchorBottom = false,
}) {
  final overlay = Overlay.of(context);
  late final OverlayEntry entry;

  entry = OverlayEntry(
    builder: (context) => _DownloadManagerOverlay(
      anchor: anchor,
      anchorBottom: anchorBottom,
      onDismiss: () {
        entry.remove();
        entry.dispose();
      },
    ),
  );

  overlay.insert(entry);
}

class _DownloadManagerOverlay extends ConsumerStatefulWidget {
  final Offset anchor;
  final bool anchorBottom;
  final VoidCallback onDismiss;

  const _DownloadManagerOverlay({
    required this.anchor,
    this.anchorBottom = false,
    required this.onDismiss,
  });

  @override
  ConsumerState<_DownloadManagerOverlay> createState() =>
      _DownloadManagerOverlayState();
}

class _DownloadManagerOverlayState
    extends ConsumerState<_DownloadManagerOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnim;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.animationsDisabled ? Duration.zero : const Duration(milliseconds: 180),
    );
    _scaleAnim = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _dismiss() {
    _controller.reverse().then((_) => widget.onDismiss());
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final entries = ref.watch(downloadManagerEntriesProvider);
    final allShares = ref.watch(shareTabProvider);
    final dismissed = ref.watch(dismissedShareDownloadsProvider);
    final activeShareDownloads = downloadingShares(allShares);
    final completedShareDownloads = seedingShares(allShares)
        .where((s) => !dismissed.contains(s.rootHash))
        .toList();
    final shareItems = [...activeShareDownloads, ...completedShareDownloads];

    const cardWidth = 340.0;
    const maxHeight = 420.0;

    // Position: card appears near the anchor.
    final screenSize = MediaQuery.of(context).size;
    double left = widget.anchor.dx;

    // Clamp horizontal.
    if (left < 8) left = 8;
    if (left + cardWidth > screenSize.width - 8) {
      left = screenSize.width - cardWidth - 8;
    }

    // Vertical positioning.
    double? top;
    double? bottom;
    if (widget.anchorBottom) {
      bottom = screenSize.height - widget.anchor.dy;
      if (bottom < 8) bottom = 8;
    } else {
      top = widget.anchor.dy;
      if (top < 8) top = 8;
    }

    return Stack(
      children: [
        // Dismiss barrier.
        Positioned.fill(
          child: GestureDetector(
            onTap: _dismiss,
            behavior: HitTestBehavior.opaque,
            child: const SizedBox.expand(),
          ),
        ),

        // Card with animation.
        Positioned(
          left: left,
          top: top,
          bottom: bottom,
          child: FadeTransition(
            opacity: _fadeAnim,
            child: ScaleTransition(
              scale: _scaleAnim,
              alignment: Alignment.bottomCenter,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  width: cardWidth,
                  constraints: const BoxConstraints(maxHeight: maxHeight),
                  decoration: BoxDecoration(
                    color: hollow.surface.withValues(alpha: 0.96),
                    borderRadius: BorderRadius.circular(hollow.radiusLg),
                    border: Border.all(
                      color: hollow.accent.withValues(alpha: 0.15),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 28,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // ── Header ──
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          HollowSpacing.md,
                          HollowSpacing.sm + 2,
                          HollowSpacing.sm,
                          HollowSpacing.xs,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              LucideIcons.download,
                              size: 14,
                              color: hollow.textSecondary,
                            ),
                            const SizedBox(width: HollowSpacing.xs),
                            Text(
                              'Downloads',
                              style: HollowTypography.subheading.copyWith(
                                color: hollow.textPrimary,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                            const Spacer(),
                            if (entries.isNotEmpty || shareItems.isNotEmpty)
                              HollowPressable(
                                onTap: () {
                                  ref.read(downloadManagerStateProvider.notifier).clearAll();
                                  final allRoots = completedShareDownloads.map((s) => s.rootHash).toSet();
                                  ref.read(dismissedShareDownloadsProvider.notifier).state = {
                                    ...ref.read(dismissedShareDownloadsProvider), ...allRoots,
                                  };
                                },
                                borderRadius:
                                    BorderRadius.circular(hollow.radiusSm),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: HollowSpacing.sm,
                                  vertical: HollowSpacing.xxs,
                                ),
                                child: Text(
                                  'Clear',
                                  style: HollowTypography.caption.copyWith(
                                    color: hollow.textSecondary,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),

                      Container(height: 1, color: hollow.border),

                      // ── Entry list or empty state ──
                      if (entries.isEmpty && shareItems.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: HollowSpacing.xl + HollowSpacing.md,
                            horizontal: HollowSpacing.lg,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                LucideIcons.inbox,
                                size: 28,
                                color:
                                    hollow.textSecondary.withValues(alpha: 0.4),
                              ),
                              const SizedBox(height: HollowSpacing.sm),
                              Text(
                                'Nothing here yet',
                                style: HollowTypography.caption.copyWith(
                                  color: hollow.textSecondary
                                      .withValues(alpha: 0.7),
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Downloaded files and shard activity show up here.',
                                style: HollowTypography.caption.copyWith(
                                  color: hollow.textSecondary
                                      .withValues(alpha: 0.5),
                                  fontSize: 10,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        )
                      else
                        Flexible(
                          child: ListView.separated(
                            shrinkWrap: true,
                            padding: const EdgeInsets.symmetric(
                              vertical: HollowSpacing.xs,
                            ),
                            itemCount: shareItems.length + entries.length,
                            separatorBuilder: (_, _) => Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: HollowSpacing.md,
                              ),
                              child: Container(
                                height: 1,
                                color: hollow.border.withValues(alpha: 0.3),
                              ),
                            ),
                            itemBuilder: (context, index) {
                              if (index < shareItems.length) {
                                return _ShareDownloadTile(item: shareItems[index]);
                              }
                              final entry = entries[index - shareItems.length];
                              if (entry.type == DownloadEntryType.rebalance) {
                                return _RebalanceTile(entry: entry);
                              }
                              return _SavedFileTile(entry: entry);
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── File entry tile ──────────────────────────────────────────

class _SavedFileTile extends ConsumerWidget {
  final DownloadManagerEntry entry;

  const _SavedFileTile({required this.entry});

  /// Reveal the file in the OS file explorer and bring it to the foreground.
  /// Windows: `explorer.exe /select,path` + `SetForegroundWindow` via PowerShell
  /// (explorer.exe alone reuses existing windows without focus).
  /// macOS: `open -R` already activates Finder.
  /// Linux: xdg-open on the parent dir.
  Future<void> _revealInFolder(BuildContext context) async {
    final path = entry.savedPath;
    if (path == null) return;
    try {
      if (Platform.isWindows) {
        // Launch Explorer with the file selected.
        await Process.start('explorer.exe', ['/select,$path']);
        // Windows has a foreground lock that blocks SetForegroundWindow from
        // background processes (causing the yellow taskbar flash). Beat the
        // lock via input-queue attachment + a synthetic Alt keypress, which
        // Windows treats as user intent and releases the lock. See
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
        // Linux: open parent directory.
        final parent = File(path).parent.path;
        await launchUrl(Uri.file(parent));
      }
    } catch (_) {
      if (!context.mounted) return;
      HollowToast.show(
        context,
        'Could not open folder',
        type: HollowToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final hasMedia = entry.isImage || entry.isVideo;

    return HollowPressable(
      onTap: () => _revealInFolder(context),
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Thumbnail / file icon.
          ClipRRect(
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            child: SizedBox(
              width: 40,
              height: 40,
              child: hasMedia && entry.savedPath != null
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.file(
                          File(entry.savedPath!),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => _fileIconFallback(hollow),
                        ),
                        if (entry.isVideo)
                          Container(
                            color: Colors.black.withValues(alpha: 0.3),
                            alignment: Alignment.center,
                            child: const Icon(
                              LucideIcons.play,
                              size: 16,
                              color: Colors.white,
                            ),
                          ),
                      ],
                    )
                  : _fileIconFallback(hollow),
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),

          // Name + path.
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.displayName,
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                if (entry.savedPath != null)
                  Text(
                    entry.savedPath!,
                    style: HollowTypography.mono.copyWith(
                      color: hollow.textSecondary.withValues(alpha: 0.7),
                      fontSize: 9,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),

          const SizedBox(width: HollowSpacing.xs),

          // Reveal-in-folder hint icon.
          Icon(
            LucideIcons.folderOpen,
            size: 12,
            color: hollow.textSecondary.withValues(alpha: 0.5),
          ),
        ],
      ),
    );
  }

  Widget _fileIconFallback(HollowTheme hollow) {
    return Container(
      color: hollow.elevated,
      alignment: Alignment.center,
      child: Icon(
        entry.isVideo
            ? LucideIcons.film
            : (entry.isImage ? LucideIcons.image : LucideIcons.file),
        size: 18,
        color: hollow.textSecondary,
      ),
    );
  }
}

// ── Share download tile ─────────────────────────────────────

class _ShareDownloadTile extends StatelessWidget {
  final ShareItemState item;

  const _ShareDownloadTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final completed = item.state == 'completed';
    final failed = item.state == 'failed';
    final progress = item.chunksTotal > 0
        ? item.chunksHave / item.chunksTotal
        : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      child: Row(
        children: [
          if (completed)
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: hollow.success.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(hollow.radiusSm),
              ),
              alignment: Alignment.center,
              child: Icon(LucideIcons.check, size: 16, color: hollow.success),
            )
          else
            SizedBox(
              width: 40,
              height: 40,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(
                      value: progress,
                      strokeWidth: 2.5,
                      backgroundColor: hollow.border,
                      valueColor: AlwaysStoppedAnimation(
                        failed ? hollow.error : hollow.accent,
                      ),
                    ),
                  ),
                  Text(
                    '${(progress * 100).round()}%',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 8,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.fileName,
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  completed
                      ? ShareCard.formatSize(item.totalSize)
                      : failed
                          ? item.error ?? 'Failed'
                          : '${item.chunksHave}/${item.chunksTotal} chunks  ·  ${ShareCard.formatSpeed(item.bytesPerSec)}/s',
                  style: HollowTypography.caption.copyWith(
                    color: completed ? hollow.success
                        : failed ? hollow.error
                        : hollow.textSecondary,
                    fontSize: 10,
                  ),
                  maxLines: 1,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Rebalance tile ───────────────────────────────────────────

class _RebalanceTile extends StatelessWidget {
  final DownloadManagerEntry entry;

  const _RebalanceTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final active = entry.status == DownloadEntryStatus.active;
    final accentColor = active ? hollow.accent : hollow.success;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(hollow.radiusSm),
            ),
            alignment: Alignment.center,
            child: Icon(
              LucideIcons.shuffle,
              size: 16,
              color: accentColor,
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.displayName,
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                ),
                const SizedBox(height: 2),
                if (entry.statusText != null)
                  Text(
                    entry.statusText!,
                    style: HollowTypography.caption.copyWith(
                      color: active ? hollow.textSecondary : hollow.success,
                      fontSize: 10,
                    ),
                    maxLines: 1,
                  ),
              ],
            ),
          ),
          if (!active)
            Icon(LucideIcons.check, size: 12, color: hollow.success),
        ],
      ),
    );
  }
}
