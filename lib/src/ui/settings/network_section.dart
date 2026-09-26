import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/gif_provider.dart';
import 'package:hollow/src/core/providers/link_preview_settings_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/relay_stats_provider.dart';
import 'package:hollow/src/core/providers/relay_status_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/settings/relay_health_card.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The pieces of Settings > Network. The page composes them; the phone's
/// settings tab still hosts the GIF and link preview groups on their own.

/// Width of a field row's controls on a pointer screen. Touch stacks them
/// under the title at full width instead.
const double _kFieldWidth = 340;

/// Awaits a settings write and says so when it fails.
Future<void> _saveSetting(BuildContext context, Future<void> write) async {
  try {
    await write;
  } catch (e) {
    if (!context.mounted) return;
    HollowToast.show(
        context, friendlyError(e, fallback: 'Could not save that setting'),
        type: HollowToastType.error);
  }
}

/// Opens a menu under the trailing edge of the button that owns [context].
void _openMenuBelow(BuildContext context, HollowMenuBuilder builder) {
  showHollowMenu(
    context: context,
    anchor: overlayAnchorOf(
      context,
      localOffset: Offset(context.size?.width ?? 0,
          (context.size?.height ?? 0) + HollowSpacing.xs),
    ),
    alignEnd: true,
    builder: builder,
  );
}

// ---------------------------------------------------------------------------
// Relay
// ---------------------------------------------------------------------------

/// The relay this identity is on, and the list to pick another. A pick only
/// applies through "Switch and restart": the relay is never switched for you.
class RelaySettingsSection extends ConsumerStatefulWidget {
  const RelaySettingsSection({super.key});

  @override
  ConsumerState<RelaySettingsSection> createState() =>
      _RelaySettingsSectionState();
}

class _RelaySettingsSectionState extends ConsumerState<RelaySettingsSection> {
  static bool get _phone => Platform.isAndroid || Platform.isIOS;

  /// The relay this process is connected to; a change needs a restart.
  late final String _activeRelay = ref.read(relayDomainProvider);
  late String _selectedRelay = _activeRelay;
  bool _open = false;
  bool _adding = false;
  bool _switching = false;
  final _newRelay = TextEditingController();

  @override
  void dispose() {
    _newRelay.dispose();
    super.dispose();
  }

  Future<void> _switchAndRestart() async {
    setState(() => _switching = true);
    try {
      await ref.read(relayDomainProvider.notifier).setDomain(_selectedRelay);
      await ref.read(savedRelayListProvider.notifier).addRelay(_selectedRelay);
      await exitForRelaySwitch();
    } catch (e) {
      if (!mounted) return;
      setState(() => _switching = false);
      HollowToast.show(context, friendlyError(e,
              fallback: "Couldn't switch relays. Try again."),
          type: HollowToastType.error);
    }
  }

  Future<void> _remove(String domain) async {
    try {
      await ref.read(savedRelayListProvider.notifier).removeRelay(domain);
      if (!mounted) return;
      if (_selectedRelay == domain) {
        setState(() => _selectedRelay = kDefaultRelayDomain);
      }
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(
          context, friendlyError(e, fallback: 'Could not remove that relay'),
          type: HollowToastType.error);
    }
  }

  Future<void> _submitNewRelay() async {
    final raw = _newRelay.text.trim();
    if (raw.isEmpty) return;
    final domain = normalizeRelayHost(raw);
    if (domain == null) {
      HollowToast.show(
          context, 'Enter a relay address such as myrelay.duckdns.org',
          type: HollowToastType.error);
      return;
    }
    if (ref.read(savedRelayListProvider).contains(domain)) return;
    try {
      await ref.read(savedRelayListProvider.notifier).addRelay(domain);
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(
          context, friendlyError(e, fallback: 'Could not add that relay'),
          type: HollowToastType.error);
      return;
    }
    if (!mounted) return;
    setState(() {
      _selectedRelay = domain;
      _newRelay.clear();
      _adding = false;
    });
  }

