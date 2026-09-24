import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/core/providers/avatar_frame_provider.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/owned_art_provider.dart';
import 'package:hollow/src/core/providers/profile_anim_provider.dart';
import 'package:hollow/src/core/providers/profile_draft_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/dialogs/avatar_frame_picker.dart';
import 'package:hollow/src/ui/dialogs/image_crop_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_image_crop_route.dart';
import 'package:hollow/src/ui/settings/profile_section.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:hollow/src/ui/shop/owned_art_panel.dart';

/// Below this the preview goes above the rows rather than beside them.
const double _kSideBySideMinWidth = 560;

const double _kThumb = 48;

/// Settings > Profile. Hosted by the desktop Settings place and pushed as a phone
/// sub-page under `SettingsDensity(touch: true)`; the host owns the scroll.
///
/// Edits wait in [profileDraftProvider] until the Settings place's unsaved bar
/// (the phone: its page bar's Save) saves them; Presence, Twitch and art apply at once.
class ProfileSettingsPage extends ConsumerWidget {
  const ProfileSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final me = ref.watch(identityProvider.select((s) => s.peerId));
    if (me == null) {
      return const SettingsPage(
        title: 'Profile',
        children: [
          HollowEmptyState(dense: true, title: 'Your profile is still loading'),
        ],
      );
    }
    final touch = SettingsDensity.touchOf(context);
    final invisible = ref.watch(invisibleModeProvider);

    return SettingsPage(
      title: 'Profile',
      children: [
        LayoutBuilder(builder: (context, constraints) {
          final editor = _ProfileEditor(peerId: me);
          final preview = ProfilePreviewCard(peerId: me);
          if (touch || constraints.maxWidth < _kSideBySideMinWidth) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                touch
                    ? preview
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                            width: ProfilePreviewCard.width, child: preview),
                      ),
                const SizedBox(height: HollowSpacing.lg),
                editor,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: editor),
              const SizedBox(width: HollowSpacing.xxl),
              SizedBox(width: ProfilePreviewCard.width, child: preview),
            ],
          );
        }),
        SettingsSection(
          title: 'Presence',
          children: [
            SettingsSwitchRow(
              title: 'Appear invisible',
              subtitle: 'You show as offline. You still see who is online.',
              value: invisible,
              onChanged: (v) => ref
                  .read(invisibleModeProvider.notifier)
                  .setInvisible(v)
                  .catchError((_) {}),
            ),
          ],
        ),
        SettingsSection(
          title: 'Connections',
          children: [TwitchConnectionRow(hollow: hollow)],
        ),
        if (ref.watch(shopAvailableProvider)) ...[
          const OwnedArtPanel(),
          const SupportMarksSection(),
        ],
      ],
    );
  }
}

/// The three image rows and the text fields.
class _ProfileEditor extends ConsumerWidget {
  final String peerId;

  const _ProfileEditor({required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.read(profileDraftProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _AvatarRow(peerId: peerId),
        _BannerRow(peerId: peerId),
        _FrameRow(peerId: peerId),
        const SizedBox(height: HollowSpacing.md),
        const SettingsFieldLabel(label: 'Display name'),
        const SizedBox(height: HollowSpacing.xs),
        HollowTextField(
          controller: draft.displayName,
          hintText: 'Enter a display name',
          maxLength: 32,
        ),
        const SizedBox(height: HollowSpacing.md),
        const SettingsFieldLabel(label: 'Status'),
        const SizedBox(height: HollowSpacing.xs),
        HollowTextField(
          controller: draft.status,
          hintText: 'What are you up to?',
          maxLength: 48,
        ),
        const SizedBox(height: HollowSpacing.md),
        const SettingsFieldLabel(label: 'About me'),
        const SizedBox(height: HollowSpacing.xs),
        HollowTextField(
          controller: draft.aboutMe,
          maxLines: 3,
          maxLength: 128,
        ),
      ],
    );
  }
}

