import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/providers/identity_provider.dart';
import 'package:haven/src/core/providers/profile_provider.dart';
import 'package:haven/src/core/providers/settings_provider.dart';
import 'package:haven/src/core/providers/theme_provider.dart';
import 'package:haven/src/rust/api/network.dart' as network_api;
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/components/haven_avatar.dart';
import 'package:haven/src/ui/components/haven_button.dart';
import 'package:haven/src/ui/components/haven_dialog.dart';
import 'package:haven/src/ui/components/haven_text_field.dart';
import 'package:haven/src/ui/components/haven_toggle.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Shows the user settings dialog for editing profile and preferences.
void showUserSettingsDialog(BuildContext context, WidgetRef ref) {
  final localPeerId = ref.read(identityProvider).peerId;
  if (localPeerId == null) return;

  final profiles = ref.read(profileProvider);
  final currentProfile = profiles[localPeerId];

  final displayNameController = TextEditingController(
    text: currentProfile?.displayName ?? '',
  );
  final statusController = TextEditingController(
    text: currentProfile?.status ?? '',
  );
  final aboutMeController = TextEditingController(
    text: currentProfile?.aboutMe ?? '',
  );

  showHavenDialog(
    context: context,
    builder: (dialogContext) {
      return _UserSettingsContent(
        localPeerId: localPeerId,
        displayNameController: displayNameController,
        statusController: statusController,
        aboutMeController: aboutMeController,
      );
    },
  );
}

/// Deterministic banner color from peer ID (shifted hue from avatar).
Color _bannerColorFromId(String id) {
  final hash = id.hashCode;
  final hue = ((hash % 360).abs() + 40) % 360; // Shift hue from avatar
  return HSLColor.fromAHSL(1.0, hue.toDouble(), 0.45, 0.35).toColor();
}

class _UserSettingsContent extends ConsumerStatefulWidget {
  final String localPeerId;
  final TextEditingController displayNameController;
  final TextEditingController statusController;
  final TextEditingController aboutMeController;

  const _UserSettingsContent({
    required this.localPeerId,
    required this.displayNameController,
    required this.statusController,
    required this.aboutMeController,
  });

  @override
  ConsumerState<_UserSettingsContent> createState() =>
      _UserSettingsContentState();
}

class _UserSettingsContentState extends ConsumerState<_UserSettingsContent> {
  // Track live fields for the preview card.
  String _liveDisplayName = '';
  String _liveStatus = '';

  // Pending toggle states (applied only on Save).
  late bool _pendingDarkMode;
  bool _pendingMinimizeToTray = true;
  bool _initialMinimizeToTray = true;
  bool _trayInitialized = false;
  bool _pendingProxy = false;
  bool _initialProxy = false;
  bool _proxyInitialized = false;

  @override
  void initState() {
    super.initState();
    _liveDisplayName = widget.displayNameController.text;
    _liveStatus = widget.statusController.text;
    widget.displayNameController.addListener(_onFieldChanged);
    widget.statusController.addListener(_onFieldChanged);

    _pendingDarkMode =
        ref.read(themeModeProvider) == ThemeMode.dark;

    // If already loaded, use the value directly.
    final trayAsync = ref.read(minimizeToTrayProvider);
    if (trayAsync.hasValue) {
      _pendingMinimizeToTray = trayAsync.value!;
      _initialMinimizeToTray = _pendingMinimizeToTray;
      _trayInitialized = true;
    }

    final proxyAsync = ref.read(proxyEnabledProvider);
    if (proxyAsync.hasValue) {
      _pendingProxy = proxyAsync.value!;
      _initialProxy = _pendingProxy;
      _proxyInitialized = true;
    }
  }

  void _onFieldChanged() {
    setState(() {
      _liveDisplayName = widget.displayNameController.text;
      _liveStatus = widget.statusController.text;
    });
  }

  @override
  void dispose() {
    widget.displayNameController.removeListener(_onFieldChanged);
    widget.statusController.removeListener(_onFieldChanged);
    super.dispose();
  }

