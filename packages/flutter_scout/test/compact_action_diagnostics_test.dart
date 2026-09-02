import 'dart:convert';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:test/test.dart';

void main() {
  test('failed action diagnostics summarize trees without losing safety', () {
    final cli = FlutterScoutCli();
    final snapshot = _largeSnapshot();
    final details = <String, Object?>{
      'before': snapshot,
      'after': snapshot,
      'failureSnapshot': snapshot,
      'activation': {'dispatched': true},
      'expectation': {
        'met': false,
        'conditions': {'text': 'Saved'},
      },
      'resolution': {
        'status': 'ambiguous',
        'candidates': ['a', 'b'],
      },
      'recentErrors': [
        {'blocking': true, 'message': 'Build failed'},
      ],
      'unknownFutureSafetyFact': {'mustReconcile': true},
    };
    final input = <String, dynamic>{
      'ok': false,
      'result': 'activated_no_observed_change',
      'dispatch': 'dispatched',
      'observation': 'no_effect',
      'postcondition': 'postcondition_not_met',
      'runtimeHealth': 'runtime_blocked',
      'errorsSinceCursor': List.generate(
        20,
        (i) => {'identity': 'fresh-$i', 'blocking': true},
      ),
      'activeBlockingSignals': List.generate(
        20,
        (i) => {'identity': 'active-$i'},
      ),
      'idempotencyKey': 'generated-key',
      'evidence': {'eventJournal': 'committed'},
      'beforeSnapshotId': 'g1:before',
      'afterSnapshotId': 'g2:after',
      'structuredError': {
        'code': 'expectation_not_met',
        'message': 'Timed out',
        'details': details,
      },
    };
    final beforeBytes = utf8
        .encode(jsonEncode(cli.debugCliResponseEnvelope(input)))
        .length;
    final compact = cli.debugCompactActionResult(input);
    final output = cli.debugCliResponseEnvelope(compact);
    final afterBytes = utf8.encode(jsonEncode(output)).length;
    expect(afterBytes, lessThan(beforeBytes ~/ 8));
    expect(afterBytes, lessThan(20000));
    expect(output['ok'], isFalse);
    expect((output['payloadBounds'] as Map)['truncated'], isFalse);
    final error = output['structuredError'] as Map;
    expect(error['code'], 'expectation_not_met');
    final retained = error['details'] as Map;
    for (final key in [
      'activation',
      'expectation',
      'resolution',
      'recentErrors',
      'unknownFutureSafetyFact',
    ]) {
      expect(retained[key], details[key]);
    }
    final after = retained['after'] as Map;
    expect(after['recentErrors'], snapshot['recentErrors']);
    expect(after['activeBlockingSignals'], snapshot['activeBlockingSignals']);
    expect(
      after['unknownFutureSafetyFact'],
      snapshot['unknownFutureSafetyFact'],
    );
    expect(after['snapshotId'], 'g2:after');
    expect(after, isNot(contains('visualTree')));
    expect((after['perception'] as Map)['limitationCount'], 200);
    expect((after['perception'] as Map)['semantics'], {'available': false});
    for (final key in [
      'dispatch',
      'observation',
      'postcondition',
      'runtimeHealth',
      'errorsSinceCursor',
      'activeBlockingSignals',
      'idempotencyKey',
      'evidence',
      'beforeSnapshotId',
      'afterSnapshotId',
    ]) {
      expect(compact[key], input[key]);
    }
    // Compaction is a projection only: verbose and persisted evidence keep the
    // original diagnostics, including their full perception limitation list.
    expect((details['after'] as Map)['visualTree'], isNotNull);
    expect(
      ((details['after'] as Map)['perception'] as Map)['limitations'],
      hasLength(200),
    );
    print('synthetic failed action: $beforeBytes -> $afterBytes UTF-8 bytes');
  });

  test(
    'new structural delta lists have explicit presentation omission counts',
    () {
      final items = List.generate(30, (i) => {'id': 'control.$i'});
      final compact = FlutterScoutCli().debugCompactActionResult({
        'ok': true,
        'result': 'changed',
        'delta': {
          'changedRegions': items,
          'controlStateChanges': items,
          'newText': List.generate(30, (i) => 'Text $i'),
          'changedRegionCoverage': {'status': 'complete', 'totalRegions': 30},
          'runtimeSignals': {
            'newCount': 1,
            'newIdentities': ['blocking-1'],
          },
          'scroll': {
            'changedRegions': items,
            'newRegions': ['scroll.a'],
          },
        },
      });
      final delta = compact['delta'] as Map;
      for (final key in ['changedRegions', 'controlStateChanges', 'newText']) {
        expect(delta[key], hasLength(12));
        expect(delta['${key}Omitted'], 18);
      }
      expect((delta['scroll'] as Map)['changedRegionsOmitted'], 18);
      expect(delta['runtimeSignals'], {
        'newCount': 1,
        'newIdentities': ['blocking-1'],
      });
      expect(delta['changedRegionCoverage'], {
        'status': 'complete',
        'totalRegions': 30,
      });
    },
  );
}

Map<String, Object?> _largeSnapshot() => {
  'screen': 'EditScreen',
  'snapshotId': 'g2:after',
  'perception': {
    'semantics': {'available': false},
    'limitations': List.generate(
      200,
      (i) => {
        'kind': 'custom_paint',
        'detail': 'visual limitation $i ${'x' * 100}',
      },
    ),
  },
  'visualTree': {
    'children': List.generate(200, (i) => {'label': 'row $i ${'x' * 100}'}),
  },
  'scrollables': List.generate(
    100,
    (i) => {
      'id': 'scroll.$i',
      'rect': [0, 0, 400, 800],
    },
  ),
  'recentErrors': [
    {'blocking': true, 'identity': 'error-1'},
  ],
  'activeBlockingSignals': [
    {'identity': 'active-1'},
  ],
  'unknownFutureSafetyFact': {'mustReconcile': true},
};
