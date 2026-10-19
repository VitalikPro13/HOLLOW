import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/profile_registry.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/time_labels.dart';
import 'package:hollow/src/rust/api/recovery.dart' as recovery_api;
import 'package:hollow/src/rust/api/updater.dart' as updater_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';

/// Shown in place of the shell when the identity loaded but its data would not
/// open. What it offers depends on why ([recovery_api.storeTrouble]): repair or
/// link again only for a database that does not open with this identity.
class DataTroubleScreen extends ConsumerStatefulWidget {
  /// The error the identity load ended with.
  final String error;

  /// Called once a repair put a database in place that opens, with the relay
  /// the person picked (the old choice lived in the database).
  final Future<void> Function(String relay) onRepaired;

  /// Phone copy; the platform decides when null.
  final bool? phone;

  const DataTroubleScreen({
    super.key,
    required this.error,
    required this.onRepaired,
    this.phone,
  });

  @override
  ConsumerState<DataTroubleScreen> createState() => _DataTroubleScreenState();
}

class _DataTroubleScreenState extends ConsumerState<DataTroubleScreen> {
  recovery_api.StoreTrouble? _trouble;

  bool get _phone => widget.phone ?? (Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    _classify();
  }

  Future<void> _classify() async {
    recovery_api.StoreTrouble trouble;
    try {
      trouble = await recovery_api.storeTrouble();
    } catch (_) {
      trouble = recovery_api.StoreTrouble.other;
    }
    if (mounted) setState(() => _trouble = trouble);
  }

  Future<void> _repair() async {
    final relay = await showHollowDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const RepairDialog(),
    );
    if (relay == null || !mounted) return;
    await widget.onRepaired(relay);
  }

  Future<void> _relink() async {
    await showHollowDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RelinkDialog(
          phone: _phone, listed: !_phone && listsKeptProfilesHere()),
    );
  }

  void _diagnostics() {
    showDiagnosticsDialog(
      context,
      starting: _trouble == recovery_api.StoreTrouble.notReady,
      trouble: _trouble?.name ?? 'unknown',
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final trouble = _trouble;
    // Nothing until the probe answers, which is quick: a flash of the wrong
    // choices would be worse than a blank moment.
    final body = switch (trouble) {
      null => const SizedBox.shrink(),
      recovery_api.StoreTrouble.unreadable => _unreadable(hollow),
      recovery_api.StoreTrouble.held => _plain(
          hollow,
          title: "Hollow can't open your data right now",
          text: 'Another program, such as a backup or antivirus tool, is '
              "using Hollow's files. Close it, then restart Hollow.",
        ),
      _ => _plain(
          hollow,
          title: "Hollow couldn't open your identity",
          text: friendlyError(widget.error),
        ),
    };
    // The phone shell gives no text style this high up.
    return ColoredBox(
      color: hollow.background,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(HollowSpacing.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: DefaultTextStyle(
                style:
                    HollowTypography.body.copyWith(color: hollow.textPrimary),
                child: body,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _title(HollowTheme hollow, String text) => Text(
        text,
        style: HollowTypography.heading.copyWith(color: hollow.textPrimary),
      );

  Widget _prose(HollowTheme hollow, String text, {bool small = false}) => Text(
        text,
        style: (small ? HollowTypography.bodySmall : HollowTypography.body)
            .copyWith(color: hollow.textSecondary),
      );

  Widget _diagnosticsButton() => HollowButton.ghost(
        touch: _phone,
        onPressed: _diagnostics,
        child: const Text('Copy diagnostics'),
      );

  Widget _plain(HollowTheme hollow,
      {required String title, required String text}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _title(hollow, title),
        const SizedBox(height: HollowSpacing.md),
        _prose(hollow, text),
        const SizedBox(height: HollowSpacing.xl),
        Wrap(
          spacing: HollowSpacing.sm,
          runSpacing: HollowSpacing.sm,
          children: [
            HollowButton.filled(
              touch: _phone,
              onPressed: relaunchApp,
              child: const Text('Restart Hollow'),
            ),
            _diagnosticsButton(),
          ],
        ),
      ],
    );
  }

  Widget _unreadable(HollowTheme hollow) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title(hollow, "Hollow can't open your data on this device"),
        const SizedBox(height: HollowSpacing.md),
        _prose(
          hollow,
          'Your identity is fine. The file that holds your messages, friends '
          "and servers won't open with it.",
        ),
        const SizedBox(height: HollowSpacing.xl),
        HollowButton.filled(
          expand: true,
          touch: _phone,
          onPressed: _repair,
          child: const Text('Repair this device'),
        ),
        const SizedBox(height: HollowSpacing.sm),
        _prose(
          hollow,
          'Sets that file aside and starts a new one. Your other devices and '
          "the servers you're in send your data back, so keep one of your "
          'devices open.',
          small: true,
        ),
        const SizedBox(height: HollowSpacing.xs),
        _prose(
          hollow,
          'If this is your only device, a repair keeps your identity but '
          'nothing else. Friends can add you again.',
          small: true,
        ),
        const SizedBox(height: HollowSpacing.lg),
        HollowButton.outline(
          expand: true,
          touch: _phone,
          onPressed: _relink,
          child: const Text('Link this device again'),
        ),
        const SizedBox(height: HollowSpacing.sm),
        _prose(
          hollow,
          _phone
              ? 'Moves everything on this phone aside and starts fresh, so you '
                  'can link it with a code from your other device.'
              : 'Moves everything on this device into a separate profile and '
                  'starts fresh, so you can link it with a code from your '
                  'other device.',
          small: true,
        ),
        const SizedBox(height: HollowSpacing.xl),
        Align(alignment: Alignment.centerLeft, child: _diagnosticsButton()),
      ],
    );
  }
}

