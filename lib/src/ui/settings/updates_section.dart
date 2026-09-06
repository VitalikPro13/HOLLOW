import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/updater_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Updates category of the desktop Settings dialog: current version, update
/// check, download/install progress, and the version list.
class UpdatesTab extends ConsumerStatefulWidget {
  const UpdatesTab({super.key});

  @override
  ConsumerState<UpdatesTab> createState() => _UpdatesTabState();
}

class _UpdatesTabState extends ConsumerState<UpdatesTab> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final status = ref.read(updaterProvider).status;
      if (status == UpdateStatus.idle || status == UpdateStatus.error) {
        ref.read(updaterProvider.notifier).checkForUpdates();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final state = ref.watch(updaterProvider);
    final notifier = ref.read(updaterProvider.notifier);

    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: HollowSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Updates',
                style: HollowTypography.heading.copyWith(
                  color: hollow.textPrimary,
                  fontSize: 20,
                ),
              ),
              const SizedBox(width: HollowSpacing.md),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: hollow.accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'v${state.currentVersion}',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: HollowSpacing.lg),

          Align(
            alignment: Alignment.centerLeft,
            child: HollowButton.filled(
              onPressed: state.status == UpdateStatus.checking
                  ? null
                  : () => notifier.checkForUpdates(),
              icon: Icon(
                state.status == UpdateStatus.checking
                    ? LucideIcons.loader
                    : LucideIcons.refreshCw,
                size: 16,
              ),
              child: Text(state.status == UpdateStatus.checking
                  ? 'Checking...'
                  : 'Check for updates'),
            ),
          ),

          if (state.status == UpdateStatus.error && state.error != null)
            ..._errorChildren(hollow, state),

          if (state.status == UpdateStatus.downloading ||
              state.status == UpdateStatus.extracting)
            ..._progressChildren(hollow, state, notifier),

          if (state.status == UpdateStatus.readyToInstall)
            ..._readyChildren(hollow, state, notifier),

          if (state.manifest != null)
            ..._versionListChildren(hollow, state, notifier),

          if (state.manifest == null &&
              state.status == UpdateStatus.idle) ...[
            const SizedBox(height: HollowSpacing.xl),
            Center(
              child: Text(
                'Press "Check for updates" to see available versions.',
                style: HollowTypography.body.copyWith(
                  color: hollow.textSecondary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _errorChildren(HollowTheme hollow, UpdateState state) {
    return [
      const SizedBox(height: HollowSpacing.md),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: hollow.error.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: hollow.error.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Icon(LucideIcons.alertCircle,
                size: 16, color: hollow.error),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(
              child: Text(
                state.error!,
                style: HollowTypography.caption.copyWith(
                  color: hollow.error,
                ),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _progressChildren(
      HollowTheme hollow, UpdateState state, UpdateNotifier notifier) {
    return [
      const SizedBox(height: HollowSpacing.lg),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: hollow.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: hollow.accent.withValues(alpha: 0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  state.status == UpdateStatus.extracting
                      ? LucideIcons.archive
                      : LucideIcons.download,
                  size: 16,
                  color: hollow.accent,
                ),
                const SizedBox(width: HollowSpacing.sm),
                Text(
                  state.status == UpdateStatus.extracting
                      ? '${_applyVerb()} v${state.selectedVersion}...'
                      : 'Downloading v${state.selectedVersion}...',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (state.status == UpdateStatus.downloading)
                  HollowPressable(
                    onTap: () => notifier.cancelDownload(),
                    semanticLabel: 'Cancel download',
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(LucideIcons.x,
                          size: 14, color: hollow.textSecondary),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: HollowSpacing.md),
            SizedBox(
              height: 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: state.status == UpdateStatus.extracting
                      ? null
                      : state.downloadProgress,
                  backgroundColor: hollow.border,
                  valueColor: AlwaysStoppedAnimation<Color>(
                      hollow.accent),
                ),
              ),
            ),
            if (state.totalBytes > 0) ...[
              const SizedBox(height: HollowSpacing.sm),
              Text(
                '${_formatBytes(state.bytesDownloaded)} / ${_formatBytes(state.totalBytes)}',
                style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
    ];
  }

  /// What the indeterminate step after the download is doing: extracting a zip,
  /// staging a tarball, or waiting on the host's flatpak install.
  static String _applyVerb() {
    if (!Platform.isLinux) return 'Extracting';
    return isFlatpakInstall ? 'Installing' : 'Preparing';
  }

  List<Widget> _readyChildren(
      HollowTheme hollow, UpdateState state, UpdateNotifier notifier) {
    // A flatpak is installed by the time we get here and only the restart is
    // left, so the card must not promise an install that already happened.
    final installed = Platform.isLinux && isFlatpakInstall;
    return [
      const SizedBox(height: HollowSpacing.lg),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: hollow.accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: hollow.accent.withValues(alpha: 0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(LucideIcons.checkCircle,
                    size: 18, color: hollow.accent),
                const SizedBox(width: HollowSpacing.sm),
                Text(
                  installed
                      ? 'v${state.selectedVersion} is installed'
                      : 'Ready to install v${state.selectedVersion}',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: HollowSpacing.md),
            HollowButton.filled(
              onPressed: () => notifier.installAndRestart(),
              icon: const Icon(LucideIcons.rotateCcw, size: 16),
              child: Text(installed ? 'Restart now' : 'Install & restart'),
            ),
            const SizedBox(height: HollowSpacing.sm),
            Text(
              installed
                  ? 'Hollow will close and come back on the new version.'
                  : 'Hollow will close and relaunch automatically.',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
              ),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _versionListChildren(
      HollowTheme hollow, UpdateState state, UpdateNotifier notifier) {
    return [
      const SizedBox(height: HollowSpacing.xl),
      Text(
        'Versions',
        style: HollowTypography.label.copyWith(
          color: hollow.textSecondary,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
      const SizedBox(height: HollowSpacing.md),
      ...state.manifest!.versions.map((v) {
        final isCurrent = v.version == state.currentVersion;
        return Padding(
          padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
          child: _VersionCard(
            version: v,
            isCurrent: isCurrent,
            isLatest: v.version == state.manifest!.latest,
            isDownloading: state.status == UpdateStatus.downloading &&
                state.selectedVersion == v.version,
            onInstall: !isCurrent &&
                    (state.status == UpdateStatus.idle ||
                        state.status == UpdateStatus.error)
                ? () => notifier.downloadVersion(v)
                : null,
          ),
        );
      }),
    ];
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _VersionCard extends StatelessWidget {
  final VersionInfo version;
  final bool isCurrent;
  final bool isLatest;
  final bool isDownloading;
  final VoidCallback? onInstall;

  const _VersionCard({
    required this.version,
    required this.isCurrent,
    required this.isLatest,
    required this.isDownloading,
    this.onInstall,
  });

  Widget _tag(HollowTheme hollow, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: HollowTypography.caption.copyWith(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isCurrent
            ? hollow.accent.withValues(alpha: 0.06)
            : hollow.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isCurrent
              ? hollow.accent.withValues(alpha: 0.2)
              : hollow.border.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'v${version.version}',
                      style: HollowTypography.body.copyWith(
                        color: hollow.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (isLatest) ...[
                      const SizedBox(width: HollowSpacing.sm),
                      _tag(hollow, 'Latest', hollow.accent),
                    ],
                    if (isCurrent) ...[
                      const SizedBox(width: HollowSpacing.sm),
                      _tag(hollow, 'Installed', hollow.textSecondary),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  version.date,
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                  ),
                ),
                if (version.notes.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    version.notes,
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary.withValues(alpha: 0.8),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (onInstall != null)
            HollowButton.outline(
              onPressed: onInstall,
              compact: true,
              child: const Text('Install'),
            ),
        ],
      ),
    );
  }
}
