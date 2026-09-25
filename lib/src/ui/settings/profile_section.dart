import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:hollow/src/core/providers/banner_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_anim_provider.dart';
import 'package:hollow/src/core/providers/profile_draft_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/support_marks_provider.dart';
import 'package:hollow/src/core/providers/twitch_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/twitch_device_code_dialog.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';

/// Pieces of Settings > Profile that stand on their own: the live preview of
/// the profile card and the Twitch connection row.

/// Deterministic banner colour from a peer id, a hue shifted from the avatar's.
Color profileBannerColorFor(String id) {
  final hue = ((id.hashCode % 360).abs() + 40) % 360;
  return HSLColor.fromAHSL(1.0, hue.toDouble(), 0.45, 0.35).toColor();
}

/// The banner others see: the pending one while the draft holds one, else the
/// saved banner (its animation first).
Uint8List? watchDraftBanner(WidgetRef ref, String peerId) {
  final draft = ref.watch(profileDraftProvider);
  if (draft.bannerChanged) return draft.bannerBytes;
  return watchAnimatedBanner(ref, peerId) ??
      ref.watch(bannerProvider(peerId)).valueOrNull;
}

/// Exactly what others see on the profile card, live as the draft changes.
class ProfilePreviewCard extends ConsumerWidget {
  final String peerId;

  const ProfilePreviewCard({super.key, required this.peerId});

  static const double width = 220;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final draft = ref.watch(profileDraftProvider);
    final notifier = ref.read(profileDraftProvider.notifier);
    final saved = ref.watch(profileProvider.select((p) => p[peerId]));

