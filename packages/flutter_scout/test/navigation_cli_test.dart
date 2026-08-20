import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('deterministic navigation CLI', () {
    test(
      'where locate and inspect since stay read-only and forward bounds',
      () async {
        final fake = await _NavigationFakeVm.start();
        addTearDown(fake.close);

        await _withNavigationSession(fake.uri, () async {
          expect(
            await FlutterScoutCli().run([
              'where',
              '--max-response-bytes',
              '8192',
            ]),
            0,
          );
          expect(
            await FlutterScoutCli().run([
              'locate',
              '--text',
              'Hair Recovery',
              '--within',
              'scroll.forms',
              '--max-candidates',
              '7',
            ]),
            0,
          );
          expect(
            await FlutterScoutCli().run([
              'inspect',
              '--since',
              'g7:${List<String>.filled(64, 'a').join()}',
            ]),
            0,
          );
        });

        expect(fake.calls, hasLength(3));
        expect(fake.calls[0].method, 'ext.flutter_scout.inspect');
        expect(fake.calls[0].params['navigationAction'], 'where');
        expect(fake.calls[0].params['maxResponseBytes'], '8192');
        expect(fake.calls[1].method, 'ext.flutter_scout.inspect');
        expect(fake.calls[1].params['navigationAction'], 'locate');
        expect(fake.calls[1].params['text'], 'Hair Recovery');
        expect(fake.calls[1].params['within'], 'scroll.forms');
        expect(fake.calls[1].params['maxCandidates'], '7');
        expect(fake.calls[2].method, 'ext.flutter_scout.inspect');
        expect(fake.calls[2].params['since'], startsWith('g7:'));
        expect(fake.mutations, isEmpty);
      },
    );

    test(
      'reveal is a protocol-v15 exactly-once mutation with declared bounds',
      () async {
        final fake = await _NavigationFakeVm.start();
        addTearDown(fake.close);

        await _withNavigationSession(fake.uri, () async {
          expect(
            await FlutterScoutCli().run([
              'reveal',
              '--text',
              'Hair Recovery',
              '--within',
              'scroll.forms',
              '--direction',
              'down',
              '--max-actions',
              '5',
              '--distance',
              '240',
              '--max-distance',
              '1000',
              '--timeout',
              '3000',
            ]),
            0,
          );
        });

        expect(fake.calls.map((call) => call.method), <String>[
          'ext.flutter_scout.inspect',
          'ext.flutter_scout.reveal',
        ]);
        final mutation = fake.mutations.single;
        expect(mutation['text'], 'Hair Recovery');
        expect(mutation['within'], 'scroll.forms');
        expect(mutation['maxActions'], '5');
        expect(mutation['distance'], '240.0');
        expect(mutation['maxDistance'], '1000.0');
        expect(mutation['timeoutMs'], '3000');
        expect(mutation['schemaVersion'], '1');
        expect(mutation['clientProtocolMin'], '15');
        expect(mutation['clientProtocolMax'], '15');
        expect(mutation['commandId'], isNotEmpty);
        expect(mutation['idempotencyKey'], isNotEmpty);
        expect(mutation['expectedStateGeneration'], '7');
        expect(mutation['runtimeInstanceId'], 'runtime-navigation');
      },
    );

    test('invalid bounds fail before transport', () async {
      final fake = await _NavigationFakeVm.start();
      addTearDown(fake.close);
      await _withNavigationSession(fake.uri, () async {
        expect(
          await FlutterScoutCli().run([
            'reveal',
            '--target',
            'btn.save',
            '--max-actions',
            '0',
          ]),
          1,
        );
        expect(
          await FlutterScoutCli().run([
            'locate',
            '--text',
            'one',
            '--target',
            'btn.one',
          ]),
          1,
        );
      });
      expect(fake.calls, isEmpty);
    });

    test(
      'bounds abstains when read-only target resolution is ambiguous',
      () async {
        final fake = await _NavigationFakeVm.start();
        addTearDown(fake.close);

        await _withNavigationSession(fake.uri, () async {
          expect(
            await FlutterScoutCli().run(<String>[
              'bounds',
              '--target',
              'ambiguous.bounds',
            ]),
            1,
          );
        });

        expect(fake.calls, hasLength(1));
        expect(fake.calls.single.params['navigationAction'], 'locate');
        expect(fake.calls.single.params['target'], 'ambiguous.bounds');
        expect(fake.mutations, isEmpty);
      },
    );

    test('bounds uses one uniquely scoped geometry observation', () async {
      final fake = await _NavigationFakeVm.start();
      addTearDown(fake.close);

      await _withNavigationSession(fake.uri, () async {
        expect(
          await FlutterScoutCli().run(<String>[
            'bounds',
            '--target',
            'btn.unique',
          ]),
          0,
        );
      });

      expect(fake.calls, hasLength(1));
      expect(fake.calls.single.params['navigationAction'], 'locate');
      expect(fake.calls.single.params['target'], 'btn.unique');
      expect(fake.mutations, isEmpty);
    });
  });
}

