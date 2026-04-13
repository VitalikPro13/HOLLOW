import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/recovery_pool_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:lucide_icons/lucide_icons.dart';

// ── Initiate Recovery Pool dialog ──────────────────────────────

/// Show the dialog to initiate a recovery pool for a server.
void showInitiateRecoveryPoolDialog(
  BuildContext context, {
  required String serverId,
  required String serverName,
}) {
  showHollowDialog(
    context: context,
    builder: (_) => _InitiateDialog(
      serverId: serverId,
      serverName: serverName,
    ),
  );
}

class _InitiateDialog extends ConsumerStatefulWidget {
  final String serverId;
  final String serverName;

  const _InitiateDialog({
    required this.serverId,
    required this.serverName,
  });

  @override
  ConsumerState<_InitiateDialog> createState() => _InitiateDialogState();
}

class _InitiateDialogState extends ConsumerState<_InitiateDialog> {
  bool _starting = false;
  String? _inviteLink;

  Future<void> _initiate() async {
    setState(() => _starting = true);
    try {
      final link = await crdt_api.initiateRecoveryPool(
        serverId: widget.serverId,
      );
      if (mounted) {
        setState(() {
          _starting = false;
          _inviteLink = link;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _starting = false);
        HollowToast.show(
          context,
          'Failed to start pool: $e',
          type: HollowToastType.error,
        );
      }
    }
  }

  void _copyLink() {
    if (_inviteLink == null) return;
    Clipboard.setData(ClipboardData(text: _inviteLink!));
    HollowToast.show(
      context,
      'Invite link copied',
      type: HollowToastType.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    // After link is generated, show the link + copy button.
    if (_inviteLink != null) {
      return HollowDialog(
        title: 'Recovery Pool Started',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Share this invite link with other ex-members of '
              '${widget.serverName}. They can join to contribute their '
              'vault shards and help reconstruct files.',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: HollowSpacing.md),
            Container(
              padding: const EdgeInsets.all(HollowSpacing.md),
              decoration: BoxDecoration(
                color: hollow.surface,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                border: Border.all(color: hollow.border),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      _inviteLink!,
                      style: HollowTypography.mono.copyWith(
                        color: hollow.accent,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  IconButton(
                    onPressed: _copyLink,
                    icon: Icon(LucideIcons.copy, size: 16, color: hollow.textSecondary),
                    iconSize: 16,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          HollowButton.filled(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      );
    }

    // Initial consent screen.
    return HollowDialog(
      title: 'Start Recovery Pool',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.server, size: 16, color: hollow.accent),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Text(
                  widget.serverName,
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.md),
          Text(
            'Start a Recovery Pool to cooperatively gather vault shards '
            'from other ex-members. This exchanges erasure-coded file '
            'shards to reconstruct large files (videos, attachments) that '
            'were distributed across the server.\n\n'
            'Your local data stays encrypted. Only vault shards are shared.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: _starting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: HollowSpacing.sm),
        HollowButton.filled(
          onPressed: _starting ? null : _initiate,
          icon: _starting
              ? SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(hollow.textPrimary),
                  ),
                )
              : const Icon(LucideIcons.shield, size: 14),
          child: Text(_starting ? 'Starting...' : 'Start Pool'),
        ),
      ],
    );
  }
}

// ── Join Recovery Pool dialog ──────────────────────────────────

/// Show the dialog to join a recovery pool via invite link.
void showJoinRecoveryPoolDialog(
  BuildContext context, {
  String? prefillLink,
}) {
  showHollowDialog(
    context: context,
    builder: (_) => _JoinDialog(prefillLink: prefillLink),
  );
}

class _JoinDialog extends ConsumerStatefulWidget {
  final String? prefillLink;

  const _JoinDialog({this.prefillLink});

  @override
  ConsumerState<_JoinDialog> createState() => _JoinDialogState();
}

class _JoinDialogState extends ConsumerState<_JoinDialog> {
  late final TextEditingController _controller;
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.prefillLink ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final link = _controller.text.trim();
    if (link.isEmpty) return;

    // Basic link format validation.
    if (!link.contains('server=') || !link.contains('token=')) {
      HollowToast.show(
        context,
        'Invalid invite link format',
        type: HollowToastType.error,
      );
      return;
    }

    setState(() => _joining = true);
    try {
      await crdt_api.joinRecoveryPool(inviteLink: link);

      // Wait for a member to welcome us (confirms the pool is active).
      // Timeout after 10 seconds if nobody responds.
      bool welcomed = false;
      for (int i = 0; i < 20; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;
        final pool = ref.read(recoveryPoolProvider);
        if (pool != null && pool.memberPeerIds.isNotEmpty) {
          welcomed = true;
          break;
        }
      }

      if (!mounted) return;

      if (welcomed) {
        // Confirm the join — clears pending flag so dashboard shows.
        ref.read(recoveryPoolProvider.notifier).confirmJoin();
        Navigator.of(context).pop();
        HollowToast.show(
          context,
          'Joined recovery pool',
          type: HollowToastType.success,
        );
      } else {
        // No one responded — pool may be dead. Clean up.
        final pool = ref.read(recoveryPoolProvider);
        if (pool != null) {
          try {
            await crdt_api.stopRecoveryPool(serverId: pool.serverId);
          } catch (_) {}
          ref.read(recoveryPoolProvider.notifier).clear();
        }
        setState(() => _joining = false);
        HollowToast.show(
          context,
          'No active pool found — nobody responded',
          type: HollowToastType.error,
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _joining = false);
        HollowToast.show(
          context,
          'Failed to join: $e',
          type: HollowToastType.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return HollowDialog(
      title: 'Join Recovery Pool',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Paste the recovery pool invite link to join. You\'ll contribute '
            'your vault shards and receive shards from other ex-members to '
            'reconstruct files.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: HollowSpacing.md),
          HollowTextField(
            controller: _controller,
            hintText: 'hollow://recovery?server=...&token=...',
            autofocus: true,
            style: HollowTypography.mono.copyWith(
              color: hollow.textPrimary,
              fontSize: 12,
            ),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: _joining ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: HollowSpacing.sm),
        HollowButton.filled(
          onPressed: _joining ? null : _join,
          icon: _joining
              ? SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(hollow.textPrimary),
                  ),
                )
              : const Icon(LucideIcons.logIn, size: 14),
          child: Text(_joining ? 'Joining...' : 'Join Pool'),
        ),
      ],
    );
  }
}
