import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A wobbling network must never hang up a call.
///
/// `RTCPeerConnectionStateDisconnected` does not mean "the call is over". It
/// means ICE consent checks have gone unanswered for a couple of seconds,
/// which is what a Wi-Fi stutter, a mobile handover or a saturated uplink look
/// like from inside libwebrtc, and it clears itself most of the time.
///
/// Every media lane used to treat it as terminal anyway, and the DM call lane
/// went further and signalled `end` to the peer, so one side's three-second
/// hiccup hung the call up on BOTH machines. The hold-open ladder in
/// `link_resilience.dart` replaced that. These guards exist because the old
/// shape is the natural one to write: grouping `disconnected` in with `failed`
/// and `closed` in a single switch reads as tidy, and reintroduces the bug.
///
/// The behaviour itself is pinned by `link_resilience_test.dart`; this file
/// only stops the lanes from routing around it.
void main() {
  test('the DM call lane reports transport states and decides nothing', () {
    final src = _read('lib/src/core/services/voice_service.dart');

    expect(src.contains('onTransportState'), isTrue,
        reason: 'VoiceService must forward raw transport states to the policy '
            'owner (CallNotifier), which is what holds a lapsing call open.');

    expect(
      RegExp(r'void Function\(String peerId\)\?\s+onDisconnected').hasMatch(src),
      isFalse,
      reason: 'The old collapse-everything-into-one-callback shape is back. '
          '`disconnected`, `failed` and `closed` mean three different things '
          'and only one of them is a hangup.',
    );
  });

  test('a network problem reaches a hangup through exactly one door', () {
    final src = _read('lib/src/core/providers/call_provider.dart');

    expect(src.contains('_endCallForLinkLoss'), isTrue,
        reason: 'The single network-driven teardown path is missing.');

    // The watchdog is the only thing allowed to decide a link is gone, and it
    // does that by calling onGiveUp. Anything else reaching for a teardown on
    // a transport state is the old bug.
    final handler = _between(src, '_voiceService!.onTransportState =', '};');
    expect(handler, isNotNull,
        reason: 'onTransportState is no longer wired in _wireCallbacks.');
    expect(
      handler!.contains('RTCPeerConnectionStateDisconnected'),
      isFalse,
      reason: 'The transport-state handler is acting on `disconnected` again. '
          'It belongs to the hold-open ladder, which holds the call and '
          'restarts ICE instead of ending it.',
    );
  });

  test('the voice mesh recovers a peer leg before closing it', () {
    final src = _read('lib/src/core/services/voice_channel_service.dart');
    final handler = _between(
        src, 'void _onPeerConnectionState(', '\n  /// Begin holding');
    expect(handler, isNotNull,
        reason: '_onPeerConnectionState moved; re-point this guard.');

    expect(handler!.contains('_startLinkWatch'), isTrue,
        reason: 'A connected mesh leg must get a hold-open watchdog. Without '
            'one, `failed` closes the peer with no recovery attempt and a '
            'member whose Wi-Fi hiccuped drops out of the channel.');

    // closePeer on a leg that HAS a watchdog is the watchdog's call to make,
    // via onGiveUp, once its window is spent.
    final closeCalls = 'closePeer'.allMatches(handler).length;
    expect(closeCalls, 1,
        reason: 'The state handler should close a peer in exactly one case: '
            'a leg that never connected. Everything else goes through the '
            'watchdog.');
  });

  test('a screen share leg holds through a wobble', () {
    final src = _read('lib/src/core/services/screen_share_service.dart');
    final handler = _between(src, 'void _onConnectionStateChanged(', '\n  }');
    expect(handler, isNotNull,
        reason: '_onConnectionStateChanged moved; re-point this guard.');

    // The teardown arm is Failed + Closed. Disconnected must sit in its own
    // arm that holds, letting the (stricter) consent watchdog decide.
    final teardownArm = _between(
        handler!, 'RTCPeerConnectionStateFailed:', 'RTCPeerConnectionState');
    expect(teardownArm, isNotNull);
    expect(
      handler.contains(
          'RTCPeerConnectionStateClosed:\n        _stopLivenessWatchdog();'),
      isTrue,
      reason: 'Failed and Closed should share the teardown arm.',
    );
    expect(
      RegExp(r'RTCPeerConnectionStateDisconnected:\s*\n\s*_stopLivenessWatchdog')
          .hasMatch(handler),
      isFalse,
      reason: 'A share leg is tearing down on `disconnected` again. That '
          'rebuilds a leg that was about to heal, and every rebuild is a '
          'visible blink plus a fresh SFrame binding. The consent watchdog '
          'already catches a genuinely dead leg in about three seconds.',
    );
  });

  test('link recovery REBUILDS the media session, it does not restart ICE '
      'in place', () {
    // An in-place ICE restart recovers the transport and destroys SFrame with
    // it: the cryptors end up bound to a transport that no longer exists.
    // Repairing them afterwards was attempted four separate ways in the field
    // (re-bind, atomic ladder, re-key, both trigger paths) and never once
    // produced working audio. A fresh peer connection fixes both at once, and
    // it is the same path a call start already takes.
    final provider = _read('lib/src/core/providers/call_provider.dart');
    expect(provider.contains('onRecoverLink: _restartMediaSession'), isTrue,
        reason: 'the DM lane must recover by rebuilding the media session.');
    expect(provider.contains('_service.restartIce()'), isFalse,
        reason: 'an in-place ICE restart is exactly what broke the audio.');

    final mesh = _read('lib/src/core/services/voice_channel_service.dart');
    final recover = _between(mesh, 'onRecoverLink:', 'onGiveUp:');
    expect(recover, isNotNull, reason: 'the mesh lost its recovery callback.');
    expect(recover!.contains('_rebuildLeg'), isTrue,
        reason: 'the mesh recovers a leg through _rebuildLeg, which drops and '
            're-dials it — what a member rejoining does.');
    expect(recover.contains('restartIceOn'), isFalse);

    final redial = _between(mesh, 'Future<void> _redialLeg(', '\n  }');
    expect(redial, isNotNull, reason: '_redialLeg moved; re-point this guard.');
    expect(redial!.contains('closePeer'), isTrue);
    expect(redial.contains('connectToPeer'), isTrue);
  });

  test('the side that cannot dial ASKS instead of waiting forever', () {
    // The mesh gives the offer to the lexicographically lower peer id. The
    // higher side's recovery used to be `closePeer` and then nothing at all:
    // it tore its leg down and waited for an offer nobody was going to send,
    // and could destroy a leg the peer had just rebuilt. Field-caught
    // 2026-08-27 — no audio for the rest of the session.
    final mesh = _read('lib/src/core/services/voice_channel_service.dart');
    final rebuild = _between(mesh, 'Future<void> _rebuildLeg(', '\n  }');
    expect(rebuild, isNotNull, reason: '_rebuildLeg moved; re-point this guard.');
    expect(rebuild!.contains('shouldInitiateIceRepair'), isTrue,
        reason: 'the rebuild must branch on the SAME glare rule the join '
            'machinery dials by, or both sides dial and ping-pong.');
    expect(rebuild.contains('_sendLegRestart'), isTrue,
        reason: 'the non-dialing side must ask its peer to re-offer. Dropping '
            'this is the bug: a silent leg with nobody dialing.');

    // Both ends watch the same leg and both can decide it is broken seconds
    // apart. Without a window the second one tears down what the first just
    // rebuilt — the mesh twin of _mediaRestartRecentlyStarted.
    expect(mesh.contains('_legRebuiltRecently'), isTrue,
        reason: 'whichever rebuild starts first must own the leg.');
    final onOffer = _between(mesh, 'Future<void> _handleSdpOffer(', '\n  }');
    expect(onOffer, isNotNull);
    expect(onOffer!.contains('_legRebuiltAt[peerId] = DateTime.now()'), isTrue,
        reason: "accepting a peer's rebuild offer must claim the window too, "
            'or our own watchdog closes the leg they just rebuilt.');
  });

  test('the leg_restart signal has all THREE Rust touches', () {
    // Voice-channel signal types are WHITELISTED in Rust exactly like call
    // signals; a type missing any touch is dropped SILENTLY, which for this
    // one means the higher-id side asks and nothing ever happens.
    const touches = {
      'rust/hollow_core/src/node/types.rs': 'VoiceChannelLegRestart',
      'rust/hollow_core/src/node/voice_handler.rs': '"leg_restart"',
      'rust/hollow_core/src/node/swarm.rs': 'VoiceChannelLegRestart',
    };
    touches.forEach((path, needle) {
      expect(_read(path).contains(needle), isTrue,
          reason: '$path is missing the leg_restart touch ($needle). A new VC '
              'signal needs the types.rs variant, the send match arm, and the '
              'swarm.rs dispatch arm.');
    });
  });

  test('voice presence is re-announced OUTSIDE the is_new guard', () {
    // A peer whose socket dies is purged from our `voice_channel_participants`,
    // and that set gates every inbound VC signal. Only the peer's own presence
    // re-announce refills it. That re-announce used to sit inside the
    // `is_new`/`synced_peers` cascade, which is false for exactly the peer that
    // just reconnected: the real relay broadcasts PeerLeft only for a CLEAN
    // leave, so a dropped peer is never removed from `synced_peers`.
    // Field-caught 2026-08-27: four offers dialed, four dropped as
    // `BLOCKED VC SDP offer from non-participant`, permanently silent channel.
    // Behaviour is pinned by `vc_reconnecting_peer_can_receive_signals_again`
    // in the harness (verified to FAIL when this block is disabled).
    final swarm = _read('rust/hollow_core/src/node/swarm.rs');
    final announce = swarm.indexOf('Re-announcing our presence');
    expect(announce, greaterThan(-1),
        reason: 'the voice presence re-announce is gone. Without it a peer '
            'that reconnects can send VC signals but never receive them.');
    final isNewGuard = swarm.indexOf('let is_new = synced_peers.insert');
    expect(isNewGuard, greaterThan(-1),
        reason: 'the is_new guard moved; re-point this guard.');
    expect(announce, lessThan(isNewGuard),
        reason: 'the re-announce is back inside the is_new cascade. That guard '
            'means "have we synced with this peer at all this session" and is '
            'FALSE for a peer that dropped and came back, which is the only '
            'peer that needs it.');
  });

  test('a mesh leg that was given up on is still reached for', () {
    // A DM call that gives up hangs up, and the user can call again. A voice
    // channel has no such moment: the member stays in the roster, so a leg
    // abandoned here is silent for as long as they sit there.
    final mesh = _read('lib/src/core/services/voice_channel_service.dart');
    expect(mesh.contains('_scheduleLegRedial'), isTrue,
        reason: 'a spent hold-open window must start a slow retry, not end '
            'the leg for good.');
    final giveUp = _between(mesh, 'onGiveUp: () {', '\n      },');
    expect(giveUp, isNotNull);
    expect(giveUp!.contains('_scheduleLegRedial'), isTrue);
  });

  test('a rebuilt leg gets the receive-side state put back', () {
    // Mute rides the shared local track and survives untouched, but deafen and
    // the per-peer volume are set ON the receiver, which the rebuild replaced.
    final mesh = _read('lib/src/core/services/voice_channel_service.dart');
    expect(mesh.contains('_restorePeerAudioState'), isTrue,
        reason: 'a fresh receiver arrives at full volume: a deafened member '
            'would become audible again on every reconnect.');
    final connected = _between(
        mesh, 'RTCPeerConnectionStateConnected) {', '\n    }');
    expect(connected, isNotNull);
    expect(connected!.contains('_restorePeerAudioState'), isTrue);
  });

  test('a crossing rebuild cannot make the call forget the camera', () {
    // Field-caught 2026-08-27: audio came back, the picture never did. A
    // rebuild sets isVideoEnabled false as it starts, so the SECOND claim on
    // the same recovery (ours, then the peer's crossing media_restart) read
    // that cleared flag and concluded the camera had never been on.
    final provider = _read('lib/src/core/providers/call_provider.dart');
    expect(provider.contains('_claimVideoRestore()'), isTrue,
        reason: 'the restore flag must be LATCHED, never assigned from the '
            'state a rebuild has already cleared.');
    expect(
      RegExp(r'_restoreVideoAfterRestart = state\.isVideoEnabled')
          .hasMatch(provider),
      isFalse,
      reason: 'the assignment is back, and with it the forgotten camera.',
    );

    // Both ends restore their own camera onto the same fresh, audio-only peer
    // connection, and each restore is a renegotiation.
    final restore =
        _between(provider, 'void _restoreAfterMediaRestart()', '\n  }');
    expect(restore, isNotNull);
    expect(restore!.contains('_cameraAutoEnableDelayMs'), isTrue,
        reason: 'two cameras coming back at the same moment is textbook '
            'renegotiation glare: one offer is never processed and the video '
            'ends up one-way. Stagger it like the call-start auto-enable.');
  });

  test('the media_restart signal has all THREE Rust touches', () {
    // Call signal types are WHITELISTED in Rust; a type missing any touch is
    // silently dropped, which for this one means a peer that never tears its
    // side down and a rebuild that half-happens.
    const touches = {
      'rust/hollow_core/src/node/types.rs': 'CallMediaRestart',
      'rust/hollow_core/src/node/voice_handler.rs': '"media_restart"',
      'rust/hollow_core/src/node/swarm.rs': 'CallMediaRestart',
    };
    touches.forEach((path, needle) {
      expect(_read(path).contains(needle), isTrue,
          reason: '$path is missing the media_restart touch ($needle). '
              'A new call signal needs the types.rs variant, the send match '
              'arm, and the swarm.rs dispatch arm.');
    });
  });

  test('a rebuilt session gets the mic state FORCED back onto it', () {
    // Field-caught 2026-08-27: the call recovered, the mute button still
    // showed muted, and the microphone was open. `setMuted` early-returns when
    // its cached flag already agrees, and `createOffer` tears media down
    // WITHOUT clearing that flag, so after a rebuild the flag said "muted"
    // while the freshly captured track was live and the re-apply did nothing.
    final service = _read('lib/src/core/services/voice_service.dart');
    expect(service.contains('void setMuted(bool muted, {bool force = false})'),
        isTrue,
        reason: 'setMuted needs a force path: the cached flag describes the '
            'track it was last applied to, and a rebuild replaces that track.');
    expect(service.contains('if (_isMuted == muted && !force) return;'), isTrue,
        reason: 'the early return must honour force.');

    final provider = _read('lib/src/core/providers/call_provider.dart');
    final restore =
        _between(provider, 'void _restoreAfterMediaRestart()', '\n  }');
    expect(restore, isNotNull,
        reason: '_restoreAfterMediaRestart moved; re-point this guard.');
    expect(restore!.contains('_applyTxGate(force: true)'), isTrue,
        reason: 'restore through the tx gate, not a bare setMuted: mute is one '
            'of THREE things that silence the mic, and deafen and PTT have to '
            'come back with it.');
  });

  test('two crossing media rebuilds cannot tear down each other', () {
    // Both ends are eligible to initiate, and in the field both did: the
    // polite side's media_restart was dropped while the peer's relay was still
    // down, and the peer started its own moments later.
    final provider = _read('lib/src/core/providers/call_provider.dart');
    expect(provider.contains('_mediaRestartRecentlyStarted'), isTrue,
        reason: 'whichever rebuild starts first must own the window.');
    final handler =
        _between(provider, 'Future<void> _handleMediaRestart(', '\n  }');
    expect(handler, isNotNull);
    expect(handler!.contains('_mediaRestartAt = DateTime.now()'), isTrue,
        reason: "receiving a peer's rebuild must also claim the window, or "
            'ours fires into it a moment later.');
  });

  test('the video ladder always has somewhere to fall before the call does',
      () {
    final src = _read('lib/src/core/services/video_quality_ladder.dart');
    expect(src.contains('VideoRung.paused'), isTrue,
        reason: 'The bottom rung stops sending video entirely. It is what '
            'guarantees voice keeps the whole uplink when nothing else fits.');
  });
}

String _read(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    fail('$path is missing. If it moved, re-point this guard rather than '
        'deleting it.');
  }
  return file.readAsStringSync().replaceAll('\r\n', '\n');
}

/// The text between the first [start] and the next [end] after it.
String? _between(String src, String start, String end) {
  final from = src.indexOf(start);
  if (from < 0) return null;
  final to = src.indexOf(end, from + start.length);
  if (to < 0) return null;
  return src.substring(from, to);
}
