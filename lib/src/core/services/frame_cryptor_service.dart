import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../rust/api/network.dart' as network_api;

void _fcLog(String msg) {
  network_api.logFromDart(message: msg);
}

/// Reusable service managing SFrame encryption for WebRTC audio/video.
///
/// Wraps flutter_webrtc's FrameCryptor + KeyProvider APIs.
/// One instance per call session (1:1 DM) or voice channel session (server).
class FrameCryptorService {
  KeyProvider? _keyProvider;

  /// Sender-side frame cryptors: "peerId:kind" -> FrameCryptor.
  /// Kind is 'audio' or 'video'. Allows separate cryptors per track type per peer.
  final Map<String, FrameCryptor> _senderCryptors = {};

  /// Receiver-side frame cryptors: "peerId:kind" -> FrameCryptor.
  final Map<String, FrameCryptor> _receiverCryptors = {};

  /// Whether encryption is active.
  bool _enabled = false;

  /// Initialize the KeyProvider. Call once per session before enabling encryption.
  ///
  /// [sharedKey]: true = all participants use the same key (server voice channels).
  ///              false = per-participant keys (DM calls).
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

  /// Set the encryption key for a participant (or shared key if sharedKey mode).
  Future<void> setKey(String participantId, int index, Uint8List key) async {
    if (_keyProvider == null) return;
    try {
      await _keyProvider!.setKey(
        participantId: participantId,
        index: index,
        key: key,
      );
      _fcLog('[HOLLOW-SFRAME] Key set for $participantId at index $index (${key.length} bytes)');
    } finally {
      // SECURITY (Phase 6.25): Clear key material from memory.
      key.fillRange(0, key.length, 0);
    }
  }

  /// Set a shared key (for server voice channels where all members share the MLS epoch key).
  Future<void> setSharedKey(int index, Uint8List key) async {
    if (_keyProvider == null) return;
    try {
      await _keyProvider!.setSharedKey(key: key, index: index);
      _fcLog('[HOLLOW-SFRAME] Shared key set at index $index (${key.length} bytes)');
    } finally {
      // SECURITY (Phase 6.25): Clear key material from memory.
      key.fillRange(0, key.length, 0);
    }
  }

  /// Enable frame encryption for an RTP sender (our outgoing audio/video).
  ///
  /// [kind] distinguishes audio vs video cryptors for the same peer.
  Future<void> enableForSender(String peerId, RTCRtpSender sender, {String kind = 'audio'}) async {
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
      };
      await cryptor.setEnabled(true);
      _senderCryptors[key] = cryptor;
      _enabled = true;
      _fcLog('[HOLLOW-SFRAME] Sender encryption enabled for $key');
    } catch (e) {
      _fcLog('[HOLLOW-SFRAME] Failed to enable sender encryption for $key: $e');
    }
  }

  /// Enable frame decryption for an RTP receiver (incoming audio/video from peer).
  ///
  /// [kind] distinguishes audio vs video cryptors for the same peer.
  Future<void> enableForReceiver(String peerId, RTCRtpReceiver receiver, {String kind = 'audio'}) async {
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
      };
      await cryptor.setEnabled(true);
      _receiverCryptors[key] = cryptor;
      _fcLog('[HOLLOW-SFRAME] Receiver decryption enabled for $key');
    } catch (e) {
      _fcLog('[HOLLOW-SFRAME] Failed to enable receiver decryption for $key: $e');
    }
  }

  /// Rotate the encryption key (e.g., on MLS epoch change).
  Future<void> rotateKey(int newIndex, Uint8List newKey) async {
    if (_keyProvider == null) return;
    await _keyProvider!.setSharedKey(key: newKey, index: newIndex);
    // Update key index on all active cryptors.
    for (final cryptor in _senderCryptors.values) {
      await cryptor.setKeyIndex(newIndex);
    }
    for (final cryptor in _receiverCryptors.values) {
      await cryptor.setKeyIndex(newIndex);
    }
    _fcLog('[HOLLOW-SFRAME] Key rotated to index $newIndex');
  }

  /// Disable and clean up cryptors for a specific peer (audio, video, and screen share).
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

  /// Whether frame encryption is currently active.
  bool get isEnabled => _enabled;

  /// Dispose all cryptors and the key provider.
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