  Future<void> _onSave() async {
    final displayName = widget.displayNameController.text.trim();
    final status = widget.statusController.text.trim();
    final aboutMe = widget.aboutMeController.text.trim();

    // Apply theme change.
    ref.read(themeModeProvider.notifier).state =
        _pendingDarkMode ? ThemeMode.dark : ThemeMode.light;

    // Apply minimize to tray change.
    if (_pendingMinimizeToTray != _initialMinimizeToTray) {
      await ref
          .read(minimizeToTrayProvider.notifier)
          .setEnabled(_pendingMinimizeToTray);
    }

    // Apply proxy change.
    final proxyChanged = _pendingProxy != _initialProxy;
    if (proxyChanged) {
      await ref
          .read(proxyEnabledProvider.notifier)
          .setEnabled(_pendingProxy);
    }

    // Save profile.
    await ref.read(profileProvider.notifier).updateMyProfile(
          displayName: displayName,
          status: status,
          aboutMe: aboutMe,
        );

    if (!mounted) return;
    Navigator.of(context).pop();

    // Show restart prompt if proxy setting changed.
    if (proxyChanged && mounted) {
      _showRestartDialog(context);
    }
  }

  void _showRestartDialog(BuildContext parentContext) {
    showHavenDialog(
      context: parentContext,
      builder: (ctx) => _RestartPrompt(),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Update pending minimize-to-tray once the async value resolves.
    if (!_trayInitialized) {
      ref.listen(minimizeToTrayProvider, (prev, next) {
        if (next.hasValue && !_trayInitialized) {
          setState(() {
            _pendingMinimizeToTray = next.value!;
            _initialMinimizeToTray = _pendingMinimizeToTray;
            _trayInitialized = true;
          });
        }
      });
    }

    // Update pending proxy once the async value resolves.
    if (!_proxyInitialized) {
      ref.listen(proxyEnabledProvider, (prev, next) {
        if (next.hasValue && !_proxyInitialized) {
          setState(() {
            _pendingProxy = next.value!;
            _initialProxy = _pendingProxy;
            _proxyInitialized = true;
          });
        }
      });
    }

    final haven = HavenTheme.of(context);
    final bannerColor = _bannerColorFromId(widget.localPeerId);
    final radius = BorderRadius.circular(haven.radiusLg);

    // Preview display name: live text or fallback.
    final previewName = _liveDisplayName.trim().isNotEmpty
        ? _liveDisplayName.trim()
        : displayNameFor(ref.watch(profileProvider), widget.localPeerId);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 600,
            minWidth: 400,
          ),
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: haven.elevated.withValues(alpha: 0.92),
                borderRadius: radius,
                border: Border.all(
                  color: haven.accent.withValues(alpha: 0.15),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 24,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      HavenSpacing.xl,
                      HavenSpacing.xl,
                      HavenSpacing.xl,
                      HavenSpacing.lg,
                    ),
                    child: Row(
                      children: [
                        Text(
                          'Settings',
                          style: HavenTypography.heading
                              .copyWith(color: haven.textPrimary),
                        ),
                      ],
                    ),
                  ),

