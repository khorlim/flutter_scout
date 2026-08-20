import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final matrix = _readJson('../../protocol/compatibility-matrix.v1.json');
  final responseSchema = _readJson(
    '../../protocol/schemas/v1/response.schema.json',
  );
  final cli = FlutterScoutCli();

  test('source matrix is explicit, current, and not release evidence', () {
    expect(
      matrix['artifactKind'],
      'flutter_scout_source_protocol_compatibility_matrix',
    );
    final evidence = matrix['evidenceScope']! as Map<String, dynamic>;
    expect(evidence['kind'], 'current_source_contract');
    expect(evidence['releaseBinariesExercised'], isFalse);
    expect(evidence['simulatorOrDeviceExercised'], isFalse);
    expect(evidence['releaseRatified'], isFalse);
    expect((matrix['remainingReleaseEvidenceBlockers']! as List), isNotEmpty);

    final current = matrix['currentContract']! as Map<String, dynamic>;
    final source = cli.debugProtocolCompatibilityContract();
    final cliPackage = current['cliPackage']! as Map<String, dynamic>;
    expect(cliPackage['name'], 'flutter_scout');
    expect(cliPackage['version'], FlutterScoutCli.packageVersion);
    expect(cliPackage['releaseState'], 'unreleased_prerelease');
    expect(current['schemaVersion'], source['schemaVersion']);
    expect(current['cliSupportedProtocolRange'], <String, Object?>{
      'minimum': source['minSupportedProtocolVersion'],
      'maximum': source['maxSupportedProtocolVersion'],
    });
    expect(
      current['requiredHelperMutationCapabilities'],
      source['requiredHelperMutationCapabilities'],
    );

    final properties = responseSchema['properties']! as Map<String, dynamic>;
    final capabilitySchema =
        properties['capabilities']! as Map<String, dynamic>;
    expect(
      (capabilitySchema['required']! as List).toSet(),
      (current['requiredHelperMutationCapabilities']! as List).toSet(),
      reason:
          'the immutable response contract and the actual CLI safety gate must agree',
    );
  });

  test('matrix covers current, N-1, and N+1 in both directions', () {
    final pairings = (matrix['pairings']! as List).cast<Map>();
    expect(pairings.map((pairing) => pairing['id']).toSet(), <String>{
      'cli_n_helper_n',
      'cli_n_helper_n_minus_1',
      'cli_n_minus_1_helper_n',
      'cli_n_helper_n_plus_1',
      'cli_n_plus_1_helper_n',
    });
    for (final pairing in pairings) {
      expect(pairing['sourceProofs'], isNotEmpty, reason: '${pairing['id']}');
    }
  });

  group('production CLI helper-envelope gate', () {
    test('accepts protocol 15 and unknown optional response fields', () {
      final response = _helperEnvelope()
        ..['futureOptionalField'] = <String, Object?>{
          'introducedBy': 'future-compatible-helper',
        };
      expect(
        cli.debugValidateHelperProtocolEnvelope(response),
        containsPair('compatible', true),
      );
    });

    for (final protocol in <int>[14, 16]) {
      test(
        'rejects a protocol $protocol-only helper with stable semantics',
        () {
          final result = cli.debugValidateHelperProtocolEnvelope(
            _helperEnvelope(
              protocolVersion: protocol,
              minimumProtocolVersion: protocol,
              maximumProtocolVersion: protocol,
            ),
          );
          expect(result['compatible'], isFalse);
          expect(result['errorCode'], 'incompatible_helper_protocol');
        },
      );
    }

    test('rejects every absent required response field', () {
      final required = (responseSchema['required']! as List).cast<String>();
      for (final field in required) {
        final response = _helperEnvelope()..remove(field);
        final result = cli.debugValidateHelperProtocolEnvelope(response);
        expect(result['compatible'], isFalse, reason: 'missing $field');
        expect(result['errorCode'], switch (field) {
          'schemaVersion' => 'incompatible_helper_schema',
          'protocolVersion' ||
          'minSupportedProtocolVersion' ||
          'maxSupportedProtocolVersion' => 'incompatible_helper_protocol',
          'runtimeInstanceId' ||
          'stateGeneration' => 'incomplete_helper_identity',
          _ => 'invalid_helper_envelope',
        }, reason: 'missing $field');
      }
    });

    test('rejects every absent or false required mutation capability', () {
      final required =
          (cli.debugProtocolCompatibilityContract()['requiredHelperMutationCapabilities']!
                  as List)
              .cast<String>();
      for (final capability in required) {
        for (final replacement in <Object?>[null, false]) {
          final response = _helperEnvelope();
          final capabilities = Map<String, bool>.from(
            response['capabilities']! as Map,
          );
          if (replacement == null) {
            capabilities.remove(capability);
          } else {
            capabilities[capability] = false;
          }
          response['capabilities'] = capabilities;
          final result = cli.debugValidateHelperProtocolEnvelope(response);
          expect(result['compatible'], isFalse, reason: capability);
          expect(
            result['errorCode'],
            'missing_mutation_capability',
            reason: capability,
          );
        }
      }
    });

    test('keeps success and failure outcome-slot semantics distinct', () {
      final failure = _helperEnvelope()
        ..['ok'] = false
        ..['result'] = null
        ..['structuredError'] = <String, Object?>{
          'code': 'target_not_found',
          'message': 'No target matched.',
        };
      expect(
        cli.debugValidateHelperProtocolEnvelope(failure),
        containsPair('compatible', true),
      );

      final successWithError = _helperEnvelope()
        ..['structuredError'] = <String, Object?>{
          'code': 'contradictory_success',
          'message': 'A successful envelope cannot carry an error.',
        };
      expect(
        cli.debugValidateHelperProtocolEnvelope(successWithError),
        containsPair('errorCode', 'invalid_helper_envelope'),
      );

      final failureWithoutError = _helperEnvelope()
        ..['ok'] = false
        ..['structuredError'] = null;
      expect(
        cli.debugValidateHelperProtocolEnvelope(failureWithoutError),
        containsPair('errorCode', 'invalid_helper_envelope'),
      );
    });

    test('published CLI error-code meanings match the executable gate', () {
      final semantics = matrix['stableErrorSemantics']! as Map<String, dynamic>;

      final wrongSchema = _helperEnvelope()..['schemaVersion'] = 2;
      expect(
        cli.debugValidateHelperProtocolEnvelope(wrongSchema)['errorCode'],
        semantics['cliRejectsHelperSchema'],
      );

      expect(
        cli.debugValidateHelperProtocolEnvelope(
          _helperEnvelope(
            protocolVersion: 14,
            minimumProtocolVersion: 14,
            maximumProtocolVersion: 14,
          ),
        )['errorCode'],
        semantics['cliRejectsHelperProtocolRange'],
      );

      final missingCapability = _helperEnvelope();
      missingCapability['capabilities'] = Map<String, bool>.from(
        missingCapability['capabilities']! as Map,
      )..remove('sourceRedaction');
      expect(
        cli.debugValidateHelperProtocolEnvelope(missingCapability)['errorCode'],
        semantics['cliRejectsMissingRequiredCapability'],
      );

      final malformed = _helperEnvelope()..remove('result');
      expect(
        cli.debugValidateHelperProtocolEnvelope(malformed)['errorCode'],
        semantics['cliRejectsMalformedRequiredResponseField'],
      );
    });
  });

  group('CLI mutation preflight dispatch boundary', () {
    test('current protocol 15 dispatches after compatible preflight', () async {
      final helper = await _FakeCompatibilityHelper.start(
        _helperEnvelope()..['futureOptionalField'] = true,
      );
      addTearDown(helper.close);

      final outcome = await _runTap(helper);

      expect(outcome.exitCode, 0);
      expect(helper.extensionMethods, <String>[
        'ext.flutter_scout.inspect',
        'ext.flutter_scout.tap',
      ]);
      expect(helper.mutationHandlerEntries, 1);
      expect(outcome.errorCode, isNull);
    });

    for (final protocol in <int>[14, 16]) {
      test(
        'protocol $protocol-only helper is rejected before mutation dispatch',
        () async {
          final helper = await _FakeCompatibilityHelper.start(
            _helperEnvelope(
              protocolVersion: protocol,
              minimumProtocolVersion: protocol,
              maximumProtocolVersion: protocol,
            ),
          );
          addTearDown(helper.close);

          final outcome = await _runTap(helper);

          expect(outcome.exitCode, 1);
          expect(helper.extensionMethods, <String>[
            'ext.flutter_scout.inspect',
          ]);
          expect(helper.mutationHandlerEntries, 0);
          expect(outcome.errorCode, 'incompatible_helper_protocol');
          expect(outcome.dispatch, 'not_dispatched');
        },
      );
    }

    test('missing capability is rejected before mutation dispatch', () async {
      final response = _helperEnvelope();
      final capabilities = Map<String, bool>.from(
        response['capabilities']! as Map,
      )..remove('sourceRedaction');
      response['capabilities'] = capabilities;
      final helper = await _FakeCompatibilityHelper.start(response);
      addTearDown(helper.close);

      final outcome = await _runTap(helper);

      expect(outcome.exitCode, 1);
      expect(helper.mutationHandlerEntries, 0);
      expect(outcome.errorCode, 'missing_mutation_capability');
      expect(outcome.dispatch, 'not_dispatched');
    });

    test('missing typed response slot is rejected before dispatch', () async {
      final helper = await _FakeCompatibilityHelper.start(
        _helperEnvelope()..remove('structuredError'),
      );
      addTearDown(helper.close);

      final outcome = await _runTap(helper);

      expect(outcome.exitCode, 1);
      expect(helper.mutationHandlerEntries, 0);
      expect(outcome.errorCode, 'invalid_helper_envelope');
      expect(outcome.dispatch, 'not_dispatched');
    });
  });
}

