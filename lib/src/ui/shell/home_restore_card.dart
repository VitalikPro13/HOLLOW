import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/services/phrase_restore.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/recovery.dart' as recovery_api;
import 'package:hollow/src/rust/api/roster.dart' as roster_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';

/// Home's "Finish restoring your identity" after a Welcome phrase restore
/// (PHRASE_RESTORE_DESIGN 5, 6.2): what comes back on its own, what needs the
/// person, and, while nobody else knows this identity yet, a way to set it
/// aside when the words were wrong.

/// The setting that holds the restore mark's time once the card was closed, so a
/// later restore on this database shows its own card.
const kRestoreCardDoneKey = 'welcome_restore_card_done';

/// The card's state: null when it does not show.
typedef RestoreCardState = ({
  int atMs,
  PhraseRestoreBranch branch,
  bool noWait,
  bool maySetAside,
});

/// Whether the card shows: a restore mark of a branch this build knows, inside
/// its window, not closed for this mark.
@visibleForTesting
bool restoreCardShows(roster_api.WelcomeRestoreState? mark,
        {required DateTime now, String? doneFor}) =>
    mark != null &&
    phraseRestoreBranchFrom(mark.branch) != null &&
    now.millisecondsSinceEpoch - mark.atMs <
        kWelcomeRestoreWindow.inMilliseconds &&
    doneFor != '${mark.atMs}';

/// Whether "Type my phrase again" is offered: Rust's gate, and at once gone
/// here when a friend accepts or a server holds us (someone else knows this
/// identity from then on).
@visibleForTesting
bool setAsideOffered(
        {required bool rustAllows,
        required bool acceptedFriend,
        required bool holdsServer}) =>
    rustAllows && !acceptedFriend && !holdsServer;

final restoreCardProvider =
    FutureProvider.autoDispose<RestoreCardState?>((ref) async {
  final acceptedFriend = ref.watch(friendsProvider
      .select((m) => m.values.any((f) => f.status == 'accepted')));
  final holdsServer = ref.watch(keptServersProvider.select((m) => m.isNotEmpty));
  final mark = await roster_api.welcomeRestoreState();
  if (mark == null) return null;
  final doneFor = await storage_api.loadSetting(key: kRestoreCardDoneKey);
  if (!restoreCardShows(mark, now: DateTime.now(), doneFor: doneFor)) {
    return null;
  }
  // An unread gate offers no set-aside; the guidance shows either way.
  final rustAllows =
      await identity_api.maySetAsideThisIdentity().catchError((_) => false);
  return (
    atMs: mark.atMs,
    branch: phraseRestoreBranchFrom(mark.branch)!,
    noWait: mark.noWait,
    maySetAside: setAsideOffered(
        rustAllows: rustAllows,
        acceptedFriend: acceptedFriend,
        holdsServer: holdsServer),
  );
});

/// Whether "Type my phrase again" did not run at this launch: Rust says it once,
/// so it is read once per run of the app.
final setAsideFailedProvider = FutureProvider<bool>(
    (ref) => recovery_api.takeSetAsideFailure().catchError((_) => false));

/// The card's line after a set-aside that did not run: try again while the
/// card still offers it, else why it no longer can.
@visibleForTesting
String setAsideFailureLine({required bool maySetAside}) => maySetAside
    ? "Hollow couldn't set this identity aside. Try again."
    : kSetAsideRefusedText;

/// The lines of the card, by branch.
@visibleForTesting
List<String> restoreCardLines(PhraseRestoreBranch branch,
        {required bool noWait}) =>
    [
      if (branch == PhraseRestoreBranch.admit) ...[
        'Add your friends again. They accept you right away, and most servers '
            'you share with them follow.',
        'If a request still shows as sent, your friend gets it the next time '
            'they open Hollow.',
      ] else ...[
        'Add your friends again. They accept you right away.',
        'Hollow asks the members of each server you own how it looked before '
            "you lost your device. If their answers don't agree, you choose.",
      ],
      'A server on another relay, or one none of your friends are in, needs an '
          'invite link from a member.',
      if (branch == PhraseRestoreBranch.admit)
        'If someone else might have your old device, remove it in Settings, '
            'under Devices.',
      if (branch == PhraseRestoreBranch.recover && noWait)
        'A device restored from a backup now joins only when you approve it. '
            'You can change this in Settings, under Security.',
      'If a friend gets a new friend request from you instead, these words may '
          'have made a different identity.',
    ];

