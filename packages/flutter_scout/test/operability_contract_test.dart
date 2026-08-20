import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('operability contract', () {
    test('observed facts match the complete deterministic golden', () async {
      await _withSession((session) async {
        final cli = FlutterScoutCli()..debugEnsurePrivateStorage();
        final logPath = p.join(
          session.path,
          'runs',
          'run-observed',
          'logs.txt',
        );
        cli.debugAtomicSessionWrite(
          p.relative(logPath, from: session.path),
          '',
        );
        Directory(p.join(session.path, 'recordings')).createSync();
        Directory(p.join(session.path, 'evidence')).createSync();
        cli.debugAtomicSessionWrite(
          'session_meta.json',
          jsonEncode(<String, Object?>{
            'mode': 'scout_owned_flutter_run',
            'state': 'ready',
            'name': 'operability-test',
            'runId': 'run-observed',
            'project': '/workspace/example_app',
            'logFile': logPath,
            'processIdentity': const <String, Object?>{
              'pid': 4242,
              'startTime': 'stable-start-token',
            },
            'supervisor': const <String, Object?>{
              'kind': 'launchd',
              'label': 'dev.flutter_scout.test',
            },
            'sourceIdentity': const <String, Object?>{
              'status': 'clean_commit',
              'commit': '0123456789abcdef0123456789abcdef01234567',
              'workingTreeDirty': false,
            },
            'lastHotUpdate': const <String, Object?>{
              'observedAt': '2026-08-20T00:00:00.000Z',
              'action': 'reload',
              'runId': 'run-observed',
              'runtimeInstanceId': 'runtime-observed',
              'sourceVerification': <String, Object?>{
                'status': 'verified',
                'verifiedCount': 3,
                'mismatchedCount': 0,
              },
            },
          }),
        );

        final response = cli.debugCliResponseEnvelope(<String, Object?>{
          'ok': true,
          'commandName': 'status',
          'running': true,
          'appReachable': true,
          'session': const <String, Object?>{
            'mode': 'scout_owned_flutter_run',
            'state': 'ready',
            'name': 'operability-test',
            'runId': 'run-observed',
            'pid': 4242,
            'supervisor': <String, Object?>{'kind': 'launchd'},
            'supervisorState': <String, Object?>{'state': 'running'},
          },
          'deviceInfo': const <String, Object?>{
            'id': 'sim-device-1',
            'name': 'Reference Simulator',
            'platform': 'ios',
            'category': 'mobile',
            'emulator': true,
          },
          'hotUpdate': const <String, Object?>{
            'ownershipProof': 'exact_process_identity',
          },
          'runtimeObservation': const <String, Object?>{
            'status': 'observed',
            'appReachability': 'reachable',
            'helper': <String, Object?>{
              'status': 'observed',
              'package': 'flutter_scout_helper',
              'packageVersion': '0.2.0-dev.1',
            },
            'protocol': <String, Object?>{
              'status': 'observed',
              'schemaVersion': 1,
              'protocolVersion': 15,
              'minimum': 15,
              'maximum': 15,
              'capabilities': <String, Object?>{
                'typedEnvelopeV1': true,
                'inAppCapture': true,
              },
            },
            'identity': <String, Object?>{
              'status': 'observed',
              'runId': 'run-observed',
              'runtimeInstanceId': 'runtime-observed',
              'stateGeneration': 27,
              'snapshotId': 'g27:stable-digest',
            },
            'screen': <String, Object?>{
              'status': 'observed',
              'name': 'HomeScreen',
              'viewSignature': 'home:ready',
              'idle': true,
            },
            'actionState': <String, Object?>{
              'status': 'held_drag_active',
              'activeDrag': true,
              'position': <double>[120, 450],
              'elapsedMs': 125,
              'allowedNextActions': <String>[
                'drag-move',
                'drag-end',
                'drag-cancel',
              ],
            },
            'recording': <String, Object?>{
              'status': 'paused',
              'active': true,
              'paused': true,
              'name': 'checkout-flow',
              'feature': 'checkout',
              'stepCount': 4,
            },
          },
        });

        final operability = Map<String, dynamic>.from(
          response['operability']! as Map,
        );
        expect(
          _goldenView(operability, session.path),
          _readGolden('operability_observed.json'),
        );
        _expectCompleteDomains(operability);
      });
    });

    test('unavailable facts are explicit and never synthesized', () async {
      await _withSession((session) async {
        final response = FlutterScoutCli().debugCliResponseEnvelope(
          <String, Object?>{
            'ok': true,
            'commandName': 'status',
            'running': false,
            'appReachable': false,
            'session': const <String, Object?>{'mode': 'unknown'},
            'runtimeObservation': const <String, Object?>{
              'status': 'unavailable',
              'appReachability': 'unreachable',
              'reason': 'vm_service_uri_unavailable',
              'helper': <String, Object?>{
                'status': 'unavailable',
                'reason': 'vm_service_uri_unavailable',
              },
              'protocol': <String, Object?>{
                'status': 'unavailable',
                'reason': 'vm_service_uri_unavailable',
              },
              'identity': <String, Object?>{
                'status': 'unavailable',
                'runId': null,
                'runtimeInstanceId': null,
                'stateGeneration': null,
              },
              'actionState': <String, Object?>{
                'status': 'unavailable',
                'activeDrag': null,
                'reason': 'vm_service_uri_unavailable',
              },
              'recording': <String, Object?>{
                'status': 'unavailable',
                'active': null,
                'reason': 'vm_service_uri_unavailable',
              },
            },
          },
        );
        final operability = Map<String, dynamic>.from(
          response['operability']! as Map,
        );
        expect(
          _goldenView(operability, session.path),
          _readGolden('operability_unavailable.json'),
        );
        _expectCompleteDomains(operability);
        expect((operability['protocol'] as Map)['status'], 'unavailable');
        expect((operability['runtime'] as Map)['runtimeInstanceId'], isNull);
        expect((operability['runtime'] as Map)['stateGeneration'], isNull);
        expect(
          (operability['prioritizedRecoveryAction'] as Map)['action'],
          contains('ensure'),
        );
      });
    });

    test(
      'persistent health separates daemon readiness from app health',
      () async {
        await _withSession((_) async {
          final response = await FlutterScoutCli()
              .debugPersistentHealthResponse(port: 17341);
          expect(response['ok'], isTrue);
          expect(response['transportHealthy'], isTrue);
          expect(response['healthy'], isFalse);
          expect(response['appReachable'], isFalse);
          expect(response['port'], 17341);
          expect(response['authenticationRequired'], isTrue);
          expect(response['transport'], containsPair('status', 'ready'));
          expect(response['appHealth'], isA<Map>());
          expect((response['appHealth'] as Map)['ok'], isFalse);
          final operability = response['operability']! as Map;
          expect((operability['app'] as Map)['reachability'], 'unreachable');
          expect(
            operability['prioritizedRecoveryAction'],
            containsPair('action', contains('ensure')),
          );
          expect(
            (response['payloadBounds'] as Map)['safetyDisposition'],
            'complete',
          );
        });
      },
    );

    test('source verification is stale after runtime replacement', () async {
      await _withSession((_) async {
        final cli = FlutterScoutCli()..debugEnsurePrivateStorage();
        cli.debugAtomicSessionWrite(
          'session_meta.json',
          jsonEncode(const <String, Object?>{
            'mode': 'attach_only',
            'state': 'ready',
            'runId': 'run-current',
            'lastHotUpdate': <String, Object?>{
              'observedAt': '2026-08-20T00:00:00.000Z',
              'action': 'reload',
              'runId': 'run-current',
              'runtimeInstanceId': 'runtime-old',
              'sourceVerification': <String, Object?>{
                'status': 'verified',
                'verifiedCount': 2,
              },
            },
          }),
        );
        final response = cli.debugCliResponseEnvelope(const <String, Object?>{
          'ok': true,
          'commandName': 'status',
          'running': true,
          'appReachable': true,
          'session': <String, Object?>{
            'mode': 'attach_only',
            'state': 'ready',
            'runId': 'run-current',
          },
          'runtimeObservation': <String, Object?>{
            'status': 'observed',
            'appReachability': 'reachable',
            'helper': <String, Object?>{
              'status': 'observed',
              'packageVersion': '0.2.0-dev.1',
            },
            'protocol': <String, Object?>{
              'status': 'observed',
              'protocolVersion': 15,
              'minimum': 15,
              'maximum': 15,
              'capabilities': <String, Object?>{},
            },
            'identity': <String, Object?>{
              'status': 'observed',
              'runId': 'run-current',
              'runtimeInstanceId': 'runtime-new',
              'stateGeneration': 1,
            },
          },
        });
        final operability = response['operability']! as Map;
        expect(
          operability['sourceFreshness'],
          allOf(
            containsPair('status', 'stale_runtime'),
            containsPair(
              'reason',
              'runtime_replaced_since_source_verification',
            ),
          ),
        );
        expect(
          operability['prioritizedRecoveryAction'],
          containsPair('action', 'flutter-scout reload'),
        );
      });
    });
  });
}