Map<String, dynamic> _readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

Map<String, dynamic> _helperEnvelope({
  int protocolVersion = 15,
  int minimumProtocolVersion = 15,
  int maximumProtocolVersion = 15,
  String commandId = 'preflight-command',
  int stateGeneration = 7,
}) {
  final digest = List<String>.filled(
    64,
    stateGeneration == 7 ? 'a' : 'b',
  ).join();
  return <String, dynamic>{
    'ok': true,
    'schemaVersion': 1,
    'protocolVersion': protocolVersion,
    'minSupportedProtocolVersion': minimumProtocolVersion,
    'maxSupportedProtocolVersion': maximumProtocolVersion,
    'capabilities': const <String, bool>{
      'typedEnvelopeV1': true,
      'stateGeneration': true,
      'stateDigestSha256': true,
      'strictMutationEnvelope': true,
      'serializedMutations': true,
      'idempotentMutations': true,
      'stableIdempotencyFingerprintV1': true,
      'idempotencyTombstonesV1': true,
      'runtimeErrorCursor': true,
      'heldDragExclusion': true,
      'sourceRedaction': true,
      'phaseTimingsV1': true,
    },
    'commandId': commandId,
    'runId': 'compatibility-run',
    'runtimeInstanceId': 'runtime-compatibility',
    'stateGeneration': stateGeneration,
    'stateDigest': digest,
    'snapshotId': 'g$stateGeneration:$digest',
    'result': const <String, Object?>{},
    'structuredError': null,
    'errorCursor': 0,
    'errorsSinceCursor': const <Object?>[],
    'activeBlockingSignals': const <Object?>[],
    'timings': _timings(mutating: false),
  };
}

