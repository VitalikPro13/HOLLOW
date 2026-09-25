import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/providers/updater_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_mark.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/version_egg_tap_target.dart';
import 'package:hollow/src/ui/settings/about_shared.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/updates_section.dart';

/// Settings > About: which Hollow this is, its updates, how to reach us, and
/// the legal documents. The header stands in for the page title.
class AboutTab extends ConsumerWidget {
  const AboutTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    // Rust's APP_VERSION is the one source, shared with mobile About.
    final appVersion = ref.watch(updaterProvider).currentVersion;
    final secondary =
        HollowTypography.bodySmall.copyWith(color: hollow.textSecondary);

    return SettingsPage(
      children: [
        Row(
          children: [
            Container(
              width: 56,
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: hollow.elevated,
                borderRadius: BorderRadius.circular(hollow.radiusLg),
              ),
              child: HollowMark(size: 28, color: hollow.accentText),
            ),
            const SizedBox(width: HollowSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Hollow',
                    style: HollowTypography.heading
                        .copyWith(color: hollow.textPrimary),
                  ),
                  // Seven taps here wake the Hollow Shop; shared with mobile.
                  VersionEggTapTarget(
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(
                          text:
                              'v${appVersion.isNotEmpty ? appVersion : 'unknown'}',
                          style: HollowTypography.monoSmall
                              .copyWith(color: hollow.textSecondary),
                        ),
                        const TextSpan(text: ' · beta · by AnonListen'),
                      ]),
                      style: secondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const UpdatesTab(),
        SettingsSection(
          title: 'Contact',
          children: [
            SettingsRow(
              title: 'Feedback',
              subtitleWidget: Text(
                kSupportEmail,
                style: HollowTypography.monoSmall
                    .copyWith(color: hollow.textSecondary),
              ),
              trailing: HollowButton.ghost(
                compact: true,
                onPressed: () => copySupportEmail(context),
                semanticLabel: 'Copy the feedback email',
                child: const Text('Copy'),
              ),
            ),
            const SettingsRow(
              title: 'Website',
              subtitle: 'hollow.anonlisten.com',
              trailing: HollowButton.ghost(
                compact: true,
                onPressed: openHollowSite,
                semanticLabel: 'Open hollow.anonlisten.com',
                child: Text('Open'),
              ),
            ),
            SettingsRow(
              title: 'Follow and support',
              subtitle: 'YouTube, X, Twitch, Kick, Patreon, Ko-fi',
              wideTrailing: true,
              trailing: Wrap(
                spacing: HollowSpacing.xs,
                runSpacing: HollowSpacing.xs,
                children: [
                  for (final (icon, name, url) in _socials)
                    HollowIconButton(
                      icon: icon,
                      label: name,
                      onPressed: () => launchBrandUrl(url),
                    ),
                ],
              ),
            ),
          ],
        ),
        SettingsSection(
          title: 'Legal',
          children: [
            SettingsRow(
              title: 'Privacy policy, terms and licenses',
              wideTrailing: true,
              trailing: Wrap(
                spacing: HollowSpacing.sm,
                runSpacing: HollowSpacing.sm,
                children: [
                  HollowButton.ghost(
                    compact: true,
                    semanticLabel: 'Read the privacy policy',
                    onPressed: () => _showLegalDocument(
                      context,
                      title: 'Privacy Policy',
                      assetPath: 'legal/PRIVACY_POLICY.md',
                    ),
                    child: const Text('Privacy'),
                  ),
                  HollowButton.ghost(
                    compact: true,
                    semanticLabel: 'Read the terms of use',
                    onPressed: () => _showLegalDocument(
                      context,
                      title: 'Terms of Use',
                      assetPath: 'legal/TERMS_OF_USE.md',
                    ),
                    child: const Text('Terms'),
                  ),
                  HollowButton.ghost(
                    compact: true,
                    semanticLabel: 'Open-source licenses',
                    onPressed: () => showHollowLicensesPage(context),
                    child: const Text('Licenses'),
                  ),
                ],
              ),
            ),
          ],
        ),
        // iOS has no adb, so this file is the only way to pull logs off a
        // test phone without a Mac.
        if (Platform.isIOS)
          const SettingsSection(
            title: 'Diagnostics',
            children: [_ExportDiagnosticsRow()],
          ),
      ],
    );
  }
}

class _ExportDiagnosticsRow extends StatefulWidget {
  const _ExportDiagnosticsRow();

  @override
  State<_ExportDiagnosticsRow> createState() => _ExportDiagnosticsRowState();
}

