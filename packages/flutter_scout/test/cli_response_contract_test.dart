import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late String _packageRoot;

void main() {
  _packageRoot = Directory.current.absolute.path;
  group('typed CLI response contract', () {
    test(
      'local success, error, helper, and heartbeat shapes match goldens',
      () async {
        await _withTemporaryWorkspace((_) async {
          final cli = FlutterScoutCli();
          final success = cli.debugCliResponseEnvelope(<String, Object?>{
            'ok': true,
            'commandName': 'version',
            'commandId': 'command-golden',
            'runId': null,
            'runtimeInstanceId': null,
            'stateGeneration': null,
            'timings': const <String, Object?>{'totalMs': 7},
            'package': 'flutter_scout',
            'version': '2.0.0-dev.1',
          });
          expect(
            _goldenView(success),
            _readGolden('cli_response_success.json'),
          );

          final failure = cli.debugCliResponseEnvelope(<String, Object?>{
            'ok': false,
            'commandName': 'input',
            'commandId': 'failure-golden',
            'runId': 'run-golden',
            'runtimeInstanceId': null,
            'stateGeneration': null,
            'error': const <String, Object?>{
              'code': 'usage',
              'message': 'A value is required.',
            },
            'timings': const <String, Object?>{'totalMs': 11},
          });
          expect(_goldenView(failure), _readGolden('cli_response_error.json'));
          final factualFailure = cli.debugCliResponseEnvelope(<String, Object?>{
            'ok': false,
            'result': const <String, Object?>{
              'dispatch': 'not_dispatched',
              'evidence': 'preserved',
            },
            'structuredError': const <String, Object?>{
              'code': 'runtime_lost',
              'message': 'The runtime was unavailable.',
            },
          });
          expect(
            factualFailure['result'],
            containsPair('dispatch', 'not_dispatched'),
          );

          final helper = cli.debugCliResponseEnvelope(<String, Object?>{
            'ok': true,
            'schemaVersion': 1,
            'protocolVersion': 15,
            'minSupportedProtocolVersion': 15,
            'maxSupportedProtocolVersion': 15,
            'capabilities': const <String, Object?>{
              'typedEnvelopeV1': true,
              'runtimeSignalProvenanceV1': true,
            },
            'capabilitySource': 'negotiated',
            'commandName': 'inspect',
            'commandId': 'helper-command',
            'runId': 'helper-run',
            'runtimeInstanceId': 'helper-runtime',
            'stateGeneration': 9,
            'result': const <String, Object?>{'screen': 'Home'},
            'structuredError': null,
            'timings': const <String, Object?>{'totalMs': 3},
            'logCursor': 4,
          });
          expect(_goldenView(helper), _readGolden('cli_helper_response.json'));

          final heartbeat = cli.debugCliHeartbeatEnvelope(
            stage: 'resolve_device',
            elapsedMs: 1250,
            commandId: 'heartbeat-command',
            runId: 'heartbeat-run',
            progress: const <String, Object?>{'requestedDevice': 'ios'},
          );
          expect(_goldenView(heartbeat), _readGolden('cli_heartbeat.json'));
        });
      },
    );

    test(
      'real local commands and structured failures all emit envelopes',
      () async {
        await _withTemporaryWorkspace((temporary) async {
          for (final arguments in const <List<String>>[
            <String>['version'],
            <String>['status'],
            <String>['record', 'list'],
            <String>['doctor'],
          ]) {
            final captured = await _captureRun(FlutterScoutCli(), arguments);
            expect(
              captured.exitCode,
              0,
              reason: '$arguments: ${captured.stderr}',
            );
            final response = _decodeSingleJson(captured.stdout);
            _expectCompleteEnvelope(response);
            _expectMeasuredOutputSerialization(response);
            expect(response['ok'], isTrue, reason: '$arguments');
            expect(response['result'], isNotNull, reason: '$arguments');
            if (const <String>{'status', 'doctor'}.contains(arguments.first)) {
              _expectOperability(response);
            }
          }

          final failure = await _captureRun(FlutterScoutCli(), const <String>[
            'record',
            'show',
            'does-not-exist',
          ]);
          expect(failure.exitCode, 1);
          final response = _decodeSingleJson(failure.stderr);
          _expectCompleteEnvelope(response);
          _expectMeasuredOutputSerialization(response);
          expect(response['ok'], isFalse);
          expect(response['result'], isNull);
          expect(
            response['structuredError'],
            allOf(isA<Map>(), containsPair('code', 'record_not_found')),
          );
          expect(response['commandId'], isNotNull);

          final health = await _captureRun(FlutterScoutCli(), const <String>[
            'health',
          ]);
          expect(health.exitCode, 1);
          final healthResponse = _decodeSingleJson(health.stdout);
          _expectCompleteEnvelope(healthResponse);
          _expectMeasuredOutputSerialization(healthResponse);
          _expectOperability(healthResponse);
          expect(healthResponse['structuredError'], isA<Map>());
          expect(
            Directory(p.join(temporary.path, '.flutter_scout')).existsSync(),
            isTrue,
          );

          final unknown = await _captureRun(FlutterScoutCli(), const <String>[
            'definitely-unknown',
          ]);
          expect(unknown.exitCode, 64);
          expect(unknown.stdout, isEmpty);
          final unknownResponse = _decodeSingleJson(unknown.stderr);
          _expectCompleteEnvelope(unknownResponse);
          _expectMeasuredOutputSerialization(unknownResponse);
          expect(
            unknownResponse['structuredError'],
            containsPair('code', 'unknown_command'),
          );
          final details =
              (unknownResponse['structuredError'] as Map)['details'] as Map;
          expect(
            details['availableCommands'],
            containsAll(<String>[
              'devices',
              'drag-cancel',
              'drag-status',
              'dismiss',
              'export-batch',
              'explore',
              'deeplink',
              'help',
            ]),
          );

          // Help is the one explicitly human-rendered stdout surface. It is
          // requested by the caller and never mixed into a machine error.
          final help = await _captureRun(FlutterScoutCli(), const <String>[
            'help',
          ]);
          expect(help.exitCode, 0);
          expect(help.stdout, contains('Flutter Scout'));
          expect(help.stderr, isEmpty);

          final commandEvents =
              File(p.join(temporary.path, '.flutter_scout', 'events.jsonl'))
                  .readAsLinesSync()
                  .map(jsonDecode)
                  .whereType<Map>()
                  .where((event) => event['type'] == 'command');
          expect(commandEvents, isNotEmpty);
          for (final event in commandEvents) {
            final typed = <String, dynamic>{
              for (final entry in event.entries)
                entry.key.toString(): entry.value,
            };
            _expectCanonicalPhaseTimings(typed);
            final phases = ((typed['timings'] as Map)['phases'] as Map);
            for (final record in phases.values.cast<Map>()) {
              expect(record['status'], 'unavailable');
              expect(
                record['reason'],
                'lifecycle_reservation_not_action_evidence',
              );
            }
          }
        });
      },
    );

    test(
      'manual direct-call mutations fail typed before VM dispatch',
      () async {
        await _withTemporaryWorkspace((_) async {
          for (final arguments in const <List<String>>[
            <String>['tap-text', 'Save'],
            <String>['drag-move', '--to', '10,20'],
            <String>['scroll-to', 'btn.save'],
          ]) {
            final captured = await _captureRun(FlutterScoutCli(), arguments);
            expect(captured.exitCode, 1, reason: '$arguments');
            final response = _decodeSingleJson(captured.stdout);
            _expectCompleteEnvelope(response);
            _expectMeasuredOutputSerialization(response);
            expect(
              response['structuredError'],
              containsPair('code', 'not_attached'),
            );
            expect(response['dispatch'], 'not_dispatched');
            expect(response['transport'], 'failed');
            expect(response['result'], isNull);
            expect(
              response['stability'],
              containsPair('state', 'runtime_lost'),
            );
            expect(response['runtimeInstanceId'], isNull);
            expect(response['stateGeneration'], isNull);
          }
        });
      },
    );

    test('mixed endpoint mutations commit evidence and reads do not', () async {
      await _withTemporaryWorkspace((temporary) async {
        for (final arguments in const <List<String>>[
          <String>['annotations', 'enable'],
          <String>['annotations', 'list'],
          <String>['record', 'start', 'contract-flow'],
          <String>['record', 'status'],
        ]) {
          await _captureRun(FlutterScoutCli(), arguments);
        }
        final events =
            File(p.join(temporary.path, '.flutter_scout', 'events.jsonl'))
                .readAsLinesSync()
                .map(jsonDecode)
                .whereType<Map<String, dynamic>>()
                .toList(growable: false);
        final actions = events
            .where((event) => event['type'] == 'action_result')
            .toList(growable: false);
        expect(actions, hasLength(2));
        expect(
          actions.map((event) => event['method']),
          unorderedEquals(<String>[
            'ext.flutter_scout.annotations',
            'ext.flutter_scout.record',
          ]),
        );
        for (final action in actions) {
          _expectCorrelatedEvent(action);
          expect(action['evidence'], containsPair('eventJournal', 'committed'));
        }
      });
    });

    test('events are deterministic and every identity is explicit', () async {
      await _withTemporaryWorkspace((temporary) async {
        final cli = FlutterScoutCli();
        expect(
          cli.debugAppendEventStrict(<String, Object?>{
            'type': 'contract',
            'commandId': 'event-command',
            'runId': 'event-run',
            'runtimeInstanceId': 'event-runtime',
            'stateGeneration': 4,
          }),
          1,
        );
        expect(
          cli.debugAppendEventStrict(<String, Object?>{'type': 'local'}),
          2,
        );
        final rows =
            File(p.join(temporary.path, '.flutter_scout', 'events.jsonl'))
                .readAsLinesSync()
                .map(jsonDecode)
                .whereType<Map<String, dynamic>>()
                .toList(growable: false);
        expect(rows.map((row) => row['eventCursor']), <Object?>[1, 2]);
        expect(rows[0]['previousEventCursor'], isNull);
        expect(rows[1]['previousEventCursor'], 1);
        for (final row in rows) {
          _expectCorrelatedEvent(row);
        }
        expect(rows[1]['runtimeInstanceId'], isNull);
        expect(rows[1]['stateGeneration'], isNull);
        expect(
          (rows[1]['correlation'] as Map)['availability'],
          containsPair('runtimeInstanceId', 'unavailable'),
        );
      });
    });

    test(
      'pathological payloads are bounded without losing envelope fields',
      () async {
        await _withTemporaryWorkspace((_) async {
          final response = FlutterScoutCli().debugCliResponseEnvelope(
            <String, Object?>{
              'ok': true,
              'commandId': 'bounded-command',
              'blob': 'x' * 70000,
            },
          );
          _expectCompleteEnvelope(response);
          expect(response['payloadBounds'], containsPair('truncated', isTrue));
          expect((response['blob'] as String).length, lessThan(70000));
          expect(
            utf8.encode(jsonEncode(response)).length,
            lessThanOrEqualTo(4 * 1024 * 1024),
          );
          expect(response['ok'], isFalse);
          expect(response['result'], isNull);
          expect(
            response['structuredError'],
            containsPair('code', 'truncated_safety_evidence'),
          );

          final lateSafetyEvidence = <String, Object?>{
            for (var index = 0; index < 1100; index++) 'filler$index': index,
            'ok': true,
            'dispatch': 'outcome_unknown',
            'errorsSinceCursor': const <String>['blocking failure'],
            'structuredError': const <String, Object?>{
              'code': 'late_blocking_error',
              'message': 'This must never be compacted into success.',
            },
          };
          final late = FlutterScoutCli().debugCliResponseEnvelope(
            lateSafetyEvidence,
          );
          _expectCompleteEnvelope(late);
          expect(late['ok'], isFalse);
          expect(late['result'], isNull);
          expect(late['safetyEvidenceStatus'], 'truncated');
          expect(
            late['structuredError'],
            containsPair('code', 'truncated_safety_evidence'),
          );
          expect(late, contains('commandId'));
          expect(late, contains('identityAvailability'));

          final longCritical = FlutterScoutCli().debugCliResponseEnvelope(
            <String, Object?>{
              'ok': false,
              'error': <String, Object?>{
                'code': 'critical_failure',
                'message': 'critical:${'z' * 70000}',
              },
            },
          );
          expect(longCritical['ok'], isFalse);
          expect(longCritical['result'], isNull);
          expect(
            longCritical['structuredError'],
            containsPair('code', 'truncated_safety_evidence'),
          );
        });
      },
    );
  });
}

