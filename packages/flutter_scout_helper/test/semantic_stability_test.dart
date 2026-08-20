import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, Object?> stability(Map<String, Object?> result) =>
      result['stability']! as Map<String, Object?>;

  testWidgets('stable means semantic quiet plus inactive scheduler evidence', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Ready'))),
    );
    await tester.pump();

    final result = await tester.runAsync(
      () => runtime.debugObserveStability(timeoutMs: 600),
    );
    final observed = stability(result!);

    expect(result['stable'], isTrue, reason: '$observed');
    expect(observed['state'], 'stable');
    expect(observed['actionable'], isTrue);
    expect(observed['stoppingReason'], 'semantic_quiet_and_no_frame_activity');
    expect(observed['bounded'], isTrue);
    expect(observed['budgetMs'], 600);
    expect(observed['elapsedMs'], lessThanOrEqualTo(600));
    expect(observed['initial'], contains('snapshotId'));
    expect(observed['final'], contains('snapshotId'));
    expect(observed['limitations'], isNotEmpty);
    expect(result['timings'], containsPair('settleMs', observed['elapsedMs']));
  });

  testWidgets('expectation early-stop is explicit transient activity', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    var status = 'Loading';
    var expectationMet = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Scaffold(body: Text(status));
          },
        ),
      ),
    );
    await tester.pump();

    final result = await tester.runAsync(() async {
      final timer = Timer(const Duration(milliseconds: 60), () {
        update(() => status = 'Ready');
        expectationMet = true;
        unawaited(tester.pump());
      });
      final observed = await runtime.debugObserveStability(
        timeoutMs: 600,
        stopWhen: () => expectationMet,
      );
      timer.cancel();
      return observed;
    });
    final observed = stability(result!);

    expect(result['stable'], isFalse);
    expect(observed['state'], 'transient', reason: '$observed');
    expect(observed['actionable'], isFalse);
    expect(observed['stoppingReason'], 'expectation_met');
    expect(observed['expectationMet'], isTrue);
    expect(observed['elapsedMs'], lessThan(600));
    final samples = observed['samples']! as Map<String, Object?>;
    expect(samples['semanticChangeCount'], greaterThanOrEqualTo(1));
  });

  testWidgets(
    'continuous background animation stays actionable when semantics are quiet',
    (tester) async {
      final runtime = FlutterScoutRuntime();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Text('Ready'),
                CircularProgressIndicator(),
                ElevatedButton(onPressed: null, child: Text('Static action')),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final result = await tester.runAsync(() async {
        var pumping = false;
        Future<void> pendingPump = Future<void>.value();
        final pumpTimer = Timer.periodic(const Duration(milliseconds: 24), (_) {
          if (pumping) return;
          pumping = true;
          pendingPump = tester
              .pump(const Duration(milliseconds: 24))
              .whenComplete(() => pumping = false);
          unawaited(pendingPump);
        });
        final observed = await runtime.debugObserveStability(timeoutMs: 800);
        pumpTimer.cancel();
        await pendingPump;
        return observed;
      });
      final observed = stability(result!);

      expect(result['stable'], isFalse);
      expect(observed['state'], 'continuous_animation');
      expect(observed['actionable'], isTrue);
      expect(
        observed['stoppingReason'],
        contains('actionable_semantics_quiet'),
      );
      final samples = observed['samples']! as Map<String, Object?>;
      expect(samples['semanticChangeCount'], 0);
      final frames = observed['frames']! as Map<String, Object?>;
      expect(frames['transientCallbackSamples'], greaterThanOrEqualTo(2));
    },
  );

  testWidgets('changing agent-visible state is never-settling, not animation', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    var counter = 0;
    var pumping = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Scaffold(body: Text('Counter $counter'));
          },
        ),
      ),
    );
    await tester.pump();

    final result = await tester.runAsync(() async {
      Future<void> pendingPump = Future<void>.value();
      final changeTimer = Timer.periodic(const Duration(milliseconds: 36), (_) {
        update(() => counter += 1);
        if (pumping) return;
        pumping = true;
        pendingPump = tester.pump().whenComplete(() => pumping = false);
        unawaited(pendingPump);
      });
      final observed = await runtime.debugObserveStability(timeoutMs: 480);
      changeTimer.cancel();
      await pendingPump;
      return observed;
    });
    final observed = stability(result!);

    expect(result['stable'], isFalse);
    expect(observed['state'], 'never_settling', reason: '$observed');
    expect(observed['actionable'], isFalse);
    expect(observed['stoppingReason'], 'budget_exhausted_semantics_changing');
    final samples = observed['samples']! as Map<String, Object?>;
    expect(samples['semanticChangeCount'], greaterThanOrEqualTo(2));
    expect(samples['distinctSemanticStates'], greaterThanOrEqualTo(3));
  });

  testWidgets('disabled semantic observation fails closed', (tester) async {
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Ready'))),
    );
    await tester.pump();
    runtime.debugSetStabilityObservationEnabled(false);

    final result = await runtime.debugObserveStability(timeoutMs: 500);
    final observed = stability(result);

    expect(result['stable'], isFalse);
    expect(observed['state'], 'observation_unavailable');
    expect(observed['actionable'], isFalse);
    expect(observed['stoppingReason'], 'observation_disabled');
    expect(observed['elapsedMs'], lessThan(100));
    runtime.debugSetStabilityObservationEnabled(true);
  });

  testWidgets('zero budget is bounded observation-unavailable, never stable', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Ready'))),
    );
    await tester.pump();

    final result = await runtime.debugObserveStability(timeoutMs: 0);
    final observed = stability(result);
    expect(result['stable'], isFalse);
    expect(observed['state'], 'observation_unavailable');
    expect(observed['stoppingReason'], 'observation_disabled_by_zero_budget');
    expect(observed['budgetMs'], 0);
  });

  testWidgets('app or runtime loss is distinct from observation failure', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('initially available'))),
    );
    await tester.pump();

    final initiallyUnavailableRuntime = FlutterScoutRuntime()
      ..debugRuntimeAvailabilityProbe = () => false;
    final unavailable = stability(
      await initiallyUnavailableRuntime.debugObserveStability(timeoutMs: 600),
    );
    expect(unavailable['state'], 'observation_unavailable');
    expect(unavailable['stoppingReason'], 'root_element_unavailable');
    expect((unavailable['samples']! as Map)['count'], 0);

    final runtime = FlutterScoutRuntime();
    var runtimeAvailable = true;
    runtime.debugRuntimeAvailabilityProbe = () => runtimeAvailable;
    addTearDown(() => runtime.debugRuntimeAvailabilityProbe = null);

    final result = await tester.runAsync(() async {
      final timer = Timer(const Duration(milliseconds: 70), () {
        runtimeAvailable = false;
      });
      final observed = await runtime.debugObserveStability(timeoutMs: 600);
      timer.cancel();
      return observed;
    });
    final observed = stability(result!);

    expect(result['stable'], isFalse);
    expect(observed['state'], 'runtime_lost');
    expect(observed['actionable'], isFalse);
    expect(
      observed['stoppingReason'],
      'app_or_runtime_lost_during_observation',
    );
    expect(observed['bounded'], isTrue);
    expect(observed['elapsedMs'], lessThan(600));
    expect((observed['samples']! as Map)['count'], greaterThan(0));
    expect((observed['initial']! as Map)['snapshotId'], isNotNull);
  });
}
