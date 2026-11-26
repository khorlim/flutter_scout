import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

/// State an app only paints: Scout never guesses it, but names the control
/// whose state it cannot read.
void main() {
  Map<String, Object?> brief() => FlutterScoutHelper.debugRuntime
      .debugInspectPayload(brief: true, maxItems: 100);

  List<Map<String, Object?>> hints() {
    final payload = brief()['stateHints'] as Map<String, Object?>?;
    return [
      for (final hint in (payload?['controls'] as List?) ?? const [])
        (hint as Map).cast<String, Object?>(),
    ];
  }

  Widget chip(String label, {required bool on, VoidCallback? onTap}) =>
      GestureDetector(
        onTap: onTap ?? () {},
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border.all(
              color: on ? Colors.green : Colors.transparent,
              width: 2,
            ),
          ),
          child: Text(label),
        ),
      );

  Future<void> pump(WidgetTester tester, List<Widget> children) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Row(children: children)),
      ),
    );
    await tester.pump();
  }

  setUp(FlutterScoutHelper.ensureRegistered);

  testWidgets('a chip without state beside one that states it is named', (
    tester,
  ) async {
    await pump(tester, [
      chip('Points', on: true),
      Semantics(selected: false, child: chip('Credit', on: false)),
    ]);

    final found = hints();
    expect(found, hasLength(1), reason: '$found');
    expect(found.single['reason'], 'siblings_report_state');
    expect(found.single['ids'], ['tap.points']);
    expect(found.single['siblings'], ['tap.credit']);
    expect(
      (brief()['stateHints']! as Map)['note'],
      contains('Semantics(selected:'),
    );
  });

  testWidgets('look-alike controls painted differently are named together', (
    tester,
  ) async {
    await pump(tester, [
      chip('<180 days', on: true),
      chip('>180 days', on: false),
    ]);

    final found = hints();
    expect(found, hasLength(1), reason: '$found');
    expect(found.single['reason'], 'painted_differently');
    expect(found.single['ids'], ['tap.lt_180_days', 'tap.gt_180_days']);
  });

  testWidgets('no hint for alike controls, stated ones, or different kinds', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Row(
                children: [
                  chip('Thai Yoga', on: false),
                  chip('Facial', on: false),
                ],
              ),
              Row(
                children: [
                  Semantics(selected: true, child: chip('Cash', on: true)),
                  Semantics(selected: false, child: chip('Card', on: false)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(hints(), isEmpty);

    // A primary and a secondary button differ by design, not by state.
    await pump(tester, [
      TextButton(onPressed: () {}, child: const Text('Cancel')),
      FilledButton(onPressed: () {}, child: const Text('Save')),
    ]);
    expect(hints(), isEmpty);
  });

  testWidgets('a tap that only repaints its target says so in the receipt', (
    tester,
  ) async {
    var on = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Row(
              children: [
                chip('Points', on: on, onTap: () => setState(() => on = !on)),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final point = tester.getCenter(find.text('Points'));

    final result = await tester.runAsync(() async {
      final frames = Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => unawaited(tester.pump(const Duration(milliseconds: 16))),
      );
      try {
        return await FlutterScoutHelper.debugRuntime.debugTapPoint(
          point,
          target: 'tap.points',
          trackInput: true,
          lateWaitMs: 300,
        );
      } finally {
        frames.cancel();
      }
    });

    expect(on, isTrue);
    expect(result!['result'], 'activated_no_observed_change');
    final painted = result['paintOnlyChange']! as Map;
    expect(painted['target'], 'tap.points');
    expect(painted['hint'], contains('crop'));
    expect(
      (result['warnings']! as List).single,
      contains('changed how tap.points is painted'),
    );
  });

  testWidgets('a tap that repaints nothing has no paint hint', (tester) async {
    await pump(tester, [chip('Points', on: false)]);
    final point = tester.getCenter(find.text('Points'));
    final result = await tester.runAsync(
      () => FlutterScoutHelper.debugRuntime.debugTapPoint(
        point,
        target: 'tap.points',
        trackInput: true,
        lateWaitMs: 300,
      ),
    );
    expect(result!['paintOnlyChange'], isNull);
  });
}
