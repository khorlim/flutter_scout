import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

/// The "Scout is driving" overlay is a picture of input for people watching.
/// These tests hold it to that: Scout's observation, hit testing, the app's
/// own builds and the stability signals behave as if it were not there.
void main() {
  late int builds;
  late int saves;

  Widget app() => MaterialApp(
    home: Builder(
      builder: (context) {
        builds++;
        return Scaffold(
          body: Column(
            children: [
              const Text('Ready'),
              // No ink splash: the app itself runs no animation here.
              GestureDetector(onTap: () => saves++, child: const Text('Save')),
              const TextField(
                key: ValueKey('name'),
                decoration: InputDecoration(labelText: 'Name'),
              ),
              const TextField(
                key: ValueKey('pin'),
                obscureText: true,
                decoration: InputDecoration(labelText: 'PIN'),
              ),
            ],
          ),
        );
      },
    ),
  );

  setUp(() {
    builds = 0;
    saves = 0;
  });

  /// Pumps real 16 ms frames, as the engine would, for [ms].
  Future<void> frames(WidgetTester tester, int ms) async {
    for (var elapsed = 0; elapsed < ms; elapsed += 16) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<FlutterScoutRuntime> attached(WidgetTester tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    final runtime = FlutterScoutRuntime();
    await runtime.debugAgentOverlay('attach');
    await tester.pump(); // post-frame install
    await tester.pump(); // build the entry
    expect(runtime.debugDrivingOverlayStatus['installed'], isTrue);
    return runtime;
  }

  Future<void> detach(WidgetTester tester, FlutterScoutRuntime runtime) async {
    await runtime.debugAgentOverlay('detach');
    await frames(tester, 500);
    final status = runtime.debugDrivingOverlayStatus;
    expect(status['installed'], isFalse, reason: '$status');
    expect(status['ticking'], isFalse, reason: '$status');
  }

  Finder overlayPaint() => find.descendant(
    of: find.byWidgetPredicate(
      (widget) =>
          widget.runtimeType.toString() == '_FlutterScoutDrivingOverlay',
    ),
    matching: find.byType(CustomPaint),
  );

  testWidgets('the overlay never appears in observation or semantics', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pump();
    final runtime = FlutterScoutRuntime();
    final before = runtime.debugSnapshot();
    final semantics = tester.ensureSemantics();

    await runtime.debugAgentOverlay('attach');
    await tester.pump();
    await tester.pump();
    await tester.runAsync(() => runtime.debugTapTarget('tap.save'));
    await frames(tester, 200);
    expect(runtime.debugDrivingOverlayStatus['effects'], greaterThan(0));
    expect(overlayPaint(), findsOneWidget);

    final during = runtime.debugSnapshot();
    expect(saves, 1);
    expect(during.stateDigest, before.stateDigest);
    expect(during.visibleText, before.visibleText);
    expect(
      [for (final node in during.interactables) node.id],
      [for (final node in before.interactables) node.id],
    );
    expect(during.visibleText.where((text) => text.contains('Scout')), isEmpty);
    expect(find.bySemanticsLabel(RegExp('Scout')), findsNothing);

    semantics.dispose();
    await detach(tester, runtime);
  });

  testWidgets('hits pass through the overlay to the app', (tester) async {
    final runtime = await attached(tester);
    await tester.runAsync(() => runtime.debugTapTarget('tap.save'));
    await frames(tester, 100);
    expect(saves, 1);

    // A person's tap lands on the app while the overlay is drawing.
    final center = tester.getCenter(find.text('Save'));
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, center, tester.view.viewId);
    final overlayBox = tester.renderObject(overlayPaint());
    expect(result.path.any((entry) => entry.target == overlayBox), isFalse);
    await tester.tapAt(center);
    await frames(tester, 600);
    expect(saves, 2);

    await detach(tester, runtime);
  });

  testWidgets('the ticker runs only while something moves', (tester) async {
    final runtime = await attached(tester);
    await frames(tester, 700);
    expect(runtime.debugDrivingOverlayStatus['ticking'], isFalse);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);

    await tester.runAsync(() => runtime.debugTapTarget('tap.save'));
    expect(runtime.debugDrivingOverlayStatus['ticking'], isTrue);
    // The ripple ends first; the cursor's name tag fades about 1.4 s in.
    await frames(tester, 1600);
    var status = runtime.debugDrivingOverlayStatus;
    expect(status['ticking'], isFalse);
    expect(status['effects'], 0);
    expect(status['controlling'], isTrue, reason: 'cursor parked');
    expect(tester.binding.hasScheduledFrame, isFalse);

    // After a quiet moment the cursor fades and the session calms down,
    // then the ticker stops again.
    await frames(tester, 2500);
    await frames(tester, 800);
    status = runtime.debugDrivingOverlayStatus;
    expect(status['controlling'], isFalse);
    expect(status['ticking'], isFalse);

    await detach(tester, runtime);
  });

  testWidgets('animation frames never rebuild the app tree', (tester) async {
    final runtime = await attached(tester);
    final buildsBefore = builds;
    await tester.runAsync(() => runtime.debugTapTarget('tap.save'));
    for (var i = 0; i < 20; i++) {
      await frames(tester, 16);
    }
    expect(builds, buildsBefore);
    await detach(tester, runtime);
  });

  testWidgets('stability still settles while the overlay animates', (
    tester,
  ) async {
    final runtime = await attached(tester);
    await frames(tester, 700);

    // A Scout act with its normal settle wait. No frames are pumped inside
    // runAsync, so the overlay's frame callback stays pending throughout.
    final tap = await tester.runAsync(
      () => runtime.debugTapPoint(
        tester.getCenter(find.text('Save')),
        waitMs: 600,
      ),
    );
    expect(tester.binding.transientCallbackCount, 1, reason: 'overlay tick');
    expect(runtime.debugAppTransientCallbackCount, 0);
    final stability = tap!['stability']! as Map<String, Object?>;
    expect(stability['state'], 'stable', reason: '$stability');
    expect(stability['elapsedMs'], lessThan(600));

    final observed = await tester.runAsync(
      () => runtime.debugObserveStability(timeoutMs: 600),
    );
    final state = observed!['stability']! as Map<String, Object?>;
    expect(state['state'], 'stable', reason: '$state');
    final frameSignals = state['frames']! as Map<String, Object?>;
    expect(frameSignals['maxTransientCallbacks'], 0);

    await frames(tester, 900);
    await detach(tester, runtime);
  });

  testWidgets('typing shows plain text but only dots for a credential', (
    tester,
  ) async {
    final runtime = await attached(tester);
    await tester.runAsync(() => runtime.debugInputTarget('field.name', 'Ada'));
    await tester.runAsync(() => runtime.debugInputTarget('field.pin', '6015'));
    final chips = runtime.debugDrivingOverlayChips;
    expect(chips, contains('Ada'));
    expect(chips, contains('••••••'));
    expect(chips.where((chip) => chip.contains('6015')), isEmpty);
    await frames(tester, 100);
    await frames(tester, 2000);
    await detach(tester, runtime);
  });

  testWidgets('a lapsed lease removes the overlay', (tester) async {
    final runtime = await attached(tester);
    await frames(tester, 6100);
    await frames(tester, 500);
    await tester.pump();
    final status = runtime.debugDrivingOverlayStatus;
    expect(status['attached'], isFalse);
    expect(status['installed'], isFalse);
    expect(overlayPaint(), findsNothing);
  });

  testWidgets('input is drawn only while an agent is attached', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    final runtime = FlutterScoutRuntime();
    await tester.runAsync(() => runtime.debugTapTarget('tap.save'));
    expect(saves, 1);
    final status = runtime.debugDrivingOverlayStatus;
    expect(status['installed'], isFalse);
    expect(status['effects'], 0);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('a running mutation holds the overlay still, then plays it', (
    tester,
  ) async {
    final runtime = await attached(tester);
    await frames(tester, 700);
    Map<String, Object?>? during;
    var transientDuring = -1;
    final response = await tester.runAsync(
      () => runtime.debugProtocolMutation(
        <String, String>{
          'schemaVersion': '1',
          'clientProtocolMin': '15',
          'clientProtocolMax': '15',
          'commandId': 'overlay-hold',
          'idempotencyKey': 'overlay-hold',
          'runId': 'run-a',
          'runtimeInstanceId': runtime.debugRuntimeInstanceId,
          'expectedStateGeneration':
              '${runtime.debugSnapshot().stateGeneration}',
          'deadlineEpochMs':
              '${DateTime.now().add(const Duration(minutes: 1)).millisecondsSinceEpoch}',
        },
        () async {
          await runtime.debugTapTarget('tap.save');
          during = runtime.debugDrivingOverlayStatus;
          transientDuring = WidgetsBinding.instance.transientCallbackCount;
          return <String, Object?>{'tapped': true};
        },
      ),
    );
    expect(response!['ok'], isTrue, reason: '$response');
    expect(saves, 1, reason: 'the input itself is never held');
    expect(during!['effects'], 0, reason: 'drawing waits for the answer');
    expect(transientDuring, 0, reason: 'no overlay frames during the act');
    expect(runtime.debugDrivingOverlayStatus['effects'], greaterThan(0));
    await frames(tester, 900);
    await detach(tester, runtime);
  });
}