/// Repair this device: say where the file goes, let a self-hoster name the relay
/// (the old choice lived in the database), then run the repair inside the dialog.
/// Pops the relay to use once a database that opens is in place.
class RepairDialog extends ConsumerStatefulWidget {
  const RepairDialog({super.key});

  @override
  ConsumerState<RepairDialog> createState() => _RepairDialogState();
}

class _RepairDialogState extends ConsumerState<RepairDialog>
    with HollowDialogAction {
  final _relayController = TextEditingController();
  bool _editRelay = false;
  String? _relayError;

  @override
  void dispose() {
    _relayController.dispose();
    super.dispose();
  }

  String get _relay {
    final text = _relayController.text.trim();
    if (!_editRelay || text.isEmpty) return kDefaultRelayDomain;
    return normalizeRelayHost(text) ?? '';
  }

  Future<void> _confirm() async {
    final relay = _relay;
    if (relay.isEmpty) {
      setState(() =>
          _relayError = 'Enter a relay address, such as myrelay.duckdns.org.');
      return;
    }
    final ok = await runDialogAction(recovery_api.repairThisDevice);
    if (ok && mounted) Navigator.of(context).pop(relay);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final folder = 'unreadable-${_isoDay(DateTime.now().toUtc())}';
    return HollowDialog(
      title: 'Repair this device?',
      width: 440,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HollowDialogText(
              "The file that won't open moves to the $folder folder beside "
              'your other Hollow files. Nothing is deleted.'),
          const SizedBox(height: HollowSpacing.md),
          const HollowDialogText(
              "Friends may see a notice that this device's keys changed. "
              "That's expected after a repair."),
          const SizedBox(height: HollowSpacing.lg),
          Row(
            children: [
              Text('Relay',
                  style: HollowTypography.label
                      .copyWith(color: hollow.textPrimary)),
              const SizedBox(width: HollowSpacing.md),
              Expanded(
                child: Text(
                  _editRelay ? '' : kDefaultRelayDomain,
                  overflow: TextOverflow.ellipsis,
                  style: HollowTypography.mono
                      .copyWith(color: hollow.textSecondary),
                ),
              ),
              if (!_editRelay)
                HollowButton.ghost(
                  compact: true,
                  onPressed: actionRunning
                      ? null
                      : () => setState(() {
                            _editRelay = true;
                            _relayController.text = kDefaultRelayDomain;
                          }),
                  child: const Text('Change'),
                ),
            ],
          ),
          if (_editRelay) ...[
            const SizedBox(height: HollowSpacing.sm),
            HollowTextField(
              controller: _relayController,
              autofocus: true,
              hintText: kDefaultRelayDomain,
              errorText: _relayError,
              onChanged: (_) {
                if (_relayError != null) setState(() => _relayError = null);
              },
            ),
          ],
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: actionRunning ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _confirm,
          loading: actionRunning,
          child: const Text('Repair'),
        ),
      ],
    );
  }
}

