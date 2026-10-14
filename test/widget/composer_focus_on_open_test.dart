import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/composer_focus_provider.dart';
import 'package:hollow/src/core/providers/composer_insert_provider.dart';
import 'package:hollow/src/core/providers/dm_navigation.dart';

import '../helpers/test_app.dart';

/// Issue #105: on a desktop, opening a conversation by hand puts the cursor in
/// its composer, so one click on a friend is enough to start typing. Phones
/// never take it (the keyboard would cover the conversation), and a
/// conversation that opens by itself never steals focus.
class _Composer extends ConsumerStatefulWidget {
  final String scope;
  const _Composer(this.scope);
  @override
  ConsumerState<_Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<_Composer>
    with ComposerFocusOnOpen<_Composer> {
  final node = FocusNode();

  @override
  String get composerScope => widget.scope;

  @override
  FocusNode get composerFocusNode => node;

  @override
  void dispose() {
    node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    watchComposerFocus();
    return TextField(focusNode: node);
  }
}

final _dmA = ComposerInsert.dmScope('peer-a');
final _dmB = ComposerInsert.dmScope('peer-b');

/// The test binding defaults to a phone platform; these cases run as a desktop.
void desktopWidgets(String description, WidgetTesterCallback body) =>
    testWidgets(description, body,
        variant: TargetPlatformVariant.only(TargetPlatform.windows));

void main() {
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester, Widget? child) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(body: child ?? const SizedBox()),
      ),
    ));
    await tester.pump();
  }

  bool focused(WidgetTester tester) =>
      tester.state<_ComposerState>(find.byType(_Composer)).node.hasFocus;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  desktopWidgets('a request made before the conversation mounts focuses it',
      (tester) async {
    await pump(tester, null);
    requestComposerFocus(container.read, _dmA);
    await pump(tester, _Composer(_dmA));
    await tester.pump();
    expect(focused(tester), isTrue);
    expect(container.read(composerFocusProvider), isNull,
        reason: 'the request fires once');
  });

  desktopWidgets('clicking the conversation already open focuses it',
      (tester) async {
    await pump(tester, _Composer(_dmA));
    expect(focused(tester), isFalse);
    requestComposerFocus(container.read, _dmA);
    await tester.pump();
    await tester.pump();
    expect(focused(tester), isTrue);
  });

  desktopWidgets('another conversation\'s request is not ours', (tester) async {
    requestComposerFocus(container.read, _dmB);
    await pump(tester, _Composer(_dmA));
    await tester.pump();
    expect(focused(tester), isFalse);
  });

  desktopWidgets('a conversation that opens on its own does not take focus',
      (tester) async {
    // A request nobody took, from long before this pane appeared (sync,
    // startup restore).
    container.read(composerFocusProvider.notifier).request(_dmA,
        at: DateTime.now().subtract(ComposerFocusRequest.freshFor * 2));
    await pump(tester, _Composer(_dmA));
    await tester.pump();
    expect(focused(tester), isFalse);
  });

  for (final phone in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('a ${phone.name} phone never takes focus', (tester) async {
      debugDefaultTargetPlatformOverride = phone;
      try {
        requestComposerFocus(container.read, _dmA);
        expect(container.read(composerFocusProvider), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  desktopWidgets('opening a DM by hand asks for its composer', (tester) async {
    late WidgetRef ref;
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(),
      child: MaterialApp(
        home: Consumer(builder: (context, r, _) {
          ref = r;
          return const SizedBox();
        }),
      ),
    ));
    openDmConversation(ref, 'peer-a');
    final request =
        ProviderScope.containerOf(tester.element(find.byType(SizedBox).first))
            .read(composerFocusProvider);
    expect(request?.scope, _dmA);
  });
}
