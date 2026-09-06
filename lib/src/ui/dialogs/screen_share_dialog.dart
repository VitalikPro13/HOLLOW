import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/core/services/desktop_capture_support.dart';
import 'package:hollow/src/core/services/macos_version.dart';
import 'package:hollow/src/core/services/screen_share_service.dart'
    show ScreenContentProfile;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/selector_pill.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';

enum ScreenShareResolution {
  p360(640, 360, '360p'),
  p480(854, 480, '480p'),
  p720(1280, 720, '720p'),
  p1080(1920, 1080, '1080p'),
  p1440(2560, 1440, '1440p'),
  p4k(3840, 2160, '4K');

  final int width, height;
  final String label;
  const ScreenShareResolution(this.width, this.height, this.label);
}

enum ScreenShareFps {
  fps5(5, '5 FPS'),
  fps15(15, '15 FPS'),
  fps30(30, '30 FPS'),
  fps60(60, '60 FPS');

  final int value;
  final String label;
  const ScreenShareFps(this.value, this.label);
}

class ScreenShareSelection {
  final String sourceId;
  final int width;
  final int height;
  final int fps;
  final bool shareAudio;
  final int pid;

  /// What the shared content mostly is, which drives the encoder tuning in
  /// [ScreenContentProfile].
  final ScreenContentProfile profile;

  /// For a WINDOW share on Windows, the window's HWND, and 0 for a screen
  /// share. The screen-audio exe resolves it to the app's audio-rendering pids
  /// itself, because libwebrtc does not populate a window [pid] dependably and
  /// a 0 there drops the share back to system audio.
  final int windowHwnd;

  const ScreenShareSelection({
    required this.sourceId,
    required this.width,
    required this.height,
    required this.fps,
    this.shareAudio = false,
    this.pid = 0,
    this.windowHwnd = 0,
    this.profile = ScreenContentProfile.motion,
  });

  /// Human-readable quality label, e.g. "1080p60".
  String get qualityLabel {
    const resLabels = {360: '360p', 480: '480p', 720: '720p', 1080: '1080p', 1440: '1440p', 2160: '4K'};
    final res = resLabels[height] ?? '${height}p';
    return '$res$fps';
  }
}

/// Shows the screen share picker, returning null when it is cancelled.
Future<ScreenShareSelection?> showScreenShareDialog(
    BuildContext context) async {
  return showHollowDialog<ScreenShareSelection>(
    context: context,
    builder: (context) => const _ScreenShareDialog(),
  );
}

class _ScreenShareDialog extends StatefulWidget {
  const _ScreenShareDialog();

  @override
  State<_ScreenShareDialog> createState() => _ScreenShareDialogState();
}

class _ScreenShareDialogState extends State<_ScreenShareDialog> {
  final Map<String, DesktopCapturerSource> _sources = {};
  String? _selectedSourceId;
  ScreenShareResolution _resolution = ScreenShareResolution.p1080;
  ScreenShareFps _fps = ScreenShareFps.fps60;
  ScreenContentProfile _profile = ScreenContentProfile.motion;
  bool _shareAudio = false;
  bool _loading = true;
  bool _showScreens = true; // true = screens tab, false = windows tab
  Timer? _refreshTimer;

  /// Wayland portal-first mode: no enumeration and no thumbnails, because the
  /// desktop's own portal dialog picks the source at capture start.
  final bool _portalMode = DesktopCaptureSupport.usePortalPicker;

  /// Portal mode only: the user wants a fresh portal prompt rather than a
  /// silent re-share of what the last grant covered.
  bool _portalFresh = false;
  late final List<ScreenShareResolution> _availableResolutions =
      _computeAvailableResolutions();

  /// Only the resolutions a connected display can produce: capture is native
  /// resolution and the encoder only downscales, so a preset above the display
  /// costs bitrate for the same pixels. Orientation-agnostic, available if ANY
  /// display fits it, and the full list when the platform reports nothing.
  List<ScreenShareResolution> _computeAvailableResolutions() {
    final displays = WidgetsBinding.instance.platformDispatcher.displays;
    if (displays.isEmpty) return ScreenShareResolution.values;
    bool fitsAny(ScreenShareResolution r) => displays.any((d) {
          final w = d.size.width, h = d.size.height;
          final long = w > h ? w : h;
          final short = w > h ? h : w;
          return r.width <= long && r.height <= short;
        });
    final fitting = ScreenShareResolution.values.where(fitsAny).toList();
    return fitting.isEmpty ? [ScreenShareResolution.p360] : fitting;
  }

