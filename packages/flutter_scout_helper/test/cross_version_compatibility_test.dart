import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final matrix = _readJson('../../protocol/compatibility-matrix.v1.json');
  final responseSchema = _readJson(
    '../../protocol/schemas/v1/response.schema.json',
  );

  test('source matrix matches the helper constants and capability surface', () {
    final runtime = FlutterScoutRuntime();
    final source = runtime.debugProtocolCompatibilityContract();
    final current = matrix['currentContract']! as Map<String, dynamic>;
    final evidence = matrix['evidenceScope']! as Map<String, dynamic>;

    expect(evidence['releaseBinariesExercised'], isFalse);
    expect(evidence['simulatorOrDeviceExercised'], isFalse);
    expect(evidence['releaseRatified'], isFalse);
    final helperPackage = current['helperPackage']! as Map<String, dynamic>;
    expect(helperPackage['name'], 'flutter_scout_helper');
    expect(helperPackage['version'], '0.2.0-dev.1');
    expect(helperPackage['releaseState'], 'unreleased_prerelease');
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('version: ${helperPackage['version']}'),
    );
    expect(current['schemaVersion'], source['schemaVersion']);
    expect(current['protocolVersion'], source['protocolVersion']);
    expect(current['helperSupportedProtocolRange'], <String, Object?>{
      'minimum': source['minSupportedProtocolVersion'],
      'maximum': source['maxSupportedProtocolVersion'],
    });
    final capabilities = source['capabilities']! as Map;
    expect(
      current['helperAdvertisedCapabilities'],
      capabilities.keys.cast<String>().toList()..sort(),
    );
    expect(
      current['requiredMutationEnvelopeParameters'],
      source['requiredMutationEnvelopeParameters'],
    );
    final responseProperties =
        responseSchema['properties']! as Map<String, dynamic>;
    final capabilitySchema =
        responseProperties['capabilities']! as Map<String, dynamic>;
    expect(
      (capabilitySchema['required']! as List).toSet(),
      (current['requiredHelperMutationCapabilities']! as List).toSet(),
      reason:
          'the response schema and CLI-required helper capabilities must agree',
    );

    final pairingIds = (matrix['pairings']! as List)
        .cast<Map>()
        .map((pairing) => pairing['id'])
        .toSet();
    expect(
      pairingIds,
      containsAll(<String>{
        'cli_n_helper_n',
        'cli_n_helper_n_minus_1',
        'cli_n_minus_1_helper_n',
        'cli_n_helper_n_plus_1',
        'cli_n_plus_1_helper_n',
      }),
    );
  });

  group('production helper protocol gate', () {
    testWidgets('current protocol 15 enters the mutation handler once', (
      tester,
    ) async {
      final runtime = await _pumpRuntime(tester);
      var handlerEntries = 0;

      final response = await runtime.debugProtocolMutation(
        _mutationEnvelope(runtime, clientProtocol: 15),
        () async {
          handlerEntries += 1;
          return const <String, Object?>{
            'activation': <String, Object?>{'dispatched': true},
            'futureOptionalField': <String, Object?>{'value': 1},
          };
        },
      );

      expect(response['ok'], isTrue);
      expect(response['result'], isNotNull);
      expect(response['structuredError'], isNull);
      expect(response['futureOptionalField'], isA<Map>());
      expect(handlerEntries, 1);
      _expectRequiredResponseFields(response, responseSchema);
      final advertised = (response['capabilities']! as Map).keys.toSet();
      expect(
        advertised,
        containsAll(
          (matrix['currentContract']!
                  as Map)['requiredHelperMutationCapabilities']
              as List,
        ),
      );
    });

    for (final protocol in <int>[14, 16]) {
      testWidgets(
        'protocol $protocol-only client is rejected before mutation handler entry',
        (tester) async {
          final runtime = await _pumpRuntime(tester);
          var handlerEntries = 0;

          final response = await runtime.debugProtocolMutation(
            _mutationEnvelope(runtime, clientProtocol: protocol),
            () async {
              handlerEntries += 1;
              return const <String, Object?>{'unexpected': true};
            },
          );

          expect(_errorCode(response), 'incompatible_protocol');
          expect(response['dispatch'], 'not_dispatched');
          expect((response['activation']! as Map)['dispatched'], isFalse);
          expect(response['result'], isNull);
          expect(handlerEntries, 0);
          _expectRequiredResponseFields(response, responseSchema);
        },
      );
    }

    testWidgets('every missing mutation envelope field abstains', (
      tester,
    ) async {
      final runtime = await _pumpRuntime(tester);
      final required =
          (runtime.debugProtocolCompatibilityContract()['requiredMutationEnvelopeParameters']!
                  as List)
              .cast<String>();
      var handlerEntries = 0;

      for (final field in required) {
        final request = _mutationEnvelope(runtime, clientProtocol: 15)
          ..remove(field);
        final response = await runtime.debugProtocolMutation(request, () async {
          handlerEntries += 1;
          return const <String, Object?>{'unexpected': true};
        });
        expect(
          _errorCode(response),
          'missing_mutation_envelope',
          reason: field,
        );
        expect(response['dispatch'], 'not_dispatched', reason: field);
        expect(
          (response['activation']! as Map)['dispatched'],
          isFalse,
          reason: field,
        );
        final details =
            (response['structuredError']! as Map)['details']! as Map;
        expect(details['missingFields'], contains(field), reason: field);
      }
      expect(handlerEntries, 0);
    });

    testWidgets('wrong schema and unknown request field retain stable errors', (
      tester,
    ) async {
      final runtime = await _pumpRuntime(tester);
      var handlerEntries = 0;
      Future<Map<String, Object?>> invoke(Map<String, String> request) =>
          runtime.debugProtocolMutation(request, () async {
            handlerEntries += 1;
            return const <String, Object?>{'unexpected': true};
          }, method: 'ext.flutter_scout.tap');

      final wrongSchema = await invoke(
        _mutationEnvelope(runtime, clientProtocol: 15)
          ..['schemaVersion'] = '2'
          ..['target'] = 'btn.save',
      );
      expect(_errorCode(wrongSchema), 'incompatible_schema');
      expect(wrongSchema['dispatch'], 'not_dispatched');

      final unknownRequestField = await invoke(
        _mutationEnvelope(runtime, clientProtocol: 15)
          ..['target'] = 'btn.save'
          ..['futureOptionalRequestField'] = 'not-allowed',
      );
      expect(_errorCode(unknownRequestField), 'unknown_parameter');
      expect(unknownRequestField['dispatch'], 'not_dispatched');
      expect(handlerEntries, 0);
    });

    testWidgets('published error-code meanings match executable failures', (
      tester,
    ) async {
      final runtime = await _pumpRuntime(tester);
      final semantics = matrix['stableErrorSemantics']! as Map<String, dynamic>;

      final missing = await runtime.debugProtocolMutation(
        const <String, String>{},
        () async => const <String, Object?>{'unexpected': true},
      );
      expect(
        _errorCode(missing),
        semantics['helperRejectsMissingMutationEnvelope'],
      );

      final wrongSchema = await runtime.debugProtocolMutation(
        _mutationEnvelope(runtime, clientProtocol: 15)..['schemaVersion'] = '2',
        () async => const <String, Object?>{'unexpected': true},
      );
      expect(_errorCode(wrongSchema), semantics['helperRejectsClientSchema']);

      final wrongProtocol = await runtime.debugProtocolMutation(
        _mutationEnvelope(runtime, clientProtocol: 14),
        () async => const <String, Object?>{'unexpected': true},
      );
      expect(
        _errorCode(wrongProtocol),
        semantics['helperRejectsClientProtocolRange'],
      );
    });
  });
}

