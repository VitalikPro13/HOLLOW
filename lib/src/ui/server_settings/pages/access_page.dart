import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_settings_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/twitch.dart' as twitch_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/follow_days_steps.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/server_settings/server_settings_widgets.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';

/// Absent means on at three days, matching Rust's `relay_catchup_secs()`.
const int _kCatchupDefaultDays = 3;

/// Who gets in, and what the relay keeps for members while they're away.
/// Switches, chips and menus write at once; the member limit is a field and
/// waits for the unsaved bar.
class AccessPage extends ConsumerStatefulWidget {
  final String serverId;
  const AccessPage({super.key, required this.serverId});

  @override
  ConsumerState<AccessPage> createState() => _AccessPageState();
}

class _AccessPageState extends ConsumerState<AccessPage> {
  final Map<String, String> _values = {};
  bool _loaded = false;

  static const _keys = [
    'is_private',
    'is_nsfw',
    'relay_catchup_secs',
    'twitch_verification_enabled',
    'twitch_channel_name',
    'twitch_channel_id',
    'twitch_min_follow_days',
    'twitch_require_sub',
    'twitch_owner_verify',
  ];

  String get _sid => widget.serverId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    for (final key in _keys) {
      try {
        _values[key] = await ref
            .read(serverSettingProvider((serverId: _sid, key: key)).future);
      } catch (_) {
        _values[key] = '';
      }
    }
    if (mounted) setState(() => _loaded = true);
  }

  bool _flag(String key) => _values[key] == 'true';

  int get _catchupDays {
    final raw = _values['relay_catchup_secs'] ?? '';
    if (raw.isEmpty) return _kCatchupDefaultDays;
    final secs = int.tryParse(raw) ?? 0;
    if (secs <= 0) return 0;
    return secs <= 86400 ? 1 : (secs <= 3 * 86400 ? 3 : 7);
  }

  /// Writes [changes] with the page already showing them; reverts and says so
  /// on failure.
  Future<void> _write(Map<String, String> changes) async {
    final before = {for (final k in changes.keys) k: _values[k] ?? ''};
    setState(() => _values.addAll(changes));
    try {
      for (final e in changes.entries) {
        await crdt_api.updateServerSetting(
            serverId: _sid, key: e.key, value: e.value);
      }
      if (changes.containsKey('is_nsfw')) {
        ref.invalidate(serverIsNsfwProvider(_sid));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _values.addAll(before));
      HollowToast.show(context, 'Could not save that: $e',
          type: HollowToastType.error);
    }
  }

  Future<void> _setTwitch(bool on) async {
    if (on && (_values['twitch_channel_id'] ?? '').isEmpty) {
      // Nothing to check against yet: ask for the channel first.
      final picked = await _editTwitchChannel();
      if (picked == null) return;
      await _write({
        'twitch_channel_name': picked.name,
        'twitch_channel_id': picked.id,
        'twitch_verification_enabled': 'true',
      });
      return;
    }
    await _write({'twitch_verification_enabled': on ? 'true' : 'false'});
  }

  Future<({String name, String id})?> _editTwitchChannel() {
    return showHollowDialog<({String name, String id})>(
      context: context,
      builder: (_) => _TwitchChannelDialog(
        name: _values['twitch_channel_name'] ?? '',
        id: _values['twitch_channel_id'] ?? '',
      ),
    );
  }

  Future<void> _changeTwitchChannel() async {
    final picked = await _editTwitchChannel();
    if (picked == null) return;
    await _write({
      'twitch_channel_name': picked.name,
      'twitch_channel_id': picked.id,
    });
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final draft = ref.read(serverSettingsDraftProvider(_sid).notifier);
    final twitchOn = _flag('twitch_verification_enabled');
    final catchup = _catchupDays;
    final channelName = _values['twitch_channel_name'] ?? '';
    final channelId = _values['twitch_channel_id'] ?? '';
    final minDays =
        effectiveFollowStep(int.tryParse(_values['twitch_min_follow_days'] ?? '') ?? 0);

    return SettingsPage(
      title: 'Access',
      intro: "Who can get in, and what the relay keeps for members while "
          "they're away.",
      children: [
        SettingsSection(
          title: 'Joining',
          children: [
            SettingsSwitchRow(
              title: 'Private server',
              subtitle: 'Nobody new can join, even with an invite link. '
                  'Everyone already here stays.',
              value: _flag('is_private'),
              onChanged: _loaded
                  ? (v) => _write({'is_private': v ? 'true' : 'false'})
                  : null,
            ),
            SettingsSwitchRow(
              title: 'Adult content',
              subtitle: "People confirm they're 18 or older before they join",
              value: _flag('is_nsfw'),
              onChanged: _loaded
                  ? (v) => _write({'is_nsfw': v ? 'true' : 'false'})
                  : null,
            ),
            SettingsRow(
              title: 'Member limit',
              subtitle: 'Blank means no limit. Nobody already here is removed.',
              trailing: SizedBox(
                width: 112,
                child: HollowTextField(
                  controller: draft.maxMembers,
                  hintText: 'No limit',
                  isDense: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                ),
              ),
            ),
          ],
        ),
        SettingsSection(
          title: 'Twitch verification',
          children: [
            SettingsRow(
              title: 'Check join requests against Twitch',
              subtitle: 'Only followers or subscribers of the channel can join',
              enabled: _loaded,
              leading: const SizedBox.square(
                dimension: HollowSpacing.xl + HollowSpacing.sm,
                child: Center(
                  child: Icon(BrandIcons.twitch,
                      size: 20, color: BrandIconColors.twitch),
                ),
              ),
              trailing: HollowToggle(
                value: twitchOn,
                semanticLabel: 'Check join requests against Twitch',
                onChanged: _loaded ? _setTwitch : null,
              ),
            ),
            if (twitchOn) ...[
              SettingsRow(
                title: 'Channel',
                subtitleWidget: Text.rich(TextSpan(children: [
                  TextSpan(text: channelName.isEmpty ? 'No name' : channelName),
                  const TextSpan(text: ' · '),
                  TextSpan(
                    text: channelId,
                    style: HollowTypography.monoSmall
                        .copyWith(color: hollow.textSecondary),
                  ),
                ])),
                trailing: HollowButton.ghost(
                  compact: true,
                  semanticLabel: 'Change the Twitch channel',
                  onPressed: _changeTwitchChannel,
                  child: const Text('Change'),
                ),
              ),
              SettingsRow(
                title: 'Followed for at least',
                subtitle: 'Any means following is enough',
                trailing: SettingsMenuPicker<int>(
                  value: minDays,
                  semanticLabel: 'Followed for at least',
                  options: [
                    for (final d in kFollowDaySteps)
                      (d, d == 0 ? 'Any' : (d == 1 ? '1 day' : '$d days')),
                  ],
                  onChanged: (d) =>
                      _write({'twitch_min_follow_days': '$d'}),
                ),
              ),
              SettingsSwitchRow(
                title: 'Subscribers only',
                subtitle: "Following isn't enough, they must subscribe",
                value: _flag('twitch_require_sub'),
                onChanged: (v) =>
                    _write({'twitch_require_sub': v ? 'true' : 'false'}),
              ),
              SettingsSwitchRow(
                title: 'Only I accept requests',
                subtitle: "A modified client can't get around it, but "
                    "requests wait until you're online",
                value: _flag('twitch_owner_verify'),
                onChanged: (v) =>
                    _write({'twitch_owner_verify': v ? 'true' : 'false'}),
              ),
            ],
          ],
        ),
        SettingsSection(
          title: 'While members are away',
          children: [
            SettingsSwitchRow(
              title: 'Offline catch-up',
              subtitle: 'The relay keeps encrypted channel messages so '
                  'members catch up when nobody else is online. Text and '
                  "file cards only, and the relay can't read them.",
              value: catchup > 0,
              onChanged: _loaded
                  ? (v) => _write({
                        'relay_catchup_secs':
                            '${(v ? _kCatchupDefaultDays : 0) * 86400}'
                      })
                  : null,
            ),
            if (catchup > 0)
              SettingsChoiceRow<int>(
                title: 'Keep them for',
                value: catchup,
                options: const [(1, '1 day'), (3, '3 days'), (7, '7 days')],
                onChanged: (d) =>
                    _write({'relay_catchup_secs': '${d * 86400}'}),
              ),
          ],
        ),
      ],
    );
  }
}