class _ExportDiagnosticsRowState extends State<_ExportDiagnosticsRow> {
  bool _busy = false;

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final bytes = Uint8List.fromList(utf8.encode(_collectDiagnostics()));
      final saved = await FilePicker.platform.saveFile(
        dialogTitle: 'Export debug logs',
        fileName: 'hollow_diagnostics.txt',
        bytes: bytes, // required on iOS and Android
      );
      if (!mounted) return;
      HollowToast.show(
        context,
        saved == null ? 'Export cancelled' : 'Diagnostics exported',
        type: saved == null ? HollowToastType.info : HollowToastType.success,
      );
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(context, friendlyError(e,
              fallback: "Couldn't export the logs. Try again."),
          type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsRow(
      title: 'Debug logs',
      subtitle: 'Push diagnostics and the recent log, in one file',
      trailing: HollowButton.outline(
        compact: true,
        loading: _busy,
        onPressed: _export,
        child: const Text('Export'),
      ),
    );
  }
}

/// The push diagnostics and the tails of the debug and crash logs, as text.
String _collectDiagnostics() {
  final buf = StringBuffer();
  buf.writeln('=== Hollow Diagnostics ===');
  buf.writeln('Exported: ${DateTime.now().toIso8601String()}');
  buf.writeln('Data dir: $hollowDataDir');
  buf.writeln();
  // The App Group container is the parent of the (migrated) data dir.
  final container = Directory(hollowDataDir).parent.path;
  void appendFile(String label, String path, {int tailBytes = 0}) {
    buf.writeln('----- $label ($path) -----');
    try {
      final f = File(path);
      if (f.existsSync()) {
        if (tailBytes > 0 && f.lengthSync() > tailBytes) {
          final raf = f.openSync();
          try {
            raf.setPositionSync(f.lengthSync() - tailBytes);
            buf.writeln('(tail, last $tailBytes bytes)');
            buf.writeln(
                utf8.decode(raf.readSync(tailBytes), allowMalformed: true));
          } finally {
            raf.closeSync();
          }
        } else {
          buf.writeln(f.readAsStringSync());
        }
      } else {
        buf.writeln('(not found)');
      }
    } catch (e) {
      buf.writeln('(read error: $e)');
    }
    buf.writeln();
  }

  appendFile('NSE metrics', '$container/push_diag/nse_metrics.log');
  appendFile('App active heartbeat', '$container/push_diag/app_active.txt');
  appendFile('Dart push log', '$hollowDataDir/push_debug.log');
  appendFile('Hollow debug log', '$hollowDataDir/hollow_debug.log',
      tailBytes: 2 * 1024 * 1024);
  appendFile('Hollow crash log', '$hollowDataDir/hollow_crash.log',
      tailBytes: 512 * 1024);
  return buf.toString();
}

/// Where AnonListen posts and takes support, in the order the row names them.
const _socials = <(IconData, String, String)>[
  (BrandIcons.youtube, 'YouTube', 'https://youtube.com/@Anon_Listen'),
  (BrandIcons.x, 'X', 'https://x.com/Anon_Listen'),
  (BrandIcons.twitch, 'Twitch', 'https://twitch.tv/AnonListen'),
  (BrandIcons.kick, 'Kick', 'https://kick.com/AnonListen'),
  (BrandIcons.patreon, 'Patreon', 'https://patreon.com/AnonListen'),
  (BrandIcons.kofi, 'Ko-fi', 'https://ko-fi.com/AnonListen'),
];

void _showLegalDocument(
  BuildContext context, {
  required String title,
  required String assetPath,
}) async {
  final hollow = HollowTheme.of(context);
  final body = await loadLegalMarkdownBody(assetPath);

  if (!context.mounted) return;

  if (SettingsDensity.touchOf(context)) {
    _showLegalSheet(context, hollow, title, body);
    return;
  }

  showHollowDialog(
    context: context,
    // A fixed reading size; the surface clamps it to the zoomed viewport and
    // the Column fills the capped height so the document scrolls inside it.
    builder: (ctx) => HollowDialogSurface(
      width: 560,
      maxHeight: 520,
      padded: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(HollowSpacing.xl,
                HollowSpacing.lg, HollowSpacing.md, HollowSpacing.md),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: HollowTypography.heading
                        .copyWith(color: hollow.textPrimary),
                  ),
                ),
                const SizedBox(width: HollowSpacing.sm),
                const HollowDialogCloseButton(),
              ],
            ),
          ),
          const HollowDivider(),
          Expanded(
            child: legalMarkdownView(
              hollow,
              body,
              padding: const EdgeInsets.all(HollowSpacing.xl),
            ),
          ),
        ],
      ),
    ),
  );
}

/// A phone reads the document in a tall sheet it can drag away.
void _showLegalSheet(
    BuildContext context, HollowTheme hollow, String title, String body) {
  showHollowSheet(
    context: context,
    scrollControlled: true,
    handle: false,
    builder: (_) => DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Column(
        children: [
          const HollowSheetHandle(),
          Padding(
            padding: const EdgeInsets.all(HollowSpacing.md),
            child: Text(
              title,
              style:
                  HollowTypography.subheading.copyWith(color: hollow.textPrimary),
            ),
          ),
          const HollowDivider(),
          Expanded(
            child: legalMarkdownView(
              hollow,
              body,
              controller: scrollController,
              padding: const EdgeInsets.all(HollowSpacing.lg),
            ),
          ),
        ],
      ),
    ),
  );
}
