import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Avatar-frame clipping CI guard (issue #54).
///
/// An avatar frame is a NON-PARTICIPATING overlay that deliberately overhangs
/// its avatar by ~16% on every side. That means any ancestor which clips to
/// the avatar's own bounds silently eats it — and the commonest such ancestor
/// is the badge `Stack` that hangs a status dot off an avatar's corner,
/// because `Stack` defaults to `Clip.hardEdge`.
///
/// It is a nasty failure to spot by eye: the ring's straight edges are outside
/// the avatar's square and get clipped, while its ROUNDED CORNERS curve back
/// inside and survive. The result is four red specks at the corners, which
/// reads as "the frame is painted behind the avatar" rather than as clipping.
/// That is exactly how it shipped in the member panel first time, while the
/// friends bar and the home dashboard looked perfect — those two happened to
/// already pass `Clip.none`.
///
/// So: a `Stack` whose first child is a `HollowAvatar` must pass
/// `clipBehavior: Clip.none`, unless that avatar opts out of frames entirely
/// with `frameId: ''` (the call surfaces, which suppress frames under their
/// speaking ring). Those Stacks want `Clip.none` anyway — every one of them
/// exists to position a badge at a NEGATIVE offset.
///
/// The behaviour this protects is asserted in
/// `test/widget/avatar_frame_test.dart` ("a badge Stack does not clip the
/// frame"); this scan just stops a new call site from reintroducing it.
void main() {
  test('a Stack wrapping a framed avatar never clips it', () {
    // Stack( [args] children: [ HollowAvatar( ... ) — args captured so the
    // clipBehavior can be checked, avatar args so frameId: '' can opt out.
    final pattern = RegExp(
      r'Stack\(\s*(?<args>(?:\w+:[^\[]*?)?)children:\s*\[\s*(?:const\s+)?'
      r'HollowAvatar\((?<avatar>[^)]*)\)',
      dotAll: true,
    );

    final failures = <String>[];
    final lib = Directory('lib');
    expect(lib.existsSync(), isTrue, reason: 'run from the repo root');

    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final src = entity.readAsStringSync();
      for (final m in pattern.allMatches(src)) {
        final args = m.namedGroup('args') ?? '';
        final avatar = m.namedGroup('avatar') ?? '';
        if (args.contains('Clip.none')) continue;
        // Opted out of frames: nothing to clip.
        if (avatar.contains("frameId: ''")) continue;
        final line = '\n'.allMatches(src.substring(0, m.start)).length + 1;
        failures.add(
          '${entity.path}:$line — Stack wrapping a HollowAvatar with no '
          "clipBehavior: Clip.none. The avatar's frame overhangs its box and "
          'will be clipped to four specks at the corners.',
        );
      }
    }

    if (failures.isNotEmpty) {
      fail('\nAvatar frames would be clipped:\n\n  ${failures.join('\n\n  ')}'
          '\n\nAdd `clipBehavior: Clip.none` to the Stack (which its badge '
          "wants anyway), or pass `frameId: ''` if that surface deliberately "
          'shows no frame.');
    }
  });
}
