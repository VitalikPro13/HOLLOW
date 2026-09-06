import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/owned_art_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/shop_provider.dart' as shop;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/shop/hollowpack_import.dart';

/// Redeeming a Hollow Shop code.
///
/// Two steps, both in Rust: a lookup that says what the code buys, then the
/// redeem, which blinds a message binding OUR master identity to the item, has
/// the shop sign it without seeing it, keeps the credential, announces it and
/// fetches the pack through the one import door. The dialog only sequences
/// those and says what happened.

/// A `hollow://redeem/<code>` link landed. The code is KEPT before the dialog
/// opens, so closing it never loses what the person paid for.
Future<void> showRedeemCodeDialog(BuildContext context, String code) async {
  try {
    await shop.keepRedeemCode(code: code);
  } catch (_) {
    // A malformed code is refused by the lookup anyway; keeping it is a
    // courtesy.
  }
  if (!context.mounted) return;
  await showHollowDialog<void>(
    context: context,
    builder: (_) => RedeemCodeDialog(initialCode: code),
  );
}

/// The Shop tab's "Redeem a code": an empty field.
Future<void> showRedeemEntryDialog(BuildContext context) {
  return showHollowDialog<void>(
    context: context,
    builder: (_) => const RedeemCodeDialog(initialCode: ''),
  );
}

enum _Step { entering, looking, found, redeeming }

class RedeemCodeDialog extends ConsumerStatefulWidget {
  final String initialCode;

  const RedeemCodeDialog({super.key, required this.initialCode});

  @override
  ConsumerState<RedeemCodeDialog> createState() => _RedeemCodeDialogState();
}

class _RedeemCodeDialogState extends ConsumerState<RedeemCodeDialog> {
  late final TextEditingController _code;
  _Step _step = _Step.entering;
  shop.RedeemLookup? _lookup;
  String? _problem;

