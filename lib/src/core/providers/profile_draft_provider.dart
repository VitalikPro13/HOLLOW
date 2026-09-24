import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_anim_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/components/hollow_toast.dart';

/// Keeps "not given" apart from an explicit null in [ProfileDraftState.copyWith].
const Object _keep = Object();

/// Unsaved Profile edits. They live here rather than in the page so leaving
/// Settings (or the Profile page) keeps them, and the Settings place can show
/// the one "unsaved changes" bar wherever the person is.
///
/// Image bytes follow the profile save convention: null with `!changed` is no
/// change, `Uint8List(0)` is the CLEAR sentinel. They are what the preview
/// paints, which for an animated pick is the animation.
class ProfileDraftState {
  final bool dirty;
  final bool saving;

  final Uint8List? avatarBytes;
  final bool avatarChanged;
  final bool avatarBusy;

  final Uint8List? bannerBytes;
  final bool bannerChanged;
  final bool bannerBusy;

  /// Pending avatar frame (issue #54): `''` clears. The picker stores an
  /// upload's blob at once, so only the id is pending.
  final String? frameId;
  final bool frameChanged;

  const ProfileDraftState({
    this.dirty = false,
    this.saving = false,
    this.avatarBytes,
    this.avatarChanged = false,
    this.avatarBusy = false,
    this.bannerBytes,
    this.bannerChanged = false,
    this.bannerBusy = false,
    this.frameId,
    this.frameChanged = false,
  });

  ProfileDraftState copyWith({
    bool? dirty,
    bool? saving,
    Object? avatarBytes = _keep,
    bool? avatarChanged,
    bool? avatarBusy,
    Object? bannerBytes = _keep,
    bool? bannerChanged,
    bool? bannerBusy,
    Object? frameId = _keep,
    bool? frameChanged,
  }) =>
      ProfileDraftState(
        dirty: dirty ?? this.dirty,
        saving: saving ?? this.saving,
        avatarBytes: identical(avatarBytes, _keep)
            ? this.avatarBytes
            : avatarBytes as Uint8List?,
        avatarChanged: avatarChanged ?? this.avatarChanged,
        avatarBusy: avatarBusy ?? this.avatarBusy,
        bannerBytes: identical(bannerBytes, _keep)
            ? this.bannerBytes
            : bannerBytes as Uint8List?,
        bannerChanged: bannerChanged ?? this.bannerChanged,
        bannerBusy: bannerBusy ?? this.bannerBusy,
        frameId: identical(frameId, _keep) ? this.frameId : frameId as String?,
        frameChanged: frameChanged ?? this.frameChanged,
      );

  /// The pending frame as the renderers take it, or null when unchanged.
  String? get effectiveFrame => frameChanged ? (frameId ?? '') : null;

  ProfileDraftState _withSlot(
    bool avatar, {
    Object? bytes = _keep,
    bool? changed,
    bool? busy,
  }) =>
      avatar
          ? copyWith(avatarBytes: bytes, avatarChanged: changed, avatarBusy: busy)
          : copyWith(bannerBytes: bytes, bannerChanged: changed, bannerBusy: busy);

  Uint8List? _bytes(bool avatar) => avatar ? avatarBytes : bannerBytes;
  bool _changed(bool avatar) => avatar ? avatarChanged : bannerChanged;
}

/// The three text fields, as a comparable value.
typedef _Texts = ({String name, String status, String about});

/// Owns the text controllers and every pending image and frame edit for the
/// app's lifetime. The page does the file pick and the crop (they need a
/// BuildContext) and hands the result here.
class ProfileDraftNotifier extends Notifier<ProfileDraftState> {
  late TextEditingController _name;
  late TextEditingController _status;
  late TextEditingController _about;

  TextEditingController get displayName => _name;
  TextEditingController get status => _status;
  TextEditingController get aboutMe => _about;

  // An animated pick splits in two: the animation is cached on the asset rail
  // under a hash and only the STILL companion rides the profile push. Null on a
  // still pick, which is what CLEARS a previous animation on save.
  final Map<bool, Uint8List?> _still = {true: null, false: null};
  final Map<bool, String?> _anim = {true: null, false: null};

  // In-flight WebP processing; these futures never throw. Save AWAITS them, so
  // an early tap cannot commit while the final bytes are still encoding.
  final Map<bool, Future<void>?> _processing = {true: null, false: null};

  // Any newer pick, clear or reset bumps the generation, so a late processing
  // result cannot clobber it.
  final Map<bool, int> _gen = {true: 0, false: 0};

  bool _syncing = false;
  _Texts _lastTexts = (name: '', status: '', about: '');