  void _cancelAdd() => setState(() {
        _newRelay.clear();
        _adding = false;
      });

  @override
  Widget build(BuildContext context) {
    final noTurn = ref.watch(relayStatusProvider)?.turn == false;
    final relays = ref.watch(savedRelayListProvider);
    return SettingsSection(
      title: 'Relay',
      children: [
        _ActiveRelayRow(
          domain: _activeRelay,
          open: _open,
          onToggle: () => setState(() => _open = !_open),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(
                left: HollowSpacing.md, bottom: HollowSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final domain in relays)
                  _RelayChoiceRow(
                    domain: domain,
                    selected: domain == _selectedRelay,
                    inUse: domain == _activeRelay,
                    noTurn: domain == _activeRelay && noTurn,
                    onSelect: () => setState(() => _selectedRelay = domain),
                    onRemove: () => _remove(domain),
                  ),
                const SizedBox(height: HollowSpacing.sm),
                if (_adding)
                  _AddRelayField(
                    controller: _newRelay,
                    onSubmit: _submitNewRelay,
                    onCancel: _cancelAdd,
                  )
                else
                  Align(
                    alignment: Alignment.centerLeft,
                    child: HollowButton.ghost(
                      compact: true,
                      icon: const Icon(LucideIcons.plus, size: 14),
                      onPressed: () => setState(() => _adding = true),
                      child: const Text('Add a relay'),
                    ),
                  ),
                const SettingsNote(
                    "Friends and servers on another relay can't be reached "
                    'from here.'),
              ],
            ),
          ),
        if (_selectedRelay != _activeRelay)
          Padding(
            padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                HollowButton.filled(
                  loading: _switching,
                  onPressed: _switchAndRestart,
                  // A phone app cannot start itself again, so it closes.
                  child: Text(_phone ? 'Switch and close' : 'Switch and restart'),
                ),
                if (_phone)
                  const SettingsNote(
                      'Open Hollow again to connect to the new relay.'),
              ],
            ),
          ),
        const RelayHealthRow(),
      ],
    );
  }
}

/// The relay in use, named in the console voice, with how it is doing. A
/// healthy relay reads as one quiet line; trouble takes a warning or error.
class _ActiveRelayRow extends ConsumerWidget {
  final String domain;
  final bool open;
  final VoidCallback onToggle;

  const _ActiveRelayRow({
    required this.domain,
    required this.open,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final connection = ref.watch(overallConnectionProvider);
    final stats = ref.watch(relayStatsProvider);
    final load = relayLoadOf(stats);

    final quiet =
        HollowTypography.bodySmall.copyWith(color: hollow.textSecondary);
    final parts = <TextSpan>[
      if (domain == kDefaultRelayDomain) const TextSpan(text: 'Official'),
      if (!connection.isOnline)
        TextSpan(
          text: connection.label,
          style: TextStyle(
            color: connection == OverallConnection.error ||
                    connection == OverallConnection.offline
                ? hollow.error
                : hollow.warning,
          ),
        )
      else ...[
        if (stats.isFresh)
          TextSpan(
              text: stats.onlineUsers == 1
                  ? '1 person online'
                  : '${stats.onlineUsers} people online'),
        if (load != null)
          TextSpan(
            text: 'load ${load.name}',
            style: load == RelayLoad.high
                ? TextStyle(color: hollow.warning)
                : null,
          ),
      ],
    ];
    final subtitle = <TextSpan>[
      for (var i = 0; i < parts.length; i++) ...[
        if (i > 0) const TextSpan(text: ' · '),
        parts[i],
      ],
    ];

    return SettingsRow(
      title: domain,
      monoTitle: true,
      subtitleWidget: subtitle.isEmpty
          ? null
          : Text.rich(TextSpan(style: quiet, children: subtitle)),
      trailing: HollowButton.ghost(
        compact: true,
        onPressed: onToggle,
        child: Text(open ? 'Done' : 'Change'),
      ),
    );
  }
}

/// One saved relay in the picker: a radio mark, the host, and what is worth
/// knowing about it.
class _RelayChoiceRow extends StatelessWidget {
  final String domain;
  final bool selected;
  final bool inUse;
  final bool noTurn;
  final VoidCallback onSelect;
  final VoidCallback onRemove;

