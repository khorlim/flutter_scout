import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:test/test.dart';

void main() {
  final schemaRoot = Directory('../../protocol/schemas/v1');

  test('published v1 protocol schemas are valid JSON with immutable ids', () {
    final files =
        schemaRoot
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.schema.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    expect(files, hasLength(8));
    for (final file in files) {
      final value = jsonDecode(file.readAsStringSync());
      expect(value, isA<Map<String, dynamic>>(), reason: file.path);
      final schema = value as Map<String, dynamic>;
      expect(
        schema[r'$schema'],
        'https://json-schema.org/draft/2020-12/schema',
      );
      expect(schema[r'$id'], contains('/protocol/schemas/v1/'));
    }
  });

  test('persistent method catalog and request enum cannot drift', () {
    final catalog =
        jsonDecode(
              File(
                '${schemaRoot.path}/persistent-methods.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final request =
        jsonDecode(
              File(
                '${schemaRoot.path}/persistent-call.schema.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final methods = (catalog['methods'] as Map<String, dynamic>).keys.toSet();
    expect(
      methods,
      containsAll(<String>{'drag-cancel', 'drag-status', 'dismiss'}),
    );
    final properties = request['properties'] as Map<String, dynamic>;
    final methodSchema = properties['method'] as Map<String, dynamic>;
    expect((methodSchema['enum'] as List<dynamic>).toSet(), methods);
  });

  test('persistent typed runtime contracts match the checked-in catalog', () {
    final catalog =
        jsonDecode(
              File(
                '${schemaRoot.path}/persistent-methods.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final published = catalog['methods'] as Map<String, dynamic>;
    final cli = FlutterScoutCli();
    final runtime = cli.debugPersistentTypedMethodContract();
    expect(runtime.keys, unorderedEquals(published.keys));

    for (final entry in runtime.entries) {
      final descriptor = entry.value! as Map<String, Object?>;
      final parameters = descriptor['parameters']! as Map<String, Object?>;
      expect(
        parameters.keys,
        unorderedEquals(
          (published[entry.key]! as List<dynamic>).cast<String>(),
        ),
        reason: entry.key,
      );
    }

    expect(
      cli.debugValidatePersistentTypedCall(<String, Object?>{
        'method': 'tap',
        'args': <String>['btn.save'],
        'params': <String, Object?>{'waitMs': 250},
      }),
      containsPair('valid', true),
    );
    expect(
      cli.debugValidatePersistentTypedCall(<String, Object?>{
        'method': 'tap',
        'args': <String>['btn.save'],
        'params': <String, Object?>{'waitMs': '250'},
      }),
      allOf(
        containsPair('valid', false),
        containsPair('errorCode', 'invalid_parameter_value'),
        containsPair('handlerEntered', false),
      ),
    );
    expect(
      cli.debugValidatePersistentTypedCall(<String, Object?>{
        'method': 'tap',
        'args': <String>['btn.save'],
        'params': <String, Object?>{'unsupported': true},
      }),
      allOf(
        containsPair('valid', false),
        containsPair('errorCode', 'unknown_parameter'),
        containsPair('handlerEntered', false),
      ),
    );
  });

  test('mutation contract requires every exactly-once identity field', () {
    final schema =
        jsonDecode(
              File(
                '${schemaRoot.path}/mutation-request.schema.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final properties = schema['properties'] as Map<String, dynamic>;
    final params = properties['params'] as Map<String, dynamic>;
    final required = (params['required'] as List<dynamic>).toSet();
    expect(
      required,
      containsAll(<String>{
        'commandId',
        'idempotencyKey',
        'runId',
        'runtimeInstanceId',
        'expectedStateGeneration',
        'deadlineEpochMs',
      }),
    );
  });

  test('mutation outcomes type durable idempotency reconciliation', () {
    final schema =
        jsonDecode(
              File(
                '${schemaRoot.path}/mutation-outcome.schema.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final properties = schema['properties'] as Map<String, dynamic>;
    expect(
      (properties['idempotencyKeyDigest'] as Map<String, dynamic>)['pattern'],
      r'^[a-f0-9]{64}$',
    );
    expect(
      (properties['expectedStateGeneration'] as Map<String, dynamic>)['type'],
      contains('null'),
    );
    final conditions = schema['allOf'] as List<dynamic>;
    final dispatchCondition = conditions.last as Map<String, dynamic>;
    final then = dispatchCondition['then'] as Map<String, dynamic>;
    expect(
      (then['required'] as List<dynamic>).toSet(),
      containsAll(<String>{'idempotencyKey', 'idempotencyKeyDigest'}),
    );
  });

  test('helper and CLI schemas publish the closed stability state set', () {
    const states = <String>{
      'stable',
      'transient',
      'continuous_animation',
      'never_settling',
      'runtime_lost',
      'observation_unavailable',
    };
    final helper =
        jsonDecode(
              File(
                '${schemaRoot.path}/response.schema.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final helperDefs = helper[r'$defs'] as Map<String, dynamic>;
    final helperStability = helperDefs['stability'] as Map<String, dynamic>;
    final helperProperties =
        helperStability['properties'] as Map<String, dynamic>;
    expect(
      (helperProperties['state'] as Map<String, dynamic>)['enum'],
      unorderedEquals(states),
    );

    final outcome =
        jsonDecode(
              File(
                '${schemaRoot.path}/mutation-outcome.schema.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final outcomeProperties = outcome['properties'] as Map<String, dynamic>;
    final outcomeStability =
        outcomeProperties['stability'] as Map<String, dynamic>;
    final stabilityProperties =
        outcomeStability['properties'] as Map<String, dynamic>;
    expect(
      (stabilityProperties['state'] as Map<String, dynamic>)['enum'],
      unorderedEquals(states),
    );
  });

  test('helper and mutation envelopes always type result and error slots', () {
    for (final name in const <String>[
      'response.schema.json',
      'mutation-outcome.schema.json',
      'navigation-response.schema.json',
    ]) {
      final schema =
          jsonDecode(File('${schemaRoot.path}/$name').readAsStringSync())
              as Map<String, dynamic>;
      final required = (schema['required'] as List<dynamic>).toSet();
      expect(required, containsAll(<String>{'result', 'structuredError'}));
      final properties = schema['properties'] as Map<String, dynamic>;
      expect(properties, contains('result'));
      expect(properties, contains('structuredError'));
    }
  });

  test('navigation schema types native crop coordinate-frame evidence', () {
    final schema =
        jsonDecode(
              File(
                '${schemaRoot.path}/navigation-response.schema.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final properties = schema['properties'] as Map<String, dynamic>;
    final frame = properties['coordinateFrame'] as Map<String, dynamic>;
    final frameProperties = frame['properties'] as Map<String, dynamic>;
    expect(
      frameProperties.keys,
      containsAll(<String>{
        'origin',
        'logicalViewport',
        'physicalViewport',
        'logicalToPhysicalScale',
        'viewMetricsAvailable',
        'provenance',
        'nativeImageContract',
      }),
    );
  });

  test('helper responses expose currently active blocking runtime signals', () {
    final schema =
        jsonDecode(
              File(
                '${schemaRoot.path}/response.schema.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(
      (schema['required'] as List<dynamic>).toSet(),
      contains('activeBlockingSignals'),
    );
    final properties = schema['properties'] as Map<String, dynamic>;
    expect(
      (properties['activeBlockingSignals'] as Map<String, dynamic>)['type'],
      'array',
    );
    final capabilities = properties['capabilities'] as Map<String, dynamic>;
    final capabilityProperties =
        capabilities['properties'] as Map<String, dynamic>;
    expect(
      (capabilityProperties['activeRuntimeSignalsV1']
          as Map<String, dynamic>)['const'],
      isTrue,
    );
  });

  test('changed-region capture publishes bounded identity and geometry', () {
    final helperCatalog =
        jsonDecode(
              File('${schemaRoot.path}/helper-methods.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final helperMethods = helperCatalog['methods'] as Map<String, dynamic>;
    final capture =
        helperMethods['ext.flutter_scout.capture'] as Map<String, dynamic>;
    expect(capture['operation'], 'read');
    expect(capture['parameters'], contains('since'));

    final persistentCatalog =
        jsonDecode(
              File(
                '${schemaRoot.path}/persistent-methods.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final persistentMethods =
        persistentCatalog['methods'] as Map<String, dynamic>;
    expect(persistentMethods['crop'], contains('changedSince'));

    final response =
        jsonDecode(
              File(
                '${schemaRoot.path}/response.schema.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final properties = response['properties'] as Map<String, dynamic>;
    final capabilities = properties['capabilities'] as Map<String, dynamic>;
    final capabilityProperties =
        capabilities['properties'] as Map<String, dynamic>;
    expect(
      (capabilityProperties['changedRegionCaptureV1']
          as Map<String, dynamic>)['const'],
      isTrue,
    );
    final definitions = response[r'$defs'] as Map<String, dynamic>;
    final selection =
        definitions['changedRegionSelection'] as Map<String, dynamic>;
    final selectionProperties = selection['properties'] as Map<String, dynamic>;
    expect(
      (selectionProperties['regionCount'] as Map<String, dynamic>)['maximum'],
      16,
    );
    expect(
      (selectionProperties['paddingLogical']
          as Map<String, dynamic>)['maximum'],
      256,
    );
    expect(
      (selectionProperties['unionAreaRatio']
          as Map<String, dynamic>)['maximum'],
      0.5,
    );
    expect(
      (selectionProperties['predictedOutputPixels']
          as Map<String, dynamic>)['maximum'],
      4194304,
    );
  });

  test('CLI response, heartbeat, and event contracts require correlation', () {
    final response =
        jsonDecode(
              File(
                '${schemaRoot.path}/cli-response.schema.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final responseRequired = (response['required'] as List<dynamic>).toSet();
    expect(
      responseRequired,
      containsAll(<String>{
        'protocolRange',
        'commandId',
        'runId',
        'runtimeInstanceId',
        'stateGeneration',
        'result',
        'structuredError',
        'timings',
        'payloadBounds',
        'safetyEvidenceStatus',
      }),
    );
    final responseProperties = response['properties'] as Map<String, dynamic>;
    final payloadBounds =
        responseProperties['payloadBounds'] as Map<String, dynamic>;
    expect(
      (payloadBounds['required'] as List<dynamic>).toSet(),
      contains('safetyDisposition'),
    );

    final heartbeat =
        jsonDecode(
              File(
                '${schemaRoot.path}/cli-heartbeat.schema.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(
      (heartbeat['required'] as List<dynamic>).toSet(),
      containsAll(<String>{
        'stage',
        'elapsedMs',
        'heartbeatCursor',
        'progress',
      }),
    );

    final event =
        jsonDecode(
              File(
                '${schemaRoot.path}/cli-event.schema.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(
      (event['required'] as List<dynamic>).toSet(),
      containsAll(<String>{
        'eventCursor',
        'previousEventCursor',
        'commandId',
        'runId',
        'runtimeInstanceId',
        'stateGeneration',
        'logCursor',
        'correlation',
      }),
    );
  });

  test('all response timings require the canonical truthful phase set', () {
    const canonicalPhases = <String>{
      'connect',
      'snapshot',
      'match',
      'dispatch',
      'settle',
      'delta',
      'logs',
      'serialize',
    };
    for (final name in const <String>[
      'response.schema.json',
      'cli-response.schema.json',
      'mutation-outcome.schema.json',
    ]) {
      final schema =
          jsonDecode(File('${schemaRoot.path}/$name').readAsStringSync())
              as Map<String, dynamic>;
      final properties = schema['properties'] as Map<String, dynamic>;
      final timings = properties['timings'] as Map<String, dynamic>;
      final timingProperties = timings['properties'] as Map<String, dynamic>;
      final phases = timingProperties['phases'] as Map<String, dynamic>;
      expect(
        (timings['required'] as List<dynamic>).toSet(),
        contains('phases'),
      );
      expect(
        (phases['required'] as List<dynamic>).toSet(),
        containsAll(canonicalPhases),
      );
      expect(
        (phases['additionalProperties'] as Map)[r'$ref'],
        '#/\$defs/timingPhase',
      );
      final definitions = schema[r'$defs'] as Map<String, dynamic>;
      final phase = definitions['timingPhase'] as Map<String, dynamic>;
      expect(
        (phase['required'] as List<dynamic>).toSet(),
        containsAll(<String>{'status', 'elapsedMs'}),
      );
      final phaseProperties = phase['properties'] as Map<String, dynamic>;
      expect(
        (phaseProperties['status'] as Map<String, dynamic>)['enum'],
        contains('unavailable'),
      );
      expect(
        (phaseProperties['elapsedMs'] as Map<String, dynamic>)['type'],
        contains('null'),
      );
      final phaseVariants = phase['oneOf'] as List<dynamic>;
      final unavailable = phaseVariants.last as Map<String, dynamic>;
      expect(
        (unavailable['required'] as List<dynamic>).toSet(),
        contains('reason'),
      );
      final unavailableProperties =
          unavailable['properties'] as Map<String, dynamic>;
      expect(
        (unavailableProperties['elapsedMs'] as Map<String, dynamic>)['type'],
        'null',
      );
    }
  });
}
