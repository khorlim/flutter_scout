import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const maximumResponseBytes = 4 * 1024 * 1024;

  Map<String, String> mutationEnvelope(
    FlutterScoutRuntime runtime, {
    required int generation,
    required String commandId,
    required String idempotencyKey,
  }) => <String, String>{
    'schemaVersion': '1',
    'clientProtocolMin': '15',
    'clientProtocolMax': '15',
    'commandId': commandId,
    'idempotencyKey': idempotencyKey,
    'runId': 'run-a',
    'runtimeInstanceId': runtime.debugRuntimeInstanceId,
    'expectedStateGeneration': '$generation',
    'deadlineEpochMs':
        '${DateTime.now().add(const Duration(minutes: 1)).millisecondsSinceEpoch}',
  };

  String errorCode(Map<String, Object?> response) =>
      (response['structuredError']! as Map)['code']! as String;

  int encodedBytes(Map<String, Object?> response) =>
      utf8.encode(jsonEncode(response)).length;

  void expectClosedPhases(Map<String, Object?> response) {
    final timings = response['timings']! as Map;
    final phases = timings['phases']! as Map;
    expect(phases.keys.toSet(), <String>{
      'connect',
      'snapshot',
      'match',
      'dispatch',
      'settle',
      'delta',
      'logs',
      'serialize',
    });
    for (final value in phases.values) {
      expect(value, isA<Map>());
      expect((value as Map)['status'], anyOf('measured', 'unavailable'));
    }
  }

  void expectMeasuredHelperSerialize(Map<String, Object?> response) {
    final timings = response['timings']! as Map;
    final phases = timings['phases']! as Map;
    final serialize = phases['serialize']! as Map;
    expect(serialize['status'], 'measured');
    expect(serialize['elapsedMs'], greaterThanOrEqualTo(0));
    expect(serialize['owner'], 'helper');
    expect(serialize['scope'], 'first_canonical_vm_response_encode_probe');
    expect(serialize['clock'], 'monotonic_stopwatch');
    expect(serialize['aggregation'], 'exclusive_non_overlapping');
  }

  testWidgets('every typed method rejects unknown parameters before dispatch', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('strict params fixture'))),
    );
    await tester.pump();

    const reads = <String>{
      'inspect',
      'capture',
      'dragStatus',
      'waitFor',
      'waitStable',
    };
    const mutations = <String>{
      'annotations',
      'back',
      'dismiss',
      'dragCancel',
      'dragEnd',
      'dragMove',
      'dragStart',
      'fill',
      'input',
      'longPress',
      'record',
      'reveal',
      'scroll',
      'scrollTo',
      'swipe',
      'tap',
      'tapText',
    };
    var mutationCount = 0;
    for (final command in reads) {
      final response = await runtime.debugProtocolRead(<String, String>{
        'schemaVersion': '1',
        'clientProtocolMin': '15',
        'clientProtocolMax': '15',
        'commandId': 'unknown-read-$command',
        'runId': 'run-a',
        'unexpected_${command}_parameter': 'must be rejected',
      }, method: 'ext.flutter_scout.$command');
      expect(errorCode(response), 'unknown_parameter', reason: command);
      expect(response['result'], isNull, reason: command);
      expectClosedPhases(response);
    }
    for (final command in mutations) {
      final response = await runtime.debugProtocolMutation(
        <String, String>{
          ...mutationEnvelope(
            runtime,
            generation: runtime.debugSnapshot().stateGeneration,
            commandId: 'unknown-mutation-$command',
            idempotencyKey: 'unknown-mutation-$command',
          ),
          'unexpected_${command}_parameter': 'must be rejected',
        },
        () async {
          mutationCount += 1;
          return <String, Object?>{'unexpected': true};
        },
        method: 'ext.flutter_scout.$command',
      );
      expect(errorCode(response), 'unknown_parameter', reason: command);
      expect(response['dispatch'], 'not_dispatched', reason: command);
      expect(
        (response['activation']! as Map)['dispatched'],
        isFalse,
        reason: command,
      );
      expectClosedPhases(response);
    }
    expect(mutationCount, 0);

    final unsupported = await runtime.debugProtocolRead(const <String, String>{
      'schemaVersion': '1',
      'clientProtocolMin': '15',
      'clientProtocolMax': '15',
      'commandId': 'unsupported',
      'runId': 'run-a',
    }, method: 'ext.flutter_scout.notRegistered');
    expect(errorCode(unsupported), 'unsupported_method');
  });

  testWidgets('only explicitly documented protocol-15 aliases remain valid', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('alias fixture'))),
    );
    await tester.pump();

    final read = await runtime.debugProtocolRead(const <String, String>{
      'schemaVersion': '1',
      'clientProtocolMin': '15',
      'clientProtocolMax': '15',
      'commandId': 'legacy-cursor',
      'runId': 'run-a',
      'errorsSinceCursor': '0',
    }, method: 'ext.flutter_scout.inspect');
    expect(read['ok'], isTrue);

    var mutationCount = 0;
    final targetAlias = await runtime.debugProtocolMutation(
      <String, String>{
        ...mutationEnvelope(
          runtime,
          generation: runtime.debugSnapshot().stateGeneration,
          commandId: 'legacy-target',
          idempotencyKey: 'legacy-target',
        ),
        'target': 'Save',
      },
      () async {
        mutationCount += 1;
        return const <String, Object?>{
          'activation': {'dispatched': true},
        };
      },
      method: 'ext.flutter_scout.tapText',
    );
    expect(targetAlias['ok'], isTrue);
    expect(mutationCount, 1);

    final undocumented = await runtime.debugProtocolRead(const <String, String>{
      'schemaVersion': '1',
      'clientProtocolMin': '15',
      'clientProtocolMax': '15',
      'commandId': 'undocumented-alias',
      'runId': 'run-a',
      'protocol': '15',
    }, method: 'ext.flutter_scout.inspect');
    expect(errorCode(undocumented), 'unknown_parameter');

    const sensitiveUnknownName = 'private_token_value_that_must_not_echo';
    final sensitiveUnknown = await runtime
        .debugProtocolRead(const <String, String>{
          'schemaVersion': '1',
          'clientProtocolMin': '15',
          'clientProtocolMax': '15',
          'commandId': 'sensitive-unknown-name',
          'runId': 'run-a',
          sensitiveUnknownName: 'ignored',
        }, method: 'ext.flutter_scout.inspect');
    expect(errorCode(sensitiveUnknown), 'unknown_parameter');
    expect(jsonEncode(sensitiveUnknown), isNot(contains(sensitiveUnknownName)));
    expect(
      ((sensitiveUnknown['structuredError']! as Map)['details']!
          as Map)['unknownParameterDisclosure'],
      'omitted_untrusted_input',
    );
  });

  testWidgets('accepts the VM service isolate routing parameter', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('transport fixture'))),
    );
    await tester.pump();

    final response = await runtime.debugProtocolRead(const <String, String>{
      'schemaVersion': '1',
      'clientProtocolMin': '15',
      'clientProtocolMax': '15',
      'commandId': 'vm-transport-read',
      'runId': 'run-a',
      'isolateId': 'isolates/123456789',
    }, method: 'ext.flutter_scout.inspect');

    expect(response['ok'], isTrue);
    expect(response['structuredError'], isNull);
  });

  testWidgets(
    'pre-handler request bounds reject huge keys and business values',
    (tester) async {
      final runtime = FlutterScoutRuntime();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('request bounds fixture'))),
      );
      await tester.pump();
      var mutationCount = 0;

      final hugeKey = 'k' * (2 * 1024 * 1024);
      final hugeKeyResponse = await runtime.debugProtocolMutation(
        <String, String>{
          ...mutationEnvelope(
            runtime,
            generation: runtime.debugSnapshot().stateGeneration,
            commandId: 'huge-key',
            idempotencyKey: hugeKey,
          ),
          'target': 'btn.safe',
        },
        () async {
          mutationCount += 1;
          return const <String, Object?>{'unexpected': true};
        },
        method: 'ext.flutter_scout.tap',
      );
      expect(errorCode(hugeKeyResponse), 'invalid_idempotency_key');
      expect(hugeKeyResponse['dispatch'], 'not_dispatched');
      expect((hugeKeyResponse['activation']! as Map)['dispatched'], isFalse);
      expect(hugeKeyResponse['rawIdempotencyKeyRetained'], isFalse);
      expect(hugeKeyResponse['idempotencyKeyStatus'], 'invalid_omitted');
      expect(hugeKeyResponse['idempotencyKeyDigest'], isNull);
      expect(jsonEncode(hugeKeyResponse), isNot(contains('k' * 256)));
      expect(mutationCount, 0);

      final hugeBusinessParams = <String, String>{
        ...mutationEnvelope(
          runtime,
          generation: runtime.debugSnapshot().stateGeneration,
          commandId: 'huge-business',
          idempotencyKey: 'huge-business-key',
        ),
        'target': 'b' * (2 * 1024 * 1024),
      };
      final hugeBusinessResponse = await runtime.debugProtocolMutation(
        hugeBusinessParams,
        () async {
          mutationCount += 1;
          return const <String, Object?>{'unexpected': true};
        },
        method: 'ext.flutter_scout.tap',
      );
      expect(errorCode(hugeBusinessResponse), 'request_parameter_too_large');
      expect(hugeBusinessResponse['dispatch'], 'not_dispatched');
      expect(
        (hugeBusinessResponse['activation']! as Map)['dispatched'],
        isFalse,
      );
      expect(mutationCount, 0);

      final safeRetry = await runtime.debugProtocolMutation(
        <String, String>{...hugeBusinessParams, 'target': 'btn.safe'},
        () async {
          mutationCount += 1;
          return const <String, Object?>{
            'activation': <String, Object?>{'dispatched': true},
          };
        },
        method: 'ext.flutter_scout.tap',
      );
      expect(safeRetry['ok'], isTrue);
      expect(mutationCount, 1);

      final documentedBulkValue = await runtime.debugProtocolMutation(
        <String, String>{
          ...mutationEnvelope(
            runtime,
            generation: runtime.debugSnapshot().stateGeneration,
            commandId: 'bulk-input',
            idempotencyKey: 'bulk-input',
          ),
          'target': 'field.notes',
          'value': 'v' * (70 * 1024),
        },
        () async {
          mutationCount += 1;
          return const <String, Object?>{
            'activation': <String, Object?>{'dispatched': true},
          };
        },
        method: 'ext.flutter_scout.input',
      );
      expect(documentedBulkValue['ok'], isTrue);
      expect(mutationCount, 2);
    },
  );

  testWidgets('idempotency failures expose only a digest of caller keys', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('idempotency fixture'))),
    );
    await tester.pump();
    const callerKey = 'caller-secret-key-1234';
    final params = <String, String>{
      ...mutationEnvelope(
        runtime,
        generation: runtime.debugSnapshot().stateGeneration,
        commandId: 'first-key-use',
        idempotencyKey: callerKey,
      ),
      'business': 'first',
    };
    final first = await runtime.debugProtocolMutation(
      params,
      () async => const <String, Object?>{
        'activation': <String, Object?>{'dispatched': true},
      },
    );
    expect(first['ok'], isTrue);

    final conflict = await runtime.debugProtocolMutation(<String, String>{
      ...params,
      'commandId': 'conflicting-key-use',
      'business': 'different',
    }, () async => const <String, Object?>{'unexpected': true});
    expect(errorCode(conflict), 'idempotency_conflict');
    expect(jsonEncode(conflict), isNot(contains(callerKey)));
    expect(
      conflict['idempotencyKeyDigest'],
      matches(RegExp(r'^[a-f0-9]{64}$')),
    );
    expect(conflict['rawIdempotencyKeyRetained'], isFalse);
  });

  test('machine-readable helper method allowlist matches the runtime', () {
    final runtime = FlutterScoutRuntime();
    final contract = runtime.debugProtocolParameterContract();
    final file = File(
      '${Directory.current.path}/../../protocol/schemas/v1/helper-methods.json',
    );
    final published =
        jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    expect(
      published['maximumEncodedResponseBytes'],
      contract['maximumEncodedResponseBytes'],
    );
    expect(published['maximumPayloadDepth'], contract['maximumPayloadDepth']);
    expect(published['maximumPayloadNodes'], contract['maximumPayloadNodes']);
    expect(published['requestLimits'], contract['requestLimits']);
    expect(
      published['commonEnvelopeParameters'],
      contract['commonEnvelopeParameters'],
    );
    final publishedMethods = published['methods']! as Map;
    final runtimeMethods = contract['methods']! as Map;
    expect(publishedMethods.keys.toSet(), runtimeMethods.keys.toSet());
    for (final method in publishedMethods.keys) {
      expect(
        publishedMethods[method],
        runtimeMethods[method],
        reason: '$method parameter contract drifted',
      );
    }
  });

  testWidgets(
    'phase timings close all eight states for direct reads and early failures',
    (tester) async {
      final runtime = FlutterScoutRuntime();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('timing fixture'))),
      );
      await tester.pump();

      final direct = await runtime.debugInspect();
      expectClosedPhases(direct);
      final directPhases = (direct['timings']! as Map)['phases']! as Map;
      for (final phase in directPhases.values.cast<Map>()) {
        expect(phase['status'], 'unavailable');
        expect(phase['reason'], 'request_timing_context_unavailable');
      }

      final rejected = await runtime.debugProtocolRead(const <String, String>{
        'schemaVersion': '1',
        'clientProtocolMin': '15',
        'clientProtocolMax': '15',
        'commandId': 'early-read-failure',
        'runId': 'run-a',
        'unknown': 'rejected',
      }, method: 'ext.flutter_scout.inspect');
      expect(errorCode(rejected), 'unknown_parameter');
      expectClosedPhases(rejected);
      final phases = (rejected['timings']! as Map)['phases']! as Map;
      expect((phases['snapshot']! as Map)['status'], 'measured');
      for (final name in const <String>[
        'match',
        'dispatch',
        'settle',
        'delta',
      ]) {
        expect((phases[name]! as Map)['status'], 'unavailable');
        expect(
          (phases[name]! as Map)['reason'],
          'not_applicable_for_read:inspect',
        );
      }
      for (final name in const <String>['connect', 'logs']) {
        expect((phases[name]! as Map)['reason'], 'measured_at_cli_boundary');
      }
      expectMeasuredHelperSerialize(rejected);
    },
  );

  testWidgets('one real protocol action measures every helper-owned phase', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ElevatedButton(
            key: const ValueKey<String>('measure_phases'),
            onPressed: () => taps += 1,
            child: const Text('Measure phases'),
          ),
        ),
      ),
    );
    await tester.pump();

    final generation = runtime.debugSnapshot().stateGeneration;
    final response = (await tester.runAsync(
      () => runtime.debugProtocolMutation(
        mutationEnvelope(
          runtime,
          generation: generation,
          commandId: 'measured-action',
          idempotencyKey: 'measured-action',
        ),
        () => runtime.debugTapTarget('btn.measure_phases'),
      ),
    ))!;
    expect(response['ok'], isTrue);
    expect(taps, 1);
    expectClosedPhases(response);
    final phases = (response['timings']! as Map)['phases']! as Map;
    for (final name in const <String>[
      'snapshot',
      'match',
      'dispatch',
      'settle',
      'delta',
    ]) {
      expect((phases[name]! as Map)['status'], 'measured', reason: name);
      expect(
        (phases[name]! as Map)['elapsedMs'],
        greaterThanOrEqualTo(0),
        reason: name,
      );
    }
    expectMeasuredHelperSerialize(response);
  });

  testWidgets(
    'mixed annotation and recorder reads never masquerade as writes',
    (tester) async {
      final runtime = FlutterScoutRuntime();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('mixed timing fixture'))),
      );
      await tester.pump();

      const readEnvelope = <String, String>{
        'schemaVersion': '1',
        'clientProtocolMin': '15',
        'clientProtocolMax': '15',
        'commandId': 'annotation-read',
        'runId': 'run-a',
        'action': 'list',
      };
      final annotationRead = await runtime.debugProtocolAnnotations(
        readEnvelope,
      );
      expect(annotationRead['ok'], isTrue);
      final annotationReadPhases =
          (annotationRead['timings']! as Map)['phases']! as Map;
      expect((annotationReadPhases['snapshot'] as Map)['status'], 'measured');
      for (final name in const <String>[
        'match',
        'dispatch',
        'settle',
        'delta',
      ]) {
        expect((annotationReadPhases[name] as Map)['status'], 'unavailable');
        expect(
          (annotationReadPhases[name] as Map)['reason'],
          'not_applicable_for_read:annotations',
        );
      }

      final annotationGeneration = runtime.debugSnapshot().stateGeneration;
      final annotationWrite = (await tester.runAsync(
        () => runtime.debugProtocolAnnotations(<String, String>{
          ...mutationEnvelope(
            runtime,
            generation: annotationGeneration,
            commandId: 'annotation-enable',
            idempotencyKey: 'annotation-enable',
          ),
          'action': 'enable',
        }),
      ))!;
      expect(annotationWrite['ok'], isTrue);
      final annotationWritePhases =
          (annotationWrite['timings']! as Map)['phases']! as Map;
      expect((annotationWritePhases['dispatch'] as Map)['status'], 'measured');
      expect((annotationWritePhases['settle'] as Map)['status'], 'measured');
      expect((annotationWritePhases['delta'] as Map)['status'], 'measured');
      expect((annotationWritePhases['snapshot'] as Map)['status'], 'measured');
      expect(
        (annotationWritePhases['match'] as Map)['reason'],
        'not_applicable:annotation_tool_state_mutation_has_no_widget_selector',
      );

      final recordRead = await runtime
          .debugProtocolRecord(const <String, String>{
            'schemaVersion': '1',
            'clientProtocolMin': '15',
            'clientProtocolMax': '15',
            'commandId': 'record-read',
            'runId': 'run-a',
            'action': 'status',
          });
      final recordReadPhases =
          (recordRead['timings']! as Map)['phases']! as Map;
      expect((recordReadPhases['snapshot'] as Map)['status'], 'measured');
      for (final name in const <String>[
        'match',
        'dispatch',
        'settle',
        'delta',
      ]) {
        expect((recordReadPhases[name] as Map)['status'], 'unavailable');
        expect(
          (recordReadPhases[name] as Map)['reason'],
          'not_applicable_for_read:record',
        );
      }

      final recordGeneration = runtime.debugSnapshot().stateGeneration;
      final recordStart = (await tester.runAsync(
        () => runtime.debugProtocolRecord(<String, String>{
          ...mutationEnvelope(
            runtime,
            generation: recordGeneration,
            commandId: 'record-start',
            idempotencyKey: 'record-start',
          ),
          'action': 'start',
          'name': 'timing-test',
        }),
      ))!;
      expect(recordStart['ok'], isTrue);
      final recordStartPhases =
          (recordStart['timings']! as Map)['phases']! as Map;
      for (final name in const <String>[
        'snapshot',
        'dispatch',
        'settle',
        'delta',
      ]) {
        expect((recordStartPhases[name] as Map)['status'], 'measured');
      }
      expect(
        (recordStartPhases['match'] as Map)['reason'],
        'not_applicable:recording_tool_state_mutation_has_no_widget_selector',
      );
      expectMeasuredHelperSerialize(recordStart);

      final stopGeneration = runtime.debugSnapshot().stateGeneration;
      final recordStop = (await tester.runAsync(
        () => runtime.debugProtocolRecord(<String, String>{
          ...mutationEnvelope(
            runtime,
            generation: stopGeneration,
            commandId: 'record-stop',
            idempotencyKey: 'record-stop',
          ),
          'action': 'stop',
          'discard': 'true',
        }),
      ))!;
      expect(recordStop['ok'], isTrue);
      final recordStopPhases =
          (recordStop['timings']! as Map)['phases']! as Map;
      for (final name in const <String>[
        'snapshot',
        'dispatch',
        'settle',
        'delta',
      ]) {
        expect((recordStopPhases[name] as Map)['status'], 'measured');
      }
      expectMeasuredHelperSerialize(recordStop);
    },
  );

  testWidgets(
    'oversized success fails closed without losing late blocking evidence',
    (tester) async {
      final runtime = FlutterScoutRuntime();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('large payload fixture'))),
      );
      await tester.pump();
      final beforeCursor = runtime.debugErrorCursor;
      final expectedGeneration = runtime.debugSnapshot().stateGeneration;
      const rawIdempotencyKey = 'caller-private-oversized-key';
      final response = await runtime.debugProtocolMutation(
        <String, String>{
          ...mutationEnvelope(
            runtime,
            generation: expectedGeneration,
            commandId: 'oversized-success',
            idempotencyKey: rawIdempotencyKey,
          ),
          'errorCursor': '$beforeCursor',
        },
        () async {
          runtime.debugRecordError(
            'Failed assertion: critical signal recorded after dispatch',
          );
          return <String, Object?>{
            'padding': 'x' * (maximumResponseBytes + 4096),
            'activation': const <String, Object?>{'dispatched': true},
            'criticalEvidenceAtEnd': const <String, Object?>{
              'observation': 'unavailable_without_bounded_response',
            },
          };
        },
      );

      expect(errorCode(response), 'response_payload_too_large');
      expect(response['ok'], isFalse);
      expect(response['result'], isNull);
      expect(response['resultStatus'], 'omitted_due_to_response_bound');
      expect(response['dispatch'], 'dispatched');
      expect(response['observation'], 'observation_unavailable');
      expect(response['runtimeInstanceId'], runtime.debugRuntimeInstanceId);
      expect(response['stateGeneration'], isA<int>());
      expect(response['expectedStateGeneration'], expectedGeneration);
      expect(response['deadlineEpochMs'], isA<int>());
      expect(
        response['idempotencyKeyDigest'],
        matches(RegExp(r'^[a-f0-9]{64}$')),
      );
      expect(response['rawIdempotencyKeyRetained'], isFalse);
      expect(jsonEncode(response), isNot(contains(rawIdempotencyKey)));
      expect(response['runtimeHealth'], 'runtime_blocked');
      expect(response['errorCursor'], greaterThan(beforeCursor));
      final signals = (response['errorsSinceCursor']! as List).cast<Map>();
      expect(signals, isNotEmpty);
      expect(signals.any((signal) => signal['blocking'] == true), isTrue);
      expect(
        signals.any((signal) => signal['diagnosticOmitted'] == true),
        isTrue,
      );
      expect(encodedBytes(response), lessThanOrEqualTo(maximumResponseBytes));
      expectClosedPhases(response);
      expectMeasuredHelperSerialize(response);
    },
  );

  testWidgets(
    'active non-blocking warnings never masquerade as blocking signals',
    (tester) async {
      final runtime = FlutterScoutRuntime();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('warning fixture'))),
      );
      await tester.pump();
      final beforeCursor = runtime.debugErrorCursor;
      final expectedGeneration = runtime.debugSnapshot().stateGeneration;

      final response = await runtime.debugProtocolMutation(
        <String, String>{
          ...mutationEnvelope(
            runtime,
            generation: expectedGeneration,
            commandId: 'active-warning',
            idempotencyKey: 'active-warning',
          ),
          'errorCursor': '$beforeCursor',
          'target': 'warning fixture',
        },
        () async {
          runtime.debugRecordActiveWarning(
            'SocketException: a recoverable network warning',
          );
          return <String, Object?>{
            'payload': 'w' * (maximumResponseBytes + 4096),
            'activation': const <String, Object?>{'dispatched': true},
            'stateGeneration': expectedGeneration,
          };
        },
        method: 'ext.flutter_scout.tap',
      );

      expect(errorCode(response), 'response_payload_too_large');
      expect(response['runtimeHealth'], 'runtime_health_unknown');
      final active = (response['activeRuntimeSignals']! as List).cast<Map>();
      expect(active, isNotEmpty);
      expect(active.every((signal) => signal['active'] == true), isTrue);
      expect(active.every((signal) => signal['blocking'] == false), isTrue);
      expect(response['activeBlockingSignals'], isEmpty);
    },
  );

  testWidgets(
    'deep and cyclic results fail closed without recursive overflow',
    (tester) async {
      final runtime = FlutterScoutRuntime();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('depth fixture'))),
      );
      await tester.pump();

      Object? deep = 'leaf';
      for (var index = 0; index < 96; index += 1) {
        deep = <String, Object?>{'level': deep};
      }
      final deepResponse = await runtime.debugProtocolMutation(
        mutationEnvelope(
          runtime,
          generation: runtime.debugSnapshot().stateGeneration,
          commandId: 'deep',
          idempotencyKey: 'deep',
        ),
        () async => <String, Object?>{
          'activation': const <String, Object?>{'dispatched': true},
          'deep': deep,
        },
      );
      expect(errorCode(deepResponse), 'truncated_safety_evidence');
      expect(deepResponse['result'], isNull);
      expect(
        encodedBytes(deepResponse),
        lessThanOrEqualTo(maximumResponseBytes),
      );

      final cyclic = <String, Object?>{};
      cyclic['self'] = cyclic;
      final cyclicResponse = await runtime.debugProtocolMutation(
        mutationEnvelope(
          runtime,
          generation: runtime.debugSnapshot().stateGeneration,
          commandId: 'cyclic',
          idempotencyKey: 'cyclic',
        ),
        () async => cyclic,
      );
      expect(errorCode(cyclicResponse), 'truncated_safety_evidence');
      expect(cyclicResponse['result'], isNull);
      expect(
        encodedBytes(cyclicResponse),
        lessThanOrEqualTo(maximumResponseBytes),
      );
    },
  );

  testWidgets('oversized failure diagnostics use the same bounded circuit', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('failure fixture'))),
    );
    await tester.pump();

    final response = await runtime.debugProtocolMutation(
      mutationEnvelope(
        runtime,
        generation: runtime.debugSnapshot().stateGeneration,
        commandId: 'oversized-failure',
        idempotencyKey: 'oversized-failure',
      ),
      () async => throw StateError('y' * (maximumResponseBytes + 4096)),
    );
    expect(errorCode(response), 'response_payload_too_large');
    expect(response['dispatch'], 'dispatch_outcome_unknown');
    expect(response['result'], isNull);
    final details = response['structuredError']! as Map;
    expect(
      (details['details']! as Map)['originalErrorCode'],
      'mutation_dispatch_failed',
    );
    expect(
      (details['details']! as Map)['originalErrorMessageDigest'],
      matches(RegExp(r'^[a-f0-9]{64}$')),
    );
    expect(encodedBytes(response), lessThanOrEqualTo(maximumResponseBytes));
    expectClosedPhases(response);
    expectMeasuredHelperSerialize(response);
  });
}
