import 'dart:async';

import 'package:flutter/foundation.dart';
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
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_chip_tabs.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hollow_skeleton.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart'
    show SettingsFieldLabel;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

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

//// Shows the screen share picker, returning null when it is cancelled.
Future<ScreenShareSelection?> showScreenShareDialog(
    BuildContext context) async {
  return showHollowDialog<ScreenShareSelection>(
    context: context,
    builder: (context) => const ScreenShareDialog(),
  );
}

/// Where the picker's sources come from, so a test can stand in for the
/// native capturer.
class ScreenShareSources {
  const ScreenShareSources();

  DesktopCapturer get capturer => desktopCapturer;

  /// macOS only: false when Screen Recording is off for Hollow.
  Future<bool> requestPermission() => Helper.requestCapturePermission();
}

/// Why the source grid is empty, when it is.
enum _SourceLoad { loading, ready, denied, failed }

class ScreenShareDialog extends StatefulWidget {
  final ScreenShareSources sources;

  const ScreenShareDialog({super.key, this.sources = const ScreenShareSources()});

  @override
  State<ScreenShareDialog> createState() => _ScreenShareDialogState();
}

class _ScreenShareDialogState extends State<ScreenShareDialog> {
  final Map<String, DesktopCapturerSource> _sources = {};
  final List<StreamSubscription<DesktopCapturerSource>> _subscriptions = [];
  String? _selectedSourceId;
  ScreenShareResolution _resolution = ScreenShareResolution.p1080;
  ScreenShareFps _fps = ScreenShareFps.fps60;
  ScreenContentProfile _profile = ScreenContentProfile.motion;
  bool _shareAudio = false;
  _SourceLoad _load = _SourceLoad.loading;
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

  DesktopCapturer get _capturer => widget.sources.capturer;