  /// What Reset returns the fields to: the saved row, or what was last saved.
  _Texts _baseline = (name: '', status: '', about: '');

  /// The `updatedAt` of the row the fields were last filled from. A reload of
  /// the same row (a patch, a stale read) must not overwrite a save.
  Object? _syncedStamp;

  @override
  ProfileDraftState build() {
    _name = TextEditingController();
    _status = TextEditingController();
    _about = TextEditingController();
    for (final c in [_name, _status, _about]) {
      c.addListener(_onText);
    }
    ref.onDispose(() {
      for (final c in [_name, _status, _about]) {
        c.dispose();
      }
    });
    ref.listen(identityProvider.select((s) => s.peerId),
        (_, _) => _syncIfClean());
    ref.listen(profileProvider, (_, _) => _syncIfClean());
    _fillFromSaved();
    return const ProfileDraftState();
  }

  _Texts _texts() =>
      (name: _name.text, status: _status.text, about: _about.text);

  void _onText() {
    if (_syncing) return;
    final now = _texts();
    // Cursor and selection moves notify too.
    if (now == _lastTexts) return;
    _lastTexts = now;
    if (!state.dirty) state = state.copyWith(dirty: true);
  }

  void _setTexts(_Texts t) {
    _syncing = true;
    try {
      // Assigning identical text still moves the caret, so only on a change.
      if (_name.text != t.name) _name.text = t.name;
      if (_status.text != t.status) _status.text = t.status;
      if (_about.text != t.about) _about.text = t.about;
    } finally {
      _syncing = false;
    }
    _lastTexts = _texts();
  }

  void _fillFromSaved() {
    final me = ref.read(identityProvider).peerId;
    final p = me == null ? null : ref.read(profileProvider)[me];
    _baseline = (
      name: p?.displayName ?? '',
      status: p?.status ?? '',
      about: p?.aboutMe ?? '',
    );
    _syncedStamp = p?.updatedAt;
    _setTexts(_baseline);
  }

  void _syncIfClean() {
    if (state.dirty || state.saving) return;
    final me = ref.read(identityProvider).peerId;
    final p = me == null ? null : ref.read(profileProvider)[me];
    if (p == null || p.updatedAt == _syncedStamp) return;
    _fillFromSaved();
  }

  void _toast(String message) {
    final nav = hollowNavigatorKey.currentState;
    final context = hollowNavigatorKey.currentContext;
    if (nav == null || context == null) return;
    HollowToast.show(context, message,
        type: HollowToastType.error, overlayState: nav.overlay);
  }

  /// Stages a cropped STILL avatar ([avatar]) or banner. The cropped PNG shows
  /// at once; the WebP encode is a real wait and swaps in behind it.
  void stageCropped(Uint8List cropped, {required bool avatar}) {
    final prevBytes = state._bytes(avatar);
    final prevChanged = state._changed(avatar);
    final prevStill = _still[avatar];
    final prevAnim = _anim[avatar];
    final gen = _gen[avatar] = _gen[avatar]! + 1;
    _still[avatar] = null;
    _anim[avatar] = null;
    state = state
        ._withSlot(avatar, bytes: cropped, changed: true, busy: true)
        .copyWith(dirty: true);
    _processing[avatar] = () async {
      try {
        final processed = avatar
            ? await network_api.processAvatar(rawBytes: cropped)
            : await network_api.processBanner(rawBytes: cropped);
        if (gen != _gen[avatar]) return;
        state = state._withSlot(avatar, bytes: processed, busy: false);
      } catch (e) {
        if (gen != _gen[avatar]) return;
        // The pick failed, so revert the optimistic staging.
        _still[avatar] = prevStill;
        _anim[avatar] = prevAnim;
        state = state._withSlot(avatar,
            bytes: prevBytes, changed: prevChanged, busy: false);
        _toast('Failed to process image');
      }
    }();
  }

  /// Stages an ANIMATED pick, which skips the cropper to keep its motion: Rust
  /// crops, walks the quality ladder and caches it on the asset rail. The
  /// failure toast is Rust's own sentence, which names the length that fits.
  void stageAnimated(Uint8List rawBytes, {required bool avatar}) {
    final gen = _gen[avatar] = _gen[avatar]! + 1;
    state = state._withSlot(avatar, busy: true).copyWith(dirty: true);
    _processing[avatar] = () async {
      try {
        final media = avatar
            ? await network_api.processAndStoreAvatarAnim(rawBytes: rawBytes)
            : await network_api.processAndStoreBannerAnim(rawBytes: rawBytes);
        if (gen != _gen[avatar]) return;
        // The blob is already stored; seeding skips the round trip back out so
        // every surface paints it immediately.
        ref.read(profileAnimProvider.notifier).seed(media.hash, media.bytes);
        _still[avatar] = media.still;
        _anim[avatar] = media.hash;
        state = state._withSlot(avatar,
            bytes: media.bytes, changed: true, busy: false);
      } catch (e) {
        if (gen != _gen[avatar]) return;
        state = state._withSlot(avatar, busy: false);
        _toast('$e');
      }
    }();
  }

