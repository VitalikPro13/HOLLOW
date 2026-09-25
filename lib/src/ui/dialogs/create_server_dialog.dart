import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/relay_switch_dialog.dart';

/// Shows a dialog to join a server by invite, or start a new one. The phone
/// opens the same dialog, which stacks the two halves.
void showCreateServerDialog(BuildContext context) {
  showHollowDialog(
    context: context,
    builder: (_) => const _AddServerDialog(),
  );
}

class _AddServerDialog extends ConsumerStatefulWidget {
  const _AddServerDialog();

  @override
  ConsumerState<_AddServerDialog> createState() => _AddServerDialogState();
}

class _AddServerDialogState extends ConsumerState<_AddServerDialog> {
  final _invite = TextEditingController();
  final _name = TextEditingController();
  bool _joining = false;
  bool _creating = false;
  String? _joinError;
  String? _createError;

  bool get _busy => _joining || _creating;

  @override
  void dispose() {
    _invite.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final input = _invite.text.trim();
    if (input.isEmpty || _busy) return;
    // Accepts a hollow:// link, a web /join# link or a raw server id.
    final invite = inviteFromInput(input, HollowLinkType.serverInvite);
    if (!isServerIdShape(invite.id)) {
      setState(() => _joinError =
          "That isn't an invite link or server ID. Check what you pasted.");
      return;
    }
    setState(() {
      _joining = true;
      _joinError = null;
    });
    try {
      // False when the invite lives on another relay: the switch dialog
      // either restarts Hollow or was declined, and this one stays put.
      if (!await ensureRelayForInviteId(context, ref,
          type: HollowLinkType.serverInvite,
          id: invite.id,
          relay: invite.relay)) {
        if (mounted) setState(() => _joining = false);
        return;
      }
      await crdt_api.joinServer(
          serverId: invite.id.toLowerCase(), nsfwConfirmed: false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _joining = false;
          _joinError = friendlyError(e,
              fallback: "Couldn't join that server. Check the link and try "
                  'again.');
        });
      }
      return;
    }
    if (!mounted) return;
    // Only queued so far: the server appears once a member lets us in, which
    // can be minutes when nobody is online.
    _closeWith('Joining server...', HollowToastType.info);
  }

  /// Pops, then toasts on the navigator's overlay, which outlives this
  /// dialog's context (feedback_toast_from_nonwidget_overlaystate).
  void _closeWith(String message, HollowToastType type) {
    final navigator = Navigator.of(context);
    final overlay = navigator.overlay;
    navigator.pop();
    if (overlay != null && overlay.mounted) {
      HollowToast.show(overlay.context, message,
          type: type, overlayState: overlay);
    }
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty || _busy) return;
    setState(() {
      _creating = true;
      _createError = null;
    });
    try {
      await crdt_api.createServer(name: name);
    } catch (e) {
      if (mounted) {
        setState(() {
          _creating = false;
          _createError = friendlyError(e,
              fallback: "Couldn't create the server. Try again.");
        });
      }
      return;
    }
    if (!mounted) return;
    _closeWith('Server created', HollowToastType.success);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final isCompact = HollowDialogSurface.isCompact(context);

    // Two halves, each a section with its own action: a person picks one,
    // never both, so neither outranks the other and both are outline.
    const joinHeader = HollowSectionHeader(
      'Join a server',
      subtitle: 'Paste an invite link or server ID.',
    );
    final joinForm = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HollowTextField(
          controller: _invite,
          hintText: 'Invite link or server ID',
          autofocus: !isCompact,
          style: HollowTypography.mono.copyWith(color: hollow.textPrimary),
          errorText: _joinError,
          onChanged: (_) => setState(() => _joinError = null),
          onSubmitted: (_) => _join(),
        ),
        const SizedBox(height: HollowSpacing.sm),
        HollowButton.outline(
          onPressed: _invite.text.trim().isEmpty || _creating ? null : _join,
          loading: _joining,
          expand: true,
          child: const Text('Join'),
        ),
      ],
    );

    const createHeader = HollowSectionHeader(
      'Start your own',
      subtitle: 'A new server of yours. Invite people once it is made.',
    );
    final createForm = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HollowTextField(
          controller: _name,
          hintText: 'My Awesome Server',
          errorText: _createError,
          onChanged: (_) => setState(() => _createError = null),
          onSubmitted: (_) => _create(),
        ),
        const SizedBox(height: HollowSpacing.sm),
        HollowButton.outline(
          onPressed: _name.text.trim().isEmpty || _joining ? null : _create,
          loading: _creating,
          expand: true,
          child: const Text('Create'),
        ),
      ],
    );

    // Side by side, the headers and the forms are separate rows, so a
    // description that wraps on one side never pushes that side's field and
    // button below the other's. The two divider pieces meet into one line.
    Widget sideBySide(Widget join, Widget create) => IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: join),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: HollowSpacing.xl),
                child: HollowVerticalDivider(),
              ),
              Expanded(child: create),
            ],
          ),
        );

    final body = isCompact
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              joinHeader,
              joinForm,
              const Padding(
                padding: EdgeInsets.symmetric(vertical: HollowSpacing.xl),
                child: HollowDivider(),
              ),
              createHeader,
              createForm,
            ],
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Top-aligned: the shorter header would centre in its slot.
              sideBySide(
                const Align(
                    alignment: AlignmentDirectional.topStart, child: joinHeader),
                const Align(
                    alignment: AlignmentDirectional.topStart,
                    child: createHeader),
              ),
              sideBySide(joinForm, createForm),
            ],
          );

    return HollowDialog(
      title: 'Add a server',
      showClose: true,
      width: 600,
      busy: _busy,
      content: body,
    );
  }
}
