import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/roster.dart' as roster_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/archive/shared/archive_file_actions.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:hollow/src/ui/shell/roster_lock.dart';
import 'package:hollow/src/core/peer_id_label.dart';

/// Multi-device management shared by the desktop Devices category and the
/// mobile Settings tab. The two surfaces differ only in text styling and row
/// action buttons, which are passed in.

/// Whether a device is worth showing by default: online, ourselves, or
/// labelled. Ghosts from past re-link cycles are offline and unlabelled, and
/// fold behind "Show all".
bool deviceIsActive(MyDevice d) =>
    d.online || d.isThisDevice || d.label.isNotEmpty;

/// The device's label, else "Desktop" or "Phone", else its shortened peer id.
String deviceTitle(MyDevice d) => d.label.isNotEmpty
    ? d.label
    : deviceKindName(d.kind) ?? shortPeerLabel(d.peerId);

/// Re-pulls the device list from the running node. Call on open: the startup
/// warm-up races node readiness and nothing keeps the list fresh while
/// Settings is closed, so it renders stale after a restart.
void refreshMyDevices(WidgetRef ref) {
  ref.read(deviceLinkProvider.notifier).refresh();
  ref.read(deviceLabelProvider.notifier).refresh();
  ref.invalidate(localDevicePeerIdProvider);
}

/// Label edit dialog, persisted through [deviceLabelProvider].
Future<void> renameDeviceFlow(
    BuildContext context, WidgetRef ref, MyDevice device) async {
  final notifier = ref.read(deviceLabelProvider.notifier);
  final name = await promptForName(
    context: context,
    title: 'Rename device',
    confirmLabel: 'Rename',
    hintText: 'Device name',
    initial: device.label,
    maxLength: 32,
    onSubmit: (name) => notifier.setLabel(device.peerId, name),
  );
  if (name == null || !context.mounted) return;
  HollowToast.show(context, 'Device renamed', type: HollowToastType.success);
}

/// Pulls servers and friends FROM an online sibling onto this device, after a
/// confirm. An offline device is refused before anything is asked.
Future<void> syncFromDeviceFlow(
    BuildContext context, WidgetRef ref, MyDevice device) async {
  final name = deviceTitle(device);
  if (!device.online) {
    HollowToast.show(context, '"$name" is offline. Bring it online first.',
        type: HollowToastType.error);
    return;
  }
  final confirmed = await showHollowConfirm(
    context: context,
    title: 'Sync from "$name"?',
    message: 'Copies any servers and friends "$name" has that this device is '
        'missing. Nothing is removed, and your messages stay as they are.',
    confirmLabel: 'Sync now',
    onConfirm: () => network_api.requestStateSync(sourceDeviceId: device.peerId),
  );
  if (!confirmed || !context.mounted) return;
  HollowToast.show(context, 'Syncing from "$name". New servers and friends '
      'appear as they arrive.',
      type: HollowToastType.info);
}

String _removalMessage(String name) =>
    '"$name" stops getting your messages at once and is taken off your '
    'servers. It locks, and erases itself in three days unless your recovery '
    'phrase is typed on it.';

/// An answer to "When did you last have it?".
enum LastHadAnswer {
  lessThanAnHour('Less than an hour ago'),
  earlierToday('Earlier today'),
  yesterday('Yesterday'),
  last7Days('In the last 7 days'),
  last30Days('In the last 30 days'),
  picked('Pick a date and time'),
  notSure('Longer ago, or not sure');

  final String label;
  const LastHadAnswer(this.label);
}

