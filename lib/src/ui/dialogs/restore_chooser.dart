import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/device_proof_copy.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/peer_id_label.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/roster_provider.dart';
import 'package:hollow/src/core/time_labels.dart';
import 'package:hollow/src/core/providers/device_proof_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/device_proof.dart' as dp;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/chat/server_recovery_notices.dart'
    show serverMemberKnownName;
import 'package:hollow/src/ui/components/hollow_toast.dart';

/// The restore chooser after a phrase recovery (DEVICE_PROOF_DESIGN 8.4): per
/// server, what its members remember, and the person's pick. A normal screen,
/// shown often, never an alarm; closing it chooses nothing. [fresh]: opened
/// for a device the roster had not counted yet (see [RestoreChooserAsk]).
Future<void> showRestoreChooser(BuildContext context, {bool fresh = false}) =>
    showHollowDialog<void>(
      context: context,
      builder: (_) => RestoreChooserDialog(fresh: fresh),
    );

/// How often the chooser re-reads the restores while it is open.
const kRestorePoll = Duration(seconds: 2);

/// The "I don't know" choice, apart from every checkpoint id.
const _dontKnow = '';

/// A restore point's date as a sentence reads it: the year only when it is not
/// this one.
String restoreDateLabel(BuildContext context, DateTime at, {DateTime? now}) {
  final l = MaterialLocalizations.of(context);
  return '${calendarDateLabel(at, now: now)}, '
      '${l.formatTimeOfDay(TimeOfDay.fromDateTime(at))}';
}

class RestoreChooserDialog extends ConsumerStatefulWidget {
  final bool fresh;
  const RestoreChooserDialog({super.key, this.fresh = false});

  @override
  ConsumerState<RestoreChooserDialog> createState() =>
      _RestoreChooserDialogState();
}

class _RestoreChooserDialogState extends ConsumerState<RestoreChooserDialog> {
  Timer? _poll;

  /// Per server: the point picked in a list, or [_dontKnow].
  final Map<String, String> _picked = {};

  /// Servers whose one clear answer the person passed over for the list.
  final Set<String> _another = {};

  /// The stage each server was in at the last read.
  final Map<String, dp.RestoreStage> _stages = {};

