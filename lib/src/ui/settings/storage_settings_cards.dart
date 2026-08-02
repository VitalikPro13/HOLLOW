import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/selector_pill.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:hollow/src/ui/settings/storage_section.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

/// Files & Storage category of the desktop Settings dialog: usage dashboard,
/// cache limit sliders, media quality, and the on-disk data location.
class StorageSettingsView extends StatelessWidget {
  const StorageSettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    return settingsCardList(const [
      SettingsCard(
        title: 'Usage',
        children: [StorageBreakdownView()],
      ),
      SettingsCard(
        title: 'Cache Limits',
        children: [
          _AutoDownloadSlider(),
          SizedBox(height: HollowSpacing.lg),
          _FilesCacheCapSlider(),
          SizedBox(height: HollowSpacing.lg),
          _VaultCacheCapSlider(),
          SizedBox(height: HollowSpacing.lg),
          _AssetCacheCapSlider(),
        ],
      ),
      SettingsCard(
        title: 'Media',
        children: [_ImageQualitySelector()],
      ),
      SettingsCard(
        title: 'Data Location',
        children: [_DataLocationRow()],
      ),
    ]);
  }
}

/// Auto-download threshold slider. Applies immediately.
class _AutoDownloadSlider extends ConsumerWidget {
  const _AutoDownloadSlider();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final threshold =
        ref.watch(autoDownloadThresholdProvider).valueOrNull ?? 169;
    final off = threshold == 0;
    return SettingsLabeledSlider(
      icon: LucideIcons.download,
      title: 'Auto-Download Threshold',
      subtitle: off
          ? 'Off — files show a download button instead (voice messages still '
              'play automatically)'
          : 'Files up to $threshold MB auto-download',
      value: off ? 0 : threshold.toDouble().clamp(34, 2048),
      min: 0,
      max: 2048,
      divisions: 50,
      label: off ? 'Off' : '$threshold MB',
      minLabel: 'Off',
      maxLabel: '2 GB',
      // Anything dragged below the 34 MB floor snaps to Off (0) — the
      // 1–33 MB range has no meaning (34 MB is the direct-transfer cap).
      onChanged: (value) => ref
          .read(autoDownloadThresholdProvider.notifier)
          .setThreshold(value.round() < 34 ? 0 : value.round()),
    );
  }
}

/// Downloaded-files cache cap slider. Applies immediately; enforced after
/// each download completes + via "Evict now".
class _FilesCacheCapSlider extends ConsumerWidget {
  const _FilesCacheCapSlider();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cap = ref.watch(filesCacheCapProvider).valueOrNull ?? 5120;
    return SettingsLabeledSlider(
      icon: LucideIcons.download,
      title: 'Downloaded Files Limit',
      subtitle:
          '${(cap / 1024).toStringAsFixed(1)} GB — oldest downloaded files are evicted when this is exceeded (messages stay re-downloadable)',
      value: cap.toDouble().clamp(512, 51200),
      min: 512,
      max: 51200,
      divisions: 99,
      label: '${(cap / 1024).toStringAsFixed(1)} GB',
      minLabel: '512 MB',
      maxLabel: '50 GB',
      onChanged: (value) =>
          ref.read(filesCacheCapProvider.notifier).setCap(value.round()),
    );
  }
}

/// Vault cache size cap slider. Applies immediately.
class _VaultCacheCapSlider extends ConsumerWidget {
  const _VaultCacheCapSlider();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cap = ref.watch(vaultCacheCapProvider).valueOrNull ?? 1024;
    return SettingsLabeledSlider(
      icon: LucideIcons.hardDrive,
      title: 'Vault Cache Limit',
      subtitle:
          '${(cap / 1024).toStringAsFixed(1)} GB — cached vault video/file playback is evicted when this is exceeded',
      value: cap.toDouble().clamp(256, 10240),
      min: 256,
      max: 10240,
      divisions: 40,
      label: cap >= 1024 ? '${(cap / 1024).toStringAsFixed(1)} GB' : '$cap MB',
      minLabel: '256 MB',
      maxLabel: '10 GB',
      onChanged: (value) =>
          ref.read(vaultCacheCapProvider.notifier).setCap(value.round()),
    );
  }
}