/// Restarts the app once the identity is set aside; tests stand in for it.
@visibleForTesting
Future<void> Function() relaunchAfterSetAside = relaunchApp;

class HomeRestoreCard extends ConsumerWidget {
  /// Phone sizing: larger type, full-size buttons.
  final bool touch;

  const HomeRestoreCard({super.key, this.touch = false});

  Future<void> _done(WidgetRef ref, int atMs) async {
    await storage_api.saveSetting(key: kRestoreCardDoneKey, value: '$atMs');
    ref.invalidate(restoreCardProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(restoreCardProvider).valueOrNull;
    if (state == null) return const SizedBox.shrink();
    final setAsideFailed =
        ref.watch(setAsideFailedProvider).valueOrNull ?? false;
    final hollow = HollowTheme.of(context);
    final lines = restoreCardLines(state.branch, noWait: state.noWait);
    final text = (touch ? HollowTypography.body : HollowTypography.bodySmall)
        .copyWith(color: hollow.textSecondary);
    return Padding(
      padding: const EdgeInsets.only(top: HollowSpacing.xl),
      child: Container(
        padding: const EdgeInsets.all(HollowSpacing.lg),
        decoration: BoxDecoration(
          color: hollow.elevated,
          borderRadius:
              BorderRadius.circular(touch ? hollow.radiusLg : hollow.radiusMd),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Finish restoring your identity',
              style: (touch ? HollowTypography.subheading : HollowTypography.body)
                  .copyWith(
                      color: hollow.textPrimary, fontWeight: FontWeight.w500),
            ),
            if (setAsideFailed) ...[
              const SizedBox(height: HollowSpacing.sm),
              Text(setAsideFailureLine(maySetAside: state.maySetAside),
                  style: text.copyWith(color: hollow.error)),
            ],
            for (final line in lines) ...[
              const SizedBox(height: HollowSpacing.sm),
              Text(line, style: text),
            ],
            const SizedBox(height: HollowSpacing.md),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: HollowSpacing.sm,
              runSpacing: HollowSpacing.sm,
              children: [
                if (state.maySetAside)
                  HollowButton.ghost(
                    compact: !touch,
                    onPressed: () => showSetAsideDialog(context, ref),
                    child: const Text('Type my phrase again'),
                  ),
                _DoneButton(touch: touch, onDone: () => _done(ref, state.atMs)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DoneButton extends StatefulWidget {
  final bool touch;
  final Future<void> Function() onDone;
  const _DoneButton({required this.touch, required this.onDone});

  @override
  State<_DoneButton> createState() => _DoneButtonState();
}

class _DoneButtonState extends State<_DoneButton> {
  bool _busy = false;

  Future<void> _press() async {
    setState(() => _busy = true);
    try {
      await widget.onDone();
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, friendlyError(e), type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => HollowButton.outline(
        compact: !widget.touch,
        loading: _busy,
        onPressed: _busy ? null : _press,
        child: const Text('Done'),
      );
}

/// Said when Rust's gate closed since the card read it (a friend accepted, a
/// server or a pending join holds us).
const kSetAsideRefusedText =
    "Someone else knows this identity now, so Hollow can't set it aside.";

/// "Type your phrase again?": sets this identity aside (nothing is deleted)
/// and restarts at Welcome. A phone closes instead and opens there. A failure
/// reads the gate again, so a refusal says so and the card stops offering it.
Future<void> showSetAsideDialog(BuildContext context, WidgetRef ref) async {
  await showHollowConfirm(
    context: context,
    title: 'Type your phrase again?',
    message: 'Hollow sets this identity aside and starts over. Nothing is '
        'deleted. If these words were right after all, type them again.',
    confirmLabel: 'Set aside',
    onConfirm: () async {
      try {
        await identity_api.setAsideThisIdentity();
      } catch (_) {
        final allowed = await identity_api
            .maySetAsideThisIdentity()
            .catchError((_) => true);
        ref.invalidate(restoreCardProvider);
        throw FriendlyException(setAsideFailureLine(maySetAside: allowed));
      }
      await relaunchAfterSetAside();
    },
  );
}
