import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/greeting.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/home_setup_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/dialogs/new_message_dialog.dart';
import 'package:hollow/src/ui/shell/home_inbox.dart';
import 'package:hollow/src/ui/shell/home_rail.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Home in Dock mode: an inbox, and one side panel for what is happening now.
///
/// Brief (design language 5.1). Job: see what needs me and get back into my
/// conversations. Focal point: the conversation list, the only place every DM
/// is listed in Dock mode. Primary action: New message. Left out: your own
/// profile (the user bar), stats and relay load (Settings), the peer id, and
/// connection state unless it is wrong (the status banner).
class HomeDashboard extends StatelessWidget {
  const HomeDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    // An app pane, not a page: both regions are anchored to the window's edges
    // and share the width between them, never centred with gutters beside them
    // (design language 5.2).
    return ColoredBox(
      color: hollow.background,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showRail = homeShowsRail(constraints.maxWidth);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Expanded(child: _HomeMain()),
              if (showRail)
                // The same side panel as a server's member list: chrome, a
                // hairline on its inner edge, full height.
                Container(
                  width: kHomeRailWidth,
                  decoration: BoxDecoration(
                    color: hollow.surface,
                    border: Border(left: BorderSide(color: hollow.border)),
                  ),
                  padding: const EdgeInsets.only(
                    top: HollowSpacing.xl,
                    left: HollowSpacing.sm,
                    right: HollowSpacing.sm,
                  ),
                  child: const HomeRail(),
                ),
            ],
          );
        },
      ),
    );
  }
}

const double kHomeRailWidth = 300;

/// Below this width the rail leaves rather than squeezing the inbox under a
/// readable width.
const double kHomeRailBreakpoint = 840;

bool homeShowsRail(double available) =>
    !available.isFinite || available >= kHomeRailBreakpoint;

class _HomeMain extends ConsumerStatefulWidget {
  const _HomeMain();

  @override
  ConsumerState<_HomeMain> createState() => _HomeMainState();
}

class _HomeMainState extends ConsumerState<_HomeMain> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final hasFriends = ref.watch(sortedFriendsProvider).isNotEmpty;
    final firstRun = homeIsFirstRun(ref);
    final showSetup = homeShowsSetup(ref);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Fixed above the scroll, so the scrollbar starts below it and the
        // search and New message stay in reach however far the list goes.
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HollowSpacing.xl + kHomeRowInset,
            HollowSpacing.xl,
            HollowSpacing.xl + kHomeRowInset,
            0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: HomeGreeting(firstRun: firstRun)),
                  if (hasFriends) ...[
                    const SizedBox(width: HollowSpacing.md),
                    SizedBox(
                      width: _kSearchWidth,
                      child: HollowTextField(
                        isDense: true,
                        hintText: 'Search conversations',
                        prefixIcon: Icon(LucideIcons.search,
                            size: 16, color: hollow.textTertiary),
                        onChanged: (v) => setState(() => _query = v),
                      ),
                    ),
                    const SizedBox(width: HollowSpacing.sm),
                    HollowButton.filled(
                      onPressed: () => showNewMessageDialog(context),
                      icon: const Icon(LucideIcons.plus, size: 16),
                      child: const Text('New message'),
                    ),
                  ],
                ],
              ),
              if (firstRun) ...[
                const SizedBox(height: HollowSpacing.xs),
                Text(
                  kHomeFirstRunLine,
                  style:
                      HollowTypography.body.copyWith(color: hollow.textSecondary),
                ),
              ],
            ],
          ),
        ),
        // One scroll for everything below: the attention strip and the
        // checklist are variable height, and an Expanded list under them would
        // overflow once the interface zoom shortens the viewport. It spans the
        // pane, padding inside, so its bar sits on the pane's edge.
        Expanded(
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding:
                    const EdgeInsets.symmetric(horizontal: HollowSpacing.xl),
                sliver: SliverMainAxisGroup(
                  slivers: [
                    SliverToBoxAdapter(
                      // Inset by the rows' own padding so every heading, card
                      // and row text shares one left edge.
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: kHomeRowInset),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const HomeAttention(),
                            if (showSetup) const HomeSetupChecklist(),
                            const SizedBox(height: HollowSpacing.xl),
                          ],
                        ),
                      ),
                    ),
                    HomeConversations(query: _query),
                    const SliverToBoxAdapter(
                        child: SizedBox(height: HollowSpacing.xl)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// No friend and no server yet.
bool homeIsFirstRun(WidgetRef ref) =>
    ref.watch(sortedFriendsProvider).isEmpty &&
    ref.watch(serverListProvider).isEmpty;

/// The checklist stays until there is a friend AND a server, or it is hidden.
bool homeShowsSetup(WidgetRef ref) {
  final setup = ref.watch(homeSetupProvider);
  return setup.loaded &&
      !setup.hidden &&
      (ref.watch(sortedFriendsProvider).isEmpty ||
          ref.watch(serverListProvider).isEmpty);
}

const kHomeFirstRunLine =
    'Your identity lives on this device. A few steps make it yours.';

/// Home's title: a greeting by the local clock and the chosen name, or the
/// welcome on a first run.
class HomeGreeting extends ConsumerStatefulWidget {
  final bool firstRun;
  const HomeGreeting({super.key, required this.firstRun});

  @override
  ConsumerState<HomeGreeting> createState() => _HomeGreetingState();
}

class _HomeGreetingState extends ConsumerState<HomeGreeting> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  /// One wake-up at the next block boundary, never a periodic clock.
  void _schedule() {
    final now = DateTime.now();
    _timer = Timer(nextGreetingChange(now).difference(now), () {
      if (!mounted) return;
      setState(() {});
      _schedule();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final localId = ref.watch(identityProvider).peerId;
    final name = (localId == null
            ? null
            : ref.watch(profileProvider
                .select((p) => chosenNameForPeer(p[localId], localId)))) ??
        kNamelessGreeting;
    return Semantics(
      header: true,
      child: Text(
        widget.firstRun
            ? 'Welcome to Hollow, $name'
            : '${greetingFor(DateTime.now())}, $name',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: HollowTypography.heading.copyWith(color: hollow.textPrimary),
      ),
    );
  }
}

/// A conversation row's own horizontal padding, which the rest of Home is inset
/// by so the text edge is shared.
const double kHomeRowInset = HollowSpacing.sm;

const double _kSearchWidth = 240;
