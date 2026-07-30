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

/// Resolution presets for screen sharing.
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

/// FPS presets for screen sharing.
enum ScreenShareFps {
  fps5(5, '5 FPS'),
  fps15(15, '15 FPS'),
  fps30(30, '30 FPS'),
  fps60(60, '60 FPS');

  final int value;
  final String label;
  const ScreenShareFps(this.value, this.label);
}

/// Result from the screen share dialog.
class ScreenShareSelection {
  final String sourceId;
  final int width;
  final int height;
  final int fps;
  final bool shareAudio;
  final int pid;

  /// What the shared content mostly is — drives encoder tuning (degradation
  /// preference, codec order, contentHint). See [ScreenContentProfile].
  final ScreenContentProfile profile;

  /// For a WINDOW share on Windows: the window's HWND (the desktop source `id`
  /// IS the decimal HWND). 0 for screen shares. The screen-audio exe resolves
  /// this HWND -> owning pid -> the app's audio-rendering pids itself, which is
  /// far more reliable than [pid] (libwebrtc does not populate a window pid
  /// dependably; it arrived as 0, so window shares fell back to system audio).
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

  /// Human-readable quality label, e.g. "1080p60", "4K30".
  String get qualityLabel {
    const resLabels = {360: '360p', 480: '480p', 720: '720p', 1080: '1080p', 1440: '1440p', 2160: '4K'};
    final res = resLabels[height] ?? '${height}p';
    return '$res$fps';
  }
}

/// Show the screen share picker dialog.
/// Returns [ScreenShareSelection] if user confirms, null if cancelled.
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
  late final List<ScreenShareResolution> _availableResolutions =
      _computeAvailableResolutions();

  /// Only offer resolutions a connected display can actually produce —
  /// capture is native-res and the encoder only ever downscales, so a
  /// preset above the display is pure waste (same pixels, higher bitrate
  /// cap). Orientation-agnostic (portrait monitors compare by long/short
  /// side); on multi-monitor setups a preset stays available if ANY display
  /// fits it. Falls back to the full list if the platform reports nothing.
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
    // Clamp the default (1080p) down to the best available tier on smaller
    // displays (e.g. a 720p laptop offers 360p/480p/720p, defaults to 720p).
    if (!_availableResolutions.contains(_resolution)) {
      _resolution = _availableResolutions.last;
    }
    _loadSources();

    // Listen for source changes.
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
      // macOS only enumerates shareable screens/windows after the user has
      // granted Screen Recording in System Settings → Privacy & Security.
      // Trigger the system prompt before getSources(); if the user denies
      // (or hasn't granted yet) we still call getSources so the dialog can
      // show its "no sources" state instead of staying on the loader.
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

      // Refresh thumbnails periodically.
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
                  // Title
                  Text(
                    'Share Your Screen',
                    style: HollowTypography.heading.copyWith(
                      color: hollow.textPrimary,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: HollowSpacing.md),

                  // Tabs: Screens / Windows. A Wayland session has no window
                  // capturer at all (DesktopCaptureSupport), so the tab is
                  // dropped instead of sitting empty forever.
                  if (DesktopCaptureSupport.canShareWindows)
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
                    )
                  else
                    Text(
                      'Wayland session: whole screens only. Your desktop asks '
                      'which one to share.',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textTertiary,
                      ),
                    ),
                  const SizedBox(height: HollowSpacing.md),

                  // Source grid
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

                  // Content profile pills — tunes the encoder for what's
                  // being shared. Switching also snaps the fps default
                  // (15 for text, 60 for motion); the user can still
                  // override fps afterwards.
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
                  // Quality: resolution pills
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
                  // Quality: FPS pills
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
                    // macOS 10.15–12.x cannot capture system audio (Apple
                    // exposes no API before ScreenCaptureKit audio in 13.0).
                    // Lock the toggle off and explain why, rather than letting
                    // the user enable a feature that silently does nothing.
                    final audioBlocked =
                        MacOsScreenAudioSupport.audioSendBlockedByOldOs;
                    if (audioBlocked && _shareAudio) {
                      // Defensive: ensure we never send with a stale-true value.
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
                        if (audioBlocked) ...[
                          const SizedBox(height: HollowSpacing.xs),
                          Text(
                            'Audio sharing needs macOS 13.0 or later. '
                            'You\'re on ${MacOsScreenAudioSupport.versionLabel ?? 'an older version'} — '
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

                  // Actions
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      HollowButton.ghost(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: HollowSpacing.sm),
                      HollowButton.filled(
                        onPressed: _selectedSourceId != null
                            ? () {
                                final selectedSource = _sources[_selectedSourceId!];
                                // For a WINDOW source the source id IS the HWND
                                // (decimal) — hand THAT to the per-app capturer,
                                // which resolves HWND -> pid -> audio pids itself.
                                // libwebrtc's `pid` field arrives as 0 for
                                // windows, so we must NOT rely on it.
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
              // Thumbnail
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
              // Name
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
