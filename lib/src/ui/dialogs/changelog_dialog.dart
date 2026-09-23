import 'package:flutter/material.dart';
import 'package:hollow/src/core/changelog.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The bundled changelog, opened on [start] with Older / Newer to walk it.
void showChangelogDialog(
    BuildContext context, List<ChangelogRelease> releases, int start) {
  if (releases.isEmpty) return;
  showHollowDialog(
    context: context,
    builder: (_) => _ChangelogDialog(releases: releases, start: start),
  );
}

class _ChangelogDialog extends StatefulWidget {
  final List<ChangelogRelease> releases;
  final int start;
  const _ChangelogDialog({required this.releases, required this.start});

  @override
  State<_ChangelogDialog> createState() => _ChangelogDialogState();
}

class _ChangelogDialogState extends State<_ChangelogDialog> {
  late int _index = widget.start.clamp(0, widget.releases.length - 1);

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final release = widget.releases[_index];
    final body = HollowTypography.body.copyWith(color: hollow.textPrimary);

    return HollowDialog(
      title: "What's new in ${release.version}",
      showClose: true,
      width: 560,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            release.title,
            style: HollowTypography.bodySmall
                .copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.lg),
          Flexible(
            child: SingleChildScrollView(
              // A new key per release, so switching starts at the top.
              key: ValueKey(release.version),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final note in release.notes) ...[
                    Text(note, style: body),
                    const SizedBox(height: HollowSpacing.lg),
                  ],
                  for (final section in release.sections) ...[
                    HollowSectionHeader(section.name, dense: true),
                    for (final item in section.items)
                      Padding(
                        padding:
                            const EdgeInsets.only(bottom: HollowSpacing.xs),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('•',
                                style: body.copyWith(
                                    color: hollow.textTertiary)),
                            const SizedBox(width: HollowSpacing.sm),
                            Expanded(child: Text(item, style: body)),
                          ],
                        ),
                      ),
                    const SizedBox(height: HollowSpacing.lg),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
      leadingActions: [
        HollowButton.ghost(
          onPressed: _index < widget.releases.length - 1
              ? () => setState(() => _index++)
              : null,
          icon: const Icon(LucideIcons.chevronLeft, size: 16),
          child: const Text('Older'),
        ),
        HollowButton.ghost(
          onPressed: _index > 0 ? () => setState(() => _index--) : null,
          child: const Text('Newer'),
        ),
      ],
    );
  }
}