/// Picks an image for the avatar ([avatar]) or banner and hands it to the
/// draft. ANIMATED input skips the cropper, which is what keeps it moving.
///
/// Deliberately no SOURCE size check: Rust rejects on what it PRODUCES, and a
/// large GIF that converts small is a fine avatar. The animated test reads the
/// BYTES, never the extension, or animated WebP and APNG go through the
/// cropper and silently arrive as a still.
Future<void> _pickImage(BuildContext context, WidgetRef ref,
    {required bool avatar}) async {
  final result = await FilePicker.platform.pickFiles(type: FileType.image);
  if (result == null || result.files.isEmpty) return;
  final raw = await result.files.first.xFile.readAsBytes();
  if (!context.mounted) return;
  final draft = ref.read(profileDraftProvider.notifier);
  if (isAnimatedImageBytes(raw)) {
    draft.stageAnimated(Uint8List.fromList(raw), avatar: avatar);
    return;
  }
  // 2.5:1 for the banner, matching the profile card and Rust's storage. A
  // phone crops on a full-screen route, the desktop in a dialog.
  final crop = Platform.isAndroid || Platform.isIOS
      ? showMobileImageCrop
      : showImageCropDialog;
  final cropped = await crop(
    context: context,
    imageBytes: raw,
    aspectRatio: avatar ? 1.0 : 2.5,
    title: avatar ? 'Crop avatar' : 'Crop banner',
  );
  if (cropped == null || !context.mounted) return;
  draft.stageCropped(cropped, avatar: avatar);
}

class _AvatarRow extends ConsumerWidget {
  final String peerId;

  const _AvatarRow({required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(profileDraftProvider);
    final savedAvatar = ref.watch(avatarProvider)[peerId];
    // An ANIMATED avatar counts even when the still cache is cold: HollowAvatar
    // paints the rail blob and never asks for the still, so `avatarProvider`
    // stays empty for the people who most obviously have one.
    final savedAnimated = isProfileAnimHash(ref.watch(
        profileProvider.select((p) => p[peerId]?.avatarAnim ?? '')));
    final pending = draft.avatarBytes;
    final hasAvatar = draft.avatarChanged
        ? (pending != null && pending.isNotEmpty)
        : (savedAnimated || (savedAvatar != null && savedAvatar.isNotEmpty));

    return SettingsRow(
      title: 'Avatar',
      // Two buttons beside a thumbnail do not fit a phone's width.
      wideTrailing: true,
      subtitle: 'Square. A GIF or animated WebP moves.',
      leading: _Busy(
        busy: draft.avatarBusy,
        child: HollowAvatar(
          peerId: peerId,
          size: _kThumb,
          imageBytes: draft.avatarChanged ? pending : null,
          frameId: '',
          animate: true,
        ),
      ),
      trailing: _ChangeRemove(
        what: 'avatar',
        busy: draft.avatarBusy,
        onChange: () => _pickImage(context, ref, avatar: true),
        onRemove: hasAvatar
            ? () => ref
                .read(profileDraftProvider.notifier)
                .clearImage(avatar: true)
            : null,
      ),
    );
  }
}

class _BannerRow extends ConsumerWidget {
  final String peerId;

  const _BannerRow({required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final draft = ref.watch(profileDraftProvider);
    final bytes = watchDraftBanner(ref, peerId);
    final hasBanner = bytes != null && bytes.isNotEmpty;
    const height = _kThumb / 2.5;
    final fallback = ColoredBox(
      color: profileBannerColorFor(peerId),
      child: const SizedBox(width: _kThumb, height: height),
    );

    return SettingsRow(
      title: 'Banner',
      wideTrailing: true,
      subtitle: 'Wide, 2.5 to 1',
      leading: _Busy(
        busy: draft.bannerBusy,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(hollow.radiusXs),
          child: hasBanner
              ? AnimatedGifImage(
                  bytes: bytes,
                  width: _kThumb,
                  height: height,
                  fit: BoxFit.cover,
                  errorWidget: fallback,
                )
              : fallback,
        ),
      ),
      trailing: _ChangeRemove(
        what: 'banner',
        busy: draft.bannerBusy,
        onChange: () => _pickImage(context, ref, avatar: false),
        onRemove: hasBanner
            ? () => ref
                .read(profileDraftProvider.notifier)
                .clearImage(avatar: false)
            : null,
      ),
    );
  }
}

class _FrameRow extends ConsumerWidget {
  final String peerId;

