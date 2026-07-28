import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/guest_provider.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';

/// Issue #28: the centre tabs (Browse / Share / Archive / Conferences) are
/// mutually exclusive, but each one is its own boolean, so every navigation
/// site had to clear all of them by hand. Conferences shipped last and half the
/// sites never learned about it — with it open, clicking a server icon left the
/// conference dashboard covering the channel it had just selected.
void main() {
  ProviderContainer container() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  test('opening a tab closes every other one', () {
    final c = container();
    for (final tab in ShellTab.values) {
      setShellTab(c.read, tab);
      expect(c.read(anyShellTabOpenProvider), isTrue);
      final open = {
        ShellTab.guest: c.read(guestTabOpenProvider),
        ShellTab.share: c.read(shareTabOpenProvider),
        ShellTab.archive: c.read(archiveTabOpenProvider),
        ShellTab.conference: c.read(conferenceTabOpenProvider),
      };
      expect(open[tab], isTrue, reason: '$tab did not open');
      expect(
        open.entries.where((e) => e.value).map((e) => e.key),
        [tab],
        reason: '$tab left a sibling tab open',
      );
    }
  });

  test('null closes all of them, uncovering the chat area', () {
    final c = container();
    setShellTab(c.read, ShellTab.conference);
    setShellTab(c.read, null);
    expect(c.read(guestTabOpenProvider), isFalse);
    expect(c.read(shareTabOpenProvider), isFalse);
    expect(c.read(archiveTabOpenProvider), isFalse);
    expect(c.read(conferenceTabOpenProvider), isFalse);
    expect(c.read(anyShellTabOpenProvider), isFalse);
  });

  /// The bug was never in the providers — it was a call site that wrote three
  /// of the four booleans. This is the guard that keeps that from coming back:
  /// `shell_tab.dart` is the only file allowed to write them.
  test('nothing outside shell_tab.dart writes a centre-tab flag directly', () {
    final lib = Directory('lib');
    expect(lib.existsSync(), isTrue,
        reason: 'expected to run from the project root (lib missing)');

    const flags = [
      'guestTabOpenProvider',
      'shareTabOpenProvider',
      'archiveTabOpenProvider',
      'conferenceTabOpenProvider',
    ];
    final offenders = <String>[];

    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('shell_tab.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        for (final flag in flags) {
          if (lines[i].contains('$flag.notifier')) {
            offenders.add('${entity.path}:${i + 1}  →  $flag');
          }
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '\nCentre tabs must be switched through '
          '`setShellTab(ref.read, ShellTab.x)` (or `null` to close them all) '
          'so a new tab can never be forgotten by one call site:\n'
          '  ${offenders.join('\n  ')}\n',
    );
  });
}
