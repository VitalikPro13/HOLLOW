import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/recovery_pool_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_copy_field.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';

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

class _InitiateDialog extends StatefulWidget {
  final String serverId;
  final String serverName;

  const _InitiateDialog({
    required this.serverId,
    required this.serverName,
  });

  @override
  State<_InitiateDialog> createState() => _InitiateDialogState();
}

class _InitiateDialogState extends State<_InitiateDialog>
    with HollowDialogAction {
  String? _inviteLink;

  Future<void> _initiate() async {
    late final String link;
    final ok = await runDialogAction(
      () async =>
          link = await crdt_api.initiateRecoveryPool(serverId: widget.serverId),
      fallback: "Couldn't start the recovery pool. Try again.",
    );
    if (!ok || !mounted) return;
    // A second step follows in this same dialog, so the busy state ends here.
    setState(() {
      actionRunning = false;
      _inviteLink = link;
    });
  }

  @override
  Widget build(BuildContext context) {
    final link = _inviteLink;
    if (link != null) {
      return HollowDialog(
        title: 'Recovery pool started',
        showClose: true,
        width: 420,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            HollowDialogText(
              'Send this link to the others who were in ${widget.serverName}. '
              'As they join, each of you shares the file pieces you hold, and '
              'the files are rebuilt from them.',
            ),
            const SizedBox(height: HollowSpacing.lg),
            HollowCopyField(value: link, name: 'recovery pool link', wrap: false),
          ],
        ),
      );
    }

    return HollowDialog(
      title: 'Start a recovery pool',
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: HollowDialogText(
        'Ask the others who were in ${widget.serverName} to help rebuild its '
        'large files, like videos and attachments. Each of you shares the '
        'file pieces you still hold, and only those pieces leave this device.',
      ),
      actions: [
        HollowButton.ghost(
          onPressed: actionRunning ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _initiate,
          loading: actionRunning,
          child: const Text('Start pool'),
        ),
      ],
    );
  }
}

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

/// The words for a join that nobody answered: the pool may be over, or its
/// members offline, and only the person who shared it can change that.
const kRecoveryPoolNoAnswer = 'Nobody in that pool answered. Ask whoever '
    'shared the link to keep Hollow open, then try again.';

class _JoinDialog extends ConsumerStatefulWidget {
  final String? prefillLink;

  const _JoinDialog({this.prefillLink});

  @override
  ConsumerState<_JoinDialog> createState() => _JoinDialogState();
}

class _JoinDialogState extends ConsumerState<_JoinDialog>
    with HollowDialogAction {
  late final TextEditingController _controller;
  String? _linkError;

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
    if (link.isEmpty || actionRunning) return;

    if (!link.contains('server=') || !link.contains('token=')) {
      setState(() => _linkError = "That isn't a recovery pool link. Paste "
          'the whole link, starting with hollow://recovery.');
      return;
    }

    final joined = await runDialogAction(() async {
      await crdt_api.joinRecoveryPool(inviteLink: link);
      if (!await _waitForWelcome()) {
        throw const FriendlyException(kRecoveryPoolNoAnswer);
      }
    }, fallback: "Couldn't join the recovery pool. Try again.");
    if (!joined || !mounted) return;
    // Clears the pending flag, which is what shows the dashboard.
    ref.read(recoveryPoolProvider.notifier).confirmJoin();
    Navigator.of(context).pop();
    HollowToast.show(context, 'Joined the recovery pool',
        type: HollowToastType.success);
  }

  /// A welcome from a member is what confirms the pool is active; with none
  /// in ten seconds the half-joined pool is stopped again.
  Future<bool> _waitForWelcome() async {
    for (var i = 0; i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return false;
      final pool = ref.read(recoveryPoolProvider);
      if (pool != null && pool.memberPeerIds.isNotEmpty) return true;
    }
    final pool = ref.read(recoveryPoolProvider);
    if (pool != null) {
      // Taken before the await: `ref` is unusable once the dialog is
      // disposed mid-flight, and the cleanup must still run.
      final poolNotifier = ref.read(recoveryPoolProvider.notifier);
      try {
        await crdt_api.stopRecoveryPool(serverId: pool.serverId);
      } catch (_) {}
      poolNotifier.clear();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return HollowDialog(
      title: 'Join a recovery pool',
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const HollowDialogText(
            'Paste the link someone sent you. You share the file pieces you '
            "hold and get theirs, so the server's large files can be rebuilt.",
          ),
          const SizedBox(height: HollowSpacing.lg),
          HollowTextField(
            controller: _controller,
            hintText: 'hollow://recovery?server=...&token=...',
            autofocus: true,
            errorText: _linkError,
            onChanged: (_) => setState(() => _linkError = null),
            onSubmitted: (_) => _join(),
            style: HollowTypography.mono.copyWith(
              color: hollow.textPrimary,
            ),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: actionRunning ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _join,
          loading: actionRunning,
          child: const Text('Join pool'),
        ),
      ],
    );
  }
}
