import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _phaseNames = <String>[
  'connect',
  'snapshot',
  'match',
  'dispatch',
  'settle',
  'delta',
  'logs',
  'serialize',
];

Map<String, Object?> _measured(int elapsedMs, {String owner = 'helper'}) =>
    <String, Object?>{
      'status': 'measured',
      'elapsedMs': elapsedMs,
      'owner': owner,
      'clock': 'monotonic_stopwatch',
      'aggregation': 'exclusive_non_overlapping',
    };

Map<String, Object?> _unavailable(String reason, {String owner = 'helper'}) =>
    <String, Object?>{
      'status': 'unavailable',
      'elapsedMs': null,
      'owner': owner,
      'reason': reason,
    };

Map<String, Object?> _phases(Map<String, int> measured) => <String, Object?>{
  for (final name in _phaseNames)
    name: measured.containsKey(name)
        ? _measured(
            measured[name]!,
            owner: const <String>{'connect', 'logs'}.contains(name)
                ? 'cli'
                : 'helper',
          )
        : _unavailable(
            'not_applicable:test_fixture',
            owner: const <String>{'connect', 'logs', 'serialize'}.contains(name)
                ? 'cli'
                : 'helper',
          ),
};

void main() {
  test('canonical closure emits all eight phases with exact semantics', () {
    final result = FlutterScoutCli().debugCanonicalPhaseTimings(
      <String, dynamic>{
        'ok': false,
        'timings': <String, Object?>{
          'phases': <String, Object?>{
            'connect': _measured(4, owner: 'cli'),
            'snapshot': _unavailable('snapshot_not_observed'),
            'match': <String, Object?>{'status': 'measured', 'elapsedMs': -1},
          },
        },
      },
    );

    final phases = (result['timings']! as Map)['phases']! as Map;
    expect(phases.keys.toList(), _phaseNames);
    expect((phases['connect'] as Map)['elapsedMs'], 4);
    expect((phases['snapshot'] as Map)['reason'], 'snapshot_not_observed');
    expect((phases['match'] as Map)['status'], 'unavailable');
    expect((phases['match'] as Map)['reason'], 'invalid_helper_phase_record');
    expect((phases['dispatch'] as Map)['elapsedMs'], isNull);
    expect(
      (phases['dispatch'] as Map)['reason'],
      'helper_phase_missing_from_response',
    );
  });

  test('action overhead is the exact exclusive sum excluding settle', () {
    final result = FlutterScoutCli().debugCanonicalPhaseTimings(
      <String, dynamic>{
        'timings': <String, Object?>{
          'phases': _phases(<String, int>{
            'connect': 2,
            'snapshot': 3,
            'match': 5,
            'dispatch': 7,
            'settle': 1000,
            'delta': 11,
            'logs': 13,
            'serialize': 17,
          }),
        },
      },
    );

    final timings = result['timings']! as Map;
    expect(timings['actionOverheadExcludingSettleMs'], 58);
    expect(
      (timings['actionOverheadExcludingSettle'] as Map)['method'],
      'sum_of_exclusive_non_settle_phases',
    );
  });

  test(
    'preflight aggregation retains sequential snapshot and serialize work',
    () {
      final cli = FlutterScoutCli();
      final result = cli.debugMergePreflightPhaseTimings(
        <String, dynamic>{
          'timings': <String, Object?>{
            'phases': _phases(<String, int>{
              'snapshot': 3,
              'dispatch': 5,
              'settle': 100,
              'serialize': 7,
            }),
          },
        },
        <String, Object?>{
          'phases': _phases(<String, int>{'snapshot': 11, 'serialize': 13}),
        },
      );
      final phases = (result['timings']! as Map)['phases']! as Map;
      expect((phases['snapshot'] as Map)['elapsedMs'], 14);
      expect((phases['snapshot'] as Map)['preflightElapsedMs'], 11);
      expect((phases['snapshot'] as Map)['actionElapsedMs'], 3);
      expect((phases['serialize'] as Map)['elapsedMs'], 20);
      expect((phases['settle'] as Map)['elapsedMs'], 100);
    },
  );

  test(
    'compact and event evidence retain canonical measured serialization',
    () {
      final previous = Directory.current;
      final temporary = Directory.systemTemp.createTempSync(
        'flutter-scout-phase-evidence-',
      );
      try {
        Directory.current = temporary.path;
        final cli = FlutterScoutCli()..debugEnsurePrivateStorage();
        final committed = cli.debugCommitActionEvidence(
          method: 'ext.flutter_scout.tap',
          result: <String, dynamic>{
            'ok': true,
            'dispatch': 'dispatched',
            'timings': <String, Object?>{
              'phases': _phases(<String, int>{
                'connect': 1,
                'snapshot': 2,
                'match': 3,
                'dispatch': 4,
                'settle': 50,
                'delta': 5,
                'logs': 6,
                'serialize': 7,
              }),
            },
          },
        );
        final compact = cli.debugCompactActionResult(committed);
        final compactPhases = ((compact['timings']! as Map)['phases']! as Map);
        expect(compactPhases.keys.toList(), _phaseNames);
        expect((compactPhases['serialize'] as Map)['status'], 'measured');
        expect(
          (compactPhases['serialize'] as Map)['boundary'],
          'action_event_journal',
        );

        final eventFile = File(
          p.join(temporary.path, '.flutter_scout', 'events.jsonl'),
        );
        final event = jsonDecode(eventFile.readAsLinesSync().single) as Map;
        final eventPhases = ((event['timings'] as Map)['phases'] as Map);
        expect(eventPhases.keys.toList(), _phaseNames);
        expect((eventPhases['serialize'] as Map)['status'], 'measured');
        expect(
          (eventPhases['serialize'] as Map)['elapsedMs'],
          greaterThanOrEqualTo(0),
        );
      } finally {
        Directory.current = previous;
        temporary.deleteSync(recursive: true);
      }
    },
  );
}
