import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/showcase_board.dart';
import 'package:hollow/src/core/providers/banner_provider.dart';
import 'package:hollow/src/core/providers/profile_anim_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/profile_identity_column.dart';
import 'package:hollow/src/ui/components/showcase_blocks.dart';
import 'package:hollow/src/ui/dialogs/showcase_editor.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_settings_tab.dart';

/// The profile on a phone: the same identity column as the desktop dialog at
/// touch density, Message right under who this is, then About, then the
/// showcase's boards stacked, left first.
void showMobileProfileSheet(
  BuildContext context, {
  required String peerId,
  String? role,
  List<crdt_api.LabelFfi>? labels,
  String? serverId,
}) {
  showHollowSheet(
    context: context,
    scrollControlled: true,
    // The handle rides over the banner, so the art meets the sheet's top.
    handle: false,
    // Room above the sheet to tap it closed.
    maxHeightFactor: 0.9,
    builder: (_) => MobileProfileSheet(
      peerId: peerId,
      role: role,
      labels: labels,
      serverId: serverId,
    ),
  );
}

class MobileProfileSheet extends ConsumerWidget {
  final String peerId;
  final String? role;
  final List<crdt_api.LabelFfi>? labels;
  final String? serverId;

  const MobileProfileSheet({
    super.key,
    required this.peerId,
    this.role,
    this.labels,
    this.serverId,
  });

  void _openChat(BuildContext context, WidgetRef ref) {
    final nav = Navigator.of(context, rootNavigator: true);
    final container = ProviderScope.containerOf(context, listen: false);
    Navigator.of(context).pop();
    ref.read(selectedPeerProvider.notifier).state = peerId;
    nav
        .push(
          hollowMobileRoute(
            settings: const RouteSettings(name: MobileChatRoute.routeName),
            builder: (_) => MobileChatRoute(peerId: peerId),
          ),
        )
        .then((_) {
          // The sheet is gone by now, so this uses the captured container rather
          // than `ref`.
          if (container.read(selectedPeerProvider) == peerId) {
            container.read(selectedPeerProvider.notifier).state = null;
          }
        });
  }

  void _editProfile(BuildContext context) {
    final nav = Navigator.of(context, rootNavigator: true).context;
    Navigator.of(context).pop();
    openMobileProfileSettings(nav);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final board = ShowcaseBoard.decode(
      ref.watch(profileProvider.select((p) => p[peerId]?.showcaseBoard)),
    );
    final hasBanner =
        (watchAnimatedBanner(ref, peerId) ??
                ref.watch(bannerProvider(peerId)).valueOrNull)
            ?.isNotEmpty ??
        false;

    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          return Stack(
            children: [
              SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ProfileIdentityColumn(
                      peerId: peerId,
                      role: role,
                      labels: labels,
                      serverId: serverId,
                      density: ProfileCardDensity.touch,
                      width: width,
                      dismissHost: () => Navigator.of(context).pop(),
                      onMessage: () => _openChat(context, ref),
                      onEditProfile: () => _editProfile(context),
                      onEditShowcase: () =>
                          showShowcaseEditorDialog(context),
                    ),
                    if (!board.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          HollowSpacing.lg,
                          HollowSpacing.sm,
                          HollowSpacing.lg,
                          HollowSpacing.xxl,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const HollowDivider(),
                            const SizedBox(height: HollowSpacing.xl),
                            ShowcaseBoardView(
                              peerId: peerId,
                              board: board,
                              columns: 1,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              // Opaque to hits, so a drag that starts on the handle moves the
              // sheet instead of scrolling the profile under it.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: HollowSpacing.xl,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  child: Center(
                    child: Container(
                      width: 32,
                      height: 4,
                      decoration: BoxDecoration(
                        color: hasBanner
                            ? Colors.white.withValues(
                                alpha: 0.7,
                              ) // design-ignore: handle on banner art
                            : hollow.border,
                        borderRadius: BorderRadius.circular(HollowRadius.pill),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
