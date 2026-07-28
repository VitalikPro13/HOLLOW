/// Animated server icons (asset-rail follow-up): [ServerIconImage] renders
/// the still icon when no animated variant exists, prefers the animated
/// blob when one does, and gates playback on hover/selected + window focus
/// (reduce-motion is internal to AnimatedGifImage).
library;

import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/member_panel_provider.dart'
    show windowFocusedProvider;
import 'package:hollow/src/core/providers/server_avatar_anim_provider.dart';
import 'package:hollow/src/core/providers/server_avatar_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/server_icon_image.dart';

import '../helpers/test_app.dart';

// 1x1 transparent PNG — the render path doesn't care that real icons are WebP.
final Uint8List _kTinyPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

final String _hash = 'a' * 64;

class _SeededAnimNotifier extends ServerAvatarAnimNotifier {
  final Map<String, ServerAvatarAnimEntry> seed;
  _SeededAnimNotifier(this.seed);

  @override
  Map<String, ServerAvatarAnimEntry> build() => seed;
}

class _SeededAvatarNotifier extends ServerAvatarNotifier {
  final Map<String, Uint8List> seed;
  _SeededAvatarNotifier(this.seed);

  @override
  Map<String, Uint8List> build() => seed;
}

Future<void> _pump(
  WidgetTester tester, {
  Map<String, ServerAvatarAnimEntry> anims = const {},
  Map<String, Uint8List> stills = const {},
  bool isSelected = false,
  bool windowFocused = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: hollowTestOverrides(extra: [
        serverAvatarAnimProvider.overrideWith(() => _SeededAnimNotifier(anims)),
        serverAvatarProvider.overrideWith(() => _SeededAvatarNotifier(stills)),
        windowFocusedProvider.overrideWith((ref) => windowFocused),
      ]),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Center(
            child: ServerIconImage(
              serverId: 'srv-1',
              size: 44,
              isSelected: isSelected,
              fallback: const Text('AB'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  testWidgets('no icon loaded renders the fallback', (tester) async {
    await _pump(tester);
    expect(find.text('AB'), findsOneWidget);
    expect(find.byType(AnimatedGifImage), findsNothing);
  });

  testWidgets('still-only server renders the still, no gif widget',
      (tester) async {
    await _pump(tester, stills: {'srv-1': _kTinyPng});
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(AnimatedGifImage), findsNothing);
  });

  testWidgets('animated variant wins over the still and idles at frame 0',
      (tester) async {
    await _pump(
      tester,
      anims: {'srv-1': ServerAvatarAnimEntry(bytes: _kTinyPng, hash: _hash)},
      stills: {'srv-1': _kTinyPng},
    );
    final gif = tester
        .widget<AnimatedGifImage>(find.byType(AnimatedGifImage));
    // Not hovered, not selected: playback stays gated.
    expect(gif.animate, isFalse);
  });

  testWidgets('selected server animates while the window is focused',
      (tester) async {
    await _pump(
      tester,
      anims: {'srv-1': ServerAvatarAnimEntry(bytes: _kTinyPng, hash: _hash)},
      isSelected: true,
    );
    final gif = tester
        .widget<AnimatedGifImage>(find.byType(AnimatedGifImage));
    expect(gif.animate, isTrue);
  });

  testWidgets('selected server pauses when the window loses focus',
      (tester) async {
    await _pump(
      tester,
      anims: {'srv-1': ServerAvatarAnimEntry(bytes: _kTinyPng, hash: _hash)},
      isSelected: true,
      windowFocused: false,
    );
    final gif = tester
        .widget<AnimatedGifImage>(find.byType(AnimatedGifImage));
    expect(gif.animate, isFalse);
  });

  testWidgets('hover un-gates animation on an unselected server',
      (tester) async {
    await _pump(
      tester,
      anims: {'srv-1': ServerAvatarAnimEntry(bytes: _kTinyPng, hash: _hash)},
    );
    final gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(
        tester.getCenter(find.byType(ServerIconImage)));
    await tester.pump();
    final gif = tester
        .widget<AnimatedGifImage>(find.byType(AnimatedGifImage));
    expect(gif.animate, isTrue);

    await gesture.moveTo(Offset.zero);
    await tester.pump();
    expect(
      tester.widget<AnimatedGifImage>(find.byType(AnimatedGifImage)).animate,
      isFalse,
    );
  });
}