    return Container(
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusLg),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PreviewBanner(peerId: peerId, busy: draft.bannerBusy),
          Transform.translate(
            offset: const Offset(0, -HollowSpacing.xl),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
              child: ListenableBuilder(
                listenable: Listenable.merge(
                    [notifier.displayName, notifier.status, notifier.aboutMe]),
                builder: (context, _) {
                  final name = notifier.displayName.text.trim();
                  final status = notifier.status.text.trim();
                  final about = notifier.aboutMe.text.trim();
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Stack(
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius:
                                  BorderRadius.circular(hollow.radiusLg),
                              border: Border.all(
                                  color: hollow.elevated,
                                  width: HollowSpacing.xs),
                            ),
                            child: HollowAvatar(
                              peerId: peerId,
                              size: 56,
                              imageBytes:
                                  draft.avatarChanged ? draft.avatarBytes : null,
                              frameId: draft.effectiveFrame,
                              animate: true,
                            ),
                          ),
                          if (draft.avatarBusy)
                            const Positioned(
                              right: 0,
                              bottom: 0,
                              child: HollowSpinner(),
                            ),
                        ],
                      ),
                      const SizedBox(height: HollowSpacing.xs),
                      Text(
                        name.isNotEmpty
                            ? name
                            : displayNameForPeer(saved, peerId),
                        style: HollowTypography.subheading
                            .copyWith(color: hollow.textPrimary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (status.isNotEmpty) ...[
                        const SizedBox(height: HollowSpacing.xxs),
                        Text(
                          status,
                          style: HollowTypography.bodySmall
                              .copyWith(color: hollow.textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (about.isNotEmpty) ...[
                        const SizedBox(height: HollowSpacing.md),
                        Text(
                          about,
                          style: HollowTypography.bodySmall
                              .copyWith(color: hollow.textPrimary),
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewBanner extends ConsumerWidget {
  final String peerId;
  final bool busy;

  const _PreviewBanner({required this.peerId, required this.busy});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The card's width over 2.5, the ratio every user banner surface, the
    // cropper and Rust's 1200x480 storage share.
    const height = ProfilePreviewCard.width / 2.5;
    final fallback = ColoredBox(
      color: profileBannerColorFor(peerId),
      child: const SizedBox(height: height, width: double.infinity),
    );
    final bytes = watchDraftBanner(ref, peerId);
    Widget banner = fallback;
    if (bytes != null && bytes.isNotEmpty) {
      banner = SizedBox(
        height: height,
        width: double.infinity,
        child: AnimatedGifImage(
          bytes: bytes,
          height: height,
          width: double.infinity,
          fit: BoxFit.cover,
          errorWidget: fallback,
        ),
      );
    }
    if (!busy) return banner;
    return Stack(
      children: [
        banner,
        const Positioned(
          top: HollowSpacing.sm,
          right: HollowSpacing.sm,
          child: HollowSpinner(),
        ),
      ],
    );
  }
}

/// Connect, verify and disconnect a Twitch account.
///
/// Public because the widget test drives it: every state it can be in is one
/// this row paints, and the rest of Settings > Profile needs a running node.
class TwitchConnectionRow extends ConsumerStatefulWidget {
  final HollowTheme hollow;

  const TwitchConnectionRow({super.key, required this.hollow});

  @override
  ConsumerState<TwitchConnectionRow> createState() =>
      _TwitchConnectionRowState();
}

enum _TwitchBusy { none, verify, disconnect }

class _TwitchConnectionRowState extends ConsumerState<TwitchConnectionRow> {
  bool _connected = false;
  String? _userId;
  String? _username;
  bool _loading = true;

  /// A verify or a disconnect is in flight; both talk to the shop.
  _TwitchBusy _busy = _TwitchBusy.none;

  /// The login on our verified credential, or null when we hold none: what the
  /// purple chip draws, rather than merely whether a token exists.
  String? _verifiedLogin;

  @override
  void initState() {
    super.initState();
    _checkConnection();
  }

  Future<void> _checkConnection() async {
    try {
      final ffi = ref.read(twitchFfiProvider);
      final connected = await ffi.isConnected();
      final userId = connected ? await ffi.userId() : null;
      final username = connected ? await ffi.username() : null;
      if (mounted) {
        setState(() {
          _connected = connected;
          _userId = userId;
          _username = username;
          _verifiedLogin = _myVerifiedLogin();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// The verified login on OUR profile row, read the way every viewer reads it.
  String? _myVerifiedLogin() {
    final me = ref.read(identityProvider).peerId;
    if (me == null) return null;
    return ref.read(twitchLoginProvider(me));
  }

  /// Asks the shop to verify the connected account and wear the credential.
  ///
  /// Every outcome is visible: a spinner, a toast carrying the shop's own
  /// sentence on a refusal, and the login on the row when it lands.
  Future<void> _verifyAccount() async {
    if (_busy != _TwitchBusy.none) return;
    setState(() => _busy = _TwitchBusy.verify);
    try {
      final outcome = await ref.read(twitchFfiProvider).verifyOwner();
      if (!mounted) return;
      setState(() {
        _verifiedLogin = outcome.verified ? outcome.login : null;
        _busy = _TwitchBusy.none;
      });
      if (outcome.verified) {
        HollowToast.show(context, 'Twitch verified as ${outcome.login}',
            type: HollowToastType.success);
      } else {
        HollowToast.show(context, outcome.message, type: HollowToastType.error);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = _TwitchBusy.none);
      HollowToast.show(context, friendlyError(e,
              fallback: "Couldn't verify Twitch. Try again."),
          type: HollowToastType.error);
    }
  }

  /// Connect, then verify.
  ///
  /// The connection alone proves nothing to anybody else: a viewer sees the
  /// CREDENTIAL, so the sign in runs straight into the verify rather than
  /// leaving the account connected and unverified. A self-declared handle is
  /// not rendered by any new client.
  Future<void> _connect() async {
    if (!mounted) return;
    showTwitchDeviceCodeDialog(context, onSuccess: () async {
      await _checkConnection();
      await _verifyAccount();
    });
  }

  Future<void> _disconnect() async {
    if (_busy != _TwitchBusy.none) return;
    setState(() => _busy = _TwitchBusy.disconnect);
    try {
      // Rust drops the credential and republishes BEFORE wiping the token: the
      // credential is a 90-day fact everyone verifies offline, so losing the
      // token alone would leave a verified chip behind.
      await ref.read(twitchFfiProvider).disconnect();
      if (mounted) {
        setState(() {
          _connected = false;
          _userId = null;
          _username = null;
          _verifiedLogin = null;
          _busy = _TwitchBusy.none;
        });
        HollowToast.show(context, 'Twitch disconnected',
            type: HollowToastType.info);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = _TwitchBusy.none);
        HollowToast.show(context, friendlyError(e,
                fallback: "Couldn't disconnect Twitch. Try again."),
            type: HollowToastType.error);
      }
    }
  }

  String? get _subtitle {
    if (_loading) return null;
    if (_verifiedLogin != null) return 'Verified as $_verifiedLogin';
    if (_connected && (_username != null || _userId != null)) {
      if (_username != null) {
        return 'Connected as $_username, not verified yet';
      }
      final id = _userId!;
      return 'Connected (ID: ${id.length > 12 ? '${id.substring(0, 12)}...' : id})';
    }
    return 'A verified mark on your name, and entry to Twitch-verified servers';
  }

  @override
  Widget build(BuildContext context) {
    final busy = _busy != _TwitchBusy.none;
    final Widget? trailing;
    if (_loading) {
      trailing = null;
    } else if (_connected) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Connected but not verified: the mark is one press away, so offer it
          // rather than making them disconnect and start again.
          if (_verifiedLogin == null) ...[
            HollowButton.outline(
              onPressed: busy ? null : _verifyAccount,
              loading: _busy == _TwitchBusy.verify,
              compact: true,
              child: const Text('Verify'),
            ),
            const SizedBox(width: HollowSpacing.sm),
          ],
          HollowButton.ghost(
            onPressed: busy ? null : _disconnect,
            loading: _busy == _TwitchBusy.disconnect,
            compact: true,
            child: const Text('Disconnect'),
          ),
        ],
      );
    } else {
      trailing = HollowButton.outline(
        onPressed: _connect,
        compact: true,
        child: const Text('Connect'),
      );
    }

    return SettingsRow(
      title: 'Twitch',
      subtitle: _subtitle,
      leading: const SizedBox.square(
        dimension: HollowSpacing.xl + HollowSpacing.sm,
        child: Center(
          child: Icon(BrandIcons.twitch,
              size: 20, color: BrandIconColors.twitch),
        ),
      ),
      trailing: trailing,
    );
  }
}