  bool get _isMacOS => defaultTargetPlatform == TargetPlatform.macOS;

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
      _load = _SourceLoad.ready;
      return;
    }
    _loadSources();

    try {
      _subscriptions.addAll([
        _capturer.onAdded.stream.listen((source) {
          if (mounted) setState(() => _sources[source.id] = source);
        }),
        _capturer.onRemoved.stream.listen((source) {
          if (!mounted) return;
          setState(() {
            _sources.remove(source.id);
            if (_selectedSourceId == source.id) _selectedSourceId = null;
          });
        }),
        _capturer.onThumbnailChanged.stream.listen((_) {
          if (mounted) setState(() {});
        }),
      ]);
    } catch (_) {
      // A capturer with no live updates still lists once.
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    for (final s in _subscriptions) {
      s.cancel();
    }
    super.dispose();
  }

  Future<void> _loadSources() async {
    if (_load != _SourceLoad.loading) {
      setState(() => _load = _SourceLoad.loading);
    }
    // macOS enumerates nothing until Screen Recording is granted, so the system
    // prompt comes first, and a denial is said as one.
    var permitted = true;
    if (_isMacOS) {
      try {
        permitted = await widget.sources.requestPermission();
      } catch (_) {}
    }
    try {
      final sources = await _capturer.getSources(
        types: DesktopCaptureSupport.sourceTypes,
      );
      if (!mounted) return;
      final noScreens = !sources.any((s) => s.type == SourceType.Screen);
      setState(() {
        for (final s in sources) {
          _sources[s.id] = s;
        }
        _load = _isMacOS && (!permitted || noScreens)
            ? _SourceLoad.denied
            : _SourceLoad.ready;
        // The first screen is what most shares are, so it starts picked.
        _selectedSourceId ??= sources
            .where((s) => s.type == SourceType.Screen)
            .map((s) => s.id)
            .firstOrNull;
      });

      _refreshTimer?.cancel();
      _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        _capturer
            .updateSources(types: DesktopCaptureSupport.sourceTypes)
            .catchError((_) => false);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() =>
          _load = _isMacOS && !permitted ? _SourceLoad.denied : _SourceLoad.failed);
    }
  }

  List<DesktopCapturerSource> get _filteredSources {
    final type = _showScreens ? SourceType.Screen : SourceType.Window;
    return _sources.values.where((s) => s.type == type).toList();
  }

  /// The pick on the tab in view: a screen picked on Screens never shares from
  /// the Windows tab, where nothing looks chosen.
  String? get _visibleSelectionId {
    final id = _selectedSourceId;
    if (id == null) return null;
    return _filteredSources.any((s) => s.id == id) ? id : null;
  }

  void _share() {
    if (_portalMode) {
      // The id is the sentinel the native side maps onto the generic PipeWire
      // capturer, and a fresh pick bumps the restore generation so the portal
      // prompts again.
      if (_portalFresh) DesktopCaptureSupport.bumpPortalGeneration();
      final portalId = DesktopCaptureSupport.portalSourceId;
      _log('[SCREEN-AUDIO] Share confirmed: portal id=$portalId '
          'audio=$_shareAudio');
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
      return;
    }
    final id = _visibleSelectionId;
    if (id == null) return;
    final selectedSource = _sources[id];
    // For a WINDOW source the source id IS the HWND, which the per-app
    // capturer resolves to audio pids itself. libwebrtc's `pid` arrives as 0
    // for windows, so it cannot be used.
    final isWindow = selectedSource?.type == SourceType.Window;
    final hwnd = isWindow ? (int.tryParse(id) ?? 0) : 0;
    _log('[SCREEN-AUDIO] Share confirmed: type=${selectedSource?.type} '
        'pid=${selectedSource?.pid ?? 0} hwnd=$hwnd audio=$_shareAudio id=$id');
    Navigator.pop(
      context,
      ScreenShareSelection(
        sourceId: id,
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

  void _log(String message) {
    try {
      network_api.logFromDart(message: message).catchError((_) {});
    } catch (_) {
      // The bridge is not up (tests).
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final canShare = _portalMode || _visibleSelectionId != null;

    return HollowDialogSurface(
      width: 680,
      maxHeight: 560,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Share your screen',
            style: HollowTypography.heading.copyWith(
              color: hollow.textPrimary,
            ),
          ),
          const SizedBox(height: HollowSpacing.lg),

          // Portal-first Wayland picker: ONE entry, because the desktop's own
          // portal dialog is where the user picks, right after pressing Share.
          if (_portalMode) ...[
            _buildPortalSection(hollow),
            const SizedBox(height: HollowSpacing.lg),
          ] else ...[
            HollowChipTabs<bool>(
              tabs: const [
                HollowChipTab(value: true, label: 'Screens'),
                HollowChipTab(value: false, label: 'Windows'),
              ],
              selected: _showScreens,
              onSelected: (v) => setState(() => _showScreens = v),
            ),
            const SizedBox(height: HollowSpacing.md),
            Expanded(child: _buildSources(hollow)),
            const SizedBox(height: HollowSpacing.lg),
          ],

          _buildOptions(hollow),
          const SizedBox(height: HollowSpacing.md),
          _buildAudio(hollow),
          const SizedBox(height: HollowSpacing.xl),

          HollowButtonTouchScope(
            touch: HollowDialogSurface.isCompact(context),
            child: Row(
              children: [
                Expanded(
                  child: canShare
                      ? const SizedBox.shrink()
                      : Text(
                          _load == _SourceLoad.loading
                              ? 'Finding your screens…'
                              : _showScreens
                                  ? 'Pick a screen to share.'
                                  : 'Pick a window to share.',
                          style: HollowTypography.bodySmall
                              .copyWith(color: hollow.textSecondary),
                        ),
                ),
                const SizedBox(width: HollowSpacing.sm),
                HollowButton.ghost(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: HollowSpacing.sm),
                HollowButton.filled(
                  onPressed: canShare ? _share : null,
                  child: const Text('Share'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSources(HollowTheme hollow) {
    final columns = _showScreens ? 2 : 3;
    const delegate = HollowSpacing.sm;
    SliverGridDelegate grid(int columns) =>
        SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: delegate,
          crossAxisSpacing: delegate,
          childAspectRatio: 16 / 10,
        );
    switch (_load) {
      case _SourceLoad.loading:
        // The final geometry, so nothing jumps when the thumbnails land.
        return GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: grid(columns),
          itemCount: columns * 2,
          itemBuilder: (_, _) =>
              HollowSkeleton(height: double.infinity, radius: hollow.radiusMd),
        );
      case _SourceLoad.denied:
        return HollowEmptyState(
          title: "Hollow isn't allowed to see your screen",
          description: 'Turn on Hollow under Screen Recording in System '
              'Settings, in Privacy & Security. Then open this again.',
          action: HollowButton.outline(
            onPressed: () => launchUrl(Uri.parse(
                    'x-apple.systempreferences:com.apple.preference.security'
                    '?Privacy_ScreenCapture'))
                .catchError((_) => false),
            child: const Text('Open System Settings'),
          ),
        );
      case _SourceLoad.failed:
        return HollowEmptyState(
          title: "Hollow couldn't list your screens and windows",
          action: HollowButton.outline(
            onPressed: _loadSources,
            child: const Text('Try again'),
          ),
        );
      case _SourceLoad.ready:
        final sources = _filteredSources;
        if (sources.isEmpty) {
          return HollowEmptyState(
            title: _showScreens ? 'No screens found' : 'No open windows found',
          );
        }
        return GridView.builder(
          gridDelegate: grid(columns),
          itemCount: sources.length,
          itemBuilder: (context, index) {
            final source = sources[index];
            return _buildSourceTile(
                hollow, source, source.id == _selectedSourceId);
          },
        );
    }
  }

  /// Label beside its chips; the chips wrap rather than overflow at a large
  /// text size.
  Widget _buildOptions(HollowTheme hollow) {
    TableRow row(String label, List<Widget> chips, {bool last = false}) {
      return TableRow(children: [
        Padding(
          padding: EdgeInsets.only(
            right: HollowSpacing.md,
            top: HollowSpacing.xs,
            bottom: last ? 0 : HollowSpacing.sm,
          ),
          child: SettingsFieldLabel(label: label),
        ),
        Padding(
          padding: last
              ? EdgeInsets.zero
              : const EdgeInsets.only(bottom: HollowSpacing.sm),
          child: Wrap(
            spacing: HollowSpacing.sm,
            runSpacing: HollowSpacing.sm,
            children: chips,
          ),
        ),
      ]);
    }

    return Table(
      columnWidths: const {
        0: IntrinsicColumnWidth(),
        1: FlexColumnWidth(),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      children: [
        // Switching the profile also snaps the fps default, which the user can
        // still override afterwards.
        row('Optimize for', [
          HollowChip(
            label: 'Smooth motion',
            selected: _profile == ScreenContentProfile.motion,
            onTap: () => setState(() {
              _profile = ScreenContentProfile.motion;
              _fps = ScreenShareFps.fps60;
            }),
          ),
          HollowChip(
            label: 'Sharp text',
            selected: _profile == ScreenContentProfile.text,
            onTap: () => setState(() {
              _profile = ScreenContentProfile.text;
              _fps = ScreenShareFps.fps15;
            }),
          ),
        ]),
        row('Resolution', [
          for (final r in _availableResolutions)
            HollowChip(
              label: r.label,
              selected: r == _resolution,
              onTap: () => setState(() => _resolution = r),
            ),
        ]),
        row(
          'Frame rate',
          [
            for (final f in ScreenShareFps.values)
              HollowChip(
                label: f.label,
                selected: f == _fps,
                onTap: () => setState(() => _fps = f),
              ),
          ],
          last: true,
        ),
      ],
    );
  }

  Widget _buildAudio(HollowTheme hollow) {
    // Older macOS exposes no system-audio API at all, so the toggle locks off
    // and says why rather than enabling a feature that silently does nothing.
    final audioBlocked = MacOsScreenAudioSupport.audioSendBlockedByOldOs;
    if (audioBlocked && _shareAudio) {
      // Never send with a stale-true value.
      WidgetsBinding.instance
          .addPostFrameCallback((_) => setState(() => _shareAudio = false));
    }
    final note = audioBlocked
        ? 'Sharing audio needs macOS 13 or newer. Your screen still shares.'
        : _portalMode && _shareAudio
            ? 'On Wayland, audio comes from your whole system (without '
                "Hollow's own sounds), even when you share one window."
            : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            HollowToggle(
              value: audioBlocked ? false : _shareAudio,
              semanticLabel: 'Share audio',
              onChanged:
                  audioBlocked ? null : (v) => setState(() => _shareAudio = v),
            ),
            const SizedBox(width: HollowSpacing.sm),
            Flexible(
              child: Text(
                'Share audio',
                style: HollowTypography.label.copyWith(
                  color: audioBlocked ? hollow.textTertiary : hollow.textPrimary,
                ),
              ),
            ),
          ],
        ),
        if (note != null) ...[
          const SizedBox(height: HollowSpacing.xs),
          Text(
            note,
            style: HollowTypography.bodySmall
                .copyWith(color: hollow.textSecondary),
          ),
        ],
      ],
    );
  }

  /// The Wayland portal-first section: one explanatory entry, plus the choice
  /// between a silent re-share and a fresh portal prompt once a grant exists.
  Widget _buildPortalSection(HollowTheme hollow) {
    final canReuse = DesktopCaptureSupport.portalGrantLikely;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const HollowDialogText(
          'Press Share and your desktop opens its own dialog. Pick a whole '
          'screen or a single window there.',
        ),
        if (canReuse) ...[
          const SizedBox(height: HollowSpacing.md),
          Wrap(
            spacing: HollowSpacing.sm,
            runSpacing: HollowSpacing.sm,
            children: [
              HollowChip(
                label: 'Same as last time',
                selected: !_portalFresh,
                onTap: () => setState(() => _portalFresh = false),
              ),
              HollowChip(
                label: 'Pick something new',
                selected: _portalFresh,
                onTap: () => setState(() => _portalFresh = true),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.xs),
          Text(
            _portalFresh
                ? 'The system dialog will ask again.'
                : 'Reshares what you shared before, without asking again.',
            style: HollowTypography.bodySmall
                .copyWith(color: hollow.textSecondary),
          ),
        ],
      ],
    );
  }

  Widget _buildSourceTile(
      HollowTheme hollow, DesktopCapturerSource source, bool isSelected) {
    final thumbnail = source.thumbnail;
    void select() => setState(() => _selectedSourceId = source.id);

    return Semantics(
      button: true,
      selected: isSelected,
      label: source.name,
      child: HollowFocusRing(
        enabled: true,
        onActivate: select,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        child: GestureDetector(
          onTap: select,
          child: Container(
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
              // The one selection mark: a border that thickens, no tint.
              border: Border.all(
                color: isSelected ? hollow.accent : hollow.border,
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
                      : Icon(
                          LucideIcons.monitor,
                          color: hollow.textTertiary,
                          size: 24,
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.sm,
                    vertical: HollowSpacing.xs,
                  ),
                  child: Text(
                    source.name,
                    style: HollowTypography.caption
                        .copyWith(color: hollow.textPrimary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
