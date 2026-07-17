import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/rust/api/share.dart' as share_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/share/paste_link_dialog.dart';
import 'package:hollow/src/ui/share/share_card.dart';

enum _ShareSubTab { myShares, serverFiles }

class ShareDashboard extends ConsumerStatefulWidget {
  const ShareDashboard({super.key});

  @override
  ConsumerState<ShareDashboard> createState() => _ShareDashboardState();
}

class _ShareDashboardState extends ConsumerState<ShareDashboard> {
  _ShareSubTab _subTab = _ShareSubTab.myShares;
  // Gates "Share a File" while shareCreateFromFile chunks + hashes the whole
  // file into the vault — multi-second for large files, and the new share
  // only appears in the list once it finishes.
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
          _buildStunWarning(hollow),
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
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      child: Row(
        children: [
          Text('Share', style: HollowTypography.heading.copyWith(color: hollow.textPrimary)),
          const SizedBox(width: HollowSpacing.lg),
          _SubTabPill(
            label: 'My Shares${userCount > 0 ? ' ($userCount)' : ''}',
            isSelected: _subTab == _ShareSubTab.myShares,
            onTap: () => setState(() => _subTab = _ShareSubTab.myShares),
          ),
          const SizedBox(width: HollowSpacing.sm),
          _SubTabPill(
            label: 'Server Files${serverCount > 0 ? ' ($serverCount)' : ''}',
            isSelected: _subTab == _ShareSubTab.serverFiles,
            onTap: () => setState(() => _subTab = _ShareSubTab.serverFiles),
          ),
          const Spacer(),
          if (_subTab == _ShareSubTab.myShares) ...[
            HollowButton.ghost(
              compact: true,
              icon: _sharing
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: hollow.textSecondary),
                    )
                  : const Icon(LucideIcons.filePlus, size: 14),
              onPressed: _sharing ? null : _pickFile,
              child: Text(_sharing ? 'Sharing…' : 'Share a File'),
            ),
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.filled(
              compact: true,
              icon: const Icon(LucideIcons.link, size: 14),
              onPressed: _showPasteDialog,
              child: const Text('Paste Link'),
            ),
          ],
        ],
      ),
    );
  }

  /// Yellow advisory strip below the header: Share transfers are STUN-only
  /// (direct P2P, no TURN relay fallback), so a transfer can fail behind
  /// strict/symmetric NATs. Mirrors the archive verification banner styling.
  Widget _buildStunWarning(HollowTheme hollow) {
    final color = Colors.amber.shade700;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg,
        vertical: 10,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border(
          bottom: BorderSide(color: hollow.border.withValues(alpha: 0.3)),
        ),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.alertTriangle, size: 14, color: color),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              'Share transfers are direct peer-to-peer (STUN-only, no relay '
              'fallback). Transfers may fail behind strict or symmetric NATs '
              'if a direct connection can\'t be established.',
              style: HollowTypography.caption.copyWith(
                color: color,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── My Shares tab ──

  Widget _buildMyShares(List<ShareItemState> userShares, HollowTheme hollow) {
    if (userShares.isEmpty) {
      return _buildEmptyState(
        hollow,
        icon: LucideIcons.share2,
        title: 'No shares yet',
        subtitle: 'Paste a link or share a file to get started',
      );
    }

    final downloading = userShares.where((s) => s.state == 'downloading' || s.state == 'failed').toList();
    final seeding = userShares.where((s) => s.state == 'completed').toList();

    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      children: [
        if (downloading.isNotEmpty) ...[
          _sectionHeader('Downloading (${downloading.length})', hollow),
          const SizedBox(height: HollowSpacing.sm),
          for (final item in downloading) ...[
            ShareCard(item: item),
            const SizedBox(height: HollowSpacing.sm),
          ],
          const SizedBox(height: HollowSpacing.lg),
        ],
        if (seeding.isNotEmpty) ...[
          _sectionHeader('Seeding (${seeding.length})', hollow),
          const SizedBox(height: HollowSpacing.sm),
          for (final item in seeding) ...[
            ShareCard(item: item),
            const SizedBox(height: HollowSpacing.sm),
          ],
        ],
      ],
    );
  }

  // ── Server Files tab ──

  Widget _buildServerFiles(List<ShareItemState> serverFiles, HollowTheme hollow) {
    if (serverFiles.isEmpty) {
      return _buildEmptyState(
        hollow,
        icon: LucideIcons.server,
        title: 'No server files',
        subtitle: 'Large files sent in server channels appear here',
      );
    }

    final serverMap = ref.watch(serverListProvider);

    // Group by server ID.
    final grouped = <String, List<ShareItemState>>{};
    for (final s in serverFiles) {
      grouped.putIfAbsent(s.serverId!, () => []).add(s);
    }

    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      children: [
        for (final entry in grouped.entries) ...[
          _sectionHeader(
            '${_serverName(entry.key, serverMap)} (${entry.value.length})',
            hollow,
          ),
          const SizedBox(height: HollowSpacing.sm),
          for (final item in entry.value) ...[
            ShareCard(item: item),
            const SizedBox(height: HollowSpacing.sm),
          ],
          const SizedBox(height: HollowSpacing.lg),
        ],
      ],
    );
  }

  // ── Shared helpers ──

  Widget _buildEmptyState(
    HollowTheme hollow, {
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: hollow.textSecondary),
          const SizedBox(height: HollowSpacing.lg),
          Text(title, style: HollowTypography.subheading.copyWith(color: hollow.textSecondary)),
          const SizedBox(height: HollowSpacing.xs),
          Text(subtitle, style: HollowTypography.bodySmall.copyWith(color: hollow.textSecondary)),
        ],
      ),
    );
  }

  String _serverName(String serverId, Map<String, dynamic> serverMap) {
    final info = serverMap[serverId];
    if (info != null) return info.name;
    return 'Server';
  }

  Widget _sectionHeader(String label, HollowTheme hollow) {
    return Padding(
      padding: const EdgeInsets.only(left: HollowSpacing.xs),
      child: Text(
        label,
        style: HollowTypography.label.copyWith(color: hollow.textSecondary),
      ),
    );
  }

  Future<void> _pickFile() async {
    if (_sharing) return;
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.single.path == null || !mounted) return;
    setState(() => _sharing = true);
    try {
      await share_api.shareCreateFromFile(sourcePath: result.files.single.path!);
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Could not share file: $e',
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

/// Pill-shaped sub-tab button — matches the Archive dashboard pattern.
class _SubTabPill extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _SubTabPill({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return HollowPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      padding: EdgeInsets.zero,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? hollow.accent.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          border: Border.all(
            color: isSelected
                ? hollow.accent.withValues(alpha: 0.3)
                : hollow.border,
          ),
        ),
        child: Text(
          label,
          style: HollowTypography.body.copyWith(
            color: isSelected ? hollow.accent : hollow.textSecondary,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}
