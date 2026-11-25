import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

/// A swipeable row the way `flutter_slidable` builds one: a plain
/// GestureDetector with only horizontal drag callbacks around the row, and
/// the row itself an app-declared semantic button.
class _SlidableLikeRow extends StatefulWidget {
  const _SlidableLikeRow({
    super.key,
    required this.label,
    required this.onTap,
    this.swipeEnabled = true,
  });

  final String label;
  final bool swipeEnabled;
  final VoidCallback onTap;

  @override
  State<_SlidableLikeRow> createState() => _SlidableLikeRowState();
}

class _SlidableLikeRowState extends State<_SlidableLikeRow> {
  double _offset = 0;
  bool open = false;

  @override
  Widget build(BuildContext context) {
    // Like Slidable, a row that cannot slide keeps its detector but nulls
    // every callback.
    final swipe = widget.swipeEnabled;
    return GestureDetector(
      onHorizontalDragStart: swipe ? (_) {} : null,
      onHorizontalDragUpdate: swipe
          ? (details) => setState(() => _offset += details.primaryDelta!)
          : null,
      onHorizontalDragEnd: swipe
          ? (_) => setState(() {
              open = _offset < -40;
              _offset = 0;
            })
          : null,
      behavior: HitTestBehavior.opaque,
      // Open shows its action pane beside the row, as Slidable does, so the
      // swipe has a visible result.
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            label: widget.label,
            onTap: widget.onTap,
            child: _PressableCard(onTap: widget.onTap, label: widget.label),
          ),
          if (open) const Text('Delete'),
        ],
      ),
    );
  }
}

/// A custom pressable built on raw pointer events (no framework detector),
/// like an app's press-effect container.
class _PressableCard extends StatelessWidget {
  const _PressableCard({required this.onTap, required this.label});

  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    var downAt = Offset.zero;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) => downAt = event.position,
      onPointerUp: (event) {
        if ((event.position - downAt).distance < 8) onTap();
      },
      child: SizedBox(
        width: 360,
        height: 64,
        child: Center(child: Text(label)),
      ),
    );
  }
}

void main() {
  testWidgets(
    'a drag-only detector does not hide the semantic button inside it',
    (tester) async {
      FlutterScoutHelper.ensureRegistered();
      var taps = 0;
      final rowKey = GlobalKey<_SlidableLikeRowState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: _SlidableLikeRow(
                key: rowKey,
                label: 'Deep Tissue',
                onTap: () => taps++,
              ),
            ),
          ),
        ),
      );
      final runtime = FlutterScoutHelper.debugRuntime;
      final rows = runtime
          .debugSnapshot()
          .interactables
          .where((node) => node.label == 'Deep Tissue')
          .toList();
      expect(rows, hasLength(1), reason: '$rows');
      final row = rows.single;
      expect(row.kind, 'btn');
      expect(row.enabled, isTrue);

      final tap = await tester.runAsync(() => runtime.debugTapTarget(row.id));
      await tester.pump();
      expect(tap?['ok'], isTrue, reason: '$tap');
      expect(taps, 1);

      // Frames keep coming while the swipe runs, as on a device, so its
      // after snapshot sees the opened row.
      Map<String, Object?>? swipe;
      runtime
          .debugSwipe({
            'target': row.id,
            'direction': 'left',
            'distance': '200',
            // The production settle; the debug entry defaults to none.
            'waitMs': '1500',
          })
          .then((value) => swipe = value);
      for (var i = 0; i < 600 && swipe == null; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      expect(swipe?['ok'], isTrue, reason: '$swipe');
      expect(rowKey.currentState!.open, isTrue);
      expect(taps, 1);
    },
  );

  testWidgets('a row that cannot slide still surfaces its enabled button', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: _SlidableLikeRow(
              label: 'Hot Stone',
              swipeEnabled: false,
              onTap: () => taps++,
            ),
          ),
        ),
      ),
    );
    final runtime = FlutterScoutHelper.debugRuntime;
    final rows = runtime
        .debugSnapshot()
        .interactables
        .where((node) => node.label == 'Hot Stone')
        .toList();
    expect(rows, hasLength(1), reason: '$rows');
    expect(rows.single.kind, 'btn');
    expect(rows.single.enabled, isTrue);

    final tap = await tester.runAsync(
      () => runtime.debugTapTarget(rows.single.id),
    );
    await tester.pump();
    expect(tap?['ok'], isTrue, reason: '$tap');
    expect(taps, 1);
  });

  testWidgets('a Dismissible row keeps its tappable tile', (tester) async {
    FlutterScoutHelper.ensureRegistered();
    var taps = 0;
    var dismissed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              if (!dismissed)
                StatefulBuilder(
                  builder: (context, setState) => Dismissible(
                    key: const ValueKey('row'),
                    onDismissed: (_) => setState(() => dismissed = true),
                    child: Semantics(
                      button: true,
                      label: 'Latte',
                      onTap: () => taps++,
                      child: _PressableCard(
                        onTap: () => taps++,
                        label: 'Latte',
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    final runtime = FlutterScoutHelper.debugRuntime;
    final row = runtime.debugSnapshot().interactables.singleWhere(
      (node) => node.label == 'Latte',
    );
    expect(row.kind, 'btn');
    expect(row.enabled, isTrue);

    final tap = await tester.runAsync(() => runtime.debugTapTarget(row.id));
    await tester.pump();
    expect(tap?['ok'], isTrue, reason: '$tap');
    expect(taps, 1);
  });

  testWidgets('a detector with press callbacks still owns its semantics', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: GestureDetector(
              onTap: () {},
              onHorizontalDragStart: (_) {},
              child: Semantics(
                button: true,
                label: 'Mocha',
                child: const SizedBox(
                  width: 200,
                  height: 60,
                  child: Center(child: Text('Mocha')),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final nodes = FlutterScoutHelper.debugRuntime
        .debugSnapshot()
        .interactables
        .where((node) => node.label == 'Mocha')
        .toList();
    expect(nodes, hasLength(1), reason: '$nodes');
    expect(nodes.single.kind, 'tap');
  });
}