  @override
  void initState() {
    super.initState();
    _code = TextEditingController(text: widget.initialCode);
    if (widget.initialCode.trim().isNotEmpty) {
      // A link brought the code: look it up straight away.
      WidgetsBinding.instance.addPostFrameCallback((_) => _lookUp());
    }
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  String _clean(Object e) =>
      e.toString().replaceFirst(RegExp(r'^[A-Za-z]+: '), '');

  Future<void> _lookUp() async {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _step = _Step.looking;
      _problem = null;
    });
    try {
      final looked = await shop.redeemLookup(code: code);
      if (!mounted) return;
      if (looked.status != 'ok') {
        // The lookup just forgot a burned, refunded or unknown code, and the
        // kept list says so on its next read.
        ref.invalidate(shop.keptRedeemCodesProvider);
        setState(() {
          _step = _Step.entering;
          _problem = looked.message;
        });
        return;
      }
      setState(() {
        _lookup = looked;
        _step = _Step.found;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _Step.entering;
        _problem = _clean(e);
      });
    }
  }

  Future<void> _redeem() async {
    final code = _code.text.trim();
    setState(() {
      _step = _Step.redeeming;
      _problem = null;
    });
    shop.RedeemOutcome outcome;
    try {
      outcome = await shop.redeemCode(code: code);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _Step.found;
        _problem = _clean(e);
      });
      return;
    }
    if (!mounted) return;

    // The credential is on the profile now: readers converge on ProfileUpdated
    // and the library on the reload.
    final me = ref.read(identityProvider).peerId;
    if (me != null && me.isNotEmpty) {
      await ref.read(profileProvider.notifier).reloadProfile(me);
    }
    ref.invalidate(shop.ownSupportCredsProvider);
    ref.invalidate(shop.keptRedeemCodesProvider);
    await ref.read(ownedArtProvider.notifier).reload();
    if (!mounted) return;

    final imported = outcome.imported;
    Navigator.of(context).pop();
    // The parent context outlives this dialog; the dialog's own is gone.
    final host = ref.context;
    if (!host.mounted) return;
    if (imported != null) {
      HollowToast.show(host, 'Support mark saved for ${outcome.title}',
          type: HollowToastType.success);
      if (outcome.warning.isNotEmpty) {
        HollowToast.show(host, outcome.warning, type: HollowToastType.info);
      }
      await showImportedPackDialog(host, ref, imported);
    } else {
      await showHollowDialog<void>(
        context: host,
        builder: (dialogContext) {
          final hollow = HollowTheme.of(dialogContext);
          return HollowDialog(
            title: 'Support mark saved',
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your support mark for ${outcome.title} by '
                  '${outcome.artistName} is on your profile.',
                  style: HollowTypography.body
                      .copyWith(color: hollow.textSecondary),
                ),
                const SizedBox(height: HollowSpacing.md),
                Text(
                  'The pack did not arrive: ${outcome.packError}. Import the '
                  '.hollowpack from your Creem download to wear the art; the '
                  'mark lights up the moment you wear it.',
                  style: HollowTypography.body
                      .copyWith(color: hollow.textSecondary),
                ),
              ],
            ),
            actions: [
              HollowButton.filled(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
    }
  }

  Widget _spinner(HollowTheme hollow) => SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: hollow.textSecondary,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final looked = _lookup;
    final busy = _step == _Step.looking || _step == _Step.redeeming;

    final children = <Widget>[
      HollowTextField(
        controller: _code,
        hintText: 'The code from your receipt',
        autofocus: widget.initialCode.isEmpty,
        onSubmitted: busy ? null : (_) => _lookUp(),
        style: HollowTypography.mono.copyWith(fontSize: 12),
      ),
      if (_problem != null) ...[
        const SizedBox(height: HollowSpacing.sm),
        Text(
          _problem!,
          style: HollowTypography.caption.copyWith(color: hollow.error),
        ),
      ],
      if (_step == _Step.entering && _problem == null) ...[
        const SizedBox(height: HollowSpacing.md),
        Text(
          'Redeeming mints a support mark for your profile through a blind '
          'signature: the shop signs it without learning who you are. Hollow '
          'then fetches the art and puts it in your library.',
          style: HollowTypography.body.copyWith(color: hollow.textSecondary),
        ),
      ],
      if (looked != null && _step != _Step.entering) ...[
        const SizedBox(height: HollowSpacing.md),
        Text(
          looked.title,
          style: HollowTypography.body.copyWith(
            color: hollow.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          'by ${looked.artistName}'
          '${looked.kinds.isEmpty ? '' : '  ${looked.kinds.join(', ')}'}',
          style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
        ),
        const SizedBox(height: HollowSpacing.md),
        if (looked.alreadySupported)
          Text(
            'You already own this item. A second redemption changes '
            'nothing on your profile: keep the code and gift it instead, '
            'or redeem it anyway.',
            style: HollowTypography.body.copyWith(color: hollow.warning),
          )
        else
          Text(
            'Once redeemed, the mark lives in your profile and its backup. '
            'It cannot be minted again for another identity, and the code '
            'is spent.',
            style: HollowTypography.body.copyWith(color: hollow.textSecondary),
          ),
        if (_step == _Step.redeeming) ...[
          const SizedBox(height: HollowSpacing.md),
          Row(
            children: [
              _spinner(hollow),
              const SizedBox(width: HollowSpacing.sm),
              Text(
                'Minting your support mark and fetching the art',
                style: HollowTypography.caption
                    .copyWith(color: hollow.textSecondary),
              ),
            ],
          ),
        ],
      ],
    ];

    final actions = <Widget>[
      HollowButton.ghost(
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: _code.text.trim()));
          if (!context.mounted) return;
          HollowToast.show(context, 'Code copied',
              type: HollowToastType.success);
        },
        child: const Text('Copy code'),
      ),
      HollowButton.ghost(
        onPressed: busy ? null : () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      if (_step == _Step.found || _step == _Step.redeeming)
        HollowButton.filled(
          onPressed: busy ? null : _redeem,
          icon: _step == _Step.redeeming ? _spinner(hollow) : null,
          child: Text(looked?.alreadySupported == true
              ? 'Redeem anyway'
              : 'Redeem'),
        )
      else
        HollowButton.filled(
          onPressed: busy ? null : _lookUp,
          icon: _step == _Step.looking ? _spinner(hollow) : null,
          child: const Text('Look up'),
        ),
    ];

    return HollowDialog(
      title: 'Redeem a code',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
      actions: actions,
    );
  }
}
