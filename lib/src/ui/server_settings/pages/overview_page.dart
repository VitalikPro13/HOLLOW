import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/server_avatar_anim_provider.dart';
import 'package:hollow/src/core/providers/server_avatar_provider.dart';
import 'package:hollow/src/core/providers/server_banner_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_settings_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/server_avatar.dart';
import 'package:hollow/src/ui/components/server_icon_image.dart';
import 'package:hollow/src/ui/dialogs/image_crop_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_image_crop_route.dart';
import 'package:hollow/src/ui/server_settings/server_settings_catalog.dart';
import 'package:hollow/src/ui/settings/server_template.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';

/// Below this the invite preview goes above the fields rather than beside.
const double _kSideBySideMinWidth = 560;
const double _kThumb = 48;

/// Animated icons and banners skip the cropper, so their size is capped here.
const int _kAnimatedMaxBytes = 2 * 1024 * 1024;

/// What the server is: icon, banner, name and description, with a preview of
/// how an invite shows them. Icon and banner apply at once; the text waits for
/// the unsaved bar.
class OverviewPage extends ConsumerStatefulWidget {
  final String serverId;
  const OverviewPage({super.key, required this.serverId});

  @override
  ConsumerState<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends ConsumerState<OverviewPage> {
  // The picked bytes render while the encode and CRDT write run. A newer pick
  // or clear bumps the generation, so a stale completion cannot clobber it.
  Uint8List? _stagedIcon;
  bool _iconBusy = false;
  int _iconGen = 0;
  Uint8List? _stagedBanner;
  bool _bannerBusy = false;
  int _bannerGen = 0;

  String get _sid => widget.serverId;

  /// Reads a picked image, cropping a still to [aspect]; null when cancelled.
  Future<Uint8List?> _pick({required double aspect, required String title,
      required String tooBig}) async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result == null || result.files.isEmpty) return null;
    final raw = await result.files.first.xFile.readAsBytes();
    if (!mounted) return null;
    if (isAnimatedImageBytes(raw)) {
      if (raw.length > _kAnimatedMaxBytes) {
        HollowToast.show(context, tooBig, type: HollowToastType.error);
        return null;
      }
      return raw;
    }
    final crop = Platform.isAndroid || Platform.isIOS
        ? showMobileImageCrop
        : showImageCropDialog;
    return crop(
        context: context, imageBytes: raw, aspectRatio: aspect, title: title);
  }

  Future<void> _changeIcon() async {
    final gen = ++_iconGen;
    final bytes = await _pick(
        aspect: 1,
        title: 'Crop server icon',
        tooBig: 'That animation is over 2 MB. Try a shorter one.');
    if (bytes == null || !mounted || gen != _iconGen) return;
    final animated = isAnimatedImageBytes(bytes);
    setState(() {
      _stagedIcon = bytes;
      _iconBusy = true;
    });
    try {
      await crdt_api.setServerAvatar(serverId: _sid, rawBytes: bytes);
      if (!mounted || gen != _iconGen) return;
      // Seed with what we sent: a DB read here races the queued write and
      // returns the previous icon.
      ref.read(serverAvatarProvider.notifier).applyLocalWrite(_sid, bytes);
      ref
          .read(serverAvatarAnimProvider.notifier)
          .applyLocalWrite(_sid, animated ? bytes : null);
      setState(() {
        _stagedIcon = null;
        _iconBusy = false;
      });
      HollowToast.show(context, 'Server icon updated',
          type: HollowToastType.success);
    } catch (e) {
      if (!mounted || gen != _iconGen) return;
      setState(() {
        _stagedIcon = null;
        _iconBusy = false;
      });
      HollowToast.show(context, 'Could not update the icon: $e',
          type: HollowToastType.error);
    }
  }

  Future<void> _removeIcon() async {
    _iconGen++;
    setState(() {
      _stagedIcon = null;
      _iconBusy = false;
    });
    try {
      await crdt_api.clearServerAvatar(serverId: _sid);
      if (!mounted) return;
      ref.read(serverAvatarProvider.notifier).applyLocalWrite(_sid, null);
      ref.read(serverAvatarAnimProvider.notifier).applyLocalWrite(_sid, null);
      HollowToast.show(context, 'Server icon removed',
          type: HollowToastType.success);
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Could not remove the icon: $e',
            type: HollowToastType.error);
      }
    }
  }

  Future<void> _changeBanner() async {
    final gen = ++_bannerGen;
    final bytes = await _pick(
        aspect: 3,
        title: 'Crop server banner',
        tooBig: 'That animation is over 2 MB. Try a shorter one.');
    if (bytes == null || !mounted || gen != _bannerGen) return;
    setState(() {
      _stagedBanner = bytes;
      _bannerBusy = true;
    });
    try {
      await crdt_api.setServerBanner(serverId: _sid, rawBytes: bytes);
      if (!mounted || gen != _bannerGen) return;
      ref.read(serverBannerProvider.notifier).applyLocalWrite(_sid, bytes);
      setState(() {
        _stagedBanner = null;
        _bannerBusy = false;
      });
      HollowToast.show(context, 'Server banner updated',
          type: HollowToastType.success);
    } catch (e) {
      if (!mounted || gen != _bannerGen) return;
      setState(() {
        _stagedBanner = null;
        _bannerBusy = false;
      });
      HollowToast.show(context, 'Could not update the banner: $e',
          type: HollowToastType.error);
    }
  }

  Future<void> _removeBanner() async {
    _bannerGen++;
    setState(() {
      _stagedBanner = null;
      _bannerBusy = false;
    });
    try {
      await crdt_api.clearServerBanner(serverId: _sid);
      if (!mounted) return;
      ref.read(serverBannerProvider.notifier).applyLocalWrite(_sid, null);
      HollowToast.show(context, 'Server banner removed',
          type: HollowToastType.success);
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Could not remove the banner: $e',
            type: HollowToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final touch = SettingsDensity.touchOf(context);
    final server = ref.watch(serverListProvider)[_sid];
    final isOwner = ref.watch(myRoleProvider(_sid)).valueOrNull == 'owner';
    final banner =
        _stagedBanner ?? ref.watch(serverBannerProvider)[_sid]?.bytes;

    return SettingsPage(
      title: 'Overview',
      children: [
        LayoutBuilder(builder: (context, constraints) {
          final editor = _Editor(
            serverId: _sid,
            icon: _IconThumb(
                serverId: _sid, staged: _stagedIcon, busy: _iconBusy),
            iconBusy: _iconBusy,
            hasIcon: _stagedIcon != null ||
                ref.watch(serverAvatarProvider).containsKey(_sid),
            onChangeIcon: _changeIcon,
            onRemoveIcon: _removeIcon,
            banner: _BannerThumb(bytes: banner, busy: _bannerBusy),
            bannerBusy: _bannerBusy,
            hasBanner: banner != null,
            onChangeBanner: _changeBanner,
            onRemoveBanner: _removeBanner,
          );
          final preview = _InvitePreview(
              serverId: _sid, stagedIcon: _stagedIcon, banner: banner);
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
                            width: _InvitePreview.width, child: preview),
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
              SizedBox(width: _InvitePreview.width, child: preview),
            ],
          );
        }),
        SettingsAdvanced(
          children: [
            SettingsRow(
              title: 'Server ID',
              subtitleWidget: Text(_sid,
                  style: HollowTypography.monoSmall.copyWith(
                      color: HollowTheme.of(context).textSecondary)),
              trailing: HollowButton.ghost(
                compact: true,
                semanticLabel: 'Copy server ID',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _sid));
                  HollowToast.show(context, 'Server ID copied');
                },
                child: const Text('Copy'),
              ),
            ),
            if (server != null)
              SettingsRow(
                title: 'Template',
                subtitle: 'Save the channels and settings to a file, or '
                    'rebuild this server from one. Messages are never '
                    'deleted.',
                wideTrailing: true,
                trailing: Wrap(
                  spacing: HollowSpacing.sm,
                  runSpacing: HollowSpacing.sm,
                  children: [
                    HollowButton.ghost(
                      compact: true,
                      semanticLabel: 'Export a template',
                      onPressed: () => exportServerTemplate(context, server),
                      child: const Text('Export'),
                    ),
                    HollowButton.ghost(
                      compact: true,
                      semanticLabel: 'Import a template',
                      onPressed: () =>
                          importServerTemplate(context, ref, server),
                      child: const Text('Import'),
                    ),
                  ],
                ),
              ),
          ],
        ),
        if (isOwner)
          SettingsSection(
            title: 'Danger zone',
            children: [
              SettingsRow(
                title: 'Delete this server',
                subtitle: "Every channel and message goes, for everyone. "
                    "This can't be undone.",
                trailing: HollowButton.outline(
                  danger: true,
                  compact: true,
                  onPressed: () => confirmDeleteServer(context, ref, _sid),
                  child: const Text('Delete server'),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _Editor extends ConsumerWidget {
  final String serverId;
  final Widget icon;
  final bool iconBusy;
  final bool hasIcon;
  final VoidCallback onChangeIcon;
  final VoidCallback onRemoveIcon;
  final Widget banner;
  final bool bannerBusy;
  final bool hasBanner;
  final VoidCallback onChangeBanner;
  final VoidCallback onRemoveBanner;

  const _Editor({
    required this.serverId,
    required this.icon,
    required this.iconBusy,
    required this.hasIcon,
    required this.onChangeIcon,
    required this.onRemoveIcon,
    required this.banner,
    required this.bannerBusy,
    required this.hasBanner,
    required this.onChangeBanner,
    required this.onRemoveBanner,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.read(serverSettingsDraftProvider(serverId).notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SettingsRow(
          title: 'Icon',
          subtitle: 'Square. A GIF or animated WebP moves.',
          wideTrailing: true,
          leading: icon,
          trailing: _ChangeRemove(
            what: 'icon',
            busy: iconBusy,
            onChange: onChangeIcon,
            onRemove: hasIcon ? onRemoveIcon : null,
          ),
        ),
        SettingsRow(
          title: 'Banner',
          subtitle: 'Wide, 3 to 1',
          wideTrailing: true,
          leading: banner,
          trailing: _ChangeRemove(
            what: 'banner',
            busy: bannerBusy,
            onChange: onChangeBanner,
            onRemove: hasBanner ? onRemoveBanner : null,
          ),
        ),
        const SizedBox(height: HollowSpacing.md),
        const SettingsFieldLabel(label: 'Name'),
        const SizedBox(height: HollowSpacing.xs),
        HollowTextField(
          controller: draft.name,
          hintText: 'Server name',
          maxLength: 32,
        ),
        const SizedBox(height: HollowSpacing.md),
        const SettingsFieldLabel(label: 'Description'),
        const SizedBox(height: HollowSpacing.xs),
        HollowTextField(
          controller: draft.description,
          hintText: 'What is this server about?',
          maxLines: 3,
          maxLength: 256,
        ),
      ],
    );
  }
}

/// Change (outline, the row's action) and Remove (ghost, null when unset).
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
        if (onRemove != null)
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

class _IconThumb extends ConsumerWidget {
  final String serverId;
  final Uint8List? staged;
  final bool busy;

  const _IconThumb(
      {required this.serverId, required this.staged, required this.busy});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final name = ref.watch(serverListProvider)[serverId]?.name ?? '';
    final radius = BorderRadius.circular(hollow.radiusMd);
    final Widget tile = staged != null
        ? ClipRRect(
            borderRadius: radius,
            child: AnimatedGifImage(
                bytes: staged!, width: _kThumb, height: _kThumb, fit: BoxFit.cover),
          )
        : ServerIconImage(
            serverId: serverId,
            size: _kThumb,
            // The authoring tile counts as watched while the page is open.
            isSelected: true,
            borderRadius: radius,
            fallback: ServerAvatar(serverId: serverId, name: name, size: _kThumb),
          );
    return _Busy(busy: busy, child: tile);
  }
}

class _BannerThumb extends StatelessWidget {
  final Uint8List? bytes;
  final bool busy;

  const _BannerThumb({required this.bytes, required this.busy});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    const height = _kThumb / 3;
    final empty = ColoredBox(
      color: hollow.elevated,
      child: const SizedBox(width: _kThumb, height: height),
    );
    return _Busy(
      busy: busy,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(hollow.radiusXs),
        child: bytes == null
            ? empty
            : AnimatedGifImage(
                bytes: bytes!,
                width: _kThumb,
                height: height,
                fit: BoxFit.cover,
                errorWidget: empty,
              ),
      ),
    );
  }
}

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

/// How an invite shows the server, live from the unsaved fields.
class _InvitePreview extends ConsumerWidget {
  final String serverId;
  final Uint8List? stagedIcon;
  final Uint8List? banner;

  const _InvitePreview(
      {required this.serverId, required this.stagedIcon, required this.banner});

  static const double width = 232;
  static const double _icon = 56;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final draft = ref.read(serverSettingsDraftProvider(serverId).notifier);
    final online = ref.watch(onlineMembersProvider(serverId)).length;
    final members = ref.watch(serverMembersProvider(serverId)).valueOrNull?.length ??
        ref.watch(serverListProvider)[serverId]?.memberCount ??
        0;
    final radius = BorderRadius.circular(hollow.radiusMd);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('How an invite shows it',
            style: HollowTypography.label.copyWith(color: hollow.textSecondary)),
        const SizedBox(height: HollowSpacing.sm),
        Container(
          decoration: BoxDecoration(
            color: hollow.elevated,
            borderRadius: BorderRadius.circular(hollow.radiusLg),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              AspectRatio(
                aspectRatio: 3,
                child: banner == null
                    ? ColoredBox(color: hollow.overlay)
                    : AnimatedGifImage(bytes: banner!, fit: BoxFit.cover),
              ),
              Transform.translate(
                offset: const Offset(0, -HollowSpacing.xl),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
                  child: ListenableBuilder(
                    listenable:
                        Listenable.merge([draft.name, draft.description]),
                    builder: (context, _) {
                      final name = draft.name.text.trim();
                      final description = draft.description.text.trim();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius:
                                  BorderRadius.circular(hollow.radiusLg),
                              border: Border.all(
                                  color: hollow.elevated,
                                  width: HollowSpacing.xs),
                            ),
                            child: stagedIcon != null
                                ? ClipRRect(
                                    borderRadius: radius,
                                    child: AnimatedGifImage(
                                        bytes: stagedIcon!,
                                        width: _icon,
                                        height: _icon,
                                        fit: BoxFit.cover),
                                  )
                                : ServerIconImage(
                                    serverId: serverId,
                                    size: _icon,
                                    isSelected: true,
                                    borderRadius: radius,
                                    fallback: ServerAvatar(
                                        serverId: serverId,
                                        name: name,
                                        size: _icon),
                                  ),
                          ),
                          const SizedBox(height: HollowSpacing.xs),
                          Text(
                            name.isEmpty ? 'Server name' : name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HollowTypography.subheading.copyWith(
                                color: name.isEmpty
                                    ? hollow.textTertiary
                                    : hollow.textPrimary),
                          ),
                          if (description.isNotEmpty) ...[
                            const SizedBox(height: HollowSpacing.xxs),
                            Text(
                              description,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: HollowTypography.bodySmall
                                  .copyWith(color: hollow.textSecondary),
                            ),
                          ],
                          const SizedBox(height: HollowSpacing.sm),
                          Text(
                            '$online online · $members '
                            '${members == 1 ? 'member' : 'members'}',
                            style: HollowTypography.caption
                                .copyWith(color: hollow.textSecondary),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