/// The moment lost or stolen judges from: the EARLIEST moment of the answer, so
/// a vague answer undoes more, never less (DEVICE_PROOF_DESIGN 8.1). "Not
/// sure" is 0 until restore points exist.
@visibleForTesting
int lostSinceMs(LastHadAnswer answer, {required DateTime now, DateTime? picked}) {
  final midnight = DateTime(now.year, now.month, now.day);
  final DateTime at = switch (answer) {
    LastHadAnswer.lessThanAnHour => now.subtract(const Duration(hours: 1)),
    LastHadAnswer.earlierToday => midnight,
    LastHadAnswer.yesterday => DateTime(now.year, now.month, now.day - 1),
    LastHadAnswer.last7Days => now.subtract(const Duration(days: 7)),
    LastHadAnswer.last30Days => now.subtract(const Duration(days: 30)),
    LastHadAnswer.picked => picked!.isAfter(now) ? now : picked,
    LastHadAnswer.notSure => DateTime.fromMillisecondsSinceEpoch(0),
  };
  return at.millisecondsSinceEpoch;
}

/// The moment [answer] means, asking for a date and time when it is
/// [LastHadAnswer.picked]; null when that ask was cancelled.
Future<int?> askLostSince(BuildContext context, LastHadAnswer answer) async {
  final now = DateTime.now();
  if (answer != LastHadAnswer.picked) return lostSinceMs(answer, now: now);
  final day =
      await pickArchiveDate(context, first: DateTime(now.year - 5), last: now);
  if (day == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(now),
  );
  if (time == null) return null;
  final picked = DateTime(day.year, day.month, day.day, time.hour, time.minute);
  return lostSinceMs(answer, now: now, picked: picked);
}

/// The answers to "When did you last have it?" as one chip row. The picked
/// moment shows beside "Pick a date and time".
class LastHadPicker extends StatelessWidget {
  final LastHadAnswer? answer;
  final int? sinceMs;
  final bool enabled;
  final void Function(LastHadAnswer answer, int sinceMs) onAnswer;

  const LastHadPicker({
    super.key,
    required this.answer,
    required this.sinceMs,
    required this.onAnswer,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final since = sinceMs;
    return Wrap(
      spacing: HollowSpacing.sm,
      runSpacing: HollowSpacing.sm,
      children: [
        for (final a in LastHadAnswer.values)
          Semantics(
            selected: a == answer,
            inMutuallyExclusiveGroup: true,
            child: HollowChip(
              key: ValueKey('last-had-${a.name}'),
              label: a.label,
              hint: a == LastHadAnswer.picked && a == answer && since != null
                  ? rosterDateLabel(
                      context, DateTime.fromMillisecondsSinceEpoch(since))
                  : null,
              selected: a == answer,
              onTap: enabled
                  ? () async {
                      final t = await askLostSince(context, a);
                      if (t != null) onAnswer(a, t);
                    }
                  : null,
            ),
          ),
      ],
    );
  }
}

/// Asks why the device goes, then removes it from our roster. Lost or stolen
/// also asks when the person last had it; what it added goes by that answer.
Future<void> removeDeviceFlow(
    BuildContext context, WidgetRef ref, MyDevice device) async {
  final name = deviceTitle(device);
  final removed = await showHollowDialog<RemovedDevice>(
    context: context,
    builder: (_) => RemoveDeviceDialog(name: name, devicePeerId: device.peerId),
  );
  if (removed == null || !context.mounted) return;
  final since = removed.lostSinceMs;
  final String message;
  if (since == null) {
    message = '$name is removed. What it did in your servers stays.';
  } else if (since <= 0) {
    message = '$name is removed. Changes it made in your servers are being '
        'undone.';
  } else {
    final at = rosterDateLabel(
        context, DateTime.fromMillisecondsSinceEpoch(since));
    message = '$name is removed. Changes it made in your servers after $at '
        'are being undone.';
  }
  HollowToast.show(context, message, type: HollowToastType.success);
}

/// What [RemoveDeviceDialog] removed: retiring when [lostSinceMs] is null.
class RemovedDevice {
  final int? lostSinceMs;
  const RemovedDevice(this.lostSinceMs);
}

/// Retire or lost or stolen, nothing picked first; lost or stolen asks when.
/// Lists what the device added: those added after that moment go with it,
/// named; the others stay unless the toggle is on.
class RemoveDeviceDialog extends ConsumerStatefulWidget {
  final String name;
  final String devicePeerId;

