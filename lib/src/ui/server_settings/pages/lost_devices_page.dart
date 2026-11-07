import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/device_proof_copy.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/peer_id_label.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/device_proof_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/role_hierarchy.dart';
import 'package:hollow/src/rust/api/device_proof.dart' as dp;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/server_recovery_notices.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart'
    show HollowDialogActionRow, showHollowConfirm;
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';

/// The owner's reviews of members' lost devices (DEVICE_PROOF_DESIGN 8.3): per
/// member device, what its re-fold left for the owner, one toggle per change,
/// nothing chosen at first. Leaving the page answers nothing.
class LostDevicesPage extends ConsumerWidget {
  final String serverId;
  const LostDevicesPage({super.key, required this.serverId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(refoldReviewsProvider(serverId));
    final all = async.valueOrNull;
    final List<Widget> children;
    if (all == null && async.hasError) {
      children = [
        SettingsLoadFailed(
          title: "The lost device reviews didn't load",
          onRetry: () => ref.invalidate(refoldReviewsProvider(serverId)),
        ),
      ];
    } else if (all == null) {
      children = const [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: HollowSpinner.medium(delayed: true),
        ),
      ];
    } else {
      final listed = [
        for (final r in all.reviews)
          if (r.listed) r,
      ];
      children = [
        if (listed.isEmpty && all.moreReports == 0)
          const HollowEmptyState(dense: true, title: 'Nothing to review'),
        for (final r in listed)
          _ReviewSection(
            key: ValueKey(('refold', r.member, r.device, r.below)),
            serverId: serverId,
            review: r,
          ),
        if (all.moreReports > 0)
          SettingsNote(refoldMoreReports(all.moreReports)),
      ];
    }
    return SettingsPage(title: 'Lost devices', children: children);
  }
}

enum _Busy { apply, keep }

/// What this device just answered: the saved line and the changes that stay
/// because someone changed them since.
typedef _Done = ({bool keptAll, List<String> stays});

class _ReviewSection extends ConsumerStatefulWidget {
  final String serverId;
  final dp.RefoldReview review;

  const _ReviewSection({super.key, required this.serverId, required this.review});

  @override
  ConsumerState<_ReviewSection> createState() => _ReviewSectionState();
}

class _ReviewSectionState extends ConsumerState<_ReviewSection> {
  final Set<String> _chosen = {};
  final Set<String> _putBack = {};
  _Busy? _busy;

  /// Set once an answer went through: the review takes no second answer.
  _Done? _done;

  dp.RefoldReview get _r => widget.review;

  @override
  void didUpdateWidget(_ReviewSection old) {
    super.didUpdateWidget(old);
    // An item that left the list (someone changed it since) cannot stay chosen.
    final keys = {for (final i in _r.items) i.key};
    _chosen.retainWhere(keys.contains);
    _putBack.retainWhere(_r.unpublished.contains);
  }

  String get _server =>
      ref.watch(serverListProvider.select((s) => s[widget.serverId]?.name)) ??
      kRestoreServerFallback;

  RefoldNames _names() {
    final sid = widget.serverId;
    final channels =
        ref.watch(serverChannelsProvider(sid)).valueOrNull ?? const {};
    final labels = ref.watch(serverLabelsProvider(sid)).valueOrNull ?? const [];
    String unnamed(String m) => memberFallback(shortPeerLabel(m));
    return RefoldNames(
      server: _server,
      member: serverMemberKnownName(ref, sid, _r.member) ?? unnamed(_r.member),
      person: (m) => serverMemberKnownName(ref, sid, m),
      unnamedPerson: unnamed,
      channel: (id) {
        final name = channels[id]?.name;
        return name == null || name.isEmpty ? null : name;
      },
      label: (id) {
        for (final l in labels) {
          if (l.labelId == id && l.name.isNotEmpty) return l.name;
        }
        return null;
      },
      role: roleDisplayName,
    );
  }

  String _channelLabel(RefoldNames n, String id) {
    final name = n.channel(id);
    return name == null ? 'a channel' : '#$name';
  }

  /// Sends the answer and keeps its outcome; throws on failure for the caller
  /// (a button's toast or the Keep all confirm's error line).
  Future<void> _send(RefoldNames names, {required bool keepAll}) async {
    final server = names.server;
    final result = await dp.answerRefoldReview(
      serverId: widget.serverId,
      member: _r.member,
      device: _r.device,
      below: _r.below,
      chosen: keepAll ? const [] : _chosen.toList(),
      putBack: keepAll ? const [] : _putBack.toList(),
    );
    if (!mounted) return;
    final whats = {
      for (final i in _r.items) i.key: refoldItemText(i, names).what,
    };
    setState(() {
      _done = (
        keptAll: keepAll,
        stays: [
          for (final k in result.itemsChangedSince)
            if (whats[k] != null) refoldChangedSince(whats[k]!),
          for (final c in result.putBackChangedSince)
            putBackChangedSince(_channelLabel(names, c)),
        ],
      );
      _chosen.clear();
      _putBack.clear();
    });
    HollowToast.show(
      context,
      keepAll ? refoldKept(server) : refoldApplied(server),
      type: HollowToastType.success,
    );
    ref.invalidate(refoldReviewsProvider(widget.serverId));
  }