  const _FrameRow({required this.peerId});

  Future<void> _choose(BuildContext context, WidgetRef ref, String current) async {
    final pick = await showAvatarFramePicker(
      context: context,
      peerId: peerId,
      currentId: current,
    );
    if (pick == null || !context.mounted) return;
    ref.read(profileDraftProvider.notifier).setFrame(pick.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(profileDraftProvider);
    final saved = ref.watch(
        profileProvider.select((p) => p[peerId]?.avatarFrame ?? ''));
    final current = draft.effectiveFrame ?? saved;
    final hasFrame = isRenderableFrame(current);

    return SettingsRow(
      title: 'Frame',
      wideTrailing: true,
      subtitle: hasFrame ? _frameName(ref, current) : 'None',
      leading: hasFrame
          ? HollowAvatar(
              peerId: peerId,
              size: _kThumb,
              imageBytes: draft.avatarChanged ? draft.avatarBytes : null,
              frameId: current,
            )
          : const _FramePlaceholder(),
      trailing: Wrap(
        spacing: HollowSpacing.sm,
        runSpacing: HollowSpacing.sm,
        children: [
          HollowButton.outline(
            onPressed: () => _choose(context, ref, current),
            compact: true,
            child: const Text('Choose'),
          ),
          if (current.isNotEmpty)
            HollowButton.ghost(
              onPressed: () =>
                  ref.read(profileDraftProvider.notifier).setFrame(''),
              compact: true,
              semanticLabel: 'Remove frame',
              child: const Text('Remove'),
            ),
        ],
      ),
    );
  }

  /// A built-in by its colour, owned art by its title.
  String _frameName(WidgetRef ref, String id) {
    final hue = builtinFrameHue(id);
    if (hue != null) {
      for (final f in kBuiltinFrames) {
        if (f.hue == hue.round()) return f.name;
      }
      return 'A colour frame';
    }
    for (final item in ref.watch(ownedArtProvider)) {
      if (item.frameHash == id) return item.title;
    }
    return 'Your own frame';
  }
}

/// Change (outline, the row's action) and Remove (ghost, null disables it).
class _ChangeRemove extends StatelessWidget {
  final String what;
  final bool busy;
  final VoidCallback onChange;
  final VoidCallback? onRemove;

  const _ChangeRemove({
    required this.what,
    required this.busy,
    required this.onChange,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    // A Wrap, so large text on a phone moves Remove to a second line.
    return Wrap(
      spacing: HollowSpacing.sm,
      runSpacing: HollowSpacing.sm,
      children: [
        HollowButton.outline(
          onPressed: onChange,
          loading: busy,
          compact: true,
          semanticLabel: 'Change $what',
          child: const Text('Change'),
        ),
        HollowButton.ghost(
          onPressed: onRemove,
          compact: true,
          semanticLabel: 'Remove $what',
          child: const Text('Remove'),
        ),
      ],
    );
  }
}

/// A small spinner on the thumb while its image encodes.
class _Busy extends StatelessWidget {
  final bool busy;
  final Widget child;

  const _Busy({required this.busy, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!busy) return child;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        const Positioned(right: 0, bottom: 0, child: HollowSpinner()),
      ],
    );
  }
}

/// Where a frame would go, drawn as a dashed outline of the avatar.
class _FramePlaceholder extends StatelessWidget {
  const _FramePlaceholder();

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return CustomPaint(
      size: const Size.square(_kThumb),
      painter: _DashedRectPainter(
        color: hollow.border,
        radius: hollow.radiusMd,
      ),
    );
  }
}

class _DashedRectPainter extends CustomPainter {
  final Color color;
  final double radius;

  const _DashedRectPainter({required this.color, required this.radius});

  static const double _dash = 4;
  static const double _gap = 3;
  static const double _stroke = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(_stroke / 2);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke;
    for (final ui.PathMetric metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + _dash), paint);
        d += _dash + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRectPainter old) =>
      old.color != color || old.radius != radius;
}