Future<void> _withSession(Future<void> Function(Directory session) body) async {
  final root = Directory.systemTemp.createTempSync('scout_operability_');
  final session = Directory(p.join(root.path, '.flutter_scout'));
  FlutterScoutRetentionDebug.debugUseSessionDirectory(session.path);
  try {
    await body(session);
  } finally {
    FlutterScoutRetentionDebug.debugUseSessionDirectory(null);
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

Map<String, Object?> _goldenView(
  Map<String, dynamic> operability,
  String sessionPath,
) {
  final canonicalSessionPath = p.join(
    Directory(p.dirname(sessionPath)).resolveSymbolicLinksSync(),
    p.basename(sessionPath),
  );

  Object? normalized(Object? value) {
    if (value is String) {
      return value
          .replaceAll(canonicalSessionPath, '<SESSION>')
          .replaceAll(sessionPath, '<SESSION>');
    }
    if (value is List) {
      return <Object?>[for (final item in value) normalized(item)];
    }
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries)
          entry.key.toString(): normalized(entry.value),
      };
    }
    return value;
  }

  final binary = operability['binary']! as Map;
  final cli = binary['cli']! as Map;
  final helper = binary['helper']! as Map;
  final protocol = operability['protocol']! as Map;
  final cliSupported = protocol['cliSupported']! as Map;
  final helperObserved = protocol['helperObserved']! as Map;
  final negotiated = protocol['negotiated']! as Map;
  final artifacts = operability['artifacts']! as Map;
  final session = operability['session']! as Map;
  final sourceFreshness = operability['sourceFreshness']! as Map;
  return normalized(<String, Object?>{
        'contractVersion': operability['contractVersion'],
        'command': operability['command'],
        'binary': <String, Object?>{
          'status': binary['status'],
          'cli': <String, Object?>{
            'package': cli['package'],
            'packageVersion': cli['packageVersion'],
          },
          'helper': helper,
        },
        'protocol': <String, Object?>{
          'status': protocol['status'],
          'cliSupported': <String, Object?>{
            'schemaVersion': cliSupported['schemaVersion'],
            'minimum': cliSupported['minimum'],
            'maximum': cliSupported['maximum'],
            'capabilities': _trueCapabilities(cliSupported['capabilities']),
          },
          'helperObserved': <String, Object?>{
            for (final key in const <String>[
              'status',
              'reason',
              'schemaVersion',
              'protocolVersion',
              'minimum',
              'maximum',
            ])
              if (helperObserved.containsKey(key)) key: helperObserved[key],
            if (helperObserved['capabilities'] is Map)
              'capabilities': _trueCapabilities(helperObserved['capabilities']),
          },
          'negotiated': <String, Object?>{
            'status': negotiated['status'],
            'selectedVersion': negotiated['selectedVersion'],
            if (negotiated['capabilities'] is Map)
              'capabilities': _trueCapabilities(negotiated['capabilities']),
            if (negotiated['capabilities'] == null) 'capabilities': null,
          },
        },
        'session': <String, Object?>{
          'status': session['status'],
          'name': session['name'],
          'mode': session['mode'],
          'state': session['state'],
          'runId': session['runId'],
          'project': session['project'],
          'sourceIdentity': session['sourceIdentity'],
        },
        'device': operability['device'],
        'app': operability['app'],
        'runnerOwnership': operability['runnerOwnership'],
        'supervisorStatus': (operability['supervisor'] as Map)['status'],
        'runtime': operability['runtime'],
        'artifacts': <String, Object?>{
          for (final name in const <String>[
            'logs',
            'recordings',
            'evidence',
            'events',
          ])
            name: artifacts[name],
        },
        'actionState': operability['actionState'],
        'recordingState': operability['recordingState'],
        'sourceFreshness': <String, Object?>{
          for (final key in const <String>[
            'status',
            'reason',
            'verifiedCount',
            'mismatchedCount',
            'action',
          ])
            if (sourceFreshness.containsKey(key)) key: sourceFreshness[key],
        },
        'prioritizedRecoveryAction': operability['prioritizedRecoveryAction'],
      })!
      as Map<String, Object?>;
}

List<String> _trueCapabilities(Object? value) {
  if (value is! Map) return const <String>[];
  return <String>[
    for (final entry in value.entries)
      if (entry.value == true) entry.key.toString(),
  ]..sort();
}

Map<String, dynamic> _readGolden(String name) => Map<String, dynamic>.from(
  jsonDecode(File(p.join('test', 'goldens', name)).readAsStringSync()) as Map,
);

void _expectCompleteDomains(Map<String, dynamic> operability) {
  for (final key in const <String>[
    'binary',
    'protocol',
    'session',
    'device',
    'app',
    'runnerOwnership',
    'supervisor',
    'runtime',
    'artifacts',
    'actionState',
    'recordingState',
    'sourceFreshness',
    'prioritizedRecoveryAction',
  ]) {
    expect(operability, contains(key), reason: 'missing $key');
  }
}
