import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';

/// Counts how often the dialog body is built from scratch.
class _Probe extends StatefulWidget {
  const _Probe();
  static int mounts = 0;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    _Probe.mounts++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox(height: 40);
}

/// A dialog runs its action while busy and comes back with an error on one field:
/// the body it comes back to is the same one, still scrolled where the person was,
/// or the error lands out of sight and the first field steals the focus.
void main() {
  testWidgets('going busy and back keeps the dialog body mounted', (tester) async {
    _Probe.mounts = 0;
    var busy = false;
    late StateSetter setBusy;
    await tester.pumpWidget(MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(
        body: StatefulBuilder(builder: (context, setState) {
          setBusy = setState;
          return HollowDialog(title: 'Set a code', busy: busy, content: const _Probe());
        }),
      ),
    ));
    expect(_Probe.mounts, 1);

    setBusy(() => busy = true);
    await tester.pump();
    setBusy(() => busy = false);
    await tester.pump();

    expect(_Probe.mounts, 1);
  });
}
