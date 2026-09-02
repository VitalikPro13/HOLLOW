/// Avatar frames (issue #54).
///
/// The hard rule Vitalik set is the first test here: a frame takes ZERO
/// layout space, so an avatar's rect with one is identical to the same
/// avatar without one. Everything else in this file guards the gates that
/// keep that true - the fixed 1.33 box, the 24px floor, and the fact that
/// the art never participates in hit testing.
library;

import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/avatar_frame_provider.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/avatar_frame.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';

import '../helpers/test_app.dart';

const String _peer = 'peer_frame_tester_0001';
final String _hash = 'a' * 64;

// 1x1 transparent PNG. The decode path does not care that real frames are
// 128px WebP.
// A genuine 2-frame GIF: `isAnimatedImageBytes` must say yes AND it has to
// really decode, so the hover path is exercised end to end.
final Uint8List _kTinyGif = Uint8List.fromList([
  0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x02, 0x00, 0x02, 0x00, 0x81, 0x00, //
  0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x21, 0xFF, 0x0B, 0x4E, 0x45, 0x54, 0x53, 0x43, 0x41, 0x50, 0x45, //
  0x32, 0x2E, 0x30, 0x03, 0x01, 0x00, 0x00, 0x00, 0x21, 0xF9, 0x04, 0x00, //
  0x0A, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x02, //
  0x00, 0x00, 0x08, 0x06, 0x00, 0x01, 0x08, 0x04, 0x10, 0x10, 0x00, 0x21, //
  0xF9, 0x04, 0x01, 0x0A, 0x00, 0x01, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00, //
  0x02, 0x00, 0x02, 0x00, 0x81, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x06, 0x00, 0x01, 0x08, 0x04, 0x10, //
  0x10, 0x00, 0x3B, //
]);

final Uint8List _kTinyPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0xA9, 0xF1, 0x9E, 0x7E, 0x00, 0x00, 0x00, //
  0x17, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x38, 0x11, 0xA5, 0xF1, //
  0x1F, 0x19, 0x33, 0x40, 0x19, 0x0C, 0x50, 0x8C, 0x5B, 0x00, 0x8E, 0x01, //
  0x56, 0x8A, 0x20, 0x95, 0x08, 0x98, 0x60, 0x01, 0x00, 0x00, 0x00, 0x00, //
  0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82, //
]);

class _SeededProfiles extends ProfileNotifier {
  final String frame;
  _SeededProfiles(this.frame);

  @override
  Map<String, storage_api.UserProfile> build() => {
        _peer: storage_api.UserProfile(
          peerId: _peer,
          displayName: 'Frame Tester',
          status: '',
          aboutMe: '',
          updatedAt: 0,
          twitchUsername: '',
          showcaseBoard: '',
          avatarFrame: frame,
          avatarAnim: '',
          bannerAnim: '',
          supportCreds: '',
        ),
      };
}

class _SeededAvatars extends AvatarNotifier {
  final Map<String, Uint8List> seed;
  _SeededAvatars(this.seed);

  @override
  Map<String, Uint8List> build() => seed;
}

class _SeededFrames extends AvatarFrameNotifier {
  final Map<String, Uint8List> art;
  _SeededFrames(this.art);

  @override
  Map<String, Uint8List> build() => art;
}

