import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:hollow/src/core/device_proof_copy.dart';
import 'package:hollow/src/core/providers/device_proof_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/dialogs/restore_chooser.dart';

/// Narrower than this, the button sits under the words.
const double _stackBelow = 520;

const double _kIcon = 16;

/// Classic's pointer to the restore chooser, under the status strips: Classic
/// has no Home, where Dock and the phone list these servers. Shown while a
/// server waits for the person's pick; no dismiss, since picking (or "I don't
/// know") is always open to them and is what ends it.
class RestorePickBanner extends ConsumerWidget {
  const RestorePickBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final restores = ref.watch(restoreChoicesProvider).valueOrNull;
    final waiting = [
      for (final c in restores?.servers ?? const [])
        if (restoreNeedsChoice(c)) c.serverId,
    ];
    if (waiting.isEmpty) return const SizedBox.shrink();

    final hollow = HollowTheme.of(context);
    final first = waiting.first;
    final name = ref.watch(serverListProvider.select((s) => s[first]?.name)) ??
        kRestoreServerFallback;
    final headline = waiting.length == 1
        ? restorePickTitle(name)
        : restorePickManyTitle(waiting.length);

    final open = HollowButton.outline(
      compact: true,
      onPressed: () => showRestoreChooser(context, serverId: first),
      child: const Text(kRestorePickAction),
    );

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(headline,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: HollowTypography.label.copyWith(color: hollow.textPrimary)),
        Text(kRestorePickBody,
            style: HollowTypography.bodySmall
                .copyWith(color: hollow.textSecondary)),
      ],
    );

    return Semantics(
      container: true,
      liveRegion: true,
      label: '$headline. $kRestorePickBody',
      child: Container(
        key: const ValueKey('restore-pick-banner'),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.lg,
          vertical: HollowSpacing.sm,
        ),
        decoration: BoxDecoration(
          // The quiet grey of an info notice: a step to take, never an alarm.
          color: hollow.noticeSurface(hollow.textSecondary),
          border: Border(bottom: BorderSide(color: hollow.border)),
        ),
        child: LayoutBuilder(builder: (context, box) {
          final stacked = box.maxWidth < _stackBelow;
          final row = Row(
            children: [
              Icon(LucideIcons.history,
                  size: _kIcon, color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(child: text),
              if (!stacked) ...[
                const SizedBox(width: HollowSpacing.md),
                open,
              ],
            ],
          );
          if (!stacked) return row;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              row,
              const SizedBox(height: HollowSpacing.sm),
              Padding(
                padding: const EdgeInsets.only(left: _kIcon + HollowSpacing.sm),
                child: open,
              ),
            ],
          );
        }),
      ),
    );
  }
}