Future<void> _withNavigationSession(
  Uri vmUri,
  Future<void> Function() body,
) async {
  final previous = Directory.current;
  final temporary = await Directory.systemTemp.createTemp(
    'flutter_scout_navigation_cli_',
  );
  try {
    Directory.current = temporary;
    final session = Directory(p.join(temporary.path, '.flutter_scout'))
      ..createSync();
    File(p.join(session.path, 'vm_uri.txt')).writeAsStringSync('$vmUri');
    File(p.join(session.path, 'session_meta.json')).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'mode': 'attach_only',
        'state': 'ready',
        'runId': 'navigation-run',
        'vmServiceUri': '$vmUri',
      }),
    );
    await body();
  } finally {
    Directory.current = previous;
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  }
}

typedef _NavigationCall = ({String method, Map<String, dynamic> params});

class _NavigationFakeVm {
  _NavigationFakeVm._(this._server);

  final HttpServer _server;
  final List<WebSocket> _sockets = <WebSocket>[];
  final List<_NavigationCall> calls = <_NavigationCall>[];
  final List<Map<String, dynamic>> mutations = <Map<String, dynamic>>[];

  Uri get uri => Uri.parse('ws://127.0.0.1:${_server.port}/ws');

  static Future<_NavigationFakeVm> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _NavigationFakeVm._(server);
    unawaited(fake._serve());
    return fake;
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
    if (method.startsWith('ext.flutter_scout.')) {
      calls.add((method: method, params: params));
      final isReveal = method == 'ext.flutter_scout.reveal';
      if (isReveal) mutations.add(params);
      _reply(
        socket,
        id,
        isReveal ? _revealResponse(params) : _inspectResponse(params),
      );
      return;
    }
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
  }

  Map<String, Object?> _inspectResponse(Map<String, dynamic> params) {
    final identity = _identity(params);
    if (params['navigationAction'] == 'where') {
      return <String, Object?>{
        ...identity,
        'orientation': 'where',
        'screen': 'Home',
        'scrollRegions': const <Object?>[],
      };
    }
    if (params['navigationAction'] == 'locate') {
      if (params['target'] == 'ambiguous.bounds') {
        return <String, Object?>{
          ...identity,
          'ok': false,
          'operation': 'locate',
          'readOnly': true,
          'stoppingReason': 'ambiguous',
          'resolution': const <String, Object?>{
            'status': 'ambiguous',
            'candidateCount': 2,
            'candidates': <Object?>[
              <String, Object?>{'handle': 'btn.first'},
              <String, Object?>{'handle': 'btn.second'},
            ],
          },
          'structuredError': const <String, Object?>{
            'code': 'target_ambiguous',
            'message': 'Two targets matched the read-only selector.',
          },
        };
      }
      return <String, Object?>{
        ...identity,
        'operation': 'locate',
        'readOnly': true,
        'coordinateFrame': const <String, Object?>{
          'primarySpace': 'logical_flutter_points',
          'origin': 'flutter_view_top_left',
          'logicalViewport': <num>[0, 0, 200, 400],
          'physicalViewport': <num>[0, 0, 400, 800],
          'devicePixelRatio': 2.0,
          'logicalToPhysicalScale': 2.0,
          'viewMetricsAvailable': true,
          'provenance': 'flutter_view_physical_size_and_device_pixel_ratio',
        },
        'resolution': const <String, Object?>{
          'status': 'unique',
          'scope': <String, Object?>{
            'runId': 'navigation-run',
            'runtimeInstanceId': 'runtime-navigation',
            'stateGeneration': 7,
            'snapshotId':
                'g7:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          },
          'target': <String, Object?>{
            'id': 'btn.unique',
            'rect': <num>[10, 20, 30, 40],
            'physicalRect': <num>[20, 40, 60, 80],
            'geometryCoordinateSpaces': <String, Object?>{
              'logical': 'logical_flutter_points',
              'physical': 'physical_pixels',
              'devicePixelRatio': 2.0,
            },
          },
        },
      };
    }
    if (params['since'] != null) {
      return <String, Object?>{
        ...identity,
        'operation': 'inspect_since',
        'requestedSnapshotId': params['since'],
        'delta': const <String, Object?>{},
      };
    }
    return identity;
  }

  Map<String, Object?> _revealResponse(Map<String, dynamic> params) =>
      <String, Object?>{
        ..._identity(params, generation: 8, mutating: true),
        'operation': 'reveal',
        'revealed': true,
        'result': 'revealed',
        'stoppingReason': 'target_revealed',
        'activation': const <String, Object?>{
          'dispatched': true,
          'observedChange': true,
        },
        'before': <String, Object?>{
          'stateGeneration': 7,
          'snapshotId': 'g7:${List<String>.filled(64, 'a').join()}',
          'screen': 'Home',
        },
        'after': <String, Object?>{
          'stateGeneration': 8,
          'snapshotId': 'g8:${List<String>.filled(64, 'b').join()}',
          'screen': 'Home',
        },
        'delta': const <String, Object?>{'changedGeometry': <Object?>[]},
      };

  Map<String, Object?> _identity(
    Map<String, dynamic> params, {
    int generation = 7,
    bool mutating = false,
  }) => <String, Object?>{
    'ok': true,
    'schemaVersion': 1,
    'protocolVersion': 15,
    'minSupportedProtocolVersion': 15,
    'maxSupportedProtocolVersion': 15,
    'capabilities': const <String, bool>{
      'typedEnvelopeV1': true,
      'stateGeneration': true,
      'stateDigestSha256': true,
      'strictMutationEnvelope': true,
      'serializedMutations': true,
      'idempotentMutations': true,
      'stableIdempotencyFingerprintV1': true,
      'phaseTimingsV1': true,
      'idempotencyTombstonesV1': true,
      'runtimeErrorCursor': true,
      'heldDragExclusion': true,
      'sourceRedaction': true,
      'boundedNavigation': true,
      'snapshotRelativeDeltas': true,
    },
    'commandId': params['commandId'],
    'runId': 'navigation-run',
    'runtimeInstanceId': 'runtime-navigation',
    'stateGeneration': generation,
    'stateDigest': List<String>.filled(64, generation == 7 ? 'a' : 'b').join(),
    'snapshotId':
        'g$generation:${List<String>.filled(64, generation == 7 ? 'a' : 'b').join()}',
    'errorCursor': 0,
    'errorsSinceCursor': const <Object?>[],
    'activeBlockingSignals': const <Object?>[],
    'result': const <String, Object?>{},
    'structuredError': null,
    'timings': _navigationFakeTimings(mutating: mutating),
  };

  void _reply(WebSocket socket, Object? id, Map<String, Object?> result) {
    _expectAdvertisedPhaseTimings(result);
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

Map<String, Object?> _navigationFakeTimings({
  required bool mutating,
}) => <String, Object?>{
  'totalMs': 1,
  'status': 'partial',
  'phases': <String, Object?>{
    for (final phase in const <String>['connect', 'logs'])
      phase: const <String, Object?>{
        'status': 'unavailable',
        'elapsedMs': null,
        'owner': 'cli',
        'reason': 'measured_at_cli_boundary',
      },
    'snapshot': const <String, Object?>{
      'status': 'measured',
      'elapsedMs': 0,
      'owner': 'helper',
    },
    for (final phase in const <String>['match', 'dispatch', 'settle', 'delta'])
      phase: mutating
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
    'serialize': const <String, Object?>{
      'status': 'measured',
      'elapsedMs': 0,
      'owner': 'helper',
    },
  },
};

void _expectAdvertisedPhaseTimings(Map<String, Object?> result) {
  final capabilities = result['capabilities'];
  if (capabilities is! Map || capabilities['phaseTimingsV1'] != true) return;
  const phaseNames = <String>[
    'connect',
    'snapshot',
    'match',
    'dispatch',
    'settle',
    'delta',
    'logs',
    'serialize',
  ];
  final timings = result['timings'];
  expect(timings, isA<Map>());
  final phases = (timings! as Map)['phases'];
  expect(phases, isA<Map>());
  expect((phases! as Map).keys.toSet(), phaseNames.toSet());
  for (final phaseName in phaseNames) {
    final record = phases[phaseName];
    expect(record, isA<Map>(), reason: phaseName);
    if ((record as Map)['status'] == 'measured') {
      expect(record['elapsedMs'], isA<int>(), reason: phaseName);
      expect(record['elapsedMs'] as int, greaterThanOrEqualTo(0));
    } else {
      expect(record['status'], 'unavailable', reason: phaseName);
      expect(record['elapsedMs'], isNull, reason: phaseName);
      expect(record['reason'], isA<String>(), reason: phaseName);
      expect((record['reason'] as String).trim(), isNotEmpty);
    }
  }
}
