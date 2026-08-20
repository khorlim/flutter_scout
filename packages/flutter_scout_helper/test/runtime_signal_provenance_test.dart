import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, String> mutationEnvelope(
    FlutterScoutRuntime runtime, {
    required int generation,
    required String commandId,
    required String idempotencyKey,
    int? deadlineEpochMs,
  }) => <String, String>{
    'schemaVersion': '1',
    'clientProtocolMin': '15',
    'clientProtocolMax': '15',
    'commandId': commandId,
    'idempotencyKey': idempotencyKey,
    'runId': 'runtime-signal-run',
    'runtimeInstanceId': runtime.debugRuntimeInstanceId,
    'expectedStateGeneration': '$generation',
    'deadlineEpochMs':
        '${deadlineEpochMs ?? DateTime.now().add(const Duration(minutes: 1)).millisecondsSinceEpoch}',
  };

  testWidgets(
    'framework and platform hooks retain distinct factual provenance',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('hook fixture'))),
      );
      await tester.pump();

      final previousFlutterError = FlutterError.onError;
      final previousPlatformError = ui.PlatformDispatcher.instance.onError;
      FlutterError.onError = (_) {};
      ui.PlatformDispatcher.instance.onError = (_, _) => true;
      final runtime = FlutterScoutRuntime()..install();
      addTearDown(() {
        FlutterError.onError = previousFlutterError;
        ui.PlatformDispatcher.instance.onError = previousPlatformError;
      });

      FlutterError.onError!(
        FlutterErrorDetails(
          exception: StateError('SCOUT_HOOK_FRAMEWORK'),
          library: 'fault_degradation_contract',
        ),
      );
      expect(
        ui.PlatformDispatcher.instance.onError!(
          StateError('SCOUT_HOOK_PLATFORM'),
          StackTrace.current,
        ),
        isTrue,
      );

      final response = await runtime.debugProtocolRead(<String, String>{
        'commandId': 'hook-signal-read',
        'runId': 'hook-signal-run',
        'errorCursor': '0',
      });
      final signals = (response['errorsSinceCursor']! as List).cast<Map>();
      expect(signals, hasLength(2));
      final framework = signals.singleWhere(
        (signal) => signal['type'] == 'flutter_error',
      );
      final platform = signals.singleWhere(
        (signal) => signal['type'] == 'platform_error',
      );

      void expectClosedSignal(
        Map signal, {
        required String source,
        required String mechanism,
      }) {
        expect(signal['identity'], isNotEmpty);
        expect(signal['timestamp'], endsWith('Z'));
        expect(signal['severity'], isNotNull);
        expect(signal['blocking'], isA<bool>());
        expect(signal['phase'], 'startup');
        expect(signal['cursor'], greaterThan(0));
        expect(signal['errorCursor'], signal['cursor']);
        expect(signal, contains('logCursor'));
        expect(signal, contains('actionCommandId'));
        expect(signal['freshness'], 'fresh');
        expect(signal['stale'], isFalse);
        expect(signal['ageStatus'], 'measured');
        expect(signal['ageMs'], isA<int>());
        expect(
          signal['provenance'],
          allOf(
            containsPair('source', source),
            containsPair('captureMechanism', mechanism),
            containsPair('observedBy', 'flutter_scout_helper'),
          ),
        );
      }

      expectClosedSignal(
        framework,
        source: 'FlutterError.onError',
        mechanism: 'framework_error_hook',
      );
      expect(framework['severity'], 'blocking');
      expect(framework['blocking'], isTrue);
      expectClosedSignal(
        platform,
        source: 'PlatformDispatcher.onError',
        mechanism: 'platform_dispatcher_error_hook',
      );
      expect(platform['blocking'], isFalse);
    },
  );

  testWidgets(
    'visible ErrorWidget is a deduplicated active blocking signal without diagnostics',
    (tester) async {
      const diagnosticSecret = 'visible-error-secret-must-not-leak';
      late StateSetter update;
      var showError = true;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Scaffold(
                body: Column(
                  children: <Widget>[
                    if (showError)
                      SizedBox(
                        width: 180,
                        height: 80,
                        child: ErrorWidget(diagnosticSecret),
                      ),
                    const Text('healthy sibling'),
                  ],
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      final runtime = FlutterScoutRuntime();

      final first = runtime.debugSnapshot();
      final firstCursor = runtime.debugErrorCursor;
      expect(firstCursor, greaterThan(0));
      final visibleSignal = first.recentErrors.lastWhere(
        (error) => error['type'] == 'visible_error_surface',
      );
      expect(visibleSignal['blocking'], isTrue);
      expect(visibleSignal['severity'], 'blocking');
      expect(
        (visibleSignal['provenance']! as Map)['captureMechanism'],
        'visible_error_widget_probe',
      );
      expect(jsonEncode(first.toJson()), isNot(contains(diagnosticSecret)));

      runtime.debugSnapshot();
      expect(runtime.debugErrorCursor, firstCursor);
      final active = await runtime.debugProtocolRead(<String, String>{
        'commandId': 'active-error-read',
        'runId': 'visible-error-run',
        'errorCursor': '$firstCursor',
      });
      expect(active['errorsSinceCursor'], isEmpty);
      final activeSignals = active['activeBlockingSignals']! as List;
      expect(activeSignals, hasLength(1));
      expect((activeSignals.single as Map)['freshness'], 'currently_active');
      expect((activeSignals.single as Map)['stale'], isFalse);
      expect(jsonEncode(activeSignals), isNot(contains(diagnosticSecret)));

      update(() => showError = false);
      await tester.pump();
      runtime.debugSnapshot();
      final cleared = await runtime.debugProtocolRead(<String, String>{
        'commandId': 'cleared-error-read',
        'runId': 'visible-error-run',
        'errorCursor': '${runtime.debugErrorCursor}',
      });
      expect(cleared['activeBlockingSignals'], isEmpty);

      update(() => showError = true);
      await tester.pump();
      runtime.debugSnapshot();
      expect(runtime.debugErrorCursor, firstCursor + 1);
    },
  );

  testWidgets(
    'runtime signals carry factual provenance and cursor-scoped correlation',
    (tester) async {
      final runtime = FlutterScoutRuntime();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('signal fixture'))),
      );
      await tester.pump();
      final snapshot = runtime.debugSnapshot();
      final cursor = runtime.debugErrorCursor;

      final response = await runtime.debugProtocolMutation(
        <String, String>{
          ...mutationEnvelope(
            runtime,
            generation: snapshot.stateGeneration,
            commandId: 'command-with-fault',
            idempotencyKey: 'command-with-fault',
          ),
          'errorCursor': '$cursor',
        },
        () {
          runtime.debugRecordError('deterministic injected fault');
          return <String, Object?>{'action': 'fault-fixture'};
        },
      );

      expect(response['ok'], isTrue);
      expect(response.containsKey('result'), isTrue);
      expect(response.containsKey('structuredError'), isTrue);
      expect(response['structuredError'], isNull);
      final signals = (response['errorsSinceCursor']! as List).cast<Map>();
      expect(signals, hasLength(1));
      final signal = signals.single;
      expect(signal['cursor'], cursor + 1);
      expect(signal['errorCursor'], cursor + 1);
      expect(signal['logCursor'], isNull);
      expect(signal['actionCommandId'], 'command-with-fault');
      expect(signal['timestamp'], endsWith('Z'));
      expect(signal['severity'], 'warning');
      expect(signal['blocking'], isFalse);
      expect(signal['phase'], 'mutation_request');
      expect(signal['freshness'], 'fresh');
      expect(signal['stale'], isFalse);
      expect(signal['observedSinceCursor'], isTrue);
      expect(signal['runId'], 'runtime-signal-run');
      expect(signal['runtimeInstanceId'], runtime.debugRuntimeInstanceId);
      expect(signal['stateGeneration'], snapshot.stateGeneration);

      final provenance = signal['provenance']! as Map;
      expect(provenance['source'], 'flutter_scout_runtime');
      expect(provenance['captureMechanism'], 'explicit_runtime_report');
      expect(provenance['observedBy'], 'flutter_scout_helper');

      final correlation = signal['correlation']! as Map;
      expect(correlation['status'], 'observed_during_request');
      expect(correlation['causalAttribution'], 'not_established');
      expect(correlation['commandId'], 'command-with-fault');
      expect(correlation['method'], 'ext.flutter_scout.debugMutation');
      expect(correlation['requestErrorCursor'], cursor);

      final afterCursor = runtime.debugErrorCursor;
      final later = await runtime.debugProtocolRead(<String, String>{
        'commandId': 'later-read',
        'runId': 'runtime-signal-run',
        'errorCursor': '$afterCursor',
      });
      expect(later['errorsSinceCursor'], isEmpty);
      expect(later['recentErrors'], isEmpty);
    },
  );

  testWidgets(
    'outer mutation deadline bounds expectation wait and failure keeps evidence',
    (tester) async {
      final runtime = FlutterScoutRuntime();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('waiting fixture'))),
      );
      await tester.pump();
      final snapshot = runtime.debugSnapshot();
      final deadline = DateTime.now()
          .add(const Duration(milliseconds: 160))
          .millisecondsSinceEpoch;

      final stopwatch = Stopwatch()..start();
      final response = await tester.runAsync(
        () => runtime.debugProtocolActionExpectation(<String, String>{
          ...mutationEnvelope(
            runtime,
            generation: snapshot.stateGeneration,
            commandId: 'bounded-expectation',
            idempotencyKey: 'bounded-expectation',
            deadlineEpochMs: deadline,
          ),
          'expectText': 'Never appears',
          'expectTimeoutMs': '5000',
          'pollMs': '20',
        }),
      );
      stopwatch.stop();

      expect(response, isNotNull);
      expect(response!['ok'], isFalse);
      expect(response.containsKey('result'), isTrue);
      expect(response.containsKey('structuredError'), isTrue);
      expect(response['result'], 'changed');
      expect(
        (response['structuredError']! as Map)['code'],
        'expectation_not_met',
      );
      final stability = response['stability']! as Map;
      expect(stability['deadlineEpochMs'], deadline);
      expect(stability['budgetMs'], lessThanOrEqualTo(160));
      expect(stability['elapsedMs'], lessThan(1000));
      expect(stability['stoppingReason'], isNotNull);
      final timings = response['timings']! as Map;
      expect(timings['expectationWaitMs'], stability['elapsedMs']);
      expect(timings['totalMs'], isA<int>());
      expect(stopwatch.elapsedMilliseconds, lessThan(1500));
    },
  );

  testWidgets('delta reports viewport keyboard and identity facts explicitly', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('delta fixture'))),
    );
    await tester.pump();
    final runtime = FlutterScoutRuntime();

    final result = await tester.runAsync(
      () => runtime.debugTrackAction(
        () async {
          tester.view.physicalSize = const Size(2400, 1200);
          tester.view.viewInsets = FakeViewPadding.zero;
          await tester.pump();
        },
        waitMs: 0,
        lateWaitMs: 0,
      ),
    );

    final delta = result!['delta']! as Map;
    final state = delta['state']! as Map;
    expect(state['beforeSnapshotId'], isNot(state['afterSnapshotId']));
    final viewport = delta['viewport']! as Map;
    expect(viewport['changed'], isTrue);
    expect((viewport['before']! as Map)['orientation'], 'portrait');
    expect((viewport['after']! as Map)['orientation'], 'landscape');
    final keyboard = delta['keyboard']! as Map;
    expect(keyboard['changed'], isTrue);
    expect((keyboard['before']! as Map)['visible'], isTrue);
    expect((keyboard['after']! as Map)['visible'], isFalse);
    expect(delta['runtimeSignals'], isA<Map>());
    expect(delta['scroll'], isA<Map>());
  });
}