  const RemoveDeviceDialog({
    super.key,
    required this.name,
    required this.devicePeerId,
  });

  @override
  ConsumerState<RemoveDeviceDialog> createState() => _RemoveDeviceDialogState();
}

class _RemoveDeviceDialogState extends ConsumerState<RemoveDeviceDialog>
    with HollowDialogAction {
  bool? _lost;
  LastHadAnswer? _answer;
  int? _sinceMs;
  roster_api.DeviceRemovalPlan? _plan;
  String? _planError;
  int _planAsk = 0;
  bool? _removeAdded;

  /// Whether the person has answered enough for Remove to act.
  bool get _ready =>
      _lost == false || (_lost == true && _sinceMs != null);

  Future<void> _loadPlan() async {
    final ask = ++_planAsk;
    setState(() {
      _plan = null;
      _planError = null;
      _removeAdded = null;
    });
    try {
      final plan = await roster_api.removeDevicePlan(
        devicePeerId: widget.devicePeerId,
        lostSinceMs: _lost == true ? _sinceMs : null,
      );
      if (mounted && ask == _planAsk) setState(() => _plan = plan);
    } catch (e) {
      if (mounted && ask == _planAsk) {
        setState(() => _planError = friendlyError(e));
      }
    }
  }

  void _pickMode(bool lost) {
    if (_lost == lost) return;
    setState(() {
      _lost = lost;
      _answer = null;
      _sinceMs = null;
    });
    if (!lost) _loadPlan();
  }

  void _answered(LastHadAnswer answer, int sinceMs) {
    if (!mounted) return;
    setState(() {
      _answer = answer;
      _sinceMs = sinceMs;
    });
    _loadPlan();
  }

  Future<void> _remove() async {
    final plan = _plan;
    final withDependents =
        _removeAdded ?? plan?.optionalOn ?? false;
    final since = _lost == true ? _sinceMs : null;
    final ok = await runDialogAction(() => network_api.revokeDevice(
          devicePeerId: widget.devicePeerId,
          lostSinceMs: since,
          withDependents: withDependents,
        ));
    if (ok && mounted) Navigator.of(context).pop(RemovedDevice(since));
  }

  Widget _option({
    required bool lost,
    required String title,
    required String subtitle,
    required bool touch,
  }) {
    final selected = _lost == lost;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: HollowListRow(
        key: ValueKey(lost ? 'remove-lost' : 'remove-retire'),
        touch: touch,
        selected: selected,
        title: title,
        subtitle: subtitle,
        onTap: actionRunning ? null : () => _pickMode(lost),
      ),
    );
  }

