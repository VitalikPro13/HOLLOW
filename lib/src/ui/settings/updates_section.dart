import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/changelog.dart';
import 'package:hollow/src/core/providers/home_setup_provider.dart';
import 'package:hollow/src/core/providers/updater_provider.dart';
import 'package:hollow/src/core/time_labels.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/changelog_dialog.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';

/// Phones update through their stores; only desktop runs the updater.
bool get _hasUpdater => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// Settings > About's Updates section: one status row for the updater, what's
/// new in this build, and older builds to fall back to.
class UpdatesTab extends ConsumerStatefulWidget {
  const UpdatesTab({super.key});

  @override
  ConsumerState<UpdatesTab> createState() => _UpdatesTabState();
}

class _UpdatesTabState extends ConsumerState<UpdatesTab> {
  bool _installing = false;

  @override
  void initState() {
    super.initState();
    if (!_hasUpdater) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final status = ref.read(updaterProvider).status;
      if (status == UpdateStatus.idle || status == UpdateStatus.error) {
        _check();
      }
    });
  }

  void _check() {
    ref.read(updaterProvider.notifier).checkForUpdates().catchError((_) {});
  }

  Future<void> _install() async {
    setState(() => _installing = true);
    try {
      await ref.read(updaterProvider.notifier).installAndRestart();
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, friendlyError(e,
                fallback: "Couldn't start the update. Try again."),
            type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSection(
      title: 'Updates',
      children: [
        if (_hasUpdater)
          _statusRow(context)
        else
          const SettingsRow(
            title: 'App store updates',
            subtitle: 'Your app store keeps Hollow up to date.',
          ),
        const _WhatsNewRow(),
        if (_hasUpdater) _earlierVersions(),
      ],
    );
  }

  Widget _statusRow(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final state = ref.watch(updaterProvider);
    final notifier = ref.read(updaterProvider.notifier);
    final hasUpdate = ref.watch(hasUpdateProvider);

    switch (state.status) {
      case UpdateStatus.downloading:
      case UpdateStatus.extracting:
        final downloading = state.status == UpdateStatus.downloading;
        return SettingsRow(
          title: downloading
              ? 'Downloading v${state.selectedVersion}'
              : '${_applyVerb()} v${state.selectedVersion}',
          subtitleWidget: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: HollowSpacing.xs),
              LinearProgressIndicator(
                value: downloading ? state.downloadProgress : null,
                minHeight: 4,
                borderRadius: BorderRadius.circular(hollow.radiusXs),
                backgroundColor: hollow.border,
                valueColor: AlwaysStoppedAnimation<Color>(hollow.accent),
              ),
              if (state.totalBytes > 0) ...[
                const SizedBox(height: HollowSpacing.xs),
                Text(
                  '${_formatBytes(state.bytesDownloaded)} of '
                  '${_formatBytes(state.totalBytes)}',
                  style: HollowTypography.monoSmall.copyWith(
                    color: hollow.textSecondary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
          trailing: downloading
              ? HollowButton.ghost(
                  compact: true,
                  onPressed: notifier.cancelDownload,
                  semanticLabel: 'Cancel download',
                  child: const Text('Cancel'),
                )
              : null,
        );

      case UpdateStatus.readyToInstall:
        // A flatpak is installed by the time we get here and only the restart
        // is left, so the row must not promise an install that already
        // happened.
        final installed = Platform.isLinux && isFlatpakInstall;
        return SettingsRow(
          title: installed
              ? 'v${state.selectedVersion} is installed'
              : 'Ready to install v${state.selectedVersion}',
          subtitle: installed
              ? 'Hollow will close and come back on the new version.'
              : 'Hollow will close and open again on its own.',
          trailing: HollowButton.filled(
            compact: true,
            loading: _installing,
            onPressed: _install,
            child: Text(installed ? 'Restart now' : 'Install and restart'),
          ),
        );

      case UpdateStatus.idle:
      case UpdateStatus.checking:
      case UpdateStatus.error:
        final checking = state.status == UpdateStatus.checking;
        final failed = state.status == UpdateStatus.error && state.error != null;
        final latest = hasUpdate ? _latestEntry(state) : null;

        final String title;
        if (failed && state.failure != UpdateFailure.check) {
          title = 'The update did not install';
        } else if (failed) {
          title = 'Could not check for updates';
        } else if (hasUpdate) {
          title = 'Version ${state.manifest!.latest} is available';
        } else if (state.manifest != null) {
          title = "You're up to date";
        } else if (checking) {
          title = 'Checking for updates';
        } else {
          title = 'Not checked yet';
        }

        final checked = state.lastChecked;
        return SettingsRow(
          title: title,
          // The failure stays beside the button that retries it.
          subtitleWidget: failed
              ? Text(state.error!,
                  style: HollowTypography.bodySmall
                      .copyWith(color: hollow.error))
              : null,
          subtitle: checked == null
              ? null
              : 'Last checked ${relativeTimeLabel(checked)}',
          trailing: latest != null && !checking
              ? HollowButton.filled(
                  compact: true,
                  onPressed: () =>
                      notifier.downloadVersion(latest).catchError((_) {}),
                  child: const Text('Download'),
                )
              : HollowButton.ghost(
                  compact: true,
                  loading: checking,
                  onPressed: _check,
                  child: const Text('Check now'),
                ),
        );
    }
  }

  Widget _earlierVersions() {
    final state = ref.watch(updaterProvider);
    final manifest = state.manifest;
    if (manifest == null || manifest.versions.isEmpty) {
      return const SizedBox.shrink();
    }
    final canInstall = state.status == UpdateStatus.idle ||
        state.status == UpdateStatus.error;
    final notifier = ref.read(updaterProvider.notifier);
    return SettingsExpandRow(
      title: 'Earlier versions',
      subtitle: 'Install an older build if a new one misbehaves',
      children: [
        for (final v in manifest.versions)
          _VersionRow(
            key: ValueKey(v.version),
            version: v,
            isCurrent: v.version == state.currentVersion,
            isLatest: v.version == manifest.latest,
            onInstall: v.version != state.currentVersion && canInstall
                ? () => notifier.downloadVersion(v).catchError((_) {})
                : null,
          ),
      ],
    );
  }

  static VersionInfo? _latestEntry(UpdateState state) {
    for (final v in state.manifest!.versions) {
      if (v.version == state.manifest!.latest) return v;
    }
    return null;
  }

  /// What the indeterminate step after the download is doing: extracting a zip,
  /// staging a tarball, or waiting on the host's flatpak install.
  static String _applyVerb() {
    if (!Platform.isLinux) return 'Extracting';
    return isFlatpakInstall ? 'Installing' : 'Preparing';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// "What's new": the headline of this build's changelog, and the full notes.
class _WhatsNewRow extends ConsumerWidget {
  const _WhatsNewRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final releases =
        ref.watch(changelogProvider).valueOrNull ?? const <ChangelogRelease>[];
    if (releases.isEmpty) return const SizedBox.shrink();
    final version = ref.watch(updaterProvider.select((u) => u.currentVersion));
    final found = releases.indexWhere((r) => r.describes(version));
    final index = found < 0 ? 0 : found;
    return SettingsRow(
      title: "What's new",
      subtitleWidget: Text(
        releases[index].title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: HollowButton.ghost(
        compact: true,
        onPressed: () {
          if (found >= 0) {
            ref
                .read(homeSetupProvider.notifier)
                .markChangelogSeen(version)
                .catchError((_) {});
          }
          showChangelogDialog(context, releases, index);
        },
        child: const Text('Read'),
      ),
    );
  }
}

/// One published build, installable unless it is the one running.
class _VersionRow extends StatelessWidget {
  final VersionInfo version;
  final bool isCurrent;
  final bool isLatest;
  final VoidCallback? onInstall;

  const _VersionRow({
    super.key,
    required this.version,
    required this.isCurrent,
    required this.isLatest,
    this.onInstall,
  });

  @override
  Widget build(BuildContext context) {
    final date = DateTime.tryParse(version.date);
    final when = date == null ? version.date : conversationTimeLabel(date);
    final line = [
      if (when.isNotEmpty) when,
      if (version.notes.isNotEmpty) version.notes,
    ].join(' · ');
    return SettingsRow(
      title: 'v${version.version}',
      subtitleWidget: line.isEmpty
          ? null
          : Text(line, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Wrap(
        spacing: HollowSpacing.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (isLatest) const HollowBadge('Latest'),
          if (isCurrent) const HollowBadge('Installed'),
          if (onInstall != null)
            HollowButton.outline(
              compact: true,
              onPressed: onInstall,
              child: const Text('Install'),
            ),
        ],
      ),
    );
  }
}