  @override
  void initState() {
    super.initState();
    // Clamp the default down to the best available tier on a smaller display.
    if (!_availableResolutions.contains(_resolution)) {
      _resolution = _availableResolutions.last;
    }

    // Portal mode never enumerates: merely building a desktop media list on
    // Wayland pops the desktop's own portal dialog, and windows cannot be
    // listed there at all.
    if (_portalMode) {
      _loading = false;
      return;
    }
    _loadSources();

    desktopCapturer.onAdded.stream.listen((source) {
      if (mounted) setState(() => _sources[source.id] = source);
    });
    desktopCapturer.onRemoved.stream.listen((source) {
      if (mounted) setState(() => _sources.remove(source.id));
    });
    desktopCapturer.onThumbnailChanged.stream.listen((source) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadSources() async {
    try {
      // macOS enumerates nothing until Screen Recording is granted, so the
      // system prompt comes first. getSources() still runs after a denial, so
      // the dialog shows its "no sources" state instead of the loader.
      if (Platform.isMacOS) {
        try {
          await Helper.requestCapturePermission();
        } catch (_) {}
      }
      final sources = await desktopCapturer.getSources(
        types: DesktopCaptureSupport.sourceTypes,
      );
      if (!mounted) return;

      setState(() {
        for (final s in sources) {
          _sources[s.id] = s;
        }
        _loading = false;
      });

      _refreshTimer?.cancel();
      _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        desktopCapturer.updateSources(types: DesktopCaptureSupport.sourceTypes);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  List<DesktopCapturerSource> get _filteredSources {
    final type = _showScreens ? SourceType.Screen : SourceType.Window;
    return _sources.values.where((s) => s.type == type).toList();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final radius = BorderRadius.circular(hollow.radiusLg);
    final sources = _filteredSources;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 680,
            maxHeight: 560,
            minWidth: 400,
          ),
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.all(HollowSpacing.xl),
              decoration: BoxDecoration(
                color: hollow.elevated.withValues(alpha: 0.95),
                borderRadius: radius,
                border: Border.all(
                    color: hollow.accent.withValues(alpha: 0.15)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Share Your Screen',
                    style: HollowTypography.heading.copyWith(
                      color: hollow.textPrimary,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: HollowSpacing.md),

                  // Portal-first Wayland picker: ONE entry, because the
                  // desktop's own portal dialog is where the user picks, right
                  // after pressing Share.
                  if (_portalMode) ...[
                    _buildPortalSection(hollow),
                    const SizedBox(height: HollowSpacing.md),
                  ] else ...[
                    Row(
                      children: [
                        _buildTab(hollow, 'Screens', _showScreens, () {
                          setState(() => _showScreens = true);
                        }),
                        const SizedBox(width: HollowSpacing.sm),
                        _buildTab(hollow, 'Windows', !_showScreens, () {
                          setState(() => _showScreens = false);
                        }),
                      ],
                    ),
                    const SizedBox(height: HollowSpacing.md),

                    Expanded(
                      child: _loading
                          ? Center(
                              child: CircularProgressIndicator(
                                color: hollow.accent,
                                strokeWidth: 2,
                              ),
                            )
                          : sources.isEmpty
                              ? Center(
                                  child: Text(
                                    _showScreens
                                        ? 'No screens found'
                                        : 'No windows found',
                                    style: HollowTypography.body.copyWith(
                                      color: hollow.textSecondary,
                                    ),
                                  ),
                                )
                              : GridView.builder(
                                  gridDelegate:
                                      SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: _showScreens ? 2 : 3,
                                    mainAxisSpacing: HollowSpacing.sm,
                                    crossAxisSpacing: HollowSpacing.sm,
                                    childAspectRatio: 16 / 10,
                                  ),
                                  itemCount: sources.length,
                                  itemBuilder: (context, index) {
                                    final source = sources[index];
                                    final isSelected =
                                        source.id == _selectedSourceId;
                                    return _buildSourceTile(
                                        hollow, source, isSelected);
                                  },
                                ),
                    ),
                    const SizedBox(height: HollowSpacing.md),
                  ],

                  // Switching the profile also snaps the fps default, which the
                  // user can still override afterwards.
                  Row(
                    children: [
                      Text(
                        'Optimize for',
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: HollowSpacing.sm),
                      _buildPill(
                          'Smooth motion',
                          _profile == ScreenContentProfile.motion,
                          () => setState(() {
                                _profile = ScreenContentProfile.motion;
                                _fps = ScreenShareFps.fps60;
                              })),
                      _buildPill(
                          'Sharp text',
                          _profile == ScreenContentProfile.text,
                          () => setState(() {
                                _profile = ScreenContentProfile.text;
                                _fps = ScreenShareFps.fps15;
                              })),
                    ],
                  ),
                  const SizedBox(height: HollowSpacing.sm),
                  Row(
                    children: [
                      Text(
                        'Resolution',
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: HollowSpacing.sm),
                      ..._availableResolutions.map((r) =>
                          _buildPill(r.label, r == _resolution,
                              () => setState(() => _resolution = r))),
                    ],
                  ),
                  const SizedBox(height: HollowSpacing.sm),
                  Row(
                    children: [
                      Text(
                        'Frame Rate',
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: HollowSpacing.sm),
                      ...ScreenShareFps.values.map((f) =>
                          _buildPill(f.label, f == _fps,
                              () => setState(() => _fps = f))),
                    ],
                  ),
                  const SizedBox(height: HollowSpacing.md),

                  Builder(builder: (context) {
                    // Older macOS exposes no system-audio API at all, so the
                    // toggle locks off and says why rather than enabling a
                    // feature that silently does nothing.
                    final audioBlocked =
                        MacOsScreenAudioSupport.audioSendBlockedByOldOs;
                    if (audioBlocked && _shareAudio) {
                      // Never send with a stale-true value.
                      WidgetsBinding.instance.addPostFrameCallback(
                          (_) => setState(() => _shareAudio = false));
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            HollowToggle(
                              value: audioBlocked ? false : _shareAudio,
                              onChanged: audioBlocked
                                  ? null
                                  : (v) => setState(() => _shareAudio = v),
                            ),
                            const SizedBox(width: HollowSpacing.sm),
                            Text(
                              'Share audio',
                              style: HollowTypography.caption.copyWith(
                                color: audioBlocked
                                    ? hollow.textTertiary
                                    : hollow.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        if (_portalMode && _shareAudio) ...[
                          const SizedBox(height: HollowSpacing.xs),
                          Text(
                            'On Wayland, audio is captured system-wide '
                            '(Hollow\'s own audio excluded), even when the '
                            'portal shares a single window.',
                            style: HollowTypography.caption.copyWith(
                              color: hollow.textTertiary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                        if (audioBlocked) ...[
                          const SizedBox(height: HollowSpacing.xs),
                          Text(
                            'Audio sharing needs macOS 13.0 or later. '
                            'You\'re on ${MacOsScreenAudioSupport.versionLabel ?? 'an older version'}. '
                            'Apple exposes no system-audio API before 13.0. '
                            'Update to 13.0+ to share audio. '
                            'Video sharing still works.',
                            style: HollowTypography.caption.copyWith(
                              color: hollow.textTertiary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ],
                    );
                  }),
                  const SizedBox(height: HollowSpacing.lg),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      HollowButton.ghost(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: HollowSpacing.sm),
                      HollowButton.filled(
                        onPressed: _portalMode
                            ? () {
                                // The id is the sentinel the native side maps
                                // onto the generic PipeWire capturer, and a
                                // fresh pick bumps the restore generation so
                                // the portal prompts again.
                                if (_portalFresh) {
                                  DesktopCaptureSupport.bumpPortalGeneration();
                                }
                                final portalId =
                                    DesktopCaptureSupport.portalSourceId;
                                network_api.logFromDart(
                                  message: '[SCREEN-AUDIO] Share confirmed: '
                                      'portal id=$portalId '
                                      'audio=$_shareAudio',
                                );
                                Navigator.pop(
                                  context,
                                  ScreenShareSelection(
                                    sourceId: portalId,
                                    width: _resolution.width,
                                    height: _resolution.height,
                                    fps: _fps.value,
                                    shareAudio: _shareAudio,
                                    profile: _profile,
                                  ),
                                );
                              }
                            : _selectedSourceId != null
                            ? () {
                                final selectedSource = _sources[_selectedSourceId!];
                                // For a WINDOW source the source id IS the
                                // HWND, which the per-app capturer resolves to
                                // audio pids itself. libwebrtc's `pid` arrives
                                // as 0 for windows, so it cannot be used.
                                final isWindow =
                                    selectedSource?.type == SourceType.Window;
                                final hwnd = isWindow
                                    ? (int.tryParse(_selectedSourceId!) ?? 0)
                                    : 0;
                                network_api.logFromDart(
                                  message: '[SCREEN-AUDIO] Share confirmed: '
                                      'type=${selectedSource?.type} '
                                      'pid=${selectedSource?.pid ?? 0} '
                                      'hwnd=$hwnd '
                                      'audio=$_shareAudio '
                                      'id=$_selectedSourceId',
                                );
                                Navigator.pop(
                                  context,
                                  ScreenShareSelection(
                                    sourceId: _selectedSourceId!,
                                    width: _resolution.width,
                                    height: _resolution.height,
                                    fps: _fps.value,
                                    shareAudio: _shareAudio,
                                    pid: selectedSource?.pid ?? 0,
                                    windowHwnd: hwnd,
                                    profile: _profile,
                                  ),
                                );
                              }
                            : null,
                        child: const Text('Share'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The Wayland portal-first section: one explanatory entry, plus the choice
  /// between a silent re-share and a fresh portal prompt once a grant exists.
  Widget _buildPortalSection(HollowTheme hollow) {
    final canReuse = DesktopCaptureSupport.portalGrantLikely;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(HollowSpacing.md),
          decoration: BoxDecoration(
            color: hollow.surface,
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            border: Border.all(color: hollow.border),
          ),
          child: Row(
            children: [
              Icon(
                Icons.desktop_windows_outlined,
                color: hollow.textSecondary,
                size: 28,
              ),
              const SizedBox(width: HollowSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Screen or window',
                      style: HollowTypography.body.copyWith(
                        color: hollow.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Press Share and your desktop opens its own dialog. '
                      'Pick a whole screen or a single window there.',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textTertiary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (canReuse) ...[
          const SizedBox(height: HollowSpacing.sm),
          Row(
            children: [
              _buildPill(
                'Same as last time',
                !_portalFresh,
                () => setState(() => _portalFresh = false),
              ),
              _buildPill(
                'Pick something new',
                _portalFresh,
                () => setState(() => _portalFresh = true),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.xs),
          Text(
            _portalFresh
                ? 'The system dialog will ask again.'
                : 'Reshares what you shared before, without asking again.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textTertiary,
              fontSize: 11,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTab(
      HollowTheme hollow, String label, bool active, VoidCallback onTap) {
    return HollowFocusRing(
      enabled: true,
      onActivate: onTap,
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.md,
            vertical: HollowSpacing.xs + 2,
          ),
          decoration: BoxDecoration(
            color: active
                ? hollow.accent.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            border: active
                ? Border.all(color: hollow.accent.withValues(alpha: 0.3))
                : null,
          ),
          child: Text(
            label,
            style: HollowTypography.caption.copyWith(
              color: active ? hollow.accent : hollow.textSecondary,
              fontWeight: active ? FontWeight.w600 : FontWeight.normal,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSourceTile(
      HollowTheme hollow, DesktopCapturerSource source, bool isSelected) {
    final thumbnail = source.thumbnail;

    return HollowFocusRing(
      enabled: true,
      onActivate: () => setState(() => _selectedSourceId = source.id),
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      child: GestureDetector(
        onTap: () => setState(() => _selectedSourceId = source.id),
        child: Container(
          decoration: BoxDecoration(
            color: hollow.surface,
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            border: Border.all(
              color: isSelected
                  ? hollow.accent
                  : hollow.border,
              width: isSelected ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: thumbnail != null && thumbnail.isNotEmpty
                    ? Image.memory(
                        Uint8List.fromList(thumbnail),
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      )
                    : Container(
                        color: hollow.elevated,
                        child: Icon(
                          Icons.desktop_windows_outlined,
                          color: hollow.textSecondary.withValues(alpha: 0.3),
                          size: 32,
                        ),
                      ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.xs + 2,
                  vertical: HollowSpacing.xs,
                ),
                color: isSelected
                    ? hollow.accent.withValues(alpha: 0.1)
                    : hollow.elevated,
                child: Text(
                  source.name,
                  style: HollowTypography.caption.copyWith(
                    color: isSelected
                        ? hollow.accent
                        : hollow.textPrimary,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPill(String label, bool active, VoidCallback onTap) {
    return SelectorPill(
      label: label,
      active: active,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.xs,
      ),
    );
  }
}
