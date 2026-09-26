import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip_tabs.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/share/paste_link_dialog.dart';
import 'package:hollow/src/ui/shell/place_header.dart';
import 'package:hollow/src/ui/share/share_card.dart';

enum _ShareSubTab { myShares, serverFiles }

/// The list's side inset: with a row's own padding it puts the row text on
/// the place title's edge.
const double _kListInset = HollowSpacing.xs;

class ShareDashboard extends ConsumerStatefulWidget {
  const ShareDashboard({super.key});

  @override
  ConsumerState<ShareDashboard> createState() => _ShareDashboardState();
}

class _ShareDashboardState extends ConsumerState<ShareDashboard> {
  _ShareSubTab _subTab = _ShareSubTab.myShares;
  // Gates "Share a file" while the whole file is chunked and hashed into the
  // vault, which takes seconds on a large one.
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(shareTabProvider.notifier).loadAll());
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final shares = ref.watch(shareTabProvider);

    final userShares = shares.where((s) => s.contextType == null).toList();
    final serverFileShares = shares.where((s) => s.serverId != null).toList();

    return Container(
      color: hollow.background,
      child: Column(
        children: [
          _buildHeader(hollow, userShares.length, serverFileShares.length),
          _buildDirectWarning(hollow),
          Expanded(
            child: _subTab == _ShareSubTab.myShares
                ? _buildMyShares(userShares, hollow)
                : _buildServerFiles(serverFileShares, hollow),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(HollowTheme hollow, int userCount, int serverCount) {
    return PlaceHeader(
      title: 'Share',
      tabs: [
        HollowChipTabs<_ShareSubTab>(
          selected: _subTab,
          onSelected: (tab) => setState(() => _subTab = tab),
          tabs: [
            HollowChipTab(
              value: _ShareSubTab.myShares,
              label: 'My shares',
              hint: userCount > 0 ? '$userCount' : null,
            ),
            HollowChipTab(
              value: _ShareSubTab.serverFiles,
              label: 'Server files',
              hint: serverCount > 0 ? '$serverCount' : null,
            ),
          ],
        ),
      ],
      actions: [
        if (_subTab == _ShareSubTab.myShares) ...[
          HollowButton.ghost(
            compact: true,
            icon: const Icon(LucideIcons.link, size: 14),
            onPressed: _showPasteDialog,
            child: const Text('Paste a link'),
          ),
          HollowButton.filled(
            compact: true,
            loading: _sharing,
            icon: const Icon(LucideIcons.filePlus, size: 14),
            onPressed: _pickFile,
            child: const Text('Share a file'),
          ),
        ],
      ],
    );
  }

  /// Always shown (Vitalik: it matters). Share transfers are STUN-only, with
  /// no TURN fallback, so a strict network can stop one and the other side
  /// sees your address. While "Always relay calls" is on it also names that
  /// carve-out: a privacy switch with a silent exception is worse than none.
  Widget _buildDirectWarning(HollowTheme hollow) {
    final alwaysRelay = ref.watch(alwaysRelayCallsProvider);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: hollow.noticeSurface(hollow.warning),
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.alertTriangle, size: 16, color: hollow.warning),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              'Share transfers are direct peer-to-peer (STUN-only, no relay '
              'fallback). Transfers may fail behind strict or symmetric NATs '
              "if a direct connection can't be established."
              '${alwaysRelay ? ' "Always relay calls" does not cover Share. '
                  'The person you share with will see your IP address.' : ''}',
              style: HollowTypography.bodySmall.copyWith(color: hollow.warning),
            ),
          ),
        ],
      ),
    );
  }

  /// What an empty list means depends on whether the list has arrived: before
  /// it lands, or when asking for it failed, "none yet" would be untrue.
  Widget? _listNotReady() {
    final status = ref.watch(shareListStatusProvider);
    if (status.failed) {
      return HollowEmptyState(
        glyph: LucideIcons.share2,
        title: "Your shares didn't load",
        action: HollowButton.ghost(
          onPressed: () => ref.read(shareTabProvider.notifier).loadAll(),
          child: const Text('Try again'),
        ),
      );
    }
    if (!status.loaded) {
      return const Center(child: HollowSpinner.large(delayed: true));
    }
    return null;
  }

  Widget _buildMyShares(List<ShareItemState> userShares, HollowTheme hollow) {
    if (userShares.isEmpty) {
      final notReady = _listNotReady();
      if (notReady != null) return notReady;
      return const HollowEmptyState(
        glyph: LucideIcons.share2,
        title: 'No shares yet',
        description: 'Share a file or paste a link to start.',
      );
    }

    final downloading = userShares
        .where((s) => s.state == 'downloading' || s.state == 'failed')
        .toList();
    final seeding = userShares.where((s) => s.state == 'completed').toList();

    return _ShareList(
      sections: [
        if (downloading.isNotEmpty) ('Downloading', downloading),
        if (seeding.isNotEmpty) ('Seeding', seeding),
      ],
    );
  }

  Widget _buildServerFiles(List<ShareItemState> serverFiles, HollowTheme hollow) {
    if (serverFiles.isEmpty) {
      final notReady = _listNotReady();
      if (notReady != null) return notReady;
      return const HollowEmptyState(
        glyph: LucideIcons.server,
        title: 'No server files',
        description: 'Large files sent in server channels show up here.',
      );
    }

    final serverMap = ref.watch(serverListProvider);
    final grouped = <String, List<ShareItemState>>{};
    for (final s in serverFiles) {
      grouped.putIfAbsent(s.serverId!, () => []).add(s);
    }

    return _ShareList(
      sections: [
        for (final entry in grouped.entries)
          (serverMap[entry.key]?.name ?? 'Server', entry.value),
      ],
    );
  }

  Future<void> _pickFile() async {
    if (_sharing) return;
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.single.path == null || !mounted) return;
    setState(() => _sharing = true);
    try {
      await ref
          .read(shareTabProvider.notifier)
          .createFromFile(result.files.single.path!);
    } catch (e) {
      if (mounted) {
        HollowToast.show(
            context,
            friendlyError(e,
                fallback: "Couldn't share the file. Try again."),
            type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  void _showPasteDialog() {
    showHollowDialog(
      context: context,
      builder: (ctx) => const PasteLinkDialog(),
    );
  }
}

/// Titled groups of share rows.
class _ShareList extends StatelessWidget {
  final List<(String, List<ShareItemState>)> sections;
  const _ShareList({required this.sections});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        _kListInset,
        HollowSpacing.md,
        _kListInset,
        HollowSpacing.lg,
      ),
      children: [
        for (final (i, (title, items)) in sections.indexed) ...[
          Padding(
            padding: EdgeInsets.fromLTRB(
              HollowSpacing.md,
              i == 0 ? 0 : HollowSpacing.lg,
              HollowSpacing.md,
              0,
            ),
            child: HollowSectionHeader(title,
                dense: true, count: '${items.length}'),
          ),
          for (final item in items)
            ShareRow(key: ValueKey(item.rootHash), item: item),
        ],
      ],
    );
  }
}
