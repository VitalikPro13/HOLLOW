import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
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
      // Desktop-only for now (the tunnel runs as a bundled subprocess).
      if (!Platform.isAndroid && !Platform.isIOS) const _AntiCensorshipCard(),
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