Map<String, dynamic> _readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

Future<FlutterScoutRuntime> _pumpRuntime(WidgetTester tester) async {
  final runtime = FlutterScoutRuntime();
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: Text('compatibility fixture'))),
  );
  await tester.pump();
  return runtime;
}

Map<String, String> _mutationEnvelope(
  FlutterScoutRuntime runtime, {
  required int clientProtocol,
}) => <String, String>{
  'schemaVersion': '1',
  'clientProtocolMin': '$clientProtocol',
  'clientProtocolMax': '$clientProtocol',
  'commandId': 'client-$clientProtocol-command',
  'idempotencyKey': 'client-$clientProtocol-key',
  'runId': 'compatibility-run',
  'runtimeInstanceId': runtime.debugRuntimeInstanceId,
  'expectedStateGeneration': '${runtime.debugSnapshot().stateGeneration}',
  'deadlineEpochMs':
      '${DateTime.now().add(const Duration(minutes: 1)).millisecondsSinceEpoch}',
};

String _errorCode(Map<String, Object?> response) =>
    (response['structuredError']! as Map)['code']! as String;

void _expectRequiredResponseFields(
  Map<String, Object?> response,
  Map<String, dynamic> schema,
) {
  for (final field in (schema['required']! as List).cast<String>()) {
    expect(response, contains(field), reason: 'required response field $field');
  }
}