  Future<void> _answer(RefoldNames names, {required bool keepAll}) async {
    if (_busy != null || _done != null) return;
    setState(() => _busy = keepAll ? _Busy.keep : _Busy.apply);
    try {
      await _send(names, keepAll: keepAll);
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, friendlyError(e), type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// Keep all is final, so it asks first when it would drop a selection.
  Future<void> _keepAll(RefoldNames names) async {
    final picked = _chosen.length + _putBack.length;
    if (picked == 0) return _answer(names, keepAll: true);
    if (_busy != null || _done != null) return;
    await showHollowConfirm(
      context: context,
      title: kKeepAllTitle,
      message: keepAllMessage(
          total: _r.items.length + _putBack.length, picked: picked),
      confirmLabel: 'Keep all',
      onConfirm: () => _send(names, keepAll: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final touch = SettingsDensity.touchOf(context);
    final names = _names();
    final server = names.server;
    final member = names.member;
    final secondary = (touch ? HollowTypography.body : HollowTypography.bodySmall)
        .copyWith(color: hollow.textSecondary);

    final answered = _r.answered;
    final done = _done;
    if (answered != null || done != null) {
      final String first;
      String? outcome;
      if (answered != null) {
        final device = deviceGivenName(answered.byDevice,
                labels: ref.watch(deviceLabelProvider),
                kinds: ref.watch(deviceKindProvider)) ??
            shortPeerLabel(answered.byDevice);
        first = answered.timeout ? kRefoldTimedOut : refoldAnsweredOn(device);
        // Both lists stay empty until the owner's next checkpoint applies it.
        if (!answered.timeout) {
          outcome = answered.undone.isEmpty && answered.kept.isEmpty
              ? refoldApplied(server)
              : refoldOutcome(
                  undone: answered.undone.length,
                  kept: answered.kept.length);
        }
      } else {
        first = done!.keptAll ? refoldKept(server) : refoldApplied(server);
      }
      return SettingsSection(
        title: refoldTitle(member),
        children: [
          Text(first, style: secondary),
          if (outcome != null) ...[
            const SizedBox(height: HollowSpacing.sm),
            Text(outcome, style: secondary),
          ],
          for (final line in done?.stays ?? const <String>[]) ...[
            const SizedBox(height: HollowSpacing.sm),
            Text(line, style: secondary),
          ],
        ],
      );
    }

    final running = _busy != null;
    final keys = [for (final i in _r.items) i.key];
    final allChosen = keys.every(_chosen.contains);
    final groups = [
      for (final g in dp.RefoldGroup.values)
        if (_r.items.any((i) => i.group == g)) g,
    ];

    Widget itemRow(dp.RefoldItem item) {
      final text = refoldItemText(item, names);
      return SettingsSwitchRow(
        key: ValueKey('refold-item-${item.key}'),
        title: text.line,
        subtitle: text.opens,
        value: _chosen.contains(item.key),
        onChanged: running
            ? null
            : (v) => setState(
                () => v ? _chosen.add(item.key) : _chosen.remove(item.key)),
      );
    }

    return SettingsSection(
      title: refoldTitle(member),
      action: keys.isEmpty
          ? null
          : HollowButton.ghost(
              compact: true,
              touch: touch,
              onPressed: running || allChosen
                  ? null
                  : () => setState(() => _chosen.addAll(keys)),
              child: const Text('Select all'),
            ),
      children: [
        Text(refoldIntro(member), style: secondary),
        if (_r.unpublished.isNotEmpty) ...[
          const SizedBox(height: HollowSpacing.sm),
          Text(refoldClosedChannels(member, server), style: secondary),
        ],
        const SizedBox(height: HollowSpacing.sm),
        Text(kRefoldTimeoutNote, style: secondary),
        if (_r.unpublished.isNotEmpty) ...[
          const SizedBox(height: HollowSpacing.lg),
          const HollowSectionHeader(kAlreadyUndoneHeading, dense: true),
          for (final c in _r.unpublished)
            SettingsRow(
              key: ValueKey('put-back-$c'),
              title: unpublishedText(_channelLabel(names, c), server),
              subtitle: _putBack.contains(c) ? putBackOpens(server) : null,
              // A phone puts the toggle under the sentence, which keeps the width.
              wideTrailing: true,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Put back', style: HollowTypography.label.copyWith(
                      color: hollow.textSecondary)),
                  const SizedBox(width: HollowSpacing.sm),
                  HollowToggle(
                    value: _putBack.contains(c),
                    semanticLabel: 'Put back ${_channelLabel(names, c)}',
                    onChanged: running
                        ? null
                        : (v) => setState(
                            () => v ? _putBack.add(c) : _putBack.remove(c)),
                  ),
                ],
              ),
            ),
        ],
        for (final g in groups) ...[
          const SizedBox(height: HollowSpacing.lg),
          HollowSectionHeader(refoldGroupHeading(g), dense: true),
          for (final item in _r.items)
            if (item.group == g) itemRow(item),
        ],
        if (_r.moreItems > 0) SettingsNote(refoldMoreItems(_r.moreItems)),
        const SizedBox(height: HollowSpacing.lg),
        // One line when both fit, else full width, as a dialog's actions do.
        HollowDialogActionRow(
          leadingCount: 0,
          children: [
            HollowButton.ghost(
              touch: touch,
              loading: _busy == _Busy.keep,
              onPressed: running ? null : () => _keepAll(names),
              child: const Text('Keep all'),
            ),
            HollowButton.outline(
              touch: touch,
              loading: _busy == _Busy.apply,
              onPressed: running || (_chosen.isEmpty && _putBack.isEmpty)
                  ? null
                  : () => _answer(names, keepAll: false),
              child: const Text('Apply selected'),
            ),
          ],
        ),
      ],
    );
  }
}
