import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('large action diagnostics commit without losing safety or ordering', () {
    _withSession((cli, session) {
      final original = _largeFailedAction();
      expect(utf8.encode(jsonEncode(original)).length, greaterThan(128 * 1024));
      final reservation = cli.debugAppendEventStrict(<String, Object?>{
        'type': 'command',
        'status': 'started',
        'commandId': 'cli-command',
      });

      final reported = cli.debugCommitActionEvidence(
        method: 'ext.flutter_scout.tap',
        result: original,
      );
      expect(reported['ok'], isFalse);
      expect(reported['evidence'], containsPair('eventJournal', 'committed'));
      expect(reported['evidence'], containsPair('eventCursor', 2));
      // Journal projection must not mutate the full/verbose response.
      expect(reported['error'], original['error']);
      expect(reported['structuredError'], original['structuredError']);

      cli.debugUpdateEventStrict(
        cursor: reservation,
        commandId: 'cli-command',
        updates: const <String, Object?>{'status': 'completed', 'exitCode': 1},
      );
      final events = FlutterScoutCli().debugReadEventJournal();
      expect(events.map((event) => event['eventCursor']), <int>[1, 2]);
      expect(events.first['status'], 'completed');
      final action = events.last;
      print(
        'action diagnostics: ${utf8.encode(jsonEncode(original)).length} '
        'input bytes -> ${utf8.encode(jsonEncode(action)).length} '
        'persisted event bytes',
      );
      expect(action['previousEventCursor'], 1);
      for (final key in <String>[
        'commandId',
        'runId',
        'runtimeInstanceId',
        'snapshotId',
        'stateGeneration',
        'stateDigest',
        'dispatch',
        'observation',
        'postcondition',
        'stability',
        'runtimeHealth',
        'errorCursor',
        'errorsSinceCursor',
        'activeBlockingSignals',
        'idempotency',
      ]) {
        expect(action[key], original[key], reason: key);
      }
      for (final key in <String>['error', 'structuredError']) {
        final error = action[key]! as Map;
        expect(error['code'], 'expectation_failed');
        final details = error['details']! as Map;
        expect(details['expectation'], 'Missing destination');
        expect(details['activation'], containsPair('dispatched', true));
        for (final stage in <String>['before', 'after']) {
          final snapshot = details[stage]! as Map;
          expect(snapshot['snapshotId'], 'snapshot-$stage');
          expect(snapshot['errorsSinceCursor'], original['errorsSinceCursor']);
          expect(
            snapshot['activeBlockingSignals'],
            original['activeBlockingSignals'],
          );
          expect(
            snapshot['observationDetail'],
            containsPair('presentation', 'summary'),
          );
          expect(snapshot.containsKey('interactables'), isFalse);
        }
      }
      final operations = Directory(
        p.join(session.path, 'events', 'segments'),
      ).listSync().whereType<File>().expand((file) => file.readAsLinesSync());
      expect(operations, hasLength(3));
      for (final operation in operations) {
        expect(
          utf8.encode('$operation\n').length,
          lessThanOrEqualTo(128 * 1024),
        );
      }
    });
  });

  test(
    'unbounded unknown diagnostics still fail closed without consuming cursor',
    () {
      _withSession((cli, _) {
        cli.debugAppendEventStrict(<String, Object?>{'type': 'before'});
        final original = _largeFailedAction();
        final error = original['error']! as Map<String, Object?>;
        (error['details']! as Map<String, Object?>)['futureSafetyEvidence'] =
            '界' * (128 * 1024);
        final reported = cli.debugCommitActionEvidence(
          method: 'ext.flutter_scout.tap',
          result: original,
        );
        expect(reported['ok'], isFalse);
        expect(
          reported['error'],
          containsPair('code', 'action_evidence_persistence_failed'),
        );
        expect(reported['mutationMayHaveOccurred'], isTrue);
        expect(reported['evidence'], containsPair('eventJournal', 'failed'));
        expect(
          cli.debugAppendEventStrict(<String, Object?>{'type': 'after'}),
          2,
        );
        expect(
          cli.debugReadEventJournal().map((event) => event['type']),
          <String>['before', 'after'],
        );
      });
    },
  );
}

Map<String, dynamic> _largeFailedAction() {
  final signals = List<Map<String, Object?>>.generate(
    20,
    (index) => <String, Object?>{
      'code': 'fresh-error-$index',
      'blocking': true,
      'cursor': index + 1,
    },
  );
  final controls = List<Map<String, Object?>>.generate(
    1000,
    (index) => <String, Object?>{
      'id': 'btn.control_$index',
      'label': '菜单项目 $index',
      'rect': <int>[0, index, 100, 40],
      'enabled': true,
    },
  );
  final error = <String, Object?>{
    'code': 'expectation_failed',
    'message': 'The requested destination was not observed.',
    'details': <String, Object?>{
      'expectation': 'Missing destination',
      'activation': <String, Object?>{
        'dispatched': true,
        'target': 'btn.control_1',
      },
      for (final stage in <String>['before', 'after'])
        stage: <String, Object?>{
          'snapshotId': 'snapshot-$stage',
          'screen': 'MenuScreen',
          'interactables': controls,
          'errorsSinceCursor': signals,
          'activeBlockingSignals': signals,
        },
    },
  };
  return <String, dynamic>{
    'ok': false,
    'schemaVersion': 1,
    'protocolVersion': 15,
    'commandId': 'runtime-command',
    'runId': 'run-journal',
    'runtimeInstanceId': 'runtime-journal',
    'snapshotId': 'snapshot-after',
    'stateGeneration': 7,
    'stateDigest': 'digest-after',
    'dispatch': 'dispatched',
    'observation': 'no_effect',
    'postcondition': 'postcondition_not_met',
    'stability': <String, Object?>{'stable': true},
    'runtimeHealth': 'runtime_blocked',
    'errorCursor': 20,
    'errorsSinceCursor': signals,
    'activeBlockingSignals': signals,
    'idempotency': <String, Object?>{'status': 'completed'},
    'error': error,
    'structuredError': error,
  };
}

void _withSession(void Function(FlutterScoutCli cli, Directory session) body) {
  final previous = Directory.current;
  final temporary = Directory.systemTemp.createTempSync('scout_action_event_');
  try {
    Directory.current = temporary;
    body(
      FlutterScoutCli(),
      Directory(p.join(temporary.path, '.flutter_scout')),
    );
  } finally {
    Directory.current = previous;
    temporary.deleteSync(recursive: true);
  }
}
