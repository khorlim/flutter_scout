import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_test/flutter_test.dart';

/// A payment row the way TunaiPro's SOA sheet builds one: a Slidable whose
/// end pane holds a Delete action, in a scroll body under a floating
/// "Add Payment" button. [rowTop] places the row; [withIcon] adds a small
/// icon button inside the row.
Widget _sheet({
  required double rowTop,
  required ValueChanged<SlidableController> onController,
  bool withIcon = false,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 120),
            child: Column(
              children: [
                SizedBox(height: rowTop),
                Slidable(
                  key: const ValueKey('payment-1'),
                  endActionPane: ActionPane(
                    extentRatio: 0.15,
                    motion: const ScrollMotion(),
                    children: [
                      SlidableAction(
                        onPressed: (_) {},
                        icon: Icons.delete,
                        label: 'Delete',
                      ),
                    ],
                  ),
                  child: Builder(
                    builder: (context) {
                      onController(Slidable.of(context)!);
                      return SizedBox(
                        height: 56,
                        child: Row(
                          children: [
                            const SizedBox(width: 16),
                            const Text('Cash'),
                            const Spacer(),
                            if (withIcon)
                              IconButton(
                                onPressed: () {},
                                icon: const Icon(
                                  Icons.info_outline,
                                  semanticLabel: 'Details',
                                ),
                              ),
                            const Text('10.00'),
                            const SizedBox(width: 16),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 400),
              ],
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 20,
            height: 48,
            child: ElevatedButton(
              onPressed: () {},
              child: const Text('Add Payment'),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Runs a Scout action while frames keep coming, as on a device, so the
/// Slidable's open animation runs before Scout takes its after snapshot.
Future<Map<String, Object?>> _withFrames(
  WidgetTester tester,
  Future<Map<String, Object?>> Function() action,
) async {
  Map<String, Object?>? result;
  Object? error;
  action().then((value) => result = value, onError: (Object e) => error = e);
  for (var i = 0; i < 600 && result == null && error == null; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  if (error != null) throw error!;
  expect(result, isNotNull, reason: 'the action never completed');
  await tester.pumpAndSettle();
  return result!;
}

/// The production settle wait; the debug entry points default to none.
const _settle = {'waitMs': '1500'};

List<String> _handles(FlutterScoutRuntime runtime) => [
  for (final node in runtime.debugSnapshot().interactables) node.id,
];

void main() {
  testWidgets('a floating button never borrows the label of a row beneath it', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    late SlidableController controller;
    // 600 tall: the button covers 532..580 and the row 520..576, so the
    // row's "Cash" sits under the button (the SOA run on 25 Nov 2026).
    await tester.pumpWidget(
      _sheet(rowTop: 520, onController: (value) => controller = value),
    );
    final runtime = FlutterScoutHelper.debugRuntime;
    final button = runtime.debugSnapshot().interactables.singleWhere(
      (node) => node.widgetType == 'ElevatedButton',
    );
    expect(button.id, 'btn.add_payment');
    expect(button.label, 'Add Payment');
    expect(_handles(runtime), isNot(contains('btn.cash')));

    // A swipe that lands on the button moves nothing: it must not say ok.
    final swipe = await _withFrames(
      tester,
      () => runtime.debugSwipe({
        'target': button.id,
        'direction': 'left',
        ..._settle,
      }),
    );
    expect(swipe['ok'], isFalse, reason: '$swipe');
    expect((swipe['error']! as Map)['code'], 'swipe_no_effect');
    expect((swipe['activation']! as Map)['dispatched'], isTrue);
    expect(swipe['result'], 'unchanged');
    expect((swipe['target']! as Map)['widgetType'], 'ElevatedButton');
    expect(controller.ratio, 0);
  });

  testWidgets('swiping a visible row reveals Delete in the next scene', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    late SlidableController controller;
    await tester.pumpWidget(
      _sheet(rowTop: 200, onController: (value) => controller = value),
    );
    final runtime = FlutterScoutHelper.debugRuntime;
    // The row's handle is the Slidable's live drag detector, not the
    // callback-less auto-close detector wrapped around it.
    final row = runtime.debugSnapshot().interactables.singleWhere(
      (node) => node.label == 'Cash',
    );
    expect(row.widgetType, 'GestureDetector');
    expect(row.enabled, isTrue);
    expect(_handles(runtime), isNot(contains('btn.delete')));

    final swipe = await _withFrames(
      tester,
      () => runtime.debugSwipe({
        'target': row.id,
        'direction': 'left',
        ..._settle,
      }),
    );
    expect(swipe['ok'], isTrue, reason: '$swipe');
    expect(swipe['result'], 'changed');
    expect(controller.ratio, lessThan(0));
    expect(_handles(runtime), contains('btn.delete'));
    expect(runtime.debugSnapshot().visibleText, contains('Delete'));
  });

  testWidgets('swiping a small control inside a row opens the row', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    late SlidableController controller;
    await tester.pumpWidget(
      _sheet(
        rowTop: 200,
        withIcon: true,
        onController: (value) => controller = value,
      ),
    );
    final runtime = FlutterScoutHelper.debugRuntime;
    final icon = runtime.debugSnapshot().interactables.singleWhere(
      (node) => node.widgetType == 'IconButton',
    );

    final swipe = await _withFrames(
      tester,
      () => runtime.debugSwipe({
        'target': icon.id,
        'direction': 'left',
        ..._settle,
      }),
    );
    expect(swipe['ok'], isTrue, reason: '$swipe');
    expect(controller.ratio, lessThan(0));
    expect(_handles(runtime), contains('btn.delete'));
  });

  testWidgets('a scroll that cannot move still reports ok', (tester) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              for (var i = 0; i < 40; i++) ListTile(title: Text('Row $i')),
            ],
          ),
        ),
      ),
    );
    final scroll = await _withFrames(
      tester,
      () => FlutterScoutHelper.debugRuntime.debugScroll({
        'direction': 'up',
        'x': '200',
        'y': '300',
        'distance': '200',
        ..._settle,
      }),
    );
    expect(scroll['ok'], isTrue, reason: '$scroll');
  });
}
