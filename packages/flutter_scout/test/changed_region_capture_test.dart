import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _baselineId =
    'g7:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _currentId =
    'g8:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  test('changed-since makes one bounded snapshot-bound capture call', () async {
    final fake = await _ChangedRegionFakeVm.start();
    addTearDown(fake.close);

    await _withChangedRegionSession(fake.uri, (root) async {
      final output = p.join(root.path, 'changed.png');
      expect(
        await FlutterScoutCli().run(<String>[
          'crop',
          '--changed-since',
          _baselineId,
          '--padding',
          '8',
          '--output',
          output,
        ]),
        0,
      );
      expect(File(output).existsSync(), isTrue);
      final decoded = img.decodeImage(File(output).readAsBytesSync());
      expect(decoded, isNotNull);
      expect(decoded!.width, 20);
      expect(decoded.height, 20);
      expect(File('$output.metadata.json').existsSync(), isTrue);
    });

    expect(fake.calls, hasLength(1));
    expect(fake.calls.single.method, 'ext.flutter_scout.capture');
    expect(fake.calls.single.params['mode'], 'changed-region');
    expect(fake.calls.single.params['since'], _baselineId);
    expect(fake.calls.single.params['padding'], '8');
    expect(fake.calls.single.params['native'], 'off');
  });

  test('stale helper history fails closed without an artifact', () async {
    final fake = await _ChangedRegionFakeVm.start(
      mode: _FakeCaptureMode.historyUnavailable,
    );
    addTearDown(fake.close);

    await _withChangedRegionSession(fake.uri, (root) async {
      final output = p.join(root.path, 'must-not-exist.png');
      expect(
        await FlutterScoutCli().run(<String>[
          'crop',
          '--changed-since',
          _baselineId,
          '--output',
          output,
        ]),
        1,
      );
      expect(File(output).existsSync(), isFalse);
      expect(File('$output.metadata.json').existsSync(), isFalse);
    });

    expect(fake.calls, hasLength(1));
  });

  test('mismatched capture verification identity is rejected', () async {
    final fake = await _ChangedRegionFakeVm.start(
      mode: _FakeCaptureMode.mismatchedVerification,
    );
    addTearDown(fake.close);

    await _withChangedRegionSession(fake.uri, (root) async {
      final output = p.join(root.path, 'mismatched.png');
      expect(
        await FlutterScoutCli().run(<String>[
          'crop',
          '--changed-since',
          _baselineId,
          '--output',
          output,
        ]),
        1,
      );
      expect(File(output).existsSync(), isFalse);
    });
  });

  test('invalid identity and native mode fail before transport', () async {
    final fake = await _ChangedRegionFakeVm.start();
    addTearDown(fake.close);

    await _withChangedRegionSession(fake.uri, (root) async {
      expect(
        await FlutterScoutCli().run(const <String>[
          'crop',
          '--changed-since',
          'not-a-snapshot',
        ]),
        1,
      );
      expect(
        await FlutterScoutCli().run(const <String>[
          'crop',
          '--changed-since',
          _baselineId,
          '--native',
        ]),
        1,
      );
    });

    expect(fake.calls, isEmpty);
  });
}

Future<void> _withChangedRegionSession(
  Uri vmUri,
  Future<void> Function(Directory root) body,
) async {
  final previous = Directory.current;
  final temporary = await Directory.systemTemp.createTemp(
    'flutter_scout_changed_region_',
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
        'runId': 'changed-region-run',
        'vmServiceUri': '$vmUri',
      }),
    );
    await body(temporary);
  } finally {
    Directory.current = previous;
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  }
}

typedef _CapturedCall = ({String method, Map<String, dynamic> params});

enum _FakeCaptureMode { success, historyUnavailable, mismatchedVerification }

class _ChangedRegionFakeVm {
  _ChangedRegionFakeVm._(this._server, this.mode);

  final HttpServer _server;
  final _FakeCaptureMode mode;
  final List<WebSocket> _sockets = <WebSocket>[];
  final List<_CapturedCall> calls = <_CapturedCall>[];

  Uri get uri => Uri.parse('ws://127.0.0.1:${_server.port}/ws');

