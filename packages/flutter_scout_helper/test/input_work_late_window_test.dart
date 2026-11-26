import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

/// The late-change window after a tap that changed nothing at once ends as
/// soon as the work the tap started has settled, keeps waiting for work it
/// can follow, and waits the whole window for work it cannot.
void main() {
  late StateSetter update;
  var label = 'Idle';

  Future<Offset> pumpButton(WidgetTester tester, VoidCallback onTap) async {
    label = 'Idle';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Column(
                children: [
                  Text(label),
                  GestureDetector(
                    onTap: onTap,
                    child: const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Tap me'),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    return tester.getCenter(find.text('Tap me'));
  }

  /// Taps through the production handler with the engine's frames running,
  /// and returns the receipt with the wall time it took.
  Future<(Map<String, Object?>, int)> tap(
    WidgetTester tester,
    Offset point, {
    int lateWaitMs = 1500,
    bool trackInput = true,
    void Function()? setUpRealAsync,
  }) async {
    final stopwatch = Stopwatch()..start();
    final result = await tester.runAsync(() async {
      setUpRealAsync?.call();
      // The engine's frames, with animation time advancing as in an app.
      final frames = Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => unawaited(tester.pump(const Duration(milliseconds: 16))),
      );
      try {
        return await FlutterScoutHelper.debugRuntime.debugTapPoint(
          point,
          lateWaitMs: lateWaitMs,
          trackInput: trackInput,
        );
      } finally {
        frames.cancel();
      }
    });
    return (result!, stopwatch.elapsedMilliseconds);
  }

  Map<String, Object?> lateWindow(Map<String, Object?> result) =>
      result['lateWindow']! as Map<String, Object?>;

  setUp(FlutterScoutHelper.ensureRegistered);

  testWidgets('a synchronous tap that changes nothing ends the window', (
    tester,
  ) async {
    final point = await pumpButton(tester, () => update(() {}));
    final (result, elapsedMs) = await tap(tester, point);

    expect(result['result'], 'activated_no_observed_change', reason: '$result');
    expect(lateWindow(result)['ended'], 'input_idle');
    expect(lateWindow(result)['ms'], 1500);
    expect(elapsedMs, lessThan(700));
  });

  testWidgets('a timer the tap started is followed until its change lands', (
    tester,
  ) async {
    final point = await pumpButton(tester, () {
      Timer(const Duration(milliseconds: 300), () {
        update(() => label = 'Done');
      });
    });
    final (result, _) = await tap(tester, point);

    expect(result['lateChangeObserved'], isTrue, reason: '$result');
    expect(lateWindow(result)['ended'], 'change_landed');
    expect(label, 'Done');
  });

  testWidgets('a timer that changes nothing ends the window when it fires', (
    tester,
  ) async {
    var fired = false;
    final point = await pumpButton(tester, () {
      Timer(const Duration(milliseconds: 300), () => fired = true);
    });
    final (result, elapsedMs) = await tap(tester, point);

    expect(fired, isTrue);
    expect(lateWindow(result)['ended'], 'input_idle', reason: '$result');
    expect(elapsedMs, greaterThanOrEqualTo(300));
    expect(elapsedMs, lessThan(1200));
  });

  testWidgets('an app await keeps the whole window', (tester) async {
    final point = await pumpButton(tester, () async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    final (result, elapsedMs) = await tap(tester, point, lateWaitMs: 500);

    final window = lateWindow(result);
    expect(window['ended'], 'window_elapsed', reason: '$result');
    expect((window['inputWork']! as Map)['busy'], 'app_async_callback');
    expect(elapsedMs, greaterThanOrEqualTo(450));
  });

  testWidgets('an event for a stream the app listened to earlier keeps the '
      'window and sees the change its listener makes', (tester) async {
    // The listener runs in the app's zone, outside the input's zone: Scout
    // cannot follow it, so the window stays open.
    final events = StreamController<int>();
    StreamSubscription<int>? subscription;
    addTearDown(() => subscription?.cancel());
    final point = await pumpButton(tester, () => events.add(1));
    final (result, _) = await tap(
      tester,
      point,
      setUpRealAsync: () => subscription = events.stream.listen((_) {
        Timer(const Duration(milliseconds: 200), () {
          update(() => label = 'Synced');
        });
      }),
    );

    final window = lateWindow(result);
    expect(result['lateChangeObserved'], isTrue, reason: '$result');
    expect(window['ended'], 'change_landed');
    expect((window['inputWork']! as Map)['busy'], 'app_microtask');
  });

  testWidgets('a short window is not overrun', (tester) async {
    final point = await pumpButton(tester, () async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    final (result, _) = await tap(tester, point, lateWaitMs: 200);

    final window = lateWindow(result);
    expect(window['ended'], 'window_elapsed', reason: '$result');
    expect(window['waitedMs'], lessThan(290));
  });

  testWidgets('a periodic timer keeps the whole window', (tester) async {
    Timer? ticker;
    final point = await pumpButton(tester, () {
      ticker = Timer.periodic(const Duration(seconds: 5), (_) {});
    });
    final (result, _) = await tap(tester, point, lateWaitMs: 400);
    ticker?.cancel();

    final window = lateWindow(result);
    expect(window['ended'], 'window_elapsed', reason: '$result');
    expect((window['inputWork']! as Map)['busy'], 'periodic_timer');
  });

  testWidgets('a Material button waits for its own feedback, then ends', (
    tester,
  ) async {
    // flutter_test defaults to Android, whose tap feedback plays a sound
    // through the test's own messenger; the macOS app has no tap sound.
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: Center(
            child: TextButton(onPressed: () {}, child: const Text('Noop')),
          ),
        ),
      ),
    );
    await tester.pump();
    final (result, elapsedMs) = await tap(
      tester,
      tester.getCenter(find.text('Noop')),
    );

    expect(lateWindow(result)['ended'], 'input_idle', reason: '$result');
    expect(elapsedMs, lessThan(1400));
  });

  testWidgets('input Scout does not track keeps the window', (tester) async {
    final point = await pumpButton(tester, () => update(() {}));
    final (result, elapsedMs) = await tap(
      tester,
      point,
      lateWaitMs: 400,
      trackInput: false,
    );

    expect(lateWindow(result)['ended'], 'window_elapsed', reason: '$result');
    expect(elapsedMs, greaterThanOrEqualTo(350));
  });

  testWidgets('lateWaitMs 0 skips the window', (tester) async {
    final point = await pumpButton(tester, () => update(() {}));
    final (result, _) = await tap(tester, point, lateWaitMs: 0);

    expect(lateWindow(result)['ended'], 'disabled', reason: '$result');
  });
}