  List<Widget> _devices(List<String> ids, bool touch) {
    final labels = ref.watch(deviceLabelProvider);
    final kinds = ref.watch(deviceKindProvider);
    return [
      for (final id in ids)
        HollowListRow(
          key: ValueKey('added-$id'),
          touch: touch,
          title: deviceGivenName(id, labels: labels, kinds: kinds) ??
              shortPeerLabel(id),
          // A device titled by its id already shows it once.
          subtitle: deviceGivenName(id, labels: labels, kinds: kinds) == null
              ? null
              : shortPeerLabel(id),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final touch = HollowDialogSurface.isCompact(context);
    final secondary =
        HollowTypography.bodySmall.copyWith(color: hollow.textSecondary);
    final plan = _plan;
    final since = _sinceMs;
    final sinceLabel = since == null || since <= 0
        ? null
        : rosterDateLabel(context, DateTime.fromMillisecondsSinceEpoch(since));
    final asked = _ready;
    final optionalOn = _removeAdded ?? plan?.optionalOn ?? false;
    final toggleLabel = _lost == true
        ? 'Also remove the devices it added earlier'
        : 'Also remove the devices it added';
    return HollowDialog(
      title: 'Remove ${widget.name}?',
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HollowDialogText(_removalMessage(widget.name)),
          const SizedBox(height: HollowSpacing.lg),
          _option(
            lost: false,
            title: "I'm retiring this device",
            subtitle: 'Replaced, sold or no longer used',
            touch: touch,
          ),
          _option(
            lost: true,
            title: 'It was lost or stolen',
            subtitle: 'Someone else may have it now',
            touch: touch,
          ),
          // Row subtitles stay one line on a phone, so what a choice does is
          // spelled out under the rows.
          if (_lost != null) ...[
            const SizedBox(height: HollowSpacing.sm),
            Text(
              _lost == true
                  ? 'Changes it made in your servers after you last had it '
                      'can be undone.'
                  : 'What it did in your servers stays. If someone else '
                      'could still use it, pick lost or stolen.',
              style: secondary,
            ),
          ],
          if (_lost == true) ...[
            const SizedBox(height: HollowSpacing.lg),
            const SettingsFieldLabel(label: 'When did you last have it?'),
            const SizedBox(height: HollowSpacing.xs),
            LastHadPicker(
              answer: _answer,
              sinceMs: _sinceMs,
              enabled: !actionRunning,
              onAnswer: _answered,
            ),
            const SizedBox(height: HollowSpacing.sm),
            Text(
              'If you are not sure, pick an earlier time. Changes your other '
              'devices and other members made stay either way.',
              style: secondary,
            ),
          ],
          if (asked && _planError != null) ...[
            const SizedBox(height: HollowSpacing.lg),
            Text(_planError!, style: secondary),
          ],
          if (asked && plan != null && _lost == true && plan.forced.isNotEmpty)
            ...[
            const SizedBox(height: HollowSpacing.lg),
            Text(
              sinceLabel == null
                  ? 'These devices are removed too, because it added them.'
                  : 'These devices are removed too, because it added them '
                      'after $sinceLabel.',
              style: HollowTypography.label.copyWith(color: hollow.textPrimary),
            ),
            const SizedBox(height: HollowSpacing.xs),
            ..._devices(plan.forced, touch),
            const SizedBox(height: HollowSpacing.xs),
            Text('If one of them is yours, pick a later time.',
                style: secondary),
          ],
          if (asked && plan != null && plan.optional.isNotEmpty) ...[
            const SizedBox(height: HollowSpacing.lg),
            ..._devices(plan.optional, touch),
            const SizedBox(height: HollowSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: Text(
                    toggleLabel,
                    style: HollowTypography.label
                        .copyWith(color: hollow.textPrimary),
                  ),
                ),
                const SizedBox(width: HollowSpacing.sm),
                HollowToggle(
                  key: const ValueKey('remove-added-toggle'),
                  value: optionalOn,
                  semanticLabel: toggleLabel,
                  onChanged: actionRunning
                      ? null
                      : (v) => setState(() => _removeAdded = v),
                ),
              ],
            ),
            if (_lost == true) ...[
              const SizedBox(height: HollowSpacing.xs),
              Text('They are treated as lost or stolen too.', style: secondary),
            ],
          ],
          if (asked && plan != null && !plan.takesEffectForServers) ...[
            const SizedBox(height: HollowSpacing.lg),
            Text(
              'Not removed for servers yet. Use your recovery phrase to take '
              'your account back.',
              style: HollowTypography.bodySmall.copyWith(color: hollow.warning),
            ),
          ],
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: actionRunning ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.danger(
          key: const ValueKey('remove-device-confirm'),
          onPressed: asked && (plan != null || _planError != null)
              ? _remove
              : null,
          loading: actionRunning,
          child: const Text('Remove'),
        ),
      ],
    );
  }
}

/// Confirms, then removes every other device from our roster.
Future<void> resetDeviceListsFlow(BuildContext context) async {
  final reset = await showHollowConfirm(
    context: context,
    title: 'Remove every other device?',
    message: 'Every device except this one stops getting your messages, '
        'locks, and erases itself in three days. To use one again, link it '
        'fresh.',
    confirmLabel: 'Remove other devices',
    destructive: true,
    onConfirm: network_api.resetDeviceLists,
  );
  if (!reset || !context.mounted) return;
  HollowToast.show(context, 'Every other device was removed.',
      type: HollowToastType.success);
}