String _isoDay(DateTime utc) =>
    '${utc.year.toString().padLeft(4, '0')}-'
    '${utc.month.toString().padLeft(2, '0')}-'
    '${utc.day.toString().padLeft(2, '0')}';

/// Link this device again: the whole data set moves aside, a desktop lists it
/// as a profile, and Hollow restarts (a phone closes) into Welcome.
class RelinkDialog extends StatefulWidget {
  final bool phone;

  /// The old data becomes a listed profile; else Welcome names its folder.
  final bool listed;

  const RelinkDialog({super.key, required this.phone, this.listed = true});

  @override
  State<RelinkDialog> createState() => _RelinkDialogState();
}

class _RelinkDialogState extends State<RelinkDialog> with HollowDialogAction {
  // The kept folder is named by the UTC day; so is the profile.
  final _today = DateTime.now().toUtc();

  Future<void> _confirm() async {
    final ok = await runDialogAction(() async {
      final kept = await recovery_api.relinkThisDevice();
      if (widget.listed) {
        await keepOldDataProfile(kept, keptDayOf(kept) ?? _today);
      }
    });
    // A phone has no self-restart: it closes and the person opens it again.
    if (ok && mounted) await relaunchApp();
  }

  @override
  Widget build(BuildContext context) {
    final name = keptProfileName(_today);
    return HollowDialog(
      title: 'Link this device again?',
      width: 440,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HollowDialogText(widget.phone
              ? 'Everything on this phone moves into a folder Hollow keeps but '
                  "can't open. Erasing this device later erases it too."
              : widget.listed
                  ? 'Everything on this device moves into a profile named '
                      '$name. You can switch to it in Settings > Profile, and '
                      'erasing this device later erases it too.'
                  : 'Everything on this device moves into a new folder next '
                      "to Hollow's data folder. Erasing this device later "
                      'erases it too.'),
          const SizedBox(height: HollowSpacing.md),
          HollowDialogText(widget.phone
              ? 'Hollow then closes. Open it again to link this phone with a '
                  'code from your other device.'
              : 'Hollow then restarts so you can link this device with a code '
                  'from your other device.'),
          const SizedBox(height: HollowSpacing.md),
          const HollowDialogText(
              "Once it's linked, your device list shows this device twice. "
              'Remove the older entry.'),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed:
              actionRunning ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _confirm,
          loading: actionRunning,
          child: const Text('Link again'),
        ),
      ],
    );
  }
}

/// The name a relinked profile's old data is listed under.
String keptProfileName(DateTime day) => 'Old data from ${dateWithYearLabel(day)}';

/// Whether a relink's old data becomes a listed profile. The list belongs to
/// the computer's own install: a portable copy or a `HOLLOW_DATA_DIR` session
/// never writes it (on a pure stick it would not exist at all), and a phone has
/// none. A pin onto the portable folder lives in that list already.
bool listsKeptProfiles({
  required bool phone,
  required bool portable,
  required bool pinned,
  required bool envOverride,
}) =>
    !phone && !envOverride && (!portable || pinned);

bool listsKeptProfilesHere() => listsKeptProfiles(
      phone: Platform.isAndroid || Platform.isIOS,
      portable: isPortableMode,
      pinned: isPinnedProfile,
      envOverride: dataDirEnvOverrideActive,
    );

