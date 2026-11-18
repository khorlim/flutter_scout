import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

// `taps: 2` sends two complete taps at one point in a single dispatch, the
// way an impatient person double taps a submit button.
void main() {
  testWidgets('a double tap presses a button twice in one receipt', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    var presses = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const ValueKey('confirm_payment'),
              onPressed: () => presses++,
              child: const Text('Confirm Payment'),
            ),
          ),
        ),
      ),
    );
    final runtime = FlutterScoutHelper.debugRuntime;
    final handle = runtime
        .debugSnapshot()
        .interactables
        .singleWhere((node) => node.label == 'Confirm Payment')
        .id;

    final stopwatch = Stopwatch()..start();
    final result = await tester.runAsync(
      () => runtime.debugTapTarget(handle, taps: 2, intervalMs: 80),
    );
    stopwatch.stop();
    await tester.pump();

    expect(result?['ok'], isTrue, reason: '$result');
    expect(presses, 2);
    expect(result?['action'], startsWith('double tap '));
    final activation = result?['activation'] as Map;
    expect(activation['dispatched'], isTrue);
    expect(activation['taps'], 2);
    expect(activation['intervalMs'], 80);
    expect(activation['secondTap'], {
      'targetStillHit': true,
      'sameHitPathAsFirstTap': true,
    });
    // The gap is honored, not stretched by a receipt round trip.
    expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(80));
  });

  testWidgets('a double tap is recognized as one by onDoubleTap', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    var doubleTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: GestureDetector(
              onDoubleTap: () => doubleTaps++,
              child: const SizedBox(
                width: 200,
                height: 80,
                child: Center(child: Text('Zoom')),
              ),
            ),
          ),
        ),
      ),
    );
    final runtime = FlutterScoutHelper.debugRuntime;
    final handle = runtime
        .debugSnapshot()
        .interactables
        .singleWhere((node) => node.label == 'Zoom')
        .id;

    final result = await tester.runAsync(
      () => runtime.debugTapTarget(handle, taps: 2),
    );
    await tester.pump();

    expect(result?['ok'], isTrue, reason: '$result');
    expect(doubleTaps, 1);
  });

  testWidgets('a single tap reports no repeat evidence', (tester) async {
    FlutterScoutHelper.ensureRegistered();
    var presses = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => presses++,
              child: const Text('Pay'),
            ),
          ),
        ),
      ),
    );
    final runtime = FlutterScoutHelper.debugRuntime;
    final handle = runtime
        .debugSnapshot()
        .interactables
        .singleWhere((node) => node.label == 'Pay')
        .id;

    final result = await tester.runAsync(() => runtime.debugTapTarget(handle));
    await tester.pump();

    expect(result?['ok'], isTrue, reason: '$result');
    expect(presses, 1);
    final activation = result?['activation'] as Map;
    expect(activation.containsKey('taps'), isFalse);
    expect(activation.containsKey('secondTap'), isFalse);
  });
}