  static Future<_ChangedRegionFakeVm> start({
    _FakeCaptureMode mode = _FakeCaptureMode.success,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _ChangedRegionFakeVm._(server, mode);
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
    if (method == 'ext.flutter_scout.capture') {
      calls.add((method: method, params: params));
      _reply(socket, id, _captureResponse(params));
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

  Map<String, Object?> _captureResponse(Map<String, dynamic> params) {
    final identity = _identity(params);
    if (mode == _FakeCaptureMode.historyUnavailable) {
      return <String, Object?>{
        ...identity,
        'ok': false,
        'result': null,
        'structuredError': const <String, Object?>{
          'code': 'snapshot_history_unavailable',
          'message': 'The requested baseline is not retained.',
        },
      };
    }
    final png = img.encodePng(img.Image(width: 20, height: 20));
    final verifiedId = mode == _FakeCaptureMode.mismatchedVerification
        ? 'g9:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
        : _currentId;
    return <String, Object?>{
      ...identity,
      'operation': 'capture_changed_region',
      'mode': 'changed-region',
      'requestedSnapshotId': _baselineId,
      'baselineScope': const <String, Object?>{
        'runId': 'changed-region-run',
        'runtimeInstanceId': 'changed-region-runtime',
        'stateGeneration': 7,
        'snapshotId': _baselineId,
      },
      'currentScope': const <String, Object?>{
        'runId': 'changed-region-run',
        'runtimeInstanceId': 'changed-region-runtime',
        'stateGeneration': 8,
        'snapshotId': _currentId,
      },
      'captureVerifiedScope': <String, Object?>{
        'runId': 'changed-region-run',
        'runtimeInstanceId': 'changed-region-runtime',
        'stateGeneration': mode == _FakeCaptureMode.mismatchedVerification
            ? 9
            : 8,
        'snapshotId': verifiedId,
      },
      'semanticChanged': true,
      'changedRegions': const <Object?>[
        <String, Object?>{
          'logicalRect': <num>[0, 0, 2, 2],
          'physicalRect': <num>[0, 0, 4, 4],
          'reasons': <String>['text_or_validation'],
          'sourceIdentities': <String>['text:label.status'],
          'geometryProvenance': <String, Object?>{
            'kind': 'derived_observation',
            'sources': <String>['snapshot_node_geometry'],
          },
        },
      ],
      'changedRegionCoverage': const <String, Object?>{
        'status': 'complete',
        'basis': 'snapshot_relative_agent_observable_semantic_geometry',
        'baselineSnapshotId': _baselineId,
        'currentSnapshotId': _currentId,
        'coordinateFrameStable': true,
        'globalScopeChanged': false,
        'totalRegionCount': 1,
        'returnedRegionCount': 1,
        'maximumReturnedRegions': 64,
        'omittedRegionCount': 0,
        'ambiguousGeometryCount': 0,
        'unavailableGeometryCount': 0,
        'nonVisualChangeCount': 0,
        'issues': <Object?>[],
        'limitations': <String>['Semantic geometry is not a pixel diff.'],
      },
      'regionSelection': const <String, Object?>{
        'strategy': 'bounded_union',
        'regionCount': 1,
        'logicalUnionRect': <num>[0, 0, 2, 2],
        'logicalPaddedRect': <num>[0, 0, 10, 10],
        'physicalPaddedRect': <num>[0, 0, 20, 20],
        'paddingLogical': 8,
        'unionAreaRatio': 0.01,
        'predictedOutputPixels': 400,
        'bounds': <String, Object?>{
          'maximumRegions': 16,
          'maximumPaddingLogical': 256.0,
          'maximumUnionAreaRatio': 0.5,
          'maximumOutputPixels': 4194304,
          'maximumOutputDimension': 4096,
        },
      },
      'coordinateFrame': const <String, Object?>{
        'primarySpace': 'logical_flutter_points',
        'origin': 'flutter_view_top_left',
        'xDirection': 'right',
        'yDirection': 'down',
        'logicalViewport': <num>[0, 0, 100, 200],
        'physicalViewport': <num>[0, 0, 200, 400],
        'devicePixelRatio': 2.0,
        'logicalToPhysicalScale': 2.0,
        'viewMetricsAvailable': true,
        'provenance': 'test_snapshot_geometry',
      },
      'backend': 'in_app_capture',
      'captureBackend': const <String, Object?>{
        'status': 'available',
        'backend': 'flutter_root_offset_layer',
      },
      'captureIdentity':
          'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
      'needsNative': false,
      'bytes': base64Encode(png),
      'width': 20,
      'height': 20,
      'pixelRatio': 2.0,
      'rect': const <num>[0, 0, 10, 10],
      'limitations': const <String>['Native fallback is unavailable.'],
    };
  }

  Map<String, Object?> _identity(Map<String, dynamic> params) =>
      <String, Object?>{
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
          'idempotencyTombstonesV1': true,
          'runtimeErrorCursor': true,
          'heldDragExclusion': true,
          'sourceRedaction': true,
          'phaseTimingsV1': true,
          'changedRegionCaptureV1': true,
        },
        'commandId': params['commandId'],
        'runId': 'changed-region-run',
        'runtimeInstanceId': 'changed-region-runtime',
        'stateGeneration': 8,
        'stateDigest':
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        'snapshotId': _currentId,
        'errorCursor': 0,
        'errorsSinceCursor': const <Object?>[],
        'activeBlockingSignals': const <Object?>[],
        'result': const <String, Object?>{},
        'structuredError': null,
        'timings': _timings(),
      };

  Map<String, Object?> _timings() => <String, Object?>{
    'status': 'partial',
    'totalMs': 0,
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
        phase: <String, Object?>{
          'status': phase == 'snapshot' || phase == 'delta'
              ? 'measured'
              : 'unavailable',
          'elapsedMs': phase == 'snapshot' || phase == 'delta' ? 0 : null,
          if (phase != 'snapshot' && phase != 'delta')
            'reason': 'not_owned_by_test_helper',
          'owner': 'helper',
          'scope': 'test',
          'clock': 'monotonic_stopwatch',
          'aggregation': 'exclusive_non_overlapping',
        },
    },
  };

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
