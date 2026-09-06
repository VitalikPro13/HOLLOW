import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../rust/api/network.dart' as network_api;

void _fcLog(String msg) {
  network_api.logFromDart(message: msg);
}

/// Reusable service managing SFrame encryption for WebRTC audio and video,
/// wrapping flutter_webrtc's FrameCryptor and KeyProvider. One instance per
/// call session or voice channel session.
class FrameCryptorService {
  KeyProvider? _keyProvider;

  /// Sender-side frame cryptors, keyed "peerId:kind" where kind is 'audio' or
  /// 'video', so each track type has its own cryptor per peer.
  final Map<String, FrameCryptor> _senderCryptors = {};

  final Map<String, FrameCryptor> _receiverCryptors = {};

  /// Serializes every mutation of the cryptor maps.
  ///
  /// [enableForReceiver] and [enableForSender] check their map, then `await`
  /// the native create, then insert: a check-then-act across a suspension
  /// point, so two callers arriving together BOTH pass the guard, BOTH create
  /// a native cryptor on the same receiver, and the map keeps only the second.
  /// The orphan stays attached natively and the two fight over the same frames.
  ///
  /// The heal ping fires two paths at once by design, so this is not
  /// hypothetical. Serializing rather than a smarter guard, because the real
  /// invariant is that a cryptor ladder (drop, re-create, set index) must not
  /// interleave with another ladder halfway through.
  Future<void> _mutations = Future<void>.value();

