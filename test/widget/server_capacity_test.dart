import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/pending_join_info.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_settings_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/dialogs/invite_dialog.dart';

// The member cap (g13): a server takes nobody new once its identities reach the
// limit in force, and the invite says so before anyone shares a link that
// cannot work.

const _fullNote = 'This server is full. New people can join once someone leaves.';

late BuildContext _ctx;

Future<void> _openInvite(WidgetTester tester, crdt_api.ServerCapacityFfi? capacity) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [serverCapacityProvider.overrideWith((ref, _) => capacity)],
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(body: Builder(builder: (context) {
        _ctx = context;
        return const SizedBox.expand();
      })),
    ),
  ));
  showInviteDialog(_ctx, 'https://hollow.chat/join#server=srv1', 'srv1');
  await tester.pumpAndSettle();
}

void main() {
  test('full means the members reached the limit in force', () {
    expect(serverIsFull(null), isFalse, reason: 'unknown is never full');
    expect(serverIsFull(const crdt_api.ServerCapacityFfi(members: 511, limit: 512, hardCap: 512)), isFalse);
    expect(serverIsFull(const crdt_api.ServerCapacityFfi(members: 512, limit: 512, hardCap: 512)), isTrue);
    expect(serverIsFull(const crdt_api.ServerCapacityFfi(members: 20, limit: 20, hardCap: 512)), isTrue,
        reason: "the owner's lower limit counts");
  });

  test('the Access page refuses a member limit above the hard cap', () {
    expect(memberLimitAboveCap(513, 512), "The limit can't be more than 512.");
    expect(memberLimitAboveCap(512, 512), isNull);
    expect(memberLimitAboveCap(5000, null), isNull, reason: 'without Rust the node still refuses');
  });

  test('a full reason keeps a server name that holds colons', () {
    final r = serverFullReason('server_full:Night: Owls:512');
    expect(r.name, 'Night: Owls');
    expect(r.max, 512);
    expect(serverFullReason('server_full:Plain:1').max, 1);
    expect(serverFullReason('server_full:No limit given').name, 'No limit given');
    expect(pendingJoinReasonText('server_full:Night: Owls:512'), 'Night: Owls is full');
  });

  testWidgets('the invite of a full server says it is full', (tester) async {
    await _openInvite(tester, const crdt_api.ServerCapacityFfi(members: 512, limit: 512, hardCap: 512));
    expect(find.text(_fullNote), findsOneWidget);
  });

  testWidgets('the invite of a server with room says nothing about it', (tester) async {
    await _openInvite(tester, const crdt_api.ServerCapacityFfi(members: 3, limit: 512, hardCap: 512));
    expect(find.text(_fullNote), findsNothing);
    await _openInvite(tester, null);
    expect(find.text(_fullNote), findsNothing);
  });
}