  const _RelayChoiceRow({
    required this.domain,
    required this.selected,
    required this.inUse,
    required this.noTurn,
    required this.onSelect,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final official = domain == kDefaultRelayDomain;
    final notes = [
      if (official) 'Official',
      if (inUse) 'In use',
    ];
    final quiet =
        HollowTypography.bodySmall.copyWith(color: hollow.textSecondary);
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: HollowPressable(
        onTap: onSelect,
        subtle: true,
        hoverColor: hollow.elevated,
        semanticLabel: domain,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.sm, vertical: HollowSpacing.xs),
        child: Row(
          children: [
            Icon(
              selected ? LucideIcons.circleDot : LucideIcons.circle,
              size: 16,
              color: selected ? hollow.accentText : hollow.textSecondary,
            ),
            const SizedBox(width: HollowSpacing.md),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      domain,
                      overflow: TextOverflow.ellipsis,
                      style: HollowTypography.mono
                          .copyWith(color: hollow.textPrimary),
                    ),
                    if (notes.isNotEmpty || noTurn)
                      Text.rich(TextSpan(style: quiet, children: [
                        TextSpan(text: notes.join(' · ')),
                        if (noTurn) ...[
                          if (notes.isNotEmpty) const TextSpan(text: ' · '),
                          TextSpan(
                            text: 'No TURN: calls need a direct route',
                            style: TextStyle(color: hollow.warning),
                          ),
                        ],
                      ])),
                  ],
                ),
              ),
            ),
            if (!official)
              Builder(
                builder: (buttonContext) => HollowIconButton(
                  icon: LucideIcons.ellipsis,
                  label: 'More for $domain',
                  tooltip: 'More',
                  onPressed: () => _openMenuBelow(
                    buttonContext,
                    (_, _) => [
                      HollowMenuItem(
                        icon: LucideIcons.trash2,
                        label: 'Remove from the list',
                        onTap: onRemove,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AddRelayField extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSubmit;
  final VoidCallback onCancel;

  const _AddRelayField({
    required this.controller,
    required this.onSubmit,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: HollowTextField(
            controller: controller,
            hintText: 'relay.example.com',
            isDense: true,
            autofocus: true,
            onSubmitted: (_) => onSubmit(),
          ),
        ),
        const SizedBox(width: HollowSpacing.sm),
        HollowButton.outline(
          compact: true,
          onPressed: onSubmit,
          child: const Text('Add'),
        ),
        const SizedBox(width: HollowSpacing.sm),
        HollowButton.ghost(
          compact: true,
          onPressed: onCancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// While you're offline
// ---------------------------------------------------------------------------

/// The relay's offline inbox for this device, and how long it holds things.
class OfflineDeliverySection extends ConsumerWidget {
  const OfflineDeliverySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(offlineInboxProvider);
    final days = ref.watch(offlineInboxRetentionProvider);
    return SettingsSection(
      title: "While you're offline",
      children: [
        SettingsSwitchRow(
          title: 'Hold my messages',
          subtitle: "Messages and files sent to you while you're offline wait "
              "on the relay, encrypted, and arrive when you're back, even if "
              "the sender has gone offline. The relay can't read them, and "
              "senders don't need this on.",
          value: enabled,
          onChanged: (v) => _saveSetting(
              context, ref.read(offlineInboxProvider.notifier).setEnabled(v)),
        ),
        if (enabled)
          SettingsChoiceRow<int>(
            title: 'Keep them for',
            value: days,
            options: const [(1, '1 day'), (3, '3 days'), (7, '7 days')],
            onChanged: (d) => _saveSetting(context,
                ref.read(offlineInboxRetentionProvider.notifier).setDays(d)),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// GIFs and link previews
// ---------------------------------------------------------------------------

/// A rating as the picker names it: the short codes ("pg-13") read as the
/// acronyms they are, anything already a word stays as the server wrote it.
String _ratingLabel(String rating) =>
    RegExp(r'^[a-z]{1,3}(-\d+)?$').hasMatch(rating)
        ? rating.toUpperCase() // design-ignore: rating acronyms (PG, R)
        : rating;

class GifRatingRow extends ConsumerWidget {
  const GifRatingRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rating = ref.watch(gifRatingProvider);
    final ratings =
        ref.watch(gifRatingsProvider).valueOrNull ?? const [kDefaultGifRating];
    return SettingsChoiceRow<String>(
      title: 'GIF rating',
      subtitle: 'Servers not marked NSFW stay at PG-13',
      value: ratings.contains(rating) ? rating : ratings.first,
      options: [for (final r in ratings) (r, _ratingLabel(r))],
      onChanged: (r) => _saveSetting(
          context, ref.read(gifRatingProvider.notifier).setRating(r)),
    );
  }
}

class GifAutoplayRow extends ConsumerWidget {
  const GifAutoplayRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsSwitchRow(
      title: 'Play GIFs automatically',
      subtitle: 'Animates every GIF in the picker. Off loads still frames '
          'and uses less data; hovering a GIF still plays it on desktop.',
      value: ref.watch(gifAutoplayProvider),
      onChanged: (v) => _saveSetting(
          context, ref.read(gifAutoplayProvider.notifier).setEnabled(v)),
    );
  }
}

/// Link previews (issue #45): whether this device fetches cards for links it
/// sends. Cards other people attach show either way.
class LinkPreviewsRow extends ConsumerStatefulWidget {
  const LinkPreviewsRow({super.key});

  @override
  ConsumerState<LinkPreviewsRow> createState() => _LinkPreviewsRowState();
}

class _LinkPreviewsRowState extends ConsumerState<LinkPreviewsRow> {
  bool _busy = false;

  Future<void> _setEnabled(bool enabled) async {
    setState(() => _busy = true);
    await _saveSetting(context,
        ref.read(linkPreviewsEnabledProvider.notifier).setEnabled(enabled));
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSwitchRow(
      title: 'Previews for links I send',
      subtitle: 'Your device fetches the title and image and sends them with '
          'the message, so the people who get it never open the link. Off: '
          'your device never touches a link you paste.',
      value: ref.watch(linkPreviewsEnabledProvider),
      // Swallow taps mid-save rather than disabling the row: the write is a
      // single settings key and finishes in a frame or two.
      onChanged: (v) {
        if (!_busy) _setEnabled(v);
      },
    );
  }
}

class GifsAndPreviewsSection extends StatelessWidget {
  const GifsAndPreviewsSection({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingsSection(
      title: 'GIFs and link previews',
      children: [GifRatingRow(), GifAutoplayRow(), LinkPreviewsRow()],
    );
  }
}

// ---------------------------------------------------------------------------
// Advanced
// ---------------------------------------------------------------------------

/// A settings row whose control is a text field and its buttons.
class _FieldRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget field;
  final List<Widget> actions;

  /// A second action under the field ("Remove key", "Reset to default").
  final Widget? secondary;

  const _FieldRow({
    required this.title,
    this.subtitle,
    required this.field,
    required this.actions,
    this.secondary,
  });

  @override
  Widget build(BuildContext context) {
    final controls = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(child: field),
            for (final a in actions) ...[
              const SizedBox(width: HollowSpacing.sm),
              a,
            ],
          ],
        ),
        if (secondary != null) ...[
          const SizedBox(height: HollowSpacing.xs),
          secondary!,
        ],
      ],
    );
    return SettingsRow(
      title: title,
      subtitle: subtitle,
      wideTrailing: true,
      trailing: SettingsDensity.touchOf(context)
          ? controls
          : SizedBox(width: _kFieldWidth, child: controls),
    );
  }
}

/// True when anything the Advanced fold holds differs from its default, so
/// the fold opens on what someone set.
bool networkAdvancedChanged(WidgetRef ref) =>
    ref.watch(gifApiKeyProvider).isNotEmpty ||
    ref.watch(gifProxyUrlProvider) != kDefaultGifProxyUrl ||
    ref.watch(embedProxyUrlProvider).isNotEmpty;

class NetworkAdvancedSettings extends ConsumerWidget {
  const NetworkAdvancedSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsAdvanced(
      initiallyOpen: networkAdvancedChanged(ref),
      children: const [KlipyKeyRows(), GifProxyRow(), SocialPreviewProxyRow()],
    );
  }
}

/// The user's own KLIPY key (direct mode), and in direct mode the hosts GIF
/// images may load from.
class KlipyKeyRows extends ConsumerStatefulWidget {
  const KlipyKeyRows({super.key});

  @override
  ConsumerState<KlipyKeyRows> createState() => _KlipyKeyRowsState();
}

class _KlipyKeyRowsState extends ConsumerState<KlipyKeyRows> {
  late final TextEditingController _keyController;
  late final TextEditingController _hostsController;
  bool _keyBusy = false;
  bool _hostsBusy = false;
  bool _keyVisible = false;

  @override
  void initState() {
    super.initState();
    _keyController = TextEditingController(text: ref.read(gifApiKeyProvider));
    _hostsController =
        TextEditingController(text: ref.read(gifMediaHostsProvider).join(', '));
    // Re-read what the last searches refused whenever these rows appear, so
    // the blocked host hints are current.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.invalidate(gifBlockedHostsProvider);
    });
  }

  @override
  void dispose() {
    _keyController.dispose();
    _hostsController.dispose();
    super.dispose();
  }

  Future<void> _saveKey(String value) async {
    setState(() => _keyBusy = true);
    try {
      await ref.read(gifApiKeyProvider.notifier).setKey(value);
      if (!mounted) return;
      _keyController.text = ref.read(gifApiKeyProvider);
      HollowToast.show(
          context,
          value.trim().isEmpty
              ? 'Back to the Hollow proxy'
              : 'Using your own KLIPY key',
          type: HollowToastType.success);
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(
          context, friendlyError(e, fallback: 'That does not look like a KLIPY API key'),
          type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _keyBusy = false);
    }
  }

  Future<void> _saveHosts(List<String> hosts) async {
    setState(() => _hostsBusy = true);
    try {
      await ref.read(gifMediaHostsProvider.notifier).setHosts(hosts);
      if (!mounted) return;
      _hostsController.text = ref.read(gifMediaHostsProvider).join(', ');
      HollowToast.show(context, 'Allowed media hosts updated',
          type: HollowToastType.success);
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(
          context, friendlyError(e, fallback: 'That is not a valid host name'),
          type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _hostsBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final apiKey = ref.watch(gifApiKeyProvider);
    final direct = ref.watch(gifDirectModeProvider);
    final hosts = ref.watch(gifMediaHostsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _FieldRow(
          title: 'Your own KLIPY key',
          subtitle: "Optional. Your key talks to KLIPY directly instead of "
              "Hollow's no-log proxy, with your own rate limit, but KLIPY then "
              'sees your IP address and every search. Keys at '
              'klipy.com/developers.',
          field: HollowTextField(
            controller: _keyController,
            hintText: 'Paste your KLIPY API key',
            isDense: true,
            obscureText: !_keyVisible,
            onChanged: (_) => setState(() {}),
            trailing: HollowIconButton(
              icon: _keyVisible ? LucideIcons.eyeOff : LucideIcons.eye,
              label: _keyVisible ? 'Hide API key' : 'Show API key',
              onPressed: () => setState(() => _keyVisible = !_keyVisible),
            ),
          ),
          actions: [
            HollowButton.outline(
              compact: true,
              loading: _keyBusy,
              onPressed: _keyController.text.trim() == apiKey
                  ? null
                  : () => _saveKey(_keyController.text),
              child: const Text('Save'),
            ),
          ],
          secondary: apiKey.isEmpty
              ? null
              : HollowButton.ghost(
                  compact: true,
                  onPressed: _keyBusy
                      ? null
                      : () {
                          _keyController.clear();
                          _saveKey('');
                        },
                  child: const Text('Remove key'),
                ),
        ),
        if (direct) ...[
          _FieldRow(
            title: 'Allowed media hosts',
            subtitle: 'GIF images load only from these, subdomains included',
            field: HollowTextField(
              controller: _hostsController,
              hintText: hosts.join(', '),
              isDense: true,
              onChanged: (_) => setState(() {}),
            ),
            actions: [
              HollowButton.outline(
                compact: true,
                loading: _hostsBusy,
                onPressed: _hostsController.text.trim() == hosts.join(', ')
                    ? null
                    : () => _saveHosts(_hostsController.text.split(',')),
                child: const Text('Save'),
              ),
            ],
          ),
          ...ref.watch(gifBlockedHostsProvider).maybeWhen(
                data: (blocked) => [
                  for (final host in blocked.where((h) => !hosts.contains(h)))
                    SettingsRow(
                      title: host,
                      subtitle: 'Images from here were blocked',
                      trailing: HollowButton.outline(
                        compact: true,
                        onPressed: _hostsBusy
                            ? null
                            : () => _saveHosts([...hosts, host]),
                        child: const Text('Allow'),
                      ),
                    ),
                ],
                orElse: () => const <Widget>[],
              ),
        ],
      ],
    );
  }
}

/// A self-hosted copy of the `gifs/` endpoint.
class GifProxyRow extends ConsumerStatefulWidget {
  const GifProxyRow({super.key});

  @override
  ConsumerState<GifProxyRow> createState() => _GifProxyRowState();
}

class _GifProxyRowState extends ConsumerState<GifProxyRow> {
  late final TextEditingController _controller;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: ref.read(gifProxyUrlProvider));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save(String value) async {
    setState(() => _busy = true);
    try {
      await ref.read(gifProxyUrlProvider.notifier).setUrl(value);
      if (!mounted) return;
      _controller.text = ref.read(gifProxyUrlProvider);
      HollowToast.show(context, 'GIF proxy updated',
          type: HollowToastType.success);
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(
          context, friendlyError(e, fallback: 'The proxy address must start with https://'),
          type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(gifProxyUrlProvider);
    return _FieldRow(
      title: 'GIF proxy',
      subtitle: 'Your own copy of the GIF endpoint. Ignored while a key is set.',
      field: HollowTextField(
        controller: _controller,
        hintText: kDefaultGifProxyUrl,
        isDense: true,
        onChanged: (_) => setState(() {}),
      ),
      actions: [
        HollowButton.outline(
          compact: true,
          loading: _busy,
          onPressed: _controller.text.trim() == current
              ? null
              : () => _save(_controller.text),
          child: const Text('Save'),
        ),
      ],
      secondary: current == kDefaultGifProxyUrl
          ? null
          : HollowButton.ghost(
              compact: true,
              onPressed: _busy ? null : () => _save(''),
              child: const Text('Reset to default'),
            ),
    );
  }
}

/// The optional hop in front of the public API that reads X and TikTok posts.
/// Every other link is fetched directly, proxy or not.
class SocialPreviewProxyRow extends ConsumerStatefulWidget {
  const SocialPreviewProxyRow({super.key});

  @override
  ConsumerState<SocialPreviewProxyRow> createState() =>
      _SocialPreviewProxyRowState();
}

class _SocialPreviewProxyRowState extends ConsumerState<SocialPreviewProxyRow> {
  late final TextEditingController _controller;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: ref.read(embedProxyUrlProvider));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save(String value) async {
    setState(() => _busy = true);
    try {
      await ref.read(embedProxyUrlProvider.notifier).setUrl(value);
      if (!mounted) return;
      _controller.text = ref.read(embedProxyUrlProvider);
      HollowToast.show(
          context,
          value.trim().isEmpty
              ? 'Social lookups go direct again'
              : 'Social lookups go through your proxy',
          type: HollowToastType.success);
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(
          context, friendlyError(e, fallback: 'The proxy address must start with https://'),
          type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final proxy = ref.watch(embedProxyUrlProvider);
    return _FieldRow(
      title: 'Social preview proxy',
      subtitle: 'Optional, empty is normal. X and TikTok cards go through a '
          'public read-only service; point this at your own to put a hop in '
          'between.',
      field: HollowTextField(
        controller: _controller,
        hintText: 'https://embed.example.com',
        isDense: true,
        onChanged: (_) => setState(() {}),
      ),
      actions: [
        HollowButton.outline(
          compact: true,
          loading: _busy,
          onPressed: _controller.text.trim() == proxy
              ? null
              : () => _save(_controller.text),
          child: const Text('Save'),
        ),
      ],
      secondary: proxy.isEmpty
          ? null
          : HollowButton.ghost(
              compact: true,
              onPressed: _busy
                  ? null
                  : () {
                      _controller.clear();
                      _save('');
                    },
              child: const Text('Remove'),
            ),
    );
  }
}

// Hidden: the current REALITY transport is non-functional. Kept, widget and
// Rust side, for a future transport attempt; it would join the Advanced fold.
/// Anti-censorship (VLESS+REALITY) proxy card, for users behind DPI
/// censorship: the relay connection is tunnelled through a local `shoes`
/// REALITY client so the traffic looks like ordinary HTTPS. Enabling or editing
/// needs a node restart, and it is desktop-only because the tunnel is a
/// bundled subprocess.
class _AntiCensorshipCard extends ConsumerStatefulWidget {
  const _AntiCensorshipCard();

  @override
  ConsumerState<_AntiCensorshipCard> createState() =>
      _AntiCensorshipCardState();
}

class _AntiCensorshipCardState extends ConsumerState<_AntiCensorshipCard> {
  final _server = TextEditingController();
  final _uuid = TextEditingController();
  final _publicKey = TextEditingController();
  final _shortId = TextEditingController();
  final _sni = TextEditingController();

  ProxyConfig _initial = const ProxyConfig();
  bool _enabled = false;
  bool _loaded = false;
  bool _expanded = false;

  @override
  void dispose() {
    _server.dispose();
    _uuid.dispose();
    _publicKey.dispose();
    _shortId.dispose();
    _sni.dispose();
    super.dispose();
  }

  void _hydrate(ProxyConfig cfg) {
    _initial = cfg;
    _enabled = cfg.enabled;
    _server.text = cfg.server;
    _uuid.text = cfg.uuid;
    _publicKey.text = cfg.publicKey;
    _shortId.text = cfg.shortId;
    _sni.text = cfg.sni;
    // Collapsed by default, because the baked-in config already works; only a
    // customised config opens it.
    _expanded = cfg.server != kDefaultProxyServer ||
        cfg.uuid != kDefaultProxyUuid ||
        cfg.publicKey != kDefaultProxyPublicKey ||
        cfg.sni != kDefaultProxySni;
    _loaded = true;
  }

  ProxyConfig get _current => ProxyConfig(
        enabled: _enabled,
        server: _server.text,
        uuid: _uuid.text,
        publicKey: _publicKey.text,
        shortId: _shortId.text,
        sni: _sni.text,
      );

  bool get _dirty {
    final c = _current;
    return c.enabled != _initial.enabled ||
        c.server.trim() != _initial.server.trim() ||
        c.uuid.trim() != _initial.uuid.trim() ||
        c.publicKey.trim() != _initial.publicKey.trim() ||
        c.shortId.trim() != _initial.shortId.trim() ||
        c.sni.trim() != _initial.sni.trim();
  }

  Future<void> _applyAndRestart() async {
    await ref.read(proxyConfigProvider.notifier).save(_current);
    try {
      await network_api.notifyShutdown();
      // The node teardown is what kills the shoes tunnel subprocess; without
      // this the old one is orphaned across the restart.
      await network_api.stopNode();
      await Future.delayed(const Duration(milliseconds: 200));
    } catch (_) {}
    await relaunchApp();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final asyncCfg = ref.watch(proxyConfigProvider);

    if (!_loaded && asyncCfg.hasValue) {
      _hydrate(asyncCfg.value!);
    }

    final canApply = _dirty && (!_enabled || _current.isComplete);

    return SettingsCard(
      title: 'Anti-Censorship',
      children: [
        Text(
          'If your network blocks Hollow (DPI censorship, e.g. Russia or '
          'China), route the relay connection through a REALITY tunnel that '
          'looks like ordinary HTTPS to a real website. It\'s pre-configured. '
          'Turn it on and restart. Only touch Advanced if you run your own '
          'relay.',
          style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
        ),
        const SizedBox(height: HollowSpacing.md),
        SettingsToggleRow(
          icon: LucideIcons.shield,
          label: 'Route through REALITY tunnel',
          value: _enabled,
          onChanged: (v) => setState(() => _enabled = v),
        ),
        const SizedBox(height: HollowSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: HollowButton.ghost(
            compact: true,
            icon: Icon(
              _expanded ? LucideIcons.chevronDown : LucideIcons.chevronRight,
              size: 14,
            ),
            onPressed: () => setState(() => _expanded = !_expanded),
            child: const Text('Advanced (self-hosting)'),
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: HollowSpacing.sm),
          _proxyField(hollow, 'Server (host:port)', _server,
              'e.g. 203.0.113.5:8443'),
          _proxyField(hollow, 'UUID', _uuid,
              'e.g. bfe68ae0-4435-41ec-950a-aacc1caa2771'),
          _proxyField(hollow, 'Public key', _publicKey, 'REALITY public key'),
          _proxyField(hollow, 'Short ID', _shortId, 'hex (may be blank)'),
          _proxyField(hollow, 'SNI', _sni, 'e.g. www.microsoft.com'),
          Align(
            alignment: Alignment.centerLeft,
            child: HollowButton.ghost(
              compact: true,
              icon: const Icon(LucideIcons.rotateCcw, size: 14),
              onPressed: () => setState(() {
                _server.text = kDefaultProxyServer;
                _uuid.text = kDefaultProxyUuid;
                _publicKey.text = kDefaultProxyPublicKey;
                _shortId.text = kDefaultProxyShortId;
                _sni.text = kDefaultProxySni;
              }),
              child: const Text('Reset to default'),
            ),
          ),
        ],
        if (canApply) ...[
          const SizedBox(height: HollowSpacing.md),
          SizedBox(
            width: double.infinity,
            child: HollowButton.filled(
              onPressed: _applyAndRestart,
              child: const Text('Apply & restart'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _proxyField(
    HollowTheme hollow,
    String label,
    TextEditingController controller,
    String hint,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: HollowTypography.micro.copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.xs),
          HollowTextField(
            controller: controller,
            hintText: hint,
            isDense: true,
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
    );
  }
}
