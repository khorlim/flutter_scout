import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;

const List<String> canonicalCliEnvelopeKeys = <String>[
  'messageType',
  'ok',
  'schemaVersion',
  'protocolVersion',
  'minSupportedProtocolVersion',
  'maxSupportedProtocolVersion',
  'protocolRange',
  'capabilities',
  'capabilitySource',
  'commandId',
  'cliCommandId',
  'commandName',
  'runId',
  'runtimeInstanceId',
  'stateGeneration',
  'identityStatus',
  'identityAvailability',
  'result',
  'structuredError',
  'timings',
  'logCursor',
  'eventCursor',
  'payloadBounds',
  'safetyEvidenceStatus',
];

Map<String, dynamic> readContractJson(String packageRoot, String relative) =>
    jsonDecode(
          File(p.normalize(p.join(packageRoot, relative))).readAsStringSync(),
        )
        as Map<String, dynamic>;

Map<String, dynamic> canonicalCliEnvelope(Map<String, Object?> envelope) {
  final result = <String, dynamic>{};
  for (final key in canonicalCliEnvelopeKeys) {
    if (!envelope.containsKey(key)) {
      throw StateError('Canonical CLI envelope is missing `$key`.');
    }
    final value = envelope[key];
    result[key] = key == 'capabilities' && value is Map
        ? SplayTreeMap<String, Object?>.from(<String, Object?>{
            for (final entry in value.entries)
              entry.key.toString(): entry.value,
          })
        : value;
  }
  return result;
}

Map<String, Object?> deterministicContractInput({
  required bool ok,
  required String commandName,
  required Object? result,
  Map<String, Object?>? error,
}) => <String, Object?>{
  'messageType': 'response',
  'ok': ok,
  'commandId': ok ? 'public-command-contract' : 'stable-error-contract',
  'cliCommandId': ok ? 'public-command-contract' : 'stable-error-contract',
  'commandName': commandName,
  'runId': null,
  'runtimeInstanceId': null,
  'stateGeneration': null,
  'result': result,
  'error': ?error,
  'logCursor': 0,
  'eventCursor': null,
  'timings': <String, Object?>{
    'totalMs': null,
    'status': 'unavailable',
    'phases': <String, Object?>{
      for (final phase in const <String>[
        'connect',
        'snapshot',
        'match',
        'dispatch',
        'settle',
        'delta',
        'logs',
        'serialize',
      ])
        phase: const <String, Object?>{
          'status': 'unavailable',
          'elapsedMs': null,
          'reason': 'current_source_contract_fixture',
        },
    },
  },
};

Map<String, dynamic> buildPublicContractGoldens(String packageRoot) {
  final commandContract = readContractJson(
    packageRoot,
    '../../protocol/schemas/v1/public-cli-commands.json',
  );
  final errorContract = readContractJson(
    packageRoot,
    '../../protocol/schemas/v1/stable-errors.json',
  );
  final commands = commandContract['commands']! as Map<String, dynamic>;
  final errors = errorContract['errors']! as Map<String, dynamic>;
  final cli = FlutterScoutCli();

  return <String, dynamic>{
    'schemaVersion': 1,
    'protocolVersion': 15,
    'artifactKind': 'flutter_scout_public_cli_envelope_goldens',
    'evidenceScope': const <String, Object?>{
      'kind': 'deterministic_current_source_envelope_construction',
      'commandsExecutedAgainstApp': false,
      'errorsInducedAgainstApp': false,
      'simulatorOrDeviceExercised': false,
      'releaseBinariesExercised': false,
    },
    'commands': <Map<String, Object?>>[
      for (final entry in commands.entries)
        if ((entry.value as Map)['surface'] == 'human_prose')
          <String, Object?>{
            'command': entry.key,
            'surface': 'human_prose',
            'canonicalEnvelope': null,
            'reason':
                'Help is intentionally prose-only and is not a machine-response record.',
          }
        else
          <String, Object?>{
            'command': entry.key,
            'surface': 'machine',
            'canonicalEnvelope': canonicalCliEnvelope(
              cli.debugCliResponseEnvelope(
                deterministicContractInput(
                  ok: true,
                  commandName: entry.key,
                  result: <String, Object?>{
                    'contractKind': 'public_command',
                    'command': entry.key,
                  },
                ),
              ),
            ),
          },
    ],
    'errors': <Map<String, Object?>>[
      for (final entry in errors.entries)
        <String, Object?>{
          'code': entry.key,
          'meaning': (entry.value as Map)['meaning'],
          'canonicalEnvelope': canonicalCliEnvelope(
            cli.debugCliResponseEnvelope(
              deterministicContractInput(
                ok: false,
                commandName: 'error-contract',
                result: null,
                error: <String, Object?>{
                  'code': entry.key,
                  'message': (entry.value as Map)['meaning'],
                },
              ),
              success: false,
            ),
          ),
        },
    ],
  };
}

String prettyContractJson(Object? value) =>
    '${const JsonEncoder.withIndent('  ').convert(value)}\n';