Map<String, dynamic> _goldenView(Map<String, Object?> response) {
  const keys = <String>[
    'messageType',
    'ok',
    'schemaVersion',
    'protocolVersion',
    'protocolRange',
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
    'stage',
    'elapsedMs',
    'heartbeatCursor',
    'progress',
  ];
  final capabilities = response['capabilities'] as Map;
  return <String, dynamic>{
    for (final key in keys)
      if (response.containsKey(key)) key: response[key],
    'capabilities': <String, Object?>{
      for (final key in const <String>[
        'runtimeSignalProvenanceV1',
        'cliResponseEnvelopeV1',
        'structuredHeartbeatsV1',
        'correlatedEventCursorsV1',
        'boundedCliPayloadsV1',
      ])
        key: capabilities[key],
    },
  };
}

Map<String, dynamic> _readGolden(String name) =>
    jsonDecode(
          File(
            p.join(_packageRoot, 'test', 'goldens', name),
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

void _expectCompleteEnvelope(Map<String, dynamic> response) {
  for (final key in const <String>[
    'messageType',
    'ok',
    'schemaVersion',
    'protocolVersion',
    'minSupportedProtocolVersion',
    'maxSupportedProtocolVersion',
    'protocolRange',
    'capabilities',
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
  ]) {
    expect(response, contains(key), reason: 'missing $key');
  }
  expect(response['schemaVersion'], 1);
  expect(response['protocolVersion'], 15);
  _expectCanonicalPhaseTimings(response);
  if (response['ok'] == true) {
    expect(response['structuredError'], isNull);
  } else {
    expect(response['structuredError'], isA<Map>());
  }
}

void _expectCanonicalPhaseTimings(Map<String, dynamic> response) {
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
  final timings = response['timings'];
  expect(timings, isA<Map>());
  final phases = (timings! as Map)['phases'];
  expect(phases, isA<Map>());
  expect((phases! as Map).keys.toList(), phaseNames);
  for (final phaseName in phaseNames) {
    final phase = phases[phaseName];
    expect(phase, isA<Map>(), reason: phaseName);
    final record = phase! as Map;
    final status = record['status'];
    expect(status, anyOf('measured', 'unavailable'), reason: phaseName);
    if (status == 'measured') {
      expect(record['elapsedMs'], isA<int>(), reason: phaseName);
      expect(record['elapsedMs'] as int, greaterThanOrEqualTo(0));
    } else {
      expect(record['elapsedMs'], isNull, reason: phaseName);
      expect(record['reason'], isA<String>(), reason: phaseName);
      expect((record['reason'] as String).trim(), isNotEmpty);
    }
  }
  final overhead = timings['actionOverheadExcludingSettle'];
  expect(overhead, isA<Map>());
  expect((overhead as Map)['excludes'], 'settle');
}

void _expectMeasuredOutputSerialization(Map<String, dynamic> response) {
  final serialize =
      (((response['timings'] as Map)['phases'] as Map)['serialize'] as Map);
  expect(serialize['status'], 'measured');
  expect(serialize['elapsedMs'], isA<int>());
  expect(serialize['elapsedMs'] as int, greaterThanOrEqualTo(0));
  expect(serialize['owner'], anyOf('cli', 'helper_and_cli'));
  expect(serialize['finalWriteLatencyIncluded'], isFalse);
}

void _expectOperability(Map<String, dynamic> response) {
  final operability = response['operability'];
  expect(operability, isA<Map>());
  for (final key in const <String>[
    'binary',
    'protocol',
    'session',
    'processOwnership',
    'vm',
    'logs',
    'capture',
    'sourceFreshness',
    'prioritizedRecoveryAction',
  ]) {
    expect(operability as Map, contains(key), reason: 'missing $key');
  }
}

void _expectCorrelatedEvent(Map<String, dynamic> event) {
  for (final key in const <String>[
    'eventCursor',
    'cursor',
    'previousEventCursor',
    'commandId',
    'cliCommandId',
    'runId',
    'sessionRunId',
    'runtimeInstanceId',
    'stateGeneration',
    'logCursor',
    'identityStatus',
    'correlation',
  ]) {
    expect(event, contains(key), reason: 'missing event $key');
  }
  expect(event['logCursor'], isA<int>());
  expect(event['correlation'], isA<Map>());
}

Map<String, dynamic> _decodeSingleJson(String text) {
  final decoded = jsonDecode(text.trim());
  expect(decoded, isA<Map>());
  return Map<String, dynamic>.from(decoded as Map);
}

Future<_CapturedRun> _captureRun(
  FlutterScoutCli cli,
  List<String> arguments,
) async {
  final capturedOut = _CapturedStdout();
  final capturedErr = _CapturedStdout();
  late final int exitCode;
  await IOOverrides.runZoned(
    () async {
      exitCode = await cli.run(arguments);
    },
    stdout: () => capturedOut,
    stderr: () => capturedErr,
  );
  return _CapturedRun(
    exitCode: exitCode,
    stdout: capturedOut.text,
    stderr: capturedErr.text,
  );
}

Future<void> _withTemporaryWorkspace(
  Future<void> Function(Directory temporary) body,
) async {
  final previous = Directory.current;
  final previousRegistry = FlutterScoutCli.debugRegistryPathOverride;
  final temporary = await Directory.systemTemp.createTemp(
    'flutter_scout_cli_response_',
  );
  try {
    Directory.current = temporary;
    FlutterScoutCli.debugRegistryPathOverride = p.join(
      temporary.path,
      'registry.json',
    );
    await body(temporary);
  } finally {
    FlutterScoutCli.debugRegistryPathOverride = previousRegistry;
    Directory.current = previous;
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  }
}

class _CapturedRun {
  const _CapturedRun({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

class _CapturedStdout implements Stdout {
  final StringBuffer _buffer = StringBuffer();

  String get text => _buffer.toString();

  @override
  void write(Object? object) => _buffer.write(object);

  @override
  void writeln([Object? object = '']) => _buffer.writeln(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _buffer.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _buffer.writeCharCode(charCode);

  @override
  void add(List<int> data) =>
      _buffer.write(utf8.decode(data, allowMalformed: true));

  @override
  Future<void> close() async {}

  @override
  Future<void> flush() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