  /// Clears the avatar ([avatar]) or banner on the next save.
  void clearImage({required bool avatar}) {
    _gen[avatar] = _gen[avatar]! + 1;
    _still[avatar] = null;
    _anim[avatar] = null;
    state = state
        ._withSlot(avatar, bytes: Uint8List(0), changed: true, busy: false)
        .copyWith(dirty: true);
  }

  /// A frame id from the picker; `''` clears.
  void setFrame(String id) {
    state = state.copyWith(frameId: id, frameChanged: true, dirty: true);
  }

  /// Commits the draft. Rethrows on failure with the edits intact.
  Future<void> save() async {
    if (state.saving) return;
    state = state.copyWith(saving: true);
    try {
      // A Save tapped during image processing WAITS for the final WebP, or for
      // the failure revert, rather than committing half-staged state.
      final avatarWait = _processing[true];
      if (avatarWait != null) await avatarWait;
      final bannerWait = _processing[false];
      if (bannerWait != null) await bannerWait;

      final sent = _texts();
      final s = state;
      final gens = {true: _gen[true]!, false: _gen[false]!};
      final me = ref.read(identityProvider).peerId ?? '';

      // The legacy `twitch_username` is carried through UNCHANGED: it is a
      // self-declaration, and the verified mark it stood in for lives in
      // `support_creds` now. Writing it from a connected account would keep an
      // unverifiable claim alive on the wire.
      await ref.read(profileProvider.notifier).updateMyProfile(
            displayName: sent.name.trim(),
            status: sent.status.trim(),
            aboutMe: sent.about.trim(),
            // The STILL rides the push; the animation is already on the rail
            // and travels as its hash. An empty hash on a still pick drops a
            // previous animation.
            avatarBytes: s.avatarChanged
                ? (_still[true] ?? s.avatarBytes)
                : null,
            bannerBytes: s.bannerChanged
                ? (_still[false] ?? s.bannerBytes)
                : null,
            twitchUsername:
                ref.read(profileProvider)[me]?.twitchUsername ?? '',
            avatarFrame: s.effectiveFrame,
            avatarAnim: s.avatarChanged ? (_anim[true] ?? '') : null,
            bannerAnim: s.bannerChanged ? (_anim[false] ?? '') : null,
          );

      _baseline = sent;
      // Anything edited while the save was in flight stays pending.
      final avatarLater = _gen[true] != gens[true];
      final bannerLater = _gen[false] != gens[false];
      final frameLater = state.frameId != s.frameId;
      if (!avatarLater) _dropSlot(true);
      if (!bannerLater) _dropSlot(false);
      final now = state;
      state = ProfileDraftState(
        dirty: _texts() != sent || avatarLater || bannerLater || frameLater,
        avatarBytes: avatarLater ? now.avatarBytes : null,
        avatarChanged: avatarLater && now.avatarChanged,
        avatarBusy: avatarLater && now.avatarBusy,
        bannerBytes: bannerLater ? now.bannerBytes : null,
        bannerChanged: bannerLater && now.bannerChanged,
        bannerBusy: bannerLater && now.bannerBusy,
        frameId: frameLater ? now.frameId : null,
        frameChanged: frameLater && now.frameChanged,
      );
    } catch (e) {
      state = state.copyWith(saving: false);
      rethrow;
    }
  }

  void _dropSlot(bool avatar) {
    _still[avatar] = null;
    _anim[avatar] = null;
    _processing[avatar] = null;
  }

  /// Drops every unsaved edit, back to the saved profile.
  void reset() {
    if (state.saving) return;
    for (final avatar in const [true, false]) {
      _gen[avatar] = _gen[avatar]! + 1;
      _dropSlot(avatar);
    }
    final me = ref.read(identityProvider).peerId;
    final p = me == null ? null : ref.read(profileProvider)[me];
    // A newer row than the one last synced wins over what we last saved.
    if (p != null && p.updatedAt != _syncedStamp) {
      _fillFromSaved();
    } else {
      _setTexts(_baseline);
    }
    state = const ProfileDraftState();
  }
}

final profileDraftProvider =
    NotifierProvider<ProfileDraftNotifier, ProfileDraftState>(
        ProfileDraftNotifier.new);
