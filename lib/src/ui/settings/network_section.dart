import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/gif_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Network category of the desktop Settings dialog: relay selection (applied
/// via explicit Apply & Restart), offline delivery, and the anti-censorship
/// tunnel. The relay selection state lives on the dialog state (it must
/// survive switching categories) and arrives here as values + callbacks.
class NetworkSettingsView extends ConsumerWidget {
  final String selectedRelay;
  final String initialRelay;
  final bool showAddRelay;
  final TextEditingController newRelayController;
  final ValueChanged<String> onSelectRelay;
  final ValueChanged<String> onRemoveRelay;
  final VoidCallback onShowAddRelay;
  final VoidCallback onSubmitAddRelay;
  final VoidCallback onCancelAddRelay;
  final VoidCallback onApplyRestart;

  const NetworkSettingsView({
    super.key,
    required this.selectedRelay,
    required this.initialRelay,
    required this.showAddRelay,
    required this.newRelayController,
    required this.onSelectRelay,
    required this.onRemoveRelay,
    required this.onShowAddRelay,
    required this.onSubmitAddRelay,
    required this.onCancelAddRelay,
    required this.onApplyRestart,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final offlineInbox = ref.watch(offlineInboxProvider);
    final retentionDays = ref.watch(offlineInboxRetentionProvider);
    return settingsCardList([
      SettingsCard(
        title: 'Relay',
        children: [
          Text(
            'Your relay determines your network. Friends and servers on a '
            'different relay won\'t be reachable.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: HollowSpacing.sm),
          for (final domain in ref.watch(savedRelayListProvider)) ...[
            _buildRelayRow(hollow, domain),
            const SizedBox(height: HollowSpacing.xs),
          ],
          if (showAddRelay)
            _buildAddRelayField(hollow)
          else
            Align(
              alignment: Alignment.centerLeft,
              child: HollowButton.ghost(
                compact: true,
                icon: const Icon(LucideIcons.plus, size: 14),
                onPressed: onShowAddRelay,
                child: const Text('Add Relay'),
              ),
            ),
          if (selectedRelay != initialRelay) ...[
            const SizedBox(height: HollowSpacing.md),
            SizedBox(
              width: double.infinity,
              child: HollowButton.filled(
                onPressed: onApplyRestart,
                child: const Text('Apply & Restart'),
              ),
            ),
          ],
        ],
      ),
      SettingsCard(
        title: 'Offline Delivery',
        children: [
          SettingsToggleRow(
            icon: LucideIcons.inbox,
            label: 'Hold My Messages While I\'m Offline',
            subtitle:
                'Messages and file cards sent TO YOU while you\'re offline '
                'wait on the relay, encrypted, and arrive when you come back '
                '— even if the sender has gone offline by then. This only '
                'affects what you receive; senders don\'t need it enabled. '
                'The relay can\'t read any of it.',
            value: offlineInbox,
            onChanged: (v) =>
                ref.read(offlineInboxProvider.notifier).setEnabled(v),
          ),
          if (offlineInbox) ...[
            const SizedBox(height: HollowSpacing.md),
            Text(
              'Keep messages for',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: HollowSpacing.xs),
            TriStateSegment<int>(
              value: retentionDays,
              options: const [
                (1, '1 day'),
                (3, '3 days'),
                (7, '7 days'),
              ],
              onChanged: (d) =>
                  ref.read(offlineInboxRetentionProvider.notifier).setDays(d),
            ),
          ],
        ],
      ),
      const GifProxySettingsCard(),
      // Anti-censorship (VLESS+REALITY) tunnel — hidden from the UI: the
      // current REALITY transport is non-functional. Kept in the codebase
      // (widget below + Rust proxy_tunnel) for a future transport attempt.
      // Desktop-only for now (the tunnel runs as a bundled subprocess).
      // if (!Platform.isAndroid && !Platform.isIOS) const _AntiCensorshipCard(),
    ]);
  }

  Widget _buildRelayRow(HollowTheme hollow, String domain) {
    final isSelected = domain == selectedRelay;
    final isActive = domain == initialRelay;
    final isOfficial = domain == kDefaultRelayDomain;

    return HollowFocusRing(
      enabled: true,
      onActivate: () => onSelectRelay(domain),
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      child: GestureDetector(
        onTap: () => onSelectRelay(domain),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.md,
            vertical: HollowSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: isSelected
                ? hollow.accent.withValues(alpha: 0.08)
                : hollow.surface.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            border: Border.all(
              color: isSelected
                  ? hollow.accent.withValues(alpha: 0.4)
                  : hollow.border.withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            children: [
              Icon(
                isSelected ? LucideIcons.checkCircle : LucideIcons.circle,
                size: 16,
                color: isSelected ? hollow.accent : hollow.textSecondary,
              ),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      domain,
                      style: HollowTypography.body.copyWith(
                        color: hollow.textPrimary,
                        fontSize: 13,
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                    if (isActive)
                      Text(
                        'Currently active',
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
              if (isOfficial)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.sm,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: hollow.accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                  ),
                  child: Text(
                    'Official',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (!isOfficial) ...[
                const SizedBox(width: HollowSpacing.sm),
                GestureDetector(
                  onTap: () => onRemoveRelay(domain),
                  child: Icon(
                    LucideIcons.x,
                    size: 14,
                    semanticLabel: 'Remove relay',
                    color: hollow.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAddRelayField(HollowTheme hollow) {
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 36,
            child: HollowTextField(
              controller: newRelayController,
              hintText: 'relay.example.com',
              isDense: true,
              autofocus: true,
            ),
          ),
        ),
        const SizedBox(width: HollowSpacing.sm),
        HollowButton.filled(
          compact: true,
          onPressed: onSubmitAddRelay,
          child: const Text('Add'),
        ),
        const SizedBox(width: HollowSpacing.xs),
        HollowButton.ghost(
          compact: true,
          onPressed: onCancelAddRelay,
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// GIF search card: content rating, plus the two ways to change WHERE
/// results come from — a self-hosted copy of `gifs/`, or the user's own
/// Klipy API key (direct mode). Everything applies immediately; the next
/// search reads the new source. Shared by desktop and mobile settings.
class GifProxySettingsCard extends ConsumerStatefulWidget {
  const GifProxySettingsCard({super.key});

  @override
  ConsumerState<GifProxySettingsCard> createState() =>
      _GifProxySettingsCardState();
}

class _GifProxySettingsCardState extends ConsumerState<GifProxySettingsCard> {
  final _controller = TextEditingController();
  final _keyController = TextEditingController();
  final _hostsController = TextEditingController();
  bool _hydrated = false;
  bool _busy = false;
  bool _keyBusy = false;
  bool _hostsBusy = false;
  bool _expanded = false;
  bool _keyVisible = false;

  @override
  void dispose() {
    _controller.dispose();
    _keyController.dispose();
    _hostsController.dispose();
    super.dispose();
  }

  Future<void> _save(String value) async {
    setState(() => _busy = true);
    try {
      await ref.read(gifProxyUrlProvider.notifier).setUrl(value);
      if (!mounted) return;
      _controller.text = ref.read(gifProxyUrlProvider);
      HollowToast.show(context, 'GIF proxy updated');
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(context, 'Invalid proxy URL — must be https://',
          type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
              : 'Using your own Klipy key');
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(context, 'That does not look like a Klipy API key',
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
      HollowToast.show(context, 'Allowed media hosts updated');
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(context, 'That is not a valid host name',
          type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _hostsBusy = false);
    }
  }

  Widget _caption(HollowTheme hollow, String text) => Text(
        text,
        style: HollowTypography.caption
            .copyWith(color: hollow.textSecondary, fontSize: 11),
      );

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final current = ref.watch(gifProxyUrlProvider);
    final apiKey = ref.watch(gifApiKeyProvider);
    final direct = ref.watch(gifDirectModeProvider);
    final rating = ref.watch(gifRatingProvider);
    final ratings =
        ref.watch(gifRatingsProvider).valueOrNull ?? const [kDefaultGifRating];
    final hosts = ref.watch(gifMediaHostsProvider);
    if (!_hydrated) {
      _controller.text = current;
      _keyController.text = apiKey;
      _hostsController.text = hosts.join(', ');
      _hydrated = true;
      _expanded = current != kDefaultGifProxyUrl || apiKey.isNotEmpty;
    }

    return SettingsCard(
      title: 'GIF Search',
      children: [
        _caption(
          hollow,
          direct
              ? 'Searches go straight to KLIPY with your own API key, so '
                  'KLIPY sees your IP address and your searches. Message '
                  'recipients still make no web requests — a picked GIF is '
                  're-encoded and sent as encrypted bytes either way.'
              : 'GIF search goes through Hollow\'s no-log proxy — the '
                  'provider never sees who searches, and message recipients '
                  'make no web requests at all.',
        ),
        const SizedBox(height: HollowSpacing.md),
        SettingsSectionLabel(label: 'Content rating'),
        const SizedBox(height: HollowSpacing.xs),
        TriStateSegment<String>(
          value: ratings.contains(rating) ? rating : ratings.first,
          options: [for (final r in ratings) (r, r.toUpperCase())],
          onChanged: (r) => ref.read(gifRatingProvider.notifier).setRating(r),
        ),
        const SizedBox(height: HollowSpacing.xs),
        _caption(
          hollow,
          'Applies to search and trending. Servers that are not marked NSFW '
          'cap results at PG-13 regardless of this setting.',
        ),
        const SizedBox(height: HollowSpacing.md),
        SettingsToggleRow(
          icon: LucideIcons.play,
          label: 'Play GIFs automatically',
          subtitle: 'Animate every GIF on screen in the picker. Turn this off '
              'to load still frames instead and use less data — on desktop, '
              'hovering a GIF still plays it.',
          value: ref.watch(gifAutoplayProvider),
          onChanged: (v) =>
              ref.read(gifAutoplayProvider.notifier).setEnabled(v),
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
            onPressed: () {
              setState(() => _expanded = !_expanded);
              // Re-read what the last searches were refused, so the blocked
              // host hints below are current whenever the section opens.
              if (_expanded) ref.invalidate(gifBlockedHostsProvider);
            },
            child: const Text('Advanced (own API key, self-hosting)'),
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: HollowSpacing.sm),
          SettingsSectionLabel(label: 'Your own KLIPY API key'),
          const SizedBox(height: HollowSpacing.xs),
          _caption(
            hollow,
            'Optional. With your own key the app talks to KLIPY directly and '
            'skips Hollow\'s proxy: your own rate limit, no dependency on '
            'our server. It is not more private — KLIPY sees your IP and '
            'every search under one key, where the shared proxy shows them '
            'one server and a random id per request. Get a key at '
            'klipy.com/developers.',
          ),
          const SizedBox(height: HollowSpacing.xs),
          Row(
            children: [
              Expanded(
                child: HollowTextField(
                  controller: _keyController,
                  hintText: 'Paste your KLIPY API key',
                  isDense: true,
                  obscureText: !_keyVisible,
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: HollowSpacing.xs),
              HollowButton.ghost(
                compact: true,
                semanticLabel:
                    _keyVisible ? 'Hide API key' : 'Show API key',
                icon: Icon(
                    _keyVisible ? LucideIcons.eyeOff : LucideIcons.eye,
                    size: 14),
                onPressed: () => setState(() => _keyVisible = !_keyVisible),
                child: const SizedBox.shrink(),
              ),
              const SizedBox(width: HollowSpacing.xs),
              HollowButton.filled(
                compact: true,
                onPressed: _keyBusy || _keyController.text.trim() == apiKey
                    ? null
                    : () => _saveKey(_keyController.text),
                child: _keyBusy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Save'),
              ),
            ],
          ),
          if (apiKey.isNotEmpty) ...[
            const SizedBox(height: HollowSpacing.xs),
            Align(
              alignment: Alignment.centerLeft,
              child: HollowButton.ghost(
                compact: true,
                icon: const Icon(LucideIcons.rotateCcw, size: 14),
                onPressed: _keyBusy
                    ? null
                    : () {
                        _keyController.clear();
                        _saveKey('');
                      },
                child: const Text('Remove key (back to the Hollow proxy)'),
              ),
            ),
          ],
          if (direct) ...[
            const SizedBox(height: HollowSpacing.md),
            SettingsSectionLabel(label: 'Allowed media hosts'),
            const SizedBox(height: HollowSpacing.xs),
            _caption(
              hollow,
              'Comma-separated. Direct mode only: the app refuses to load GIF '
              'images from any other host, so a KLIPY CDN change can be fixed '
              'here without waiting for an app update. Subdomains are '
              'included.',
            ),
            const SizedBox(height: HollowSpacing.xs),
            Row(
              children: [
                Expanded(
                  child: HollowTextField(
                    controller: _hostsController,
                    hintText: hosts.join(', '),
                    isDense: true,
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: HollowSpacing.sm),
                HollowButton.filled(
                  compact: true,
                  onPressed: _hostsBusy ||
                          _hostsController.text.trim() == hosts.join(', ')
                      ? null
                      : () => _saveHosts(_hostsController.text.split(',')),
                  child: _hostsBusy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Save'),
                ),
              ],
            ),
            ...ref.watch(gifBlockedHostsProvider).maybeWhen(
                  data: (blocked) => [
                    for (final host
                        in blocked.where((h) => !hosts.contains(h))) ...[
                      const SizedBox(height: HollowSpacing.xs),
                      Row(
                        children: [
                          Icon(LucideIcons.shieldAlert,
                              size: 13, color: hollow.textTertiary),
                          const SizedBox(width: HollowSpacing.xs),
                          Expanded(
                            child: Text(
                              'Blocked images from $host',
                              style: HollowTypography.caption.copyWith(
                                  color: hollow.textTertiary, fontSize: 11),
                            ),
                          ),
                          HollowButton.ghost(
                            compact: true,
                            onPressed: _hostsBusy
                                ? null
                                : () => _saveHosts([...hosts, host]),
                            child: const Text('Allow'),
                          ),
                        ],
                      ),
                    ],
                  ],
                  orElse: () => const <Widget>[],
                ),
          ],
          const SizedBox(height: HollowSpacing.md),
          SettingsSectionLabel(label: 'Self-hosted proxy'),
          const SizedBox(height: HollowSpacing.xs),
          _caption(
            hollow,
            'Only if you run your own copy of the gifs/ endpoint. Ignored '
            'while an API key above is set.',
          ),
          const SizedBox(height: HollowSpacing.xs),
          Row(
            children: [
              Expanded(
                child: HollowTextField(
                  controller: _controller,
                  hintText: kDefaultGifProxyUrl,
                  isDense: true,
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowButton.filled(
                compact: true,
                onPressed: _busy || _controller.text.trim() == current
                    ? null
                    : () => _save(_controller.text),
                child: _busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Save'),
              ),
            ],
          ),
          if (current != kDefaultGifProxyUrl) ...[
            const SizedBox(height: HollowSpacing.xs),
            Align(
              alignment: Alignment.centerLeft,
              child: HollowButton.ghost(
                compact: true,
                icon: const Icon(LucideIcons.rotateCcw, size: 14),
                onPressed: _busy ? null : () => _save(''),
                child: const Text('Reset to default'),
              ),
            ),
          ],
        ],
      ],
    );
  }
}

/// Anti-censorship (VLESS+REALITY) proxy card in the Network category.
/// For users behind DPI censorship (Russia/TSPU, China/GFW): the relay
/// connection is tunnelled through a local `shoes` REALITY client so the
/// traffic looks like ordinary HTTPS to a real website. Enabling / editing
/// requires a node restart (same model as changing the relay). Desktop-only for
/// now — the tunnel runs as a bundled subprocess.
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
    // Collapse Advanced by default — the baked-in config already works. Only
    // auto-open if the user has customised away from the official defaults
    // (i.e. they're self-hosting a different relay).
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
      // stopNode() runs the node teardown, which kills the shoes tunnel
      // subprocess (proxy_tunnel::stop). Without this the old shoes.exe is
      // orphaned across the restart. Boot-time sweep is the backstop.
      await network_api.stopNode();
      await Future.delayed(const Duration(milliseconds: 200));
    } catch (_) {}
    final exe = Platform.resolvedExecutable;
    await Process.start(exe, [], mode: ProcessStartMode.detached);
    await Future.delayed(const Duration(milliseconds: 100));
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final asyncCfg = ref.watch(proxyConfigProvider);

    // Hydrate controllers once from the loaded persisted config.
    if (!_loaded && asyncCfg.hasValue) {
      _hydrate(asyncCfg.value!);
    }

    // Enabling with an incomplete config is not applicable — the button gates on it.
    final canApply = _dirty && (!_enabled || _current.isComplete);

    return SettingsCard(
      title: 'Anti-Censorship',
      children: [
        Text(
          'If your network blocks Hollow (DPI censorship, e.g. Russia or '
          'China), route the relay connection through a REALITY tunnel that '
          'looks like ordinary HTTPS to a real website. It\'s pre-configured — '
          'just turn it on and restart. Only touch Advanced if you run your own '
          'relay.',
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary,
            fontSize: 11,
          ),
        ),
        const SizedBox(height: HollowSpacing.md),
        SettingsToggleRow(
          icon: LucideIcons.shield,
          label: 'Route through REALITY tunnel',
          value: _enabled,
          onChanged: (v) => setState(() => _enabled = v),
        ),
        const SizedBox(height: HollowSpacing.sm),
        // Advanced — the raw config. Collapsed by default; normal users never
        // open it (the baked-in defaults already work).
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
              child: const Text('Apply & Restart'),
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
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontSize: 10,
            ),
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
