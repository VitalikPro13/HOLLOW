import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/shell/home_inbox.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// Sets a nickname without the settings write, which needs the FFI.
class _Nicknames extends LocalNicknameNotifier {
  void put(String peerId, String nickname) {
    state = {...state, peerId: nickname};
    setLocalNicknamesRef(state);
  }
}

void main() {
  tearDown(() => setLocalNicknamesRef(const {}));

  testWidgets('a nickname set in the Friends Manager renames the Home row',
      (tester) async {
    final container = ProviderContainer(
      overrides: hollowTestOverrides(extra: [
        localNicknameProvider.overrideWith(_Nicknames.new),
      ]),
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Column(children: [
              for (final c in homeDmConversations(ref)) Text(c.title),
            ]),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('Bee'), findsNothing);

    (container.read(localNicknameProvider.notifier) as _Nicknames)
        .put(kFriendPeerId1, 'Bee');
    await tester.pump();

    expect(find.text('Bee'), findsOneWidget,
        reason: 'the row rebuilds on the nickname, not on the next event');
  });
}