/// Asset blob cache cap slider (emotes, stickers, GIFs). Applies immediately;
/// enforced whenever new asset bytes land. Assets still used by your personal
/// set or a server are never evicted.
class _AssetCacheCapSlider extends ConsumerWidget {
  const _AssetCacheCapSlider();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cap = ref.watch(assetCacheCapProvider).valueOrNull ?? 512;
    return SettingsLabeledSlider(
      icon: LucideIcons.smile,
      title: 'Emotes & GIFs Limit',
      subtitle:
          '$cap MB — least-recently added emotes, stickers and GIFs are evicted '
          'when this is exceeded (ones your servers or personal set use are kept). '
          'Separate from this: the GIF search cache is capped at 200 MB, with '
          'the oldest thumbnails evicted past that.',
      value: cap.toDouble().clamp(64, 4096),
      min: 64,
      max: 4096,
      divisions: 63,
      label: cap >= 1024 ? '${(cap / 1024).toStringAsFixed(1)} GB' : '$cap MB',
      minLabel: '64 MB',
      maxLabel: '4 GB',
      onChanged: (value) =>
          ref.read(assetCacheCapProvider.notifier).setCap(value.round()),
    );
  }
}

/// Image quality tier selector — a row of three pill chips matching the
/// screen share dialog's resolution/FPS selector style. Phase 6.75.
class _ImageQualitySelector extends ConsumerWidget {
  const _ImageQualitySelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final currentAsync = ref.watch(imageQualityProvider);
    final current = currentAsync.valueOrNull ?? ImageQuality.balanced;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Image Quality',
          style: HollowTypography.body.copyWith(
            color: hollow.textPrimary,
            fontWeight: FontWeight.w500,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: HollowSpacing.xs),
        Text(
          current.description,
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary,
            fontSize: 11,
          ),
        ),
        const SizedBox(height: HollowSpacing.sm),
        Row(
          children: ImageQuality.values
              .map((q) => SelectorPill(
                    label: q.label,
                    active: q == current,
                    animated: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: HollowSpacing.md,
                      vertical: HollowSpacing.xs + 2,
                    ),
                    onTap: () {
                      ref.read(imageQualityProvider.notifier).setQuality(q);
                    },
                  ))
              .toList(),
        ),
        const SizedBox(height: HollowSpacing.sm),
        Text(
          'Images and GIFs are converted to WebP to save bandwidth and storage. '
          'Receivers can still save them as PNG, JPG, etc.',
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary.withValues(alpha: 0.7),
            fontSize: 10,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

/// Data location row + open-folder button.
class _DataLocationRow extends StatelessWidget {
  const _DataLocationRow();

  /// The on-disk data directory shown in the FILES section. Mirrors the Rust
  /// core's `dirs::data_dir()/hollow` per platform, resolved to a real path via
  /// the home/APPDATA env var (falls back to the `~`/`%APPDATA%` template if the
  /// env var is missing). Desktop only — mobile uses a sandboxed app container.
  /// Portable mode overrides all of it with the hollow_data folder by the exe.
  static String _dataLocationPath() {
    if (isPortableMode) return hollowDataDir;
    final env = Platform.environment;
    if (Platform.isWindows) {
      final appData = env['APPDATA'];
      return appData != null ? '$appData\\hollow' : r'%APPDATA%\hollow';
    }
    final home = env['HOME'] ?? '~';
    if (Platform.isMacOS) {
      return '$home/Library/Application Support/hollow';
    }
    // Linux: XDG_DATA_HOME, default ~/.local/share.
    final xdg = env['XDG_DATA_HOME'];
    final base = (xdg != null && xdg.isNotEmpty) ? xdg : '$home/.local/share';
    return '$base/hollow';
  }

  /// Open the data directory in the OS file manager.
  Future<void> _openDataFolder(BuildContext context) async {
    final dir = _dataLocationPath();
    try {
      if (Platform.isWindows) {
        await Process.start('explorer.exe', [dir]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [dir]);
      } else {
        await launchUrl(Uri.file(dir));
      }
    } catch (_) {
      if (!context.mounted) return;
      HollowToast.show(context, 'Could not open folder',
          type: HollowToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(LucideIcons.folder, size: 16, color: hollow.textSecondary),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                _dataLocationPath(),
                style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary,
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(height: 2),
              Text(
                isPortableMode
                    ? 'Portable mode — identity key, encrypted database, and '
                        'downloaded files travel with the app folder.'
                    : 'Identity key, encrypted database, and downloaded files.',
                style: HollowTypography.caption
                    .copyWith(color: hollow.textSecondary, fontSize: 10),
              ),
            ],
          ),
        ),
        const SizedBox(width: HollowSpacing.sm),
        HollowButton.outline(
          onPressed: () => _openDataFolder(context),
          icon: const Icon(LucideIcons.externalLink, size: 14),
          compact: true,
          child: const Text('Open'),
        ),
      ],
    );
  }
}