Map<String, Object?> _timings({required bool mutating}) => <String, Object?>{
  'totalMs': 0,
  'status': 'partial',
  'phases': <String, Object?>{
    for (final phase in const <String>['connect', 'logs'])
      phase: const <String, Object?>{
        'status': 'unavailable',
        'elapsedMs': null,
        'owner': 'cli',
        'reason': 'measured_at_cli_boundary',
      },
    for (final phase in const <String>[
      'snapshot',
      'match',
      'dispatch',
      'settle',
      'delta',
      'serialize',
    ])
      phase: mutating
          ? const <String, Object?>{
              'status': 'measured',
              'elapsedMs': 0,
              'owner': 'helper',
            }
          : phase == 'snapshot' || phase == 'serialize'
          ? const <String, Object?>{
              'status': 'measured',
              'elapsedMs': 0,
              'owner': 'helper',
            }
          : const <String, Object?>{
              'status': 'unavailable',
              'elapsedMs': null,
              'owner': 'helper',
              'reason': 'not_applicable_for_read:inspect',
            },
  },
};

class _CliOutcome {
  const _CliOutcome({
    required this.exitCode,
    required this.errorCode,
    required this.dispatch,
  });

  final int exitCode;
  final String? errorCode;
  final String? dispatch;
}

Future<_CliOutcome> _runTap(_FakeCompatibilityHelper helper) async {
  final previous = Directory.current;
  final temporary = await Directory.systemTemp.createTemp(
    'flutter_scout_cross_version_',
  );
  try {
    Directory.current = temporary;
    final session = Directory(p.join(temporary.path, '.flutter_scout'))
      ..createSync();
    File(p.join(session.path, 'vm_uri.txt')).writeAsStringSync('${helper.uri}');
    File(p.join(session.path, 'session_meta.json')).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'mode': 'attach_only',
        'state': 'ready',
        'runId': 'compatibility-run',
        'vmServiceUri': '${helper.uri}',
      }),
    );
    final exitCode = await FlutterScoutCli().run(<String>[
      'tap',
      'btn.save',
      '--wait-ms=-14000',
    ]);
    final events = File(
      p.join(session.path, 'events.jsonl'),
    ).readAsLinesSync().map((line) => jsonDecode(line) as Map<String, dynamic>);
    final action = events.lastWhere(
      (event) => event['type'] == 'action_result',
    );
    final structuredError = action['structuredError'];
    return _CliOutcome(
      exitCode: exitCode,
      errorCode: structuredError is Map
          ? structuredError['code']?.toString()
          : null,
      dispatch: action['dispatch']?.toString(),
    );
  } finally {
    Directory.current = previous;
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  }
}

