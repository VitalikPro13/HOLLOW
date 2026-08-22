/// Animated avatars on the asset rail.
///
/// The profile blob carries only the STILL; the animation is a hash whose
/// bytes are pulled on demand. That split is only a win if the renderer gets
/// the precedence exactly right, and it has two halves that fail in opposite
/// directions:
///
///   * hold the animation and paint the still  -> the feature does nothing;
///   * miss the still while the pull is in flight -> a blank face on every
///     surface until the owner happens to be online.
///
/// Both are pinned here.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/core/providers/profile_anim_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';

import '../helpers/test_app.dart';

const String _peer = 'peer_anim_tester_0001';
final String _hash = 'b' * 64;

/// Two distinguishable payloads. Nothing here decodes them — the assertions
/// are about WHICH list reaches the widget.
final Uint8List _still = Uint8List.fromList([1, 2, 3, 4]);
final Uint8List _anim = Uint8List.fromList([9, 8, 7, 6, 5]);

class _SeededProfiles extends ProfileNotifier {
  final String anim;
  _SeededProfiles(this.anim);

  @override
  Map<String, storage_api.UserProfile> build() => {
        _peer: storage_api.UserProfile(
          peerId: _peer,
          displayName: 'Anim Tester',
          status: '',
          aboutMe: '',
          updatedAt: 0,
          twitchUsername: '',
          showcaseBoard: '',
          avatarFrame: '',
          avatarAnim: anim,
          bannerAnim: '',
        ),
      };
}

class _SeededAvatars extends AvatarNotifier {
  final Map<String, Uint8List> seed;
  _SeededAvatars(this.seed);

  @override
  Map<String, Uint8List> build() => seed;
}

class _SeededAnims extends ProfileAnimNotifier {
  // Not `seed` - the notifier already has a seed() method.
  final Map<String, Uint8List> held;
  _SeededAnims(this.held);

  @override
  Map<String, Uint8List> build() => held;
}

/// The bytes [HollowAvatar] actually chose, read off the widget it built.
/// With animate: true the avatar always renders through [AnimatedGifImage],
/// so its `bytes` field IS the decision under test.
Uint8List? _painted(WidgetTester tester) {
  final found = find.byType(AnimatedGifImage);
  if (found.evaluate().isEmpty) return null;
  return tester.widget<AnimatedGifImage>(found.first).bytes;
}

Future<void> _pump(
  WidgetTester tester, {
  required String animHash,
  Map<String, Uint8List> still = const {},
  Map<String, Uint8List> rail = const {},
}) async {
  await tester.pumpWidget(
    ProviderScope(
      // A fresh key per pump, or Riverpod keeps the previous notifiers and
      // every later case silently measures the first one again.
      key: UniqueKey(),
      overrides: hollowTestOverrides(extra: [
        profileProvider.overrideWith(() => _SeededProfiles(animHash)),
        avatarProvider.overrideWith(() => _SeededAvatars(still)),
        profileAnimProvider.overrideWith(() => _SeededAnims(rail)),
      ]),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Center(
            child: HollowAvatar(peerId: _peer, size: 48, animate: true),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('the rail animation wins over the still it companions',
      (tester) async {
    await _pump(
      tester,
      animHash: _hash,
      still: {_peer: _still},
      rail: {_hash: _anim},
    );
    expect(_painted(tester), same(_anim),
        reason: 'holding the animation and painting the still is the feature '
            'doing nothing');
  });

  testWidgets('the still carries the face while the pull is in flight',
      (tester) async {
    // The hash is known, the bytes are not here yet — the ordinary state for
    // anyone you just met.
    await _pump(tester, animHash: _hash, still: {_peer: _still}, rail: const {});
    expect(_painted(tester), same(_still),
        reason: 'a face must never go blank waiting for a rail pull');
  });

  testWidgets('no animated variant means nothing changes at all',
      (tester) async {
    await _pump(tester, animHash: '', still: {_peer: _still});
    expect(_painted(tester), same(_still));
  });

  testWidgets('an explicit imageBytes override still wins over both',
      (tester) async {
    // Archive rows and the settings preview hand bytes in directly; the rail
    // must not reach around them.
    final override = Uint8List.fromList([4, 4, 4]);
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: hollowTestOverrides(extra: [
          profileProvider.overrideWith(() => _SeededProfiles(_hash)),
          avatarProvider.overrideWith(() => _SeededAvatars({_peer: _still})),
          profileAnimProvider.overrideWith(() => _SeededAnims({_hash: _anim})),
        ]),
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Center(
              child: HollowAvatar(
                peerId: _peer,
                size: 48,
                animate: true,
                imageBytes: override,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(_painted(tester), same(override));
  });

  test('only a 64-hex reference names art on the rail', () {
    expect(isProfileAnimHash('b' * 64), isTrue);
    expect(isProfileAnimHash(''), isFalse,
        reason: 'empty is STILL-ONLY, not a reference');
    expect(isProfileAnimHash('g' * 64), isFalse, reason: 'not hex');
    expect(isProfileAnimHash('b' * 63), isFalse);
    expect(isProfileAnimHash('../../etc/passwd'), isFalse);
  });
}