/// The Twitch channel a join request is checked against: its name for the
/// joiner's messages and its numeric id for the check itself. Typing a name
/// looks the id up; the id field stays editable for when that cannot run.
class _TwitchChannelDialog extends StatefulWidget {
  final String name;
  final String id;
  const _TwitchChannelDialog({required this.name, required this.id});

  @override
  State<_TwitchChannelDialog> createState() => _TwitchChannelDialogState();
}

enum _Lookup { idle, looking, found, missing, failed }

class _TwitchChannelDialogState extends State<_TwitchChannelDialog> {
  late final _name = TextEditingController(text: widget.name);
  late final _id = TextEditingController(text: widget.id);
  Timer? _debounce;
  _Lookup _lookup = _Lookup.idle;
  String _message = '';

  /// Bumped per lookup, so a slow answer for an older name is ignored.
  int _gen = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _name.dispose();
    _id.dispose();
    super.dispose();
  }

  void _onName(String _) {
    _debounce?.cancel();
    final login = _name.text.trim();
    if (login.isEmpty) {
      _gen++;
      setState(() => _lookup = _Lookup.idle);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 600), () => _find(login));
  }

  Future<void> _find(String login) async {
    final gen = ++_gen;
    setState(() => _lookup = _Lookup.looking);
    try {
      final found = await twitch_api.twitchLookupChannel(login: login);
      if (!mounted || gen != _gen) return;
      setState(() {
        if (found == null) {
          _lookup = _Lookup.missing;
        } else {
          _lookup = _Lookup.found;
          _message = found.displayName;
          _id.text = found.id;
        }
      });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _lookup = _Lookup.failed;
        _message = '$e';
      });
    }
  }

  Future<void> _fill() async {
    try {
      final userId = await twitch_api.twitchGetUserId();
      final username = await twitch_api.twitchGetUsername();
      if (!mounted) return;
      if (userId == null) {
        HollowToast.show(context, 'Connect Twitch in Settings, Profile first',
            type: HollowToastType.error);
        return;
      }
      _gen++;
      _debounce?.cancel();
      setState(() {
        _id.text = userId;
        if (username != null) _name.text = username;
        _lookup = _Lookup.idle;
      });
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Could not read your Twitch account: $e',
            type: HollowToastType.error);
      }
    }
  }

  void _save() {
    final id = _id.text.trim();
    if (id.isEmpty) return;
    final name = _lookup == _Lookup.found ? _message : _name.text.trim();
    Navigator.of(context).pop((name: name, id: id));
  }

  Widget _status(HollowTheme hollow) {
    final (text, color) = switch (_lookup) {
      _Lookup.idle => (
          'Type the channel name and its ID fills in',
          hollow.textSecondary
        ),
      _Lookup.looking => ('Looking it up', hollow.textSecondary),
      _Lookup.found => ('Found $_message', hollow.success),
      _Lookup.missing => ('No Twitch channel has that name', hollow.error),
      _Lookup.failed => (_message, hollow.error),
    };
    return Row(
      children: [
        if (_lookup == _Lookup.looking) ...[
          const HollowSpinner(),
          const SizedBox(width: HollowSpacing.xs),
        ],
        Expanded(
          child: Text(text,
              style: HollowTypography.bodySmall.copyWith(color: color)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowDialog(
      title: 'Twitch channel',
      width: 420,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SettingsFieldLabel(label: 'Channel name'),
          const SizedBox(height: HollowSpacing.xs),
          HollowTextField(
            controller: _name,
            hintText: 'As it appears in twitch.tv/name',
            maxLength: 25,
            showCounter: false,
            autofocus: true,
            onChanged: _onName,
          ),
          const SizedBox(height: HollowSpacing.xs),
          _status(hollow),
          const SizedBox(height: HollowSpacing.md),
          const SettingsFieldLabel(label: 'Twitch user ID'),
          const SizedBox(height: HollowSpacing.xs),
          HollowTextField(
            controller: _id,
            hintText: 'The number, like 123456789',
            maxLength: 32,
            showCounter: false,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
      leadingActions: [
        HollowButton.ghost(
          onPressed: _fill,
          child: const Text('Fill from my account'),
        ),
      ],
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ListenableBuilder(
          listenable: _id,
          builder: (context, _) => HollowButton.filled(
            onPressed: _id.text.trim().isEmpty ? null : _save,
            child: const Text('Save'),
          ),
        ),
      ],
    );
  }
}
