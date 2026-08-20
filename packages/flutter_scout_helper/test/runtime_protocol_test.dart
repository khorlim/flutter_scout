import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, String> mutationEnvelope(
    FlutterScoutRuntime runtime, {
    required int generation,
    required String commandId,
    required String idempotencyKey,
    String runId = 'run-a',
    String? runtimeInstanceId,
    int? deadlineEpochMs,
    int clientProtocolMin = 15,
    int clientProtocolMax = 15,
  }) {
    return {
      'schemaVersion': '1',
      'clientProtocolMin': '$clientProtocolMin',
      'clientProtocolMax': '$clientProtocolMax',
      'commandId': commandId,
      'idempotencyKey': idempotencyKey,
      'runId': runId,
      'runtimeInstanceId': runtimeInstanceId ?? runtime.debugRuntimeInstanceId,
      'expectedStateGeneration': '$generation',
      'deadlineEpochMs':
          '${deadlineEpochMs ?? DateTime.now().add(const Duration(minutes: 1)).millisecondsSinceEpoch}',
    };
  }

  String errorCode(Map<String, Object?> response) {
    final error = response['structuredError'] as Map<String, Object?>;
    return error['code']! as String;
  }

  testWidgets(
    'state generation is stable for unchanged canonical state and advances on change',
    (tester) async {
      final runtime = FlutterScoutRuntime();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('state one'))),
      );
      await tester.pump();

      final first = runtime.debugSnapshot();
      final unchanged = runtime.debugSnapshot();
      expect(first.stateGeneration, greaterThan(0));
      expect(unchanged.stateGeneration, first.stateGeneration);
      expect(unchanged.stateDigest, first.stateDigest);
      expect(first.stateDigest, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(
        first.snapshotId,
        'g${first.stateGeneration}:${first.stateDigest}',
      );

      final full = runtime.debugInspectPayload();
      final brief = runtime.debugInspectPayload(brief: true);
      for (final payload in [full, brief, first.summaryJson()]) {
        expect(payload['stateGeneration'], first.stateGeneration);
        expect(payload['stateDigest'], first.stateDigest);
        expect(payload['snapshotId'], first.snapshotId);
      }

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('state two'))),
      );
      await tester.pump();
      final changed = runtime.debugSnapshot();
      expect(changed.stateGeneration, greaterThan(first.stateGeneration));
      expect(changed.stateDigest, isNot(first.stateDigest));
      expect(changed.stateDigest, matches(RegExp(r'^[a-f0-9]{64}$')));
    },
  );

  testWidgets(
    'strict mutation envelope abstains on missing incompatible stale run runtime and deadline inputs',
    (tester) async {
      final runtime = FlutterScoutRuntime();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('protocol fixture'))),
      );
      await tester.pump();
      var mutationCount = 0;
      Future<Map<String, Object?>> mutate() async {
        mutationCount += 1;
        return {'mutationCount': mutationCount};
      }

      final missing = await runtime.debugProtocolMutation({}, mutate);
      expect(errorCode(missing), 'missing_mutation_envelope');
      expect(mutationCount, 0);

      final generation = runtime.debugSnapshot().stateGeneration;
      for (final incompatibleVersion in const <int>[14, 16]) {
        final incompatible = await runtime.debugProtocolMutation(
          mutationEnvelope(
            runtime,
            generation: generation,
            commandId: 'incompatible-$incompatibleVersion',
            idempotencyKey: 'incompatible-$incompatibleVersion',
            clientProtocolMin: incompatibleVersion,
            clientProtocolMax: incompatibleVersion,
          ),
          mutate,
        );
        expect(
          errorCode(incompatible),
          'incompatible_protocol',
          reason: 'protocol $incompatibleVersion must fail before mutation',
        );
        expect(mutationCount, 0);
      }

      final stale = await runtime.debugProtocolMutation(
        mutationEnvelope(
          runtime,
          generation: generation - 1,
          commandId: 'stale',
          idempotencyKey: 'stale',
        ),
        mutate,
      );
      expect(errorCode(stale), 'stale_state_generation');
      expect(mutationCount, 0);

      final valid = await runtime.debugProtocolMutation(
        mutationEnvelope(
          runtime,
          generation: runtime.debugSnapshot().stateGeneration,
          commandId: 'valid',
          idempotencyKey: 'valid',
        ),
        mutate,
      );
      expect(valid['ok'], isTrue);
      expect(mutationCount, 1);

      final runMismatch = await runtime.debugProtocolMutation(
        mutationEnvelope(
          runtime,
          generation: runtime.debugSnapshot().stateGeneration,
          commandId: 'wrong-run',
          idempotencyKey: 'wrong-run',
          runId: 'run-b',
        ),
        mutate,
      );
      expect(errorCode(runMismatch), 'run_mismatch');

      final runtimeMismatch = await runtime.debugProtocolMutation(
        mutationEnvelope(
          runtime,
          generation: runtime.debugSnapshot().stateGeneration,
          commandId: 'wrong-runtime',
          idempotencyKey: 'wrong-runtime',
          runtimeInstanceId: 'other-runtime',
        ),
        mutate,
      );
      expect(errorCode(runtimeMismatch), 'runtime_instance_mismatch');

      final expired = await runtime.debugProtocolMutation(
        mutationEnvelope(
          runtime,
          generation: runtime.debugSnapshot().stateGeneration,
          commandId: 'expired',
          idempotencyKey: 'expired',
          deadlineEpochMs: DateTime.now()
              .subtract(const Duration(seconds: 1))
              .millisecondsSinceEpoch,
        ),
        mutate,
      );
      expect(errorCode(expired), 'mutation_deadline_expired');
      expect(mutationCount, 1, reason: 'every rejected request must abstain');
    },
  );

  testWidgets(
    'mutations serialize and duplicate requests execute exactly once',
    (tester) async {
      final runtime = FlutterScoutRuntime();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('serialization fixture'))),
      );
      await tester.pump();
      await tester.runAsync(() async {
        final generation = runtime.debugSnapshot().stateGeneration;
        final firstStarted = Completer<void>();
        final releaseFirst = Completer<void>();
        final order = <String>[];

        final first = runtime.debugProtocolMutation(
          mutationEnvelope(
            runtime,
            generation: generation,
            commandId: 'first',
            idempotencyKey: 'first',
          ),
          () async {
            order.add('first-start');
            firstStarted.complete();
            await releaseFirst.future;
            order.add('first-end');
            return {'which': 'first'};
          },
        );
        await Future.any<void>([
          firstStarted.future,
          first.then<void>((response) {
            fail('first mutation abstained before callback: $response');
          }),
        ]);
        final second = runtime.debugProtocolMutation(
          mutationEnvelope(
            runtime,
            generation: generation,
            commandId: 'second',
            idempotencyKey: 'second',
          ),
          () async {
            order.add('second-start');
            return {'which': 'second'};
          },
        );
        await Future<void>.delayed(Duration.zero);
        expect(order, ['first-start']);
        releaseFirst.complete();
        await Future.wait([first, second]);
        expect(order, ['first-start', 'first-end', 'second-start']);

        var duplicateCount = 0;
        final duplicateGate = Completer<void>();
        final duplicateParams = mutationEnvelope(
          runtime,
          generation: runtime.debugSnapshot().stateGeneration,
          commandId: 'duplicate',
          idempotencyKey: 'duplicate',
        );
        final original = runtime.debugProtocolMutation(
          duplicateParams,
          () async {
            duplicateCount += 1;
            await duplicateGate.future;
            return {'duplicateCount': duplicateCount};
          },
        );
        final retry = runtime.debugProtocolMutation(duplicateParams, () async {
          duplicateCount += 100;
          return {'duplicateCount': duplicateCount};
        });
        duplicateGate.complete();
        final duplicateResponses = await Future.wait([original, retry]);
        expect(duplicateCount, 1);
        expect(duplicateResponses[1], duplicateResponses[0]);

        final volatileRetry = await runtime.debugProtocolMutation(
          {
            ...duplicateParams,
            'commandId': 'duplicate-retry-command',
            'expectedStateGeneration': '999999',
            'deadlineEpochMs': '${DateTime.now().millisecondsSinceEpoch + 1}',
            'errorCursor': '4242',
          },
          () async {
            duplicateCount += 1000;
            return {'duplicateCount': duplicateCount};
          },
        );
        expect(volatileRetry, duplicateResponses.first);
        expect(duplicateCount, 1);

        final conflict = await runtime.debugProtocolMutation(
          {...duplicateParams, 'value': 'different'},
          () async {
            duplicateCount += 1;
            return {'duplicateCount': duplicateCount};
          },
        );
        expect(errorCode(conflict), 'idempotency_conflict');
        expect(duplicateCount, 1);

        for (final identityChange in <Map<String, String>>[
          {'runId': 'different-run'},
          {'runtimeInstanceId': 'different-runtime'},
        ]) {
          final identityConflict = await runtime.debugProtocolMutation(
            {...duplicateParams, ...identityChange},
            () async {
              duplicateCount += 1;
              return {'duplicateCount': duplicateCount};
            },
          );
          expect(errorCode(identityConflict), 'idempotency_conflict');
        }
        expect(duplicateCount, 1);
      });
    },
  );

  testWidgets(
    'bounded completed outcomes leave exact tombstones and never redispatch',
    (tester) async {
      final runtime = FlutterScoutRuntime();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('bounded registry'))),
      );
      await tester.pump();

      var dispatches = 0;
      for (var index = 0; index <= 256; index++) {
        final response = await runtime.debugProtocolMutation(
          {
            ...mutationEnvelope(
              runtime,
              generation: runtime.debugSnapshot().stateGeneration,
              commandId: 'bounded-$index',
              idempotencyKey: 'bounded-$index',
            ),
            'businessValue': 'value-$index',
          },
          () async {
            dispatches += 1;
            return {'index': index};
          },
        );
        expect(response['ok'], isTrue, reason: 'index=$index');
      }
      expect(dispatches, 257);

      final prunedRetry = await runtime.debugProtocolMutation(
        {
          ...mutationEnvelope(
            runtime,
            generation: runtime.debugSnapshot().stateGeneration,
            commandId: 'bounded-0-retry',
            idempotencyKey: 'bounded-0',
          ),
          'businessValue': 'value-0',
        },
        () async {
          dispatches += 1000;
          return {'unexpected': true};
        },
      );
      expect(errorCode(prunedRetry), 'idempotency_outcome_pruned');
      expect(dispatches, 257);

      final conflict = await runtime.debugProtocolMutation(
        {
          ...mutationEnvelope(
            runtime,
            generation: runtime.debugSnapshot().stateGeneration,
            commandId: 'bounded-0-conflict',
            idempotencyKey: 'bounded-0',
          ),
          'businessValue': 'changed',
        },
        () async {
          dispatches += 1000;
          return {'unexpected': true};
        },
      );
      expect(errorCode(conflict), 'idempotency_conflict');
      expect(dispatches, 257);
    },
  );

  testWidgets('held drag excludes unrelated protocol mutations', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.expand())),
    );
    await tester.pump();

    runtime.debugSetHeldDragGate(true);
    try {
      var mutationCount = 0;
      final response = await runtime.debugProtocolMutation(
        mutationEnvelope(
          runtime,
          generation: runtime.debugSnapshot().stateGeneration,
          commandId: 'unrelated',
          idempotencyKey: 'unrelated',
        ),
        () async {
          mutationCount += 1;
          return {'mutationCount': mutationCount};
        },
      );
      expect(errorCode(response), 'held_drag_active');
      expect(mutationCount, 0);
      expect(runtime.debugHeldDragActive, isTrue);
    } finally {
      runtime.debugSetHeldDragGate(false);
      expect(runtime.debugHeldDragActive, isFalse);
    }

    runtime.debugSetHeldDragGate(true);
    final expired = await runtime.debugProtocolMutation(
      mutationEnvelope(
        runtime,
        generation: runtime.debugSnapshot().stateGeneration,
        commandId: 'expired-drag',
        idempotencyKey: 'expired-drag',
        deadlineEpochMs: DateTime.now()
            .subtract(const Duration(seconds: 1))
            .millisecondsSinceEpoch,
      )..['by'] = '1,1',
      () => {'unexpected': true},
      method: 'ext.flutter_scout.dragMove',
    );
    expect(errorCode(expired), 'mutation_deadline_expired');
    expect(runtime.debugHeldDragActive, isFalse);

    runtime.debugSetHeldDragGate(true);
    final fault = await runtime.debugProtocolMutation(
      mutationEnvelope(
        runtime,
        generation: runtime.debugSnapshot().stateGeneration,
        commandId: 'faulted-drag',
        idempotencyKey: 'faulted-drag',
      )..['by'] = '1,1',
      () => throw StateError('injected drag fault'),
      method: 'ext.flutter_scout.dragMove',
    );
    expect(errorCode(fault), 'mutation_dispatch_failed');
    expect(runtime.debugHeldDragActive, isFalse);
  });

  testWidgets(
    'runtime errors have monotonic cursors and fresh dedupe identities',
    (tester) async {
      final runtime = FlutterScoutRuntime();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('error fixture'))),
      );
      await tester.pump();

      runtime.debugRecordError('first fault');
      final cursor = runtime.debugErrorCursor;
      runtime.debugRecordError('repeated fault');
      runtime.debugRecordError('repeated fault');
      final response = await runtime.debugProtocolRead({
        'commandId': 'read-errors',
        'errorCursor': '$cursor',
        'runId': 'run-a',
      });

      expect(response['schemaVersion'], 1);
      expect(response['protocolVersion'], 15);
      expect(response['minSupportedProtocolVersion'], 15);
      expect(response['maxSupportedProtocolVersion'], 15);
      expect(response['commandId'], 'read-errors');
      expect(response['runtimeInstanceId'], runtime.debugRuntimeInstanceId);
      expect(response['stateGeneration'], greaterThan(0));
      expect(response['timings'], isA<Map<String, Object?>>());
      expect(
        response['capabilities'],
        containsPair('runtimeErrorCursor', true),
      );
      expect(response['errorCursor'], cursor + 2);

      final fresh = (response['errorsSinceCursor']! as List).cast<Map>();
      final legacyFresh = (response['recentErrors']! as List).cast<Map>();
      expect(fresh, hasLength(2));
      expect(legacyFresh, hasLength(2));
      expect(fresh.map((error) => error['cursor']), [cursor + 1, cursor + 2]);
      expect(fresh[0]['identity'], fresh[1]['identity']);
      expect(fresh[0]['identity'], matches(RegExp(r'^[a-f0-9]{64}$')));

      final action = await runtime.debugProtocolMutation({
        ...mutationEnvelope(
          runtime,
          generation: runtime.debugSnapshot().stateGeneration,
          commandId: 'action-errors',
          idempotencyKey: 'action-errors',
        ),
        'errorCursor': '$cursor',
      }, () => {'action': 'noop'});
      expect((action['errorsSinceCursor']! as List), hasLength(2));
    },
  );

  test('mixed endpoints classify reads separately from mutations', () {
    final runtime = FlutterScoutRuntime();
    bool mutation(String endpoint, String action) =>
        runtime.debugIsMutationRequest('ext.flutter_scout.$endpoint', {
          'action': action,
        });

    expect(mutation('annotations', 'list'), isFalse);
    expect(mutation('annotations', 'targets'), isFalse);
    expect(mutation('annotations', 'get-crop'), isFalse);
    expect(mutation('annotations', 'mark-fixed'), isTrue);
    expect(mutation('record', 'status'), isFalse);
    expect(mutation('record', 'steps'), isFalse);
    expect(mutation('record', 'start'), isTrue);
    for (final read in [
      'inspect',
      'capture',
      'waitStable',
      'waitFor',
      'dragStatus',
    ]) {
      expect(
        runtime.debugIsMutationRequest('ext.flutter_scout.$read', const {}),
        isFalse,
      );
    }
  });
}
