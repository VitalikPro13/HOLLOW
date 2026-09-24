import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/profile_registry.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:url_launcher/url_launcher.dart';

/// The rows of Settings > Files & Storage below its usage summary.

/// A megabyte count as the sliders read it out.
String _mbLabel(int mb) =>
    mb >= 1024 ? '${(mb / 1024).toStringAsFixed(1)} GB' : '$mb MB';

/// Every cap and threshold here saves as it moves; a failed write says so.
void _save(BuildContext context, Future<void> write) {
  write.catchError((_) {
    if (context.mounted) {
      HollowToast.show(context, 'Could not save that setting',
          type: HollowToastType.error);
    }
  });
}

class StorageDownloadsSection extends StatelessWidget {
  const StorageDownloadsSection({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingsSection(
      title: 'Downloads',
      children: [
        _AutoDownloadSlider(),
        _FilesCacheCapSlider(),
        _ImageQualityRow(),
      ],
    );
  }
}

class _AutoDownloadSlider extends ConsumerWidget {
  const _AutoDownloadSlider();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final threshold =
        ref.watch(autoDownloadThresholdProvider).valueOrNull ?? 169;
    final off = threshold == 0;
    return SettingsSliderRow(
      title: 'Download automatically',
      subtitle: 'Bigger files wait for a click. Voice messages always play.',
      value: off ? 0 : threshold.toDouble().clamp(34, 2048),
      min: 0,
      max: 2048,
      divisions: 50,
      valueLabel: off ? 'Off' : _mbLabel(threshold),
      // Below the 34 MB direct-transfer cap the range has no meaning, so
      // anything dragged there snaps to Off.
      onChanged: (value) => _save(
          context,
          ref
              .read(autoDownloadThresholdProvider.notifier)
              .setThreshold(value.round() < 34 ? 0 : value.round())),
    );
  }
}

/// Enforced after each download completes.
class _FilesCacheCapSlider extends ConsumerWidget {
  const _FilesCacheCapSlider();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cap = ref.watch(filesCacheCapProvider).valueOrNull ?? 5120;
    return SettingsSliderRow(
      title: 'Keep downloads up to',
      subtitle: 'The oldest go first. They stay downloadable from the chat.',
      value: cap.toDouble().clamp(512, 51200),
      min: 512,
      max: 51200,
      divisions: 99,
      valueLabel: _mbLabel(cap),
      onChanged: (value) => _save(context,
          ref.read(filesCacheCapProvider.notifier).setCap(value.round())),
    );
  }
}

class _ImageQualityRow extends ConsumerWidget {
  const _ImageQualityRow();

  static String _label(ImageQuality q) => switch (q) {
        ImageQuality.lossless => 'Lossless',
        ImageQuality.balanced => 'Balanced',
        ImageQuality.small => 'Small',
      };

  static String _description(ImageQuality q) => switch (q) {
        ImageQuality.lossless =>
          'Pixel-perfect (100%), for art, diagrams and screenshots.',
        ImageQuality.balanced => 'At 50%, looks the same and is about 95% '
            'smaller.',
        ImageQuality.small => 'At 30%, strong compression for slow '
            'connections.',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current =
        ref.watch(imageQualityProvider).valueOrNull ?? ImageQuality.balanced;
    return SettingsChoiceRow<ImageQuality>(
      title: 'Image quality',
      subtitle: '${_description(current)} Sent as WebP; people can still '
          'save them as PNG or JPG.',
      value: current,
      options: [for (final q in ImageQuality.values) (q, _label(q))],
      onChanged: (q) =>
          _save(context, ref.read(imageQualityProvider.notifier).setQuality(q)),
    );
  }
}

/// Where this profile's identity, database and files live. Desktop only.
class DataFolderRow extends StatelessWidget {
  const DataFolderRow({super.key});

  /// Portable mode and a pinned profile resolve their own root; otherwise it
  /// mirrors the Rust core's `dirs::data_dir()/hollow`.
  static String _dataLocationPath() {
    if (isPortableMode || isPinnedProfile) return hollowDataDir;
    return defaultDesktopDataRoot();
  }

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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SettingsRow(
          title: 'Data folder',
          subtitleWidget: SelectableText(
            _dataLocationPath(),
            style:
                HollowTypography.monoSmall.copyWith(color: hollow.textSecondary),
          ),
          trailing: HollowButton.ghost(
            compact: true,
            onPressed: () => _openDataFolder(context),
            child: const Text('Open'),
          ),
        ),
        if (isPortableMode)
          const SettingsNote(
              'Portable mode keeps your identity and files with the app '
              'folder.'),
      ],
    );
  }
}

/// Caches few people tune: vault playback and the emote and GIF images.
class StorageAdvancedSettings extends ConsumerWidget {
  const StorageAdvancedSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vaultAsync = ref.watch(vaultCacheCapProvider);
    final assetsAsync = ref.watch(assetCacheCapProvider);
    final vault = vaultAsync.valueOrNull ?? 1024;
    final assets = assetsAsync.valueOrNull ?? 512;
    return SettingsAdvanced(
      // Decided again once both caps have loaded, so a changed one opens it.
      key: ValueKey(vaultAsync.hasValue && assetsAsync.hasValue),
      initiallyOpen: vault != 1024 || assets != 512,
      children: [
        SettingsSliderRow(
          title: 'Vault cache',
          subtitle: 'Played vault videos and files, oldest cleared first',
          value: vault.toDouble().clamp(256, 10240),
          min: 256,
          max: 10240,
          divisions: 40,
          valueLabel: _mbLabel(vault),
          onChanged: (value) => _save(context,
              ref.read(vaultCacheCapProvider.notifier).setCap(value.round())),
        ),
        SettingsSliderRow(
          title: 'Emotes and GIFs',
          subtitle: 'The ones your servers use are always kept',
          value: assets.toDouble().clamp(64, 4096),
          min: 64,
          max: 4096,
          divisions: 63,
          valueLabel: _mbLabel(assets),
          onChanged: (value) => _save(context,
              ref.read(assetCacheCapProvider.notifier).setCap(value.round())),
        ),
      ],
    );
  }
}