                  // Two-column body
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: HavenSpacing.xl,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Left: Profile preview card
                        SizedBox(
                          width: 220,
                          child: Container(
                            decoration: BoxDecoration(
                              color: haven.surface,
                              borderRadius:
                                  BorderRadius.circular(haven.radiusMd),
                              border: Border.all(color: haven.border),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Banner
                                Container(
                                  height: 80,
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [
                                        bannerColor,
                                        bannerColor.withValues(alpha: 0.7),
                                      ],
                                    ),
                                  ),
                                ),

                                // Avatar overlapping banner
                                Transform.translate(
                                  offset: const Offset(0, -32),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: HavenSpacing.md,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.center,
                                      children: [
                                        // Avatar with border
                                        Container(
                                          decoration: BoxDecoration(
                                            borderRadius:
                                                BorderRadius.circular(
                                                    haven.radiusMd + 2),
                                            border: Border.all(
                                              color: haven.surface,
                                              width: 3,
                                            ),
                                          ),
                                          child: HavenAvatar(
                                            peerId: widget.localPeerId,
                                            size: 64,
                                          ),
                                        ),

                                        const SizedBox(
                                            height: HavenSpacing.xs + 2),

                                        // Display name
                                        Text(
                                          previewName,
                                          style: HavenTypography.subheading
                                              .copyWith(
                                            color: haven.textPrimary,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 15,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          textAlign: TextAlign.center,
                                        ),

                                        // Status (before divider)
                                        if (_liveStatus.trim().isNotEmpty) ...[
                                          const SizedBox(
                                              height: HavenSpacing.xs),
                                          Text(
                                            _liveStatus.trim(),
                                            style: HavenTypography.caption
                                                .copyWith(
                                              color: haven.textSecondary,
                                              fontSize: 11,
                                              fontStyle: FontStyle.italic,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.center,
                                          ),
                                        ],

                                        const SizedBox(
                                            height: HavenSpacing.sm),
                                        Container(
                                          height: 1,
                                          color: haven.border,
                                        ),

                                        // About Me preview
                                        if (widget.aboutMeController.text
                                            .trim()
                                            .isNotEmpty) ...[
                                          const SizedBox(
                                              height: HavenSpacing.sm),
                                          Text(
                                            'ABOUT ME',
                                            style: HavenTypography.caption
                                                .copyWith(
                                              color: haven.textSecondary,
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: 0.5,
                                              fontSize: 9,
                                            ),
                                          ),
                                          const SizedBox(
                                              height: HavenSpacing.xxs),
                                          Text(
                                            widget.aboutMeController.text
                                                .trim(),
                                            style: HavenTypography.caption
                                                .copyWith(
                                              color: haven.textSecondary,
                                              fontSize: 11,
                                            ),
                                            maxLines: 4,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.center,
                                          ),
                                        ],

                                        // Peer ID footer
                                        const SizedBox(
                                            height: HavenSpacing.sm),
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Icon(
                                              LucideIcons.copy,
                                              size: 8,
                                              color: haven.textSecondary
                                                  .withValues(alpha: 0.35),
                                            ),
                                            const SizedBox(width: 3),
                                            Text(
                                              widget.localPeerId.length > 16
                                                  ? widget.localPeerId
                                                      .substring(
                                                          widget.localPeerId
                                                                  .length -
                                                              8)
                                                  : widget.localPeerId,
                                              style: HavenTypography.mono
                                                  .copyWith(
                                                color: haven.textSecondary
                                                    .withValues(alpha: 0.35),
                                                fontSize: 8,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(width: HavenSpacing.xl),

                        // Right: Input fields
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _FieldLabel(label: 'DISPLAY NAME'),
                              const SizedBox(height: HavenSpacing.xs),
                              HavenTextField(
                                controller:
                                    widget.displayNameController,
                                hintText: 'Enter a display name',
                                autofocus: true,
                                maxLength: 32,
                              ),

                              const SizedBox(height: HavenSpacing.lg),

                              _FieldLabel(label: 'STATUS'),
                              const SizedBox(height: HavenSpacing.xs),
                              HavenTextField(
                                controller: widget.statusController,
                                hintText: 'What are you up to?',
                                maxLength: 48,
                              ),

                              const SizedBox(height: HavenSpacing.lg),

                              _FieldLabel(label: 'ABOUT ME'),
                              const SizedBox(height: HavenSpacing.xs),
                              HavenTextField(
                                controller: widget.aboutMeController,
                                hintText: 'Tell us about yourself',
                                maxLines: 3,
                                maxLength: 128,
                                onChanged: (_) => setState(() {}),
                              ),

                              const SizedBox(height: HavenSpacing.xl),

                              // Divider
                              Container(
                                height: 1,
                                color: haven.border,
                              ),

                              const SizedBox(height: HavenSpacing.lg),

                              // Theme toggle
                              Row(
                                children: [
                                  Icon(
                                    _pendingDarkMode
                                        ? LucideIcons.moon
                                        : LucideIcons.sun,
                                    size: 16,
                                    color: haven.textSecondary,
                                  ),
                                  const SizedBox(width: HavenSpacing.sm),
                                  Expanded(
                                    child: Text(
                                      'Dark Mode',
                                      style:
                                          HavenTypography.body.copyWith(
                                        color: haven.textPrimary,
                                      ),
                                    ),
                                  ),
                                  HavenToggle(
                                    value: _pendingDarkMode,
                                    onChanged: (value) {
                                      setState(() {
                                        _pendingDarkMode = value;
                                      });
                                    },
                                  ),
                                ],
                              ),

                              const SizedBox(height: HavenSpacing.md),

                              // Minimize to tray toggle
                              if (Platform.isWindows ||
                                  Platform.isLinux ||
                                  Platform.isMacOS)
                                Row(
                                  children: [
                                    Icon(
                                      LucideIcons.minimize2,
                                      size: 16,
                                      color: haven.textSecondary,
                                    ),
                                    const SizedBox(width: HavenSpacing.sm),
                                    Expanded(
                                      child: Text(
                                        'Minimize to Tray',
                                        style:
                                            HavenTypography.body.copyWith(
                                          color: haven.textPrimary,
                                        ),
                                      ),
                                    ),
                                    HavenToggle(
                                      value: _pendingMinimizeToTray,
                                      onChanged: (value) {
                                        setState(() {
                                          _pendingMinimizeToTray = value;
                                        });
                                      },
                                    ),
                                  ],
                                ),

                              if (Platform.isWindows ||
                                  Platform.isLinux ||
                                  Platform.isMacOS)
                                const SizedBox(height: HavenSpacing.md),

                              // Proxy toggle
                              Row(
                                children: [
                                  Icon(
                                    LucideIcons.shield,
                                    size: 16,
                                    color: haven.textSecondary,
                                  ),
                                  const SizedBox(width: HavenSpacing.sm),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Use Proxy',
                                          style:
                                              HavenTypography.body.copyWith(
                                            color: haven.textPrimary,
                                          ),
                                        ),
                                        Text(
                                          'For restricted networks',
                                          style: HavenTypography.caption
                                              .copyWith(
                                            color: haven.textSecondary,
                                            fontSize: 10,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  HavenToggle(
                                    value: _pendingProxy,
                                    onChanged: (value) {
                                      setState(() {
                                        _pendingProxy = value;
                                      });
                                    },
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Actions
                  Padding(
                    padding: const EdgeInsets.all(HavenSpacing.xl),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        HavenButton.ghost(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: HavenSpacing.sm),
                        HavenButton.filled(
                          onPressed: _onSave,
                          child: const Text('Save'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Restart prompt dialog shown after proxy setting changes.
class _RestartPrompt extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final haven = HavenTheme.of(context);
    final radius = BorderRadius.circular(haven.radiusMd);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Material(
          color: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: haven.elevated.withValues(alpha: 0.95),
              borderRadius: radius,
              border: Border.all(
                color: haven.accent.withValues(alpha: 0.15),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 20,
                ),
              ],
            ),
            padding: const EdgeInsets.all(HavenSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.rotateCcw,
                  size: 32,
                  color: haven.accent,
                ),
                const SizedBox(height: HavenSpacing.md),
                Text(
                  'Restart Required',
                  style: HavenTypography.subheading.copyWith(
                    color: haven.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: HavenSpacing.sm),
                Text(
                  'The proxy setting requires a restart to take effect.',
                  style: HavenTypography.body.copyWith(
                    color: haven.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: HavenSpacing.xl),
                Row(
                  children: [
                    Expanded(
                      child: HavenButton.ghost(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Restart Later'),
                      ),
                    ),
                    const SizedBox(width: HavenSpacing.sm),
                    Expanded(
                      child: HavenButton.filled(
                        onPressed: () async {
                          // Graceful shutdown: notify peers, stop node.
                          try {
                            await network_api.notifyShutdown();
                            await Future.delayed(
                                const Duration(milliseconds: 200));
                          } catch (_) {}

                          // Spawn new instance before exiting.
                          final exe = Platform.resolvedExecutable;
                          await Process.start(exe, [],
                              mode: ProcessStartMode.detached);

                          // Small delay to let the OS fully detach the child.
                          await Future.delayed(
                              const Duration(milliseconds: 100));
                          exit(0);
                        },
                        child: const Text('Restart Now'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String label;
  const _FieldLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);
    return Text(
      label,
      style: HavenTypography.caption.copyWith(
        color: haven.textSecondary,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
        fontSize: 10,
      ),
    );
  }
}