  /// Whether any server was listed while the chooser was open.
  bool _sawServers = false;
  String? _restoring;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(kRestorePoll, (_) {
      if (mounted) ref.invalidate(restoreChoicesProvider);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// A pick counts only for a point still on screen, in the stage it was made.
  void _onRestores(dp.Restores r) {
    if (r.servers.isNotEmpty) _sawServers = true;
    final byId = {for (final c in r.servers) c.serverId: c};
    _picked.removeWhere((sid, cp) {
      final c = byId[sid];
      return c == null ||
          c.stage != _stages[sid] ||
          (cp != _dontKnow && !_shownPoints(c).any((p) => p.cp == cp));
    });
    _another.removeWhere(
        (sid) => byId[sid] == null || byId[sid]!.stage != _stages[sid]);
    _stages
      ..clear()
      ..addAll({for (final c in r.servers) c.serverId: c.stage});
  }

  static List<dp.RestorePoint> _shownPoints(dp.RestoreChoices c) =>
      c.points.isNotEmpty ? c.points : [?c.pick];

  Future<void> _restore(String serverId, String server, String? cp) async {
    if (_restoring != null) return;
    setState(() => _restoring = serverId);
    try {
      await dp.chooseRestore(serverId: serverId, cp: cp);
      ref.invalidate(restoreChoicesProvider);
    } catch (e) {
      if (mounted) {
        debugPrint('[HOLLOW] choose_restore failed: ${friendlyError(e)}');
        HollowToast.show(context, restoreFailed(server),
            type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _restoring = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<dp.Restores>>(restoreChoicesProvider, (_, next) {
      final r = next.valueOrNull;
      if (r != null) setState(() => _onRestores(r));
    });
    final async = ref.watch(restoreChoicesProvider);
    final restores = async.valueOrNull;
    if (restores?.servers.isNotEmpty ?? false) _sawServers = true;
    final compact = HollowDialogSurface.isCompact(context);
    final body = HollowTypography.body
        .copyWith(color: HollowTheme.of(context).textPrimary);
    final Widget content;
    if (restores == null && async.hasError) {
      content = HollowEmptyState(
        dense: true,
        title: "Hollow couldn't check your servers",
        action: HollowButton.ghost(
          onPressed: () => ref.invalidate(restoreChoicesProvider),
          child: const Text('Try again'),
        ),
      );
    } else if (restores == null) {
      content = const Align(
        alignment: AlignmentDirectional.centerStart,
        child: HollowSpinner.medium(delayed: true),
      );
    } else if (restores.servers.isEmpty) {
      final unknown = restoreUnknownShown(restores,
          fresh: widget.fresh,
          holdsServers: ref.watch(serverListProvider).isNotEmpty);
      content = Text(
        unknown
            ? kRestoreUnknownServers
            : _sawServers
                ? restoreDone('Every server')
                : kRestoreNothing,
        style: body,
      );
    } else {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < restores.servers.length; i++) ...[
            if (i > 0) const SizedBox(height: HollowSpacing.xl),
            _server(context, restores.servers[i], compact),
          ],
        ],
      );
    }
    return HollowDialog(
      title: kRestoreTitle,
      width: 480,
      showClose: true,
      // A phone's rows and buttons take touch size.
      content: HollowButtonTouchScope(touch: compact, child: content),
    );
  }

  String? _date(BuildContext context, dp.RestorePoint p) => p.dateMs == null
      ? null
      : restoreDateLabel(
          context, DateTime.fromMillisecondsSinceEpoch(p.dateMs!));

  /// The confirming members by the name we hold, else the name their own card
  /// gives, else "a member" with the end of the id.
  List<String> _supporters(dp.RestoreChoices c, dp.RestorePoint p) {
    final cards = p.namedByNames;
    String? card(int i) {
      final name = i < cards.length ? cards[i] : null;
      return name == null || name.isEmpty ? null : name;
    }

    return [
      for (final (i, m) in p.namedBy.indexed)
        serverMemberKnownName(ref, c.serverId, m) ??
            card(i) ??
            memberFallback(shortPeerLabel(m)),
    ];
  }

  Widget _server(BuildContext context, dp.RestoreChoices c, bool compact) {
    final hollow = HollowTheme.of(context);
    final server = ref.watch(
            serverListProvider.select((s) => s[c.serverId]?.name)) ??
        kRestoreServerFallback;
    final body = HollowTypography.body.copyWith(color: hollow.textPrimary);
    final secondary =
        HollowTypography.bodySmall.copyWith(color: hollow.textSecondary);
    final busy = _restoring == c.serverId;
    final locked = _restoring != null;

    Widget waiting(String text) => Row(
          children: [
            const HollowSpinner(),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(child: Text(text, style: body)),
          ],
        );

    final pick = c.pick;
    switch (c.stage) {
      case dp.RestoreStage.checking:
        return waiting(restoreChecking(server));
      case dp.RestoreStage.waiting:
        return waiting(restoreWaiting(server));
      case dp.RestoreStage.nobodyReachable:
        return Text(restoreNobody(server), style: body);
      case dp.RestoreStage.waitingForMember:
        return Text(restoreWaitingForMember(server),
            key: ValueKey('restore-wait-${c.serverId}'), style: body);
      case dp.RestoreStage.done:
        return Text(restoreDone(server), style: body);
      case dp.RestoreStage.pick when pick != null && !_another.contains(c.serverId):
        final date = _date(context, pick);
        final names = _supporters(c, pick);
        return Column(
          key: ValueKey('restore-pick-${c.serverId}'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              date == null
                  ? restorePickBeforeUpdate(server, names)
                  : restorePick(server, date, names),
              style: body,
            ),
            const SizedBox(height: HollowSpacing.xs),
            Text(kRestorePickNote, style: secondary),
            const SizedBox(height: HollowSpacing.md),
            HollowDialogActionRow(
              leadingCount: 0,
              children: [
                HollowButton.ghost(
                  onPressed: locked
                      ? null
                      : () => setState(() => _another.add(c.serverId)),
                  child: const Text('Choose another point'),
                ),
                HollowButton.outline(
                  loading: busy,
                  onPressed:
                      locked ? null : () => _restore(c.serverId, server, pick.cp),
                  child: const Text('Restore'),
                ),
              ],
            ),
          ],
        );
      case dp.RestoreStage.pick:
      case dp.RestoreStage.points:
      case dp.RestoreStage.onlyOne:
        final points = _shownPoints(c);
        // A pick outlives neither its point nor its stage ([_onRestores]).
        final chosen = _picked[c.serverId];
        final String header;
        if (c.stage == dp.RestoreStage.onlyOne && points.isNotEmpty) {
          final first = _supporters(c, points.first);
          header = restoreOnlyOne(
              first.isEmpty ? 'one member' : first.first, server);
        } else {
          header = restorePoints(server);
        }
        Widget option(String value, String title, String? subtitle) =>
            Semantics(
              selected: chosen == value,
              inMutuallyExclusiveGroup: true,
              child: HollowListRow(
                key: ValueKey('restore-point-${c.serverId}-$value'),
                title: title,
                subtitle: subtitle,
                selected: chosen == value,
                touch: compact,
                wrap: true,
                onTap: locked
                    ? null
                    : () => setState(() {
                          _picked[c.serverId] = value;
                          _stages[c.serverId] = c.stage;
                        }),
              ),
            );
        return Column(
          key: ValueKey('restore-points-${c.serverId}'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(header, style: body),
            const SizedBox(height: HollowSpacing.sm),
            for (final p in points)
              option(
                p.cp,
                restorePointTitle(_date(context, p)),
                p.namedBy.isEmpty
                    ? null
                    : restorePointNamedBy(_supporters(c, p)),
              ),
            option(_dontKnow, kRestoreDontKnow, null),
            const SizedBox(height: HollowSpacing.xs),
            Text(kRestoreDontKnowNote, style: secondary),
            const SizedBox(height: HollowSpacing.md),
            HollowDialogActionRow(
              leadingCount: 0,
              children: [
                HollowButton.outline(
                  loading: busy,
                  onPressed: locked || chosen == null
                      ? null
                      : () => _restore(c.serverId, server,
                          chosen == _dontKnow ? null : chosen),
                  child: const Text('Restore'),
                ),
              ],
            ),
          ],
        );
    }
  }
}

/// When the shell offers the chooser on its own (DEVICE_PROOF_DESIGN 8.4).
/// Nothing routes above the App Lock cover or the roster lock, so an offer
/// waits for both and checks them again right before it shows; one chooser at
/// a time, and once the person closed it, nothing reopens it in this run.
class RestoreChooserOffers {
  final ProviderContainer _c;
  final bool Function() _alive;
  final Future<void> Function({required bool fresh}) _show;
  final Future<dp.Restores> Function() _fetch;