class _FakeCompatibilityHelper {
  _FakeCompatibilityHelper._(this._server, this._preflight);

  final HttpServer _server;
  final Map<String, dynamic> _preflight;
  final List<WebSocket> _sockets = <WebSocket>[];
  final List<String> extensionMethods = <String>[];
  int mutationHandlerEntries = 0;

  Uri get uri => Uri.parse('ws://127.0.0.1:${_server.port}/ws');

  static Future<_FakeCompatibilityHelper> start(
    Map<String, dynamic> preflight,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final helper = _FakeCompatibilityHelper._(server, preflight);
    unawaited(helper._serve());
    return helper;
  }

  Future<void> _serve() async {
    await for (final request in _server) {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        continue;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      _sockets.add(socket);
      socket.listen((data) => _handle(socket, data));
    }
  }

  void _handle(WebSocket socket, Object? data) {
    final request = jsonDecode(data! as String) as Map<String, dynamic>;
    final id = request['id'];
    final method = request['method']!.toString();
    final params = request['params'] is Map
        ? Map<String, dynamic>.from(request['params'] as Map)
        : <String, dynamic>{};
    if (method == 'getVM') {
      _reply(socket, id, <String, Object?>{
        'type': 'VM',
        'name': 'vm',
        'architectureBits': 64,
        'hostCPU': 'test',
        'operatingSystem': 'test',
        'targetCPU': 'test',
        'version': 'test',
        'pid': 1,
        'startTime': 0,
        'isolates': const <Object?>[
          <String, Object?>{
            'type': '@Isolate',
            'id': 'isolates/1',
            'name': 'main',
            'number': '1',
            'isSystemIsolate': false,
          },
        ],
      });
      return;
    }
    if (!method.startsWith('ext.flutter_scout.')) {
      socket.add(
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'error': <String, Object?>{
            'code': -32601,
            'message': 'Unknown method $method',
          },
        }),
      );
      return;
    }
    extensionMethods.add(method);
    if (method == 'ext.flutter_scout.inspect') {
      _reply(socket, id, <String, Object?>{
        ..._preflight,
        if (_preflight.containsKey('commandId'))
          'commandId': params['commandId'],
      });
      return;
    }

    mutationHandlerEntries += 1;
    final response =
        _helperEnvelope(
            commandId: params['commandId']!.toString(),
            stateGeneration: 8,
          )
          ..['runId'] = params['runId']
          ..['runtimeInstanceId'] = params['runtimeInstanceId']
          ..['result'] = 'changed'
          ..['activation'] = const <String, Object?>{
            'dispatched': true,
            'observedChange': true,
          }
          ..['before'] = const <String, Object?>{
            'stateGeneration': 7,
            'snapshotId': 'g7:before',
          }
          ..['after'] = const <String, Object?>{
            'stateGeneration': 8,
            'snapshotId': 'g8:after',
          }
          ..['timings'] = _timings(mutating: true);
    _reply(socket, id, response);
  }

  void _reply(WebSocket socket, Object? id, Map<String, Object?> result) {
    socket.add(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'result': result,
      }),
    );
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      await socket.close();
    }
    await _server.close(force: true);
  }
}
