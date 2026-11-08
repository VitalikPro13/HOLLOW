import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/relay_denial_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/storage_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/server_settings/server_settings_catalog.dart';
import 'package:hollow/src/ui/settings/about_section.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/storage_section.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Narrower than this (at text scale 1), the actions go under the words.
const double _actionsBesideFrom = 900;

const double _kIcon = 16;

/// The most of the screen's height the notice takes before it scrolls.
const double _maxHeightShare = 0.45;

/// How long "Try again" shows busy; the notice goes away on its own if the relay
/// carries the server again.
const Duration _askingFor = Duration(seconds: 4);

/// The Terms as a refusal opens them: under a relay Hollow does not run, a warning
/// first that these Terms are not that relay's rules.
void showRelayTerms(BuildContext context, String domain, {bool? touch}) {
  showLegalDocument(
    context,
    title: 'Terms of Use',
    assetPath: 'legal/TERMS_OF_USE.md',
    touch: touch,
    notice: domain == kDefaultRelayDomain
        ? null
        : ForeignRelayTermsNotice(
            domain: domain,
            // On the document's own text edge: the sheet's, else the dialog's.
            inset: touch ?? SettingsDensity.touchOf(context)
                ? HollowSpacing.lg
                : HollowSpacing.xl,
          ),
  );
}

/// Where a server (or meeting) this relay refuses keeps its composer: the reason,
/// the relay, and what the person can still do. History, search and files stay
/// readable above it; nothing here sends.
class RelayDeniedNotice extends ConsumerStatefulWidget {
  final String serverId;

  /// A meeting (`conf:{id}`): no leave or clear here, the meeting view owns those.
  final bool meeting;

  /// Phone sizing.
  final bool touch;

  const RelayDeniedNotice({
    super.key,
    required this.serverId,
    this.meeting = false,
    this.touch = false,
  });

  @override
  ConsumerState<RelayDeniedNotice> createState() => _RelayDeniedNoticeState();
}

class _RelayDeniedNoticeState extends ConsumerState<RelayDeniedNotice> {
  Timer? _asking;

  @override
  void dispose() {
    _asking?.cancel();
    super.dispose();
  }

  void _tryAgain() {
    retryRelayDenials();
    setState(() => _asking = Timer(_askingFor, () {
          if (mounted) setState(() => _asking = null);
        }));
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final touch = widget.touch;
    final domain = ref.watch(relayDomainProvider);
    final text = (touch ? HollowTypography.body : HollowTypography.bodySmall)
        .copyWith(color: hollow.textPrimary);
    final quiet =
        HollowTypography.caption.copyWith(color: hollow.textSecondary);
    final scaler = MediaQuery.textScalerOf(context);
    final relayActions = <Widget>[
      HollowButton.ghost(
        compact: true,
        touch: touch,
        loading: _asking != null,
        onPressed: _tryAgain,
        child: const Text('Try again'),
      ),
      HollowButton.ghost(
        compact: true,
        touch: touch,
        semanticLabel: 'Read the Terms of use',
        onPressed: () => showRelayTerms(context, domain, touch: touch),
        child: const Text('Terms of use'),
      ),
    ];
    final localActions = <Widget>[
      if (!widget.meeting) ...[
        HollowButton.ghost(
          compact: true,
          touch: touch,
          onPressed: () => confirmAndClearServerMessages(
            context,
            ref.read(storageActionsProvider),
            serverId: widget.serverId,
            serverName: ref.read(serverListProvider)[widget.serverId]?.name,
          ),
          child: const Text('Clear messages'),
        ),
        HollowButton.ghost(
          compact: true,
          touch: touch,
          onPressed: () => confirmLeaveServer(context, ref, widget.serverId),
          child: const Text('Leave server'),
        ),
      ],
    ];
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        key: const ValueKey('relay-denied-notice'),
        width: double.infinity,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * _maxHeightShare,
        ),
        decoration: BoxDecoration(
          color: hollow.noticeSurface(hollow.error),
          border: Border(top: BorderSide(color: hollow.border)),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.lg,
            vertical: HollowSpacing.md,
          ),
          child: LayoutBuilder(builder: (context, box) {
            // Wide, the actions sit on the trailing edge; narrow, under the words.
            final wide = box.maxWidth >= scaler.scale(_actionsBesideFrom);
            final words = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                    widget.meeting ? kMeetingDeniedText : kServerDeniedText,
                    style: text),
                const SizedBox(height: HollowSpacing.xs),
                Text(kDeniedKeepsText, style: quiet),
                const SizedBox(height: HollowSpacing.xxs),
                Text(domain,
                    style: HollowTypography.monoSmall
                        .copyWith(color: hollow.textTertiary)),
              ],
            );
            // Breaks between the relay's pair and the device's pair first, so a
            // narrow screen never leaves one button on a line of its own.
            Widget pair(List<Widget> buttons) => Wrap(
                  spacing: HollowSpacing.sm,
                  runSpacing: HollowSpacing.xs,
                  children: buttons,
                );
            final row = Wrap(
              spacing: HollowSpacing.sm,
              runSpacing: HollowSpacing.xs,
              children: [
                pair(relayActions),
                if (localActions.isNotEmpty) pair(localActions),
              ],
            );
            // The icon sits on the first line, at any text size.
            final firstLine = scaler.scale(text.fontSize!) * text.height!;
            return Row(
              crossAxisAlignment:
                  wide ? CrossAxisAlignment.center : CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: wide ? null : firstLine,
                  child: Center(
                    widthFactor: 1,
                    child: Icon(LucideIcons.ban,
                        size: scaler.scale(_kIcon), color: hollow.error),
                  ),
                ),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: wide
                      ? words
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            words,
                            const SizedBox(height: HollowSpacing.sm),
                            // The labels sit on the text edge, the hover past it
                            // (a compact button's own inset).
                            HollowBleed(
                                horizontal: HollowSpacing.md, child: row),
                          ],
                        ),
                ),
                if (wide) ...[
                  const SizedBox(width: HollowSpacing.lg),
                  row,
                ],
              ],
            );
          }),
        ),
      ),
    );
  }
}

/// At the top of the Terms when they were opened for a relay Hollow does not run.
class ForeignRelayTermsNotice extends StatelessWidget {
  final String domain;

  /// Left and right, matching the document below.
  final double inset;

  const ForeignRelayTermsNotice(
      {super.key, required this.domain, this.inset = HollowSpacing.lg});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final style =
        HollowTypography.bodySmall.copyWith(color: hollow.textPrimary);
    final firstLine = scaler.scale(style.fontSize!) * style.height!;
    return Container(
      key: const ValueKey('foreign-relay-terms-notice'),
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: inset,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: hollow.noticeSurface(hollow.warning),
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: firstLine,
            child: Center(
              widthFactor: 1,
              child: Icon(LucideIcons.triangleAlert,
                  size: scaler.scale(_kIcon), color: hollow.warning),
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                  text: domain,
                  style: HollowTypography.monoSmall
                      .copyWith(color: hollow.textPrimary),
                ),
                const TextSpan(text: kForeignRelayTermsTail),
              ]),
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}
