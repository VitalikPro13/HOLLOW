import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';

/// Total visible DM message count, the number two synced devices compare.
///
/// DMs fully converge across a person's devices, so both should report the
/// same value. Channel messages are excluded: they are lazy-paged per device
/// and would diverge even when fully synced.
final _dmMessageCountProvider = FutureProvider.autoDispose<int>((ref) async {
  // The last-message map is the cheapest proxy for "the DM table changed".
  ref.watch(lastDmMessageProvider);
  try {
    return await storage_api.countAllDmMessages();
  } catch (_) {
    return 0;
  }
});

/// Settings > Devices: counts that fully converge across a person's devices,
/// so opening this on two of them shows at a glance whether they agree.
class SyncCheckCard extends ConsumerWidget {
  const SyncCheckCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(myDevicesProvider);
    final devicesOnline = devices.where((d) => d.online).length;
    final dmCount = ref.watch(_dmMessageCountProvider);
    final hollow = HollowTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SettingsRow(
          title: 'Sync check',
          subtitle: "Open this on each device. When they're in sync, the "
              'numbers match.',
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
          child: Wrap(
            spacing: HollowSpacing.xl,
            runSpacing: HollowSpacing.sm,
            children: [
              _Count('Friends', '${ref.watch(sortedFriendsProvider).length}'),
              _Count('Servers', '${ref.watch(serverListProvider).length}'),
              _Count(
                'Direct messages',
                dmCount.maybeWhen(data: (n) => '$n', orElse: () => '…'),
              ),
              _Count(
                'Devices online',
                '$devicesOnline / ${devices.length}',
                // Green only when every sibling is online, so the colour
                // answers "are we converging right now?".
                valueColor: devices.length > 1
                    ? (devicesOnline == devices.length
                        ? hollow.success
                        : hollow.warning)
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Count extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _Count(this.label, this.value, {this.valueColor});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
        ),
        Text(
          value,
          style: HollowTypography.mono.copyWith(
            color: valueColor ?? hollow.textPrimary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
