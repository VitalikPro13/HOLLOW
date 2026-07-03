// Guards the vendored scrollable_positioned_list patch (findChildIndexCallback):
// in a reverse:true chat list, appending a new message shifts every builder
// index by one — row elements must be MOVED to their new slots, not torn down
// and re-inflated. Without the patch every visible row remounts on every new
// message, which showed up as the whole chat (avatars, names, bubbles)
// blinking on each arrival.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

int _probeMounts = 0;

class _Probe extends StatefulWidget {
  const _Probe({super.key, required this.id});
  final String id;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    _probeMounts++;
  }

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: 40, child: Text(widget.id));
}

void main() {
  testWidgets(
      'reverse chat list moves row elements on append instead of remounting',
      (tester) async {
    _probeMounts = 0;
    var items = List.generate(30, (i) => 'm$i'); // chronological, m29 newest
    late StateSetter rebuild;

    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(
        builder: (context, setState) {
          rebuild = setState;
          final indexById = {
            for (var i = 0; i < items.length; i++) items[i]: i,
          };
          return ScrollablePositionedList.builder(
            reverse: true,
            initialScrollIndex: 0,
            initialAlignment: 0.0,
            itemCount: items.length,
            findChildIndexCallback: (key) {
              if (key is! ValueKey<Object>) return null;
              final id = key.value;
              if (id is! String) return null;
              final i = indexById[id];
              if (i == null) return null;
              return items.length - 1 - i;
            },
            itemBuilder: (context, revIndex) {
              final id = items[items.length - 1 - revIndex];
              return KeyedSubtree(
                key: ValueKey<Object>(id),
                child: _Probe(id: id),
              );
            },
          );
        },
      ),
    ));

    final mountsAfterFirstBuild = _probeMounts;
    expect(mountsAfterFirstBuild, greaterThan(5)); // sanity: rows visible

    // A new message arrives: appended chronologically = revIndex 0.
    rebuild(() => items = [...items, 'new-message']);
    await tester.pump();

    // Existing rows must keep their State. Allowed new mounts: the new
    // message itself, plus the previously-newest row (it crosses the
    // package's center-sliver boundary, where elements cannot migrate).
    final newMounts = _probeMounts - mountsAfterFirstBuild;
    expect(newMounts, lessThanOrEqualTo(2),
        reason: 'existing rows remounted on append — the '
            'findChildIndexCallback element-reuse patch has regressed');
    expect(find.text('new-message'), findsOneWidget);
  });
}
