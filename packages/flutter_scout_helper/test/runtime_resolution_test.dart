import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, Object?> resolutionOf(Map<String, Object?> response) =>
      response['resolution']! as Map<String, Object?>;

  Map<String, String> mutationEnvelope(
    FlutterScoutRuntime runtime, {
    required int generation,
    required String commandId,
  }) => {
    'schemaVersion': '1',
    'clientProtocolMin': '15',
    'clientProtocolMax': '15',
    'commandId': commandId,
    'idempotencyKey': commandId,
    'runId': 'resolver-tests',
    'runtimeInstanceId': runtime.debugRuntimeInstanceId,
    'expectedStateGeneration': '$generation',
    'deadlineEpochMs':
        '${DateTime.now().add(const Duration(minutes: 1)).millisecondsSinceEpoch}',
  };

  testWidgets(
    'duplicate labels, ids, keys, and tap-text matches abstain with ranked evidence',
    (tester) async {
      FlutterScoutHelper.ensureRegistered();
      var dispatched = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Padding(
                  padding: EdgeInsets.zero,
                  child: ElevatedButton(
                    key: const ValueKey('duplicate-key'),
                    onPressed: () => dispatched++,
                    child: const Text('Save'),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.zero,
                  child: ElevatedButton(
                    key: const ValueKey('duplicate-key'),
                    onPressed: () => dispatched++,
                    child: const Text('Save'),
                  ),
                ),
                TextButton(
                  onPressed: () => dispatched++,
                  child: const Text('OK'),
                ),
                TextButton(
                  onPressed: () => dispatched++,
                  child: const Text('OK'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final runtime = FlutterScoutHelper.debugRuntime;
      for (final target in [
        'btn.duplicate_key',
        'duplicate-key',
        'Save',
        'Sav',
      ]) {
        final response = (await tester.runAsync(
          () => runtime.debugTapTarget(target),
        ))!;
        expect(response['ok'], isFalse, reason: target);
        final resolution = resolutionOf(response);
        expect(resolution['status'], 'ambiguous', reason: target);
        final candidates = (resolution['candidates']! as List).cast<Map>();
        expect(candidates, hasLength(2));
        expect(
          candidates.every(
            (candidate) =>
                candidate['heuristicRank'] is int &&
                candidate['scoreKind'] == 'uncalibrated_heuristic',
          ),
          isTrue,
        );
        expect(
          candidates.every(
            (candidate) => (candidate['scope']! as Map)['snapshotId'] is String,
          ),
          isTrue,
        );
      }

      final textResponse = (await tester.runAsync(
        () => runtime.debugTapTextTarget('OK'),
      ))!;
      expect(resolutionOf(textResponse)['status'], 'ambiguous');
      expect(dispatched, 0);
      expect(runtime.debugWaitForConditionsMet({'target': 'Save'}), isFalse);
    },
  );

  testWidgets('duplicate field selector never mutates either controller', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    final first = TextEditingController();
    final second = TextEditingController();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Padding(
                padding: EdgeInsets.zero,
                child: TextField(
                  key: const ValueKey('shared-email'),
                  controller: first,
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
              ),
              Padding(
                padding: EdgeInsets.zero,
                child: TextField(
                  key: const ValueKey('shared-email'),
                  controller: second,
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final response = (await tester.runAsync(
      () => FlutterScoutHelper.debugRuntime.debugInputTarget(
        'field.shared_email',
        'must-not-write',
      ),
    ))!;
    expect(resolutionOf(response)['status'], 'ambiguous');
    expect(first.text, isEmpty);
    expect(second.text, isEmpty);
  });

  testWidgets('duplicate scroll handle abstains before either viewport moves', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    final first = ScrollController();
    final second = ScrollController();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    Widget scrollable(ScrollController controller) => Expanded(
      child: SingleChildScrollView(
        key: const ValueKey('shared-scroll'),
        controller: controller,
        child: const SizedBox(height: 1200, child: Text('content')),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(children: [scrollable(first), scrollable(second)]),
        ),
      ),
    );
    await tester.pump();

    final response = (await tester.runAsync(
      () => FlutterScoutHelper.debugRuntime.debugScroll({
        'target': 'scroll.shared_scroll',
        'distance': '80',
      }),
    ))!;
    expect(resolutionOf(response)['status'], 'ambiguous');
    expect(first.offset, 0);
    expect(second.offset, 0);
  });

  testWidgets(
    'modal background, disabled control, and full occlusion are typed abstentions',
    (tester) async {
      FlutterScoutHelper.ensureRegistered();
      var dispatched = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Align(
                  alignment: Alignment.topCenter,
                  child: ElevatedButton(
                    onPressed: () => dispatched++,
                    child: const Text('Background Save'),
                  ),
                ),
                const Positioned.fill(
                  child: ModalBarrier(
                    dismissible: false,
                    color: Colors.black26,
                  ),
                ),
                Center(
                  child: AlertDialog(
                    title: const Text('Confirm'),
                    actions: [
                      ElevatedButton(
                        onPressed: null,
                        child: const Text('Disabled'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final runtime = FlutterScoutHelper.debugRuntime;
      final background = (await tester.runAsync(
        () => runtime.debugTapTarget('btn.background_save'),
      ))!;
      expect(resolutionOf(background)['status'], 'wrongSurface');
      final disabled = (await tester.runAsync(
        () => runtime.debugTapTarget('btn.disabled'),
      ))!;
      expect(resolutionOf(disabled)['status'], 'disabled');
      expect(dispatched, 0);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Center(
                  child: ElevatedButton(
                    onPressed: () => dispatched++,
                    child: const Text('Covered'),
                  ),
                ),
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final covered = (await tester.runAsync(
        () => runtime.debugTapTarget('btn.covered'),
      ))!;
      expect(resolutionOf(covered)['status'], 'occluded');
      expect(dispatched, 0);
    },
  );

  testWidgets('partially visible control uses a proven visible safe point', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    var dispatched = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: -55,
                top: 80,
                width: 110,
                child: ElevatedButton(
                  onPressed: () => dispatched++,
                  child: const Text('Partial'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final response = (await tester.runAsync(
      () => FlutterScoutHelper.debugRuntime.debugTapTarget('btn.partial'),
    ))!;
    expect(response['ok'], isTrue);
    final resolution = resolutionOf(response);
    expect(resolution['status'], 'unique');
    final safePoint = (resolution['safePoint']! as List).cast<num>();
    expect(safePoint[0], greaterThanOrEqualTo(0));
    expect((resolution['immediateHitTest']! as Map)['containsTarget'], isTrue);
    expect(dispatched, 1);
  });

  testWidgets(
    'stale protocol generation prevents targeted dispatch and explicit coordinates report their frame',
    (tester) async {
      final runtime = FlutterScoutRuntime();
      var targetDispatches = 0;
      var revision = 0;
      late StateSetter setFixtureState;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              setFixtureState = setState;
              return Scaffold(
                body: Column(
                  children: [
                    Text('revision $revision'),
                    ElevatedButton(
                      onPressed: () => targetDispatches++,
                      child: const Text('Run'),
                    ),
                    const Expanded(
                      child: SingleChildScrollView(child: Text('body')),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      final generation = runtime.debugSnapshot().stateGeneration;
      setFixtureState(() => revision++);
      await tester.pump();

      final stale = await runtime.debugProtocolMutation(
        mutationEnvelope(
          runtime,
          generation: generation,
          commandId: 'stale-target-dispatch',
        ),
        () => runtime.debugTapTarget('btn.run'),
      );
      expect(
        (stale['structuredError']! as Map)['code'],
        'stale_state_generation',
      );
      expect(targetDispatches, 0);

      final coordinate = (await tester.runAsync(
        () => runtime.debugScroll({'x': '20', 'y': '30', 'distance': '10'}),
      ))!;
      final evidence = coordinate['coordinateEvidence']! as Map;
      expect(evidence['coordinateSpace'], 'logical');
      expect(evidence['logicalPoint'], [20.0, 30.0]);
      expect(evidence['physicalPoint'], isA<List>());
      expect(evidence['devicePixelRatio'], greaterThan(0));
      expect(evidence['viewport'], isA<List>());
      expect(evidence['immediateHitTest'], isA<Map>());
    },
  );
}