Future<void> _pump(
  WidgetTester tester, {
  String frame = '',
  double size = 40,
  Map<String, Uint8List> art = const {},
  Widget Function(Widget avatar)? wrap,
}) async {
  final avatar = HollowAvatar(peerId: _peer, size: size);
  await tester.pumpWidget(
    ProviderScope(
      // A fresh key per pump, or Riverpod keeps the notifier from the
      // previous pump and every "now with a frame" pump silently measures
      // the frameless tree again.
      key: UniqueKey(),
      overrides: hollowTestOverrides(extra: [
        profileProvider.overrideWith(() => _SeededProfiles(frame)),
        avatarFrameProvider.overrideWith(() => _SeededFrames(art)),
      ]),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Center(child: wrap == null ? avatar : wrap(avatar)),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  tearDown(() => AvatarFrameCache.instance.clearForTest());

  testWidgets('a frame costs the layout NOTHING', (tester) async {
    // The whole design rests on this. Measure the same avatar twice.
    await _pump(tester, frame: '');
    final bare = tester.getRect(find.byType(HollowAvatar));

    await _pump(tester, frame: 'b:200');
    final framed = tester.getRect(find.byType(HollowAvatar));

    expect(find.byType(AvatarFrame), findsOneWidget,
        reason: 'the frame must actually be rendering');
    expect(framed, bare,
        reason: 'a framed avatar occupies exactly the same rect as a bare one');
  });

  testWidgets('a frame in a row cannot shift its neighbours', (tester) async {
    Widget row(Widget avatar) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [avatar, const Text('after')],
        );

    await _pump(tester, frame: '', wrap: row);
    final bare = tester.getRect(find.text('after'));

    await _pump(tester, frame: 'b:200', wrap: row);
    expect(tester.getRect(find.text('after')), bare,
        reason: 'nothing beside a framed avatar may move');
  });

  testWidgets('the art box is size * kFrameScale, centred on the avatar',
      (tester) async {
    await _pump(tester, frame: 'b:200', size: 48);
    final avatar = tester.getRect(find.byType(HollowAvatar));
    final art = tester.getRect(find.byType(CustomPaint).last);

    expect(art.width, closeTo(48 * kFrameScale, 0.01));
    expect(art.height, closeTo(48 * kFrameScale, 0.01));
    expect(art.center.dx, closeTo(avatar.center.dx, 0.01));
    expect(art.center.dy, closeTo(avatar.center.dy, 0.01));
    // Tall art is scaled DOWN into that box, never allowed to grow it: the
    // ceiling is the box, and BoxFit.contain is what enforces it.
    expect(art.width, lessThan(48 * 1.5));
  });

  testWidgets('below the 24px floor no frame is drawn at all', (tester) async {
    await _pump(tester, frame: 'b:200', size: kFrameMinAvatarSize - 1);
    expect(find.byType(AvatarFrame), findsNothing,
        reason: 'at 18-20px a frame is mush, so it is skipped entirely');

    await _pump(tester, frame: 'b:200', size: kFrameMinAvatarSize);
    expect(find.byType(AvatarFrame), findsOneWidget);
  });

  testWidgets('an unrenderable ID draws nothing', (tester) async {
    // Anything Rust would have refused on ingest still has to be inert here,
    // because an old row could hold one.
    for (final id in ['b:999', 'b:', 'nonsense', 'abc']) {
      await _pump(tester, frame: id);
      expect(find.byType(AvatarFrame), findsNothing, reason: 'id: $id');
    }
  });

  testWidgets('frameId overrides the stored frame, and empty draws none',
      (tester) async {
    // The settings preview shows a PENDING pick, not what is saved.
    await tester.pumpWidget(
      ProviderScope(
        overrides: hollowTestOverrides(extra: [
          profileProvider.overrideWith(() => _SeededProfiles('b:200')),
        ]),
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: const Scaffold(
            body: Center(
              child: HollowAvatar(peerId: _peer, size: 40, frameId: ''),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(AvatarFrame), findsNothing);
  });

  testWidgets('a badge Stack does not clip the frame', (tester) async {
    // The shape every avatar-with-a-status-dot has. `Stack` defaults to
    // Clip.hardEdge and sizes to its one non-positioned child, so without
    // Clip.none it clips the frame to four specks at the corners - which
    // reads as "the frame is painted behind the avatar", not as clipping.
    // Shipped exactly that way in the member panel first time.
    await _pump(
      tester,
      frame: 'b:200',
      size: 40,
      wrap: (avatar) => Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          const Positioned(
            right: -1,
            bottom: -1,
            child: SizedBox(width: 8, height: 8),
          ),
        ],
      ),
    );
    final art = tester.renderObject(find.byType(CustomPaint).last);
    final avatar = tester.getRect(find.byType(HollowAvatar));
    // The frame's paint bounds have to still be the full 1.33 box: if an
    // ancestor clipped, the recorded paint would be cut to the avatar.
    expect((art as dynamic).paintBounds.width, closeTo(40 * kFrameScale, 0.01));
    expect(tester.getRect(find.byType(CustomPaint).last).left,
        closeTo(avatar.left - frameOverhang(40), 0.01));
  });

  testWidgets('the art never eats a click meant for a neighbour',
      (tester) async {
    // The overlay overhangs the avatar by ~16% each side, straight over
    // whatever sits next to it in a row.
    int taps = 0;
    await _pump(
      tester,
      frame: 'b:200',
      size: 40,
      wrap: (avatar) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          avatar,
          GestureDetector(
            onTap: () => taps++,
            child: const SizedBox(width: 40, height: 40, child: Text('hit')),
          ),
        ],
      ),
    );
    // Tap the neighbour's LEFT edge, which the frame's box overlaps.
    final neighbour = tester.getRect(find.text('hit'));
    await tester.tapAt(Offset(neighbour.left + 2, neighbour.center.dy));
    await tester.pump();
    expect(taps, 1, reason: 'the frame overlay must be pointer-transparent');
  });

  testWidgets('rows sharing a frame decode its art ONCE', (tester) async {
    // The trap this design exists to avoid: one decoder per widget turns
    // sixty member rows into hundreds of megabytes of decoration.
    // runAsync, because a real image decode needs the real event loop.
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: hollowTestOverrides(extra: [
            profileProvider.overrideWith(() => _SeededProfiles(_hash)),
            avatarFrameProvider
                .overrideWith(() => _SeededFrames({_hash: _kTinyPng})),
          ]),
          child: MaterialApp(
            theme: HollowThemeData.dark(),
            home: Scaffold(
              body: Column(
                children: [
                  for (int i = 0; i < 12; i++)
                    const HollowAvatar(peerId: _peer, size: 40),
                ],
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(find.byType(AvatarFrame), findsNWidgets(12));
    expect(AvatarFrameCache.instance.stillCount, 1,
        reason: 'twelve rows, one decoded image');
    // Nothing is animating, so no full frame set is held either.
    expect(AvatarFrameCache.instance.heldArtCount, 0);
  });

  group('hover is the ROW, not the artwork', () {
    // Aiming at 32px of art to make it move is a pixel-hunting game. The row
    // already lights up on hover; the motion has to agree with it.
    Future<void> pumpRow(WidgetTester tester, {required String frame}) async {
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: hollowTestOverrides(extra: [
            profileProvider.overrideWith(() => _SeededProfiles(frame)),
            avatarFrameProvider
                .overrideWith(() => _SeededFrames({_hash: _kTinyPng})),
          ]),
          child: MaterialApp(
            theme: HollowThemeData.dark(),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 300,
                  child: HollowPressable(
                    onTap: () {},
                    child: const Row(
                      children: [
                        HollowAvatar(peerId: _peer, size: 40),
                        SizedBox(width: 12),
                        Expanded(child: Text('far end of the row')),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('a framed avatar in a row owns no MouseRegion of its own',
        (tester) async {
      await pumpRow(tester, frame: _hash);
      final frame = find.byType(AvatarFrame);
      expect(frame, findsOneWidget);
      expect(
        find.descendant(of: frame, matching: find.byType(MouseRegion)),
        findsNothing,
        reason: 'inside a row the ROW supplies hover; a second MouseRegion '
            'would only re-create the pixel-hunting target',
      );
    });

    testWidgets('hovering the far end of the row still plays the frame',
        (tester) async {
      await pumpRow(tester, frame: _hash);
      final state = tester.state<ConsumerState<AvatarFrame>>(
          find.byType(AvatarFrame)) as dynamic;
      expect(state.hoveringForTest, isFalse);

      // Point at the TEXT, nowhere near the avatar.
      final gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.text('far end of the row')));
      await tester.pump();

      expect(state.hoveringForTest, isTrue,
          reason: 'the whole row is the hover target');

      await gesture.moveTo(const Offset(5, 5));
      await tester.pump();
      expect(state.hoveringForTest, isFalse);
    });

    testWidgets('an animated AVATAR plays on row hover, and only then',
        (tester) async {
      // The decode is the reason this is gated: AnimatedGifImage decodes
      // EVERY frame up front, so it may exist only while a row is hovered -
      // which the pointer bounds to one at a time.
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: hollowTestOverrides(extra: [
            profileProvider.overrideWith(() => _SeededProfiles('')),
            avatarProvider.overrideWith(() => _SeededAvatars({_peer: _kTinyGif})),
          ]),
          child: MaterialApp(
            theme: HollowThemeData.dark(),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 300,
                  child: HollowPressable(
                    onTap: () {},
                    child: const Row(
                      children: [
                        HollowAvatar(peerId: _peer, size: 40),
                        SizedBox(width: 12),
                        Expanded(child: Text('far end of the row')),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(AnimatedGifImage), findsNothing,
          reason: 'a list row must not decode every frame at rest');

      final gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.text('far end of the row')));
      await tester.pump();
      expect(find.byType(AnimatedGifImage), findsOneWidget,
          reason: 'hovering anywhere on the row starts it');

      await gesture.moveTo(const Offset(5, 5));
      await tester.pump();
      expect(find.byType(AnimatedGifImage), findsNothing,
          reason: 'and leaving frees the frames again');
    });

    testWidgets('a STILL avatar never mounts the animated decoder',
        (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: hollowTestOverrides(extra: [
            profileProvider.overrideWith(() => _SeededProfiles('')),
            avatarProvider.overrideWith(() => _SeededAvatars({_peer: _kTinyPng})),
          ]),
          child: MaterialApp(
            theme: HollowThemeData.dark(),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 300,
                  child: HollowPressable(
                    onTap: () {},
                    child: const Row(
                      children: [
                        HollowAvatar(peerId: _peer, size: 40),
                        SizedBox(width: 12),
                        Expanded(child: Text('far end of the row')),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.text('far end of the row')));
      await tester.pump();
      expect(find.byType(AnimatedGifImage), findsNothing,
          reason: 'nothing to animate, so nothing to decode');
    });

    testWidgets('a standalone framed avatar still hovers itself',
        (tester) async {
      // A picker tile or a preview IS the whole target, so it keeps its own
      // MouseRegion.
      await _pump(tester, frame: _hash, art: {_hash: _kTinyPng});
      expect(
        find.descendant(
            of: find.byType(AvatarFrame), matching: find.byType(MouseRegion)),
        findsOneWidget,
      );
    });
  });

  group('frame IDs', () {
    test('built-in hues parse in canonical form only', () {
      expect(builtinFrameHue('b:0'), 0);
      expect(builtinFrameHue('b:359'), 359);
      expect(builtinFrameHue('b:168'), 168);
      // Non-canonical or out of range: the ID must round-trip 1:1 with the
      // Rust validator, or one frame ends up with two IDs.
      expect(builtinFrameHue('b:012'), isNull);
      expect(builtinFrameHue('b:360'), isNull);
      expect(builtinFrameHue('b:'), isNull);
      expect(builtinFrameHue('b:teal'), isNull);
      expect(builtinFrameHue('a' * 64), isNull);
    });

    test('hashes are 64 lowercase hex and nothing else', () {
      expect(isFrameHash('a' * 64), isTrue);
      expect(isFrameHash('A' * 64), isFalse);
      expect(isFrameHash('a' * 63), isFalse);
      expect(isFrameHash('g' * 64), isFalse);
      expect(isRenderableFrame(''), isFalse);
      expect(isRenderableFrame('b:168'), isTrue);
      expect(isRenderableFrame('a' * 64), isTrue);
    });
  });
}