  /// The start's own dialogs, which an after-recovery offer waits behind.
  Future<void> Function() startChain;

  bool _open = false;
  int _closes = 0;

  RestoreChooserOffers(
    this._c, {
    required bool Function() alive,
    required Future<void> Function({required bool fresh}) show,
    Future<dp.Restores> Function()? fetch,
    Future<void> Function()? startChain,
  })  : _alive = alive,
        _show = show,
        _fetch = fetch ?? dp.restoreChoices,
        startChain = startChain ?? (() async {});

  bool get _blocked =>
      _c.read(appLockedProvider) ||
      _c.read(rosterGateProvider).kind != RosterGateKind.none;

  Future<void> _until<T>(ProviderListenable<T> p, bool Function(T) ok) async {
    if (ok(_c.read(p))) return;
    final done = Completer<void>();
    final sub = _c.listen<T>(p, (_, v) {
      if (ok(v) && !done.isCompleted) done.complete();
    });
    try {
      await done.future;
    } finally {
      sub.close();
    }
  }

  /// At a start: only when a server waits for the person's pick, and only on a
  /// device the roster counted when the start began. One let in meanwhile
  /// (joined with the phrase, or done waiting) is not recovering anything.
  Future<void> atStart({required bool countedAtStart}) async {
    if (!countedAtStart) return;
    if (_closes > 0 || _c.read(rosterGateProvider).kind != RosterGateKind.none) {
      return;
    }
    await _offer(fresh: false, due: (r) => r.servers.any(restoreNeedsChoice));
  }

  /// After a phrase recovery, behind the start's dialogs, unless the person
  /// closed a chooser since the recovery asked.
  Future<void> afterRecovery({required bool fresh}) async {
    final closesAtAsk = _closes;
    await startChain().catchError((_) {});
    if (_closes > closesAtAsk) return;
    await _offer(
        fresh: fresh,
        due: (r) => restoreChooserDue(r,
            fresh: fresh, holdsServers: _c.read(serverListProvider).isNotEmpty));
  }

  Future<void> _offer(
      {required bool fresh, required bool Function(dp.Restores) due}) async {
    if (_open) return;
    _open = true;
    try {
      while (_alive()) {
        await _until(rosterGateProvider, (g) => g.kind == RosterGateKind.none);
        await _until<bool>(appLockedProvider, (locked) => !locked);
        if (!_alive()) return;
        final dp.Restores restores;
        try {
          restores = await _fetch();
        } catch (e) {
          debugPrint('[HOLLOW] Restore choices skipped: $e');
          return;
        }
        if (!_alive()) return;
        // A lock that came up during the read: wait for it again.
        if (_blocked) continue;
        if (!due(restores)) return;
        await _show(fresh: fresh);
        _closes++;
        return;
      }
    } finally {
      _open = false;
    }
  }
}