  /// Runs [op] after every previously queued mutation has finished.
  ///
  /// CRITICAL: never call this from inside another [_serialize] block. The
  /// public methods take the lock and delegate to `_*Unlocked` internals for
  /// exactly that reason; a nested acquisition would wait on itself forever.
  Future<T> _serialize<T>(Future<T> Function() op) {
    final result = _mutations.then((_) => op());
    // The chain must survive a failing op, or one thrown error wedges every
    // later cryptor change for the life of the call.
    _mutations = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  /// Whether key material has been set. Enable paths gate on it: a cryptor is
  /// only useful once a key exists.
  bool _enabled = false;

  /// Current key index; new cryptors use it.
  int currentKeyIndex = 0;

  /// Fired on every cryptor state transition, in both directions. Drives the
  /// SFrame heal ladder: sustained MissingKey, DecryptionFailed or
  /// InternalError means the peer and we disagree on key material.
  void Function(String participantId, String kind, bool isReceiver,
      FrameCryptorState state)? onCryptorStateChanged;

  static bool isFailureState(FrameCryptorState state) =>
      state == FrameCryptorState.FrameCryptorStateMissingKey ||
      state == FrameCryptorState.FrameCryptorStateDecryptionFailed ||
      state == FrameCryptorState.FrameCryptorStateEncryptionFailed ||
      state == FrameCryptorState.FrameCryptorStateInternalError;

  /// Initializes the KeyProvider, once per session before enabling encryption.
  /// [sharedKey] true means all participants use the same key (server voice
  /// channels), false means per-participant keys (DM calls).
  Future<void> init({bool sharedKey = true}) async {
    final options = KeyProviderOptions(
      sharedKey: sharedKey,
      ratchetSalt: Uint8List.fromList('hollow-sframe-salt'.codeUnits),
      ratchetWindowSize: 16,
      failureTolerance: -1, // unlimited
      keyRingSize: 16,
      discardFrameWhenCryptorNotReady: false,
    );
    _keyProvider = await frameCryptorFactory.createDefaultKeyProvider(options);
    _fcLog('[HOLLOW-SFRAME] KeyProvider initialized (sharedKey=$sharedKey)');
  }

  /// Sets the encryption key for a participant, or the shared key in
  /// sharedKey mode.
  Future<void> setKey(String participantId, int index, Uint8List key) async {
    if (_keyProvider == null) return;
    try {
      await _keyProvider!.setKey(
        participantId: participantId,
        index: index,
        key: key,
      );
      _enabled = true; // key material present — cryptors may be created
      _fcLog('[HOLLOW-SFRAME] Key set for $participantId at index $index (${key.length} bytes)');
    } finally {
      // Clear key material from memory.
      key.fillRange(0, key.length, 0);
    }
  }

  /// Sets a shared key, for server voice channels where all members share the
  /// MLS epoch key.
  Future<void> setSharedKey(int index, Uint8List key) async {
    if (_keyProvider == null) return;
    try {
      await _keyProvider!.setSharedKey(key: key, index: index);
      _enabled = true; // key material present — cryptors may be created
      _fcLog('[HOLLOW-SFRAME] Shared key set at index $index (${key.length} bytes)');
    } finally {
      // Clear key material from memory.
      key.fillRange(0, key.length, 0);
    }
  }

  /// Enables frame encryption for an RTP sender. [kind] distinguishes audio
  /// from video cryptors for the same peer.
  Future<void> enableForSender(String peerId, RTCRtpSender sender,
          {String kind = 'audio'}) =>
      _serialize(() => _enableForSenderUnlocked(peerId, sender, kind: kind));

  Future<void> _enableForSenderUnlocked(String peerId, RTCRtpSender sender,
      {String kind = 'audio'}) async {
    if (_keyProvider == null) return;
    final key = '$peerId:$kind';
    if (_senderCryptors.containsKey(key)) return;

    try {
      final cryptor = await frameCryptorFactory.createFrameCryptorForRtpSender(
        participantId: peerId,
        sender: sender,
        algorithm: Algorithm.kAesGcm,
        keyProvider: _keyProvider!,
      );
      cryptor.onFrameCryptorStateChanged = (pid, state) {
        _fcLog('[HOLLOW-SFRAME] Sender $pid ($kind) state: $state');
        onCryptorStateChanged?.call(peerId, kind, false, state);
      };
      await cryptor.setEnabled(true);
      _senderCryptors[key] = cryptor;
      _enabled = true;
      _fcLog('[HOLLOW-SFRAME] Sender encryption enabled for $key');
    } catch (e) {
      _fcLog('[HOLLOW-SFRAME] Failed to enable sender encryption for $key: $e');
    }
  }

  /// Enables frame decryption for an RTP receiver. [kind] distinguishes audio
  /// from video cryptors for the same peer.
  Future<void> enableForReceiver(String peerId, RTCRtpReceiver receiver,
          {String kind = 'audio'}) =>
      _serialize(() => _enableForReceiverUnlocked(peerId, receiver, kind: kind));

  Future<void> _enableForReceiverUnlocked(String peerId, RTCRtpReceiver receiver,
      {String kind = 'audio'}) async {
    if (_keyProvider == null) return;
    final key = '$peerId:$kind';
    if (_receiverCryptors.containsKey(key)) return;

    try {
      final cryptor =
          await frameCryptorFactory.createFrameCryptorForRtpReceiver(
        participantId: peerId,
        receiver: receiver,
        algorithm: Algorithm.kAesGcm,
        keyProvider: _keyProvider!,
      );
      cryptor.onFrameCryptorStateChanged = (pid, state) {
        _fcLog('[HOLLOW-SFRAME] Receiver $pid ($kind) state: $state');
        onCryptorStateChanged?.call(peerId, kind, true, state);
      };
      await cryptor.setEnabled(true);
      _receiverCryptors[key] = cryptor;
      _fcLog('[HOLLOW-SFRAME] Receiver decryption enabled for $key');
    } catch (e) {
      _fcLog('[HOLLOW-SFRAME] Failed to enable receiver decryption for $key: $e');
    }
  }

  /// Rotates the encryption key, on an MLS epoch change.
  Future<void> rotateKey(int newIndex, Uint8List newKey) async {
    if (_keyProvider == null) return;
    currentKeyIndex = newIndex;
    await _keyProvider!.setSharedKey(key: newKey, index: newIndex);
    // CRITICAL: key material present means cryptors may be created. This flag
    // was historically only set in enableForSender while every VC enable path
    // guards on it, so voice-channel SFrame never engaged until a screen share
    // flipped it on ONE side, and the first epoch change then made that side
    // encrypt while the other had no decryptor (issue #27).
    _enabled = true;
    for (final cryptor in _senderCryptors.values) {
      await cryptor.setKeyIndex(newIndex);
    }
    for (final cryptor in _receiverCryptors.values) {
      await cryptor.setKeyIndex(newIndex);
    }
    _fcLog('[HOLLOW-SFRAME] Key rotated to index $newIndex');
  }

  /// Disposes the SENDER cryptor for (peerId, kind) so a REPLACEMENT RTP
  /// sender can be re-enabled. Without this, [enableForSender], idempotent per
  /// key, silently keeps the cryptor bound to the removed sender and the new
  /// track goes out undecryptable.
  Future<void> disableSender(String peerId, {String kind = 'audio'}) =>
      _serialize(() => _disableSenderUnlocked(peerId, kind: kind));

  Future<void> _disableSenderUnlocked(String peerId,
      {String kind = 'audio'}) async {
    final key = '$peerId:$kind';
    final sender = _senderCryptors.remove(key);
    if (sender == null) return;
    try {
      await sender.setEnabled(false);
      await sender.dispose();
      _fcLog('[HOLLOW-SFRAME] Sender cryptor dropped for $key (device switch)');
    } catch (e) {
      _fcLog('[HOLLOW-SFRAME] Failed to drop sender cryptor for $key: $e');
    }
  }

  /// Disposes the RECEIVER cryptor for (peerId, kind), the mirror of
  /// [disableSender]. A remote mid-call device switch lands as a NEW inbound
  /// transceiver, and without dropping the old cryptor [enableForReceiver]
  /// skips the new receiver and the fresh track plays as ciphertext.
  Future<void> disableReceiver(String peerId, {String kind = 'audio'}) =>
      _serialize(() => _disableReceiverUnlocked(peerId, kind: kind));

  Future<void> _disableReceiverUnlocked(String peerId,
      {String kind = 'audio'}) async {
    final key = '$peerId:$kind';
    final receiver = _receiverCryptors.remove(key);
    if (receiver == null) return;
    try {
      await receiver.setEnabled(false);
      await receiver.dispose();
      _fcLog('[HOLLOW-SFRAME] Receiver cryptor dropped for $key (rebind)');
    } catch (e) {
      _fcLog('[HOLLOW-SFRAME] Failed to drop receiver cryptor for $key: $e');
    }
  }

  /// Sets the key index on all cryptors for one peer, such as newly created
  /// screen-share cryptors.
  Future<void> setKeyIndexForPeer(String peerId, int index) =>
      _serialize(() => _setKeyIndexForPeerUnlocked(peerId, index));

  Future<void> _setKeyIndexForPeerUnlocked(String peerId, int index) async {
    for (final entry in _senderCryptors.entries) {
      if (entry.key.startsWith('$peerId:')) {
        await entry.value.setKeyIndex(index);
      }
    }
    for (final entry in _receiverCryptors.entries) {
      if (entry.key.startsWith('$peerId:')) {
        await entry.value.setKeyIndex(index);
      }
    }
  }

  /// Re-binds BOTH directions for one peer as a single atomic ladder, for a
  /// transport rebuilt underneath us by an ICE restart: the cryptors are
  /// idempotent per (peer, kind), so a plain re-enable is a no-op on a stale
  /// binding and the old one has to be dropped first.
  ///
  /// One lock for the whole ladder, not one per step: taking it five times
  /// would let the heal ping or a mic switch interleave between the drop and
  /// the re-create, leaving a receiver with two competing cryptors or none.
  Future<void> reassert({
    required String peerId,
    RTCRtpSender? sender,
    RTCRtpReceiver? receiver,
    String kind = 'audio',
    int keyIndex = 0,
  }) =>
      _serialize(() async {
        await _disableSenderUnlocked(peerId, kind: kind);
        await _disableReceiverUnlocked(peerId, kind: kind);
        if (sender != null) {
          await _enableForSenderUnlocked(peerId, sender, kind: kind);
        }
        if (receiver != null) {
          await _enableForReceiverUnlocked(peerId, receiver, kind: kind);
        }
        // A freshly created cryptor defaults to index 0. DM calls do use 0,
        // but stating it is the rule everywhere else
        // (`feedback_sframe_key_index`), and a silent MissingKey is the
        // failure this whole method exists to stop.
        await _setKeyIndexForPeerUnlocked(peerId, keyIndex);
        _fcLog('[HOLLOW-SFRAME] Re-asserted $peerId:$kind '
            '(sender=${sender != null} receiver=${receiver != null})');
      });

  /// Disables and cleans up cryptors for one peer: audio, video, screen share.
  Future<void> disableForPeer(String peerId) async {
    for (final kind in ['audio', 'video', 'screen_audio', 'screen_video']) {
      final key = '$peerId:$kind';
      final sender = _senderCryptors.remove(key);
      if (sender != null) {
        await sender.setEnabled(false);
        await sender.dispose();
      }
      final receiver = _receiverCryptors.remove(key);
      if (receiver != null) {
        await receiver.setEnabled(false);
        await receiver.dispose();
      }
    }
  }

  bool get isEnabled => _enabled;

  Future<void> dispose() async {
    for (final cryptor in _senderCryptors.values) {
      try { await cryptor.setEnabled(false); } catch (_) {}
      try { await cryptor.dispose(); } catch (_) {}
    }
    _senderCryptors.clear();
    for (final cryptor in _receiverCryptors.values) {
      try { await cryptor.setEnabled(false); } catch (_) {}
      try { await cryptor.dispose(); } catch (_) {}
    }
    _receiverCryptors.clear();
    try { await _keyProvider?.dispose(); } catch (_) {}
    _keyProvider = null;
    _enabled = false;
    _fcLog('[HOLLOW-SFRAME] Disposed');
  }
}