/// Lists the folder a relink kept as its own profile, once.
Future<void> keepOldDataProfile(String path, DateTime day) async {
  if (!listsKeptProfilesHere()) return;
  final registry = readProfileRegistrySync();
  await saveProfileRegistryIfChanged(
      registry, registryWithKeptProfile(registry, path, keptProfileName(day)));
}

/// The day in a kept folder's name (`<root>-old-YYYY-MM-DD[-n]`).
DateTime? keptDayOf(String path) {
  final m = RegExp(r'-old-(\d{4})-(\d{2})-(\d{2})(-\d+)?$')
      .firstMatch(path.replaceAll(r'\', '/'));
  if (m == null) return null;
  return DateTime.utc(
      int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
}

/// What Welcome says after a relink: the old data's profile name on a
/// desktop that lists it (listed again if a restart cut the listing short),
/// its folder where nothing lists it, an empty name on a phone, null when
/// there was no relink.
Future<({String? profile, String? folder})?> keptOldDataForWelcome() async {
  String? path;
  try {
    path = await recovery_api.relinkWelcome();
  } catch (_) {}
  if (path == null) return null;
  if (Platform.isAndroid || Platform.isIOS) return (profile: '', folder: null);
  if (!listsKeptProfilesHere()) return (profile: null, folder: path);
  for (final p in readProfileRegistrySync().custom) {
    if (sameProfilePath(p.path, path)) return (profile: p.name, folder: null);
  }
  final day = keptDayOf(path) ?? DateTime.now().toUtc();
  await keepOldDataProfile(path, day);
  return (profile: keptProfileName(day), folder: null);
}

/// What the diagnostics hold above the file list: version, platform and why
/// the screen is up. Never an id: the Rust half aliases every id it finds.
@visibleForTesting
String diagnosticsHeader({
  required String version,
  required String platform,
  required String trouble,
  required bool portable,
  required bool pinned,
}) =>
    'Hollow $version\n'
    'Platform $platform\n'
    'Trouble $trouble\n'
    'Portable $portable, pinned profile $pinned\n';

/// Shows what Copy diagnostics puts on the clipboard, and copies it on Copy.
/// [starting]: a start-up step is unfinished, so only the header goes (a held
/// wipe and a held landing must read the same).
Future<void> showDiagnosticsDialog(BuildContext context,
    {required bool starting, required String trouble}) async {
  String version;
  try {
    version = updater_api.getCurrentVersion();
  } catch (_) {
    version = 'unknown';
  }
  try {
    final build = updater_api.getCurrentBuild();
    if (build > 0) version = '$version+$build';
  } catch (_) {}
  var body = '';
  try {
    body = await recovery_api.diagnosticsReport(starting: starting);
  } catch (_) {}
  final text = diagnosticsHeader(
        version: version,
        platform: '${Platform.operatingSystem} '
            '${Platform.operatingSystemVersion}',
        trouble: trouble,
        portable: isPortableMode,
        pinned: isPinnedProfile,
      ) +
      (body.isEmpty ? '' : '\n$body');
  if (!context.mounted) return;
  await showHollowDialog<void>(
    context: context,
    builder: (_) => DiagnosticsDialog(text: text),
  );
}

class DiagnosticsDialog extends StatelessWidget {
  final String text;

  const DiagnosticsDialog({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowDialog(
      title: 'Diagnostics',
      width: 560,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const HollowDialogText(
              'Hollow copies the app version, the names and sizes of its files '
              'and the end of its log. Messages, keys and IDs are left out. '
              'Read it before you share it.'),
          const SizedBox(height: HollowSpacing.md),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: hollow.elevated,
                borderRadius: BorderRadius.circular(hollow.radiusMd),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(HollowSpacing.md),
                child: SelectableText(
                  text,
                  style: HollowTypography.monoSmall
                      .copyWith(color: hollow.textPrimary),
                ),
              ),
            ),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        HollowButton.filled(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (!context.mounted) return;
            HollowToast.show(context, 'Diagnostics copied',
                type: HollowToastType.success);
          },
          child: const Text('Copy'),
        ),
      ],
    );
  }
}
