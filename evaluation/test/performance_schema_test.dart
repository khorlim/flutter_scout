import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';
import 'package:test/test.dart';

void main() {
  test('sample schema requires every phase, resource, and safety effect', () {
    final schema = _schema('performance_sample.schema.json');
    final definitions = schema[r'$defs']! as Map<String, Object?>;
    final phases = definitions['phases']! as Map<String, Object?>;
    final resources = definitions['resources']! as Map<String, Object?>;
    final effects = definitions['effects']! as Map<String, Object?>;

    expect(phases['required'], performancePhaseNames);
    expect(resources['required'], ['cpu', 'memory', 'frameTime', 'endurance']);
    expect(effects['required'], [
      'focus',
      'pointerGesture',
      'route',
      'semantics',
      'overlay',
      'businessState',
      'syntheticFrameCount',
      'provenance',
    ]);
  });

  test('report schema structurally forbids a release-eligibility claim', () {
    final schema = _schema('performance_report.schema.json');
    final definitions = schema[r'$defs']! as Map<String, Object?>;
    final release = definitions['releaseAssessment']! as Map<String, Object?>;
    final properties = release['properties']! as Map<String, Object?>;
    final claimable = properties['claimable']! as Map<String, Object?>;

    expect(claimable['const'], isFalse);
  });

  test('config schema does not permit weaker gold latency targets', () {
    final schema = _schema('performance_config.schema.json');
    final definitions = schema[r'$defs']! as Map<String, Object?>;
    final thresholds = definitions['thresholds']! as Map<String, Object?>;
    final properties = thresholds['properties']! as Map<String, Object?>;

    int maximum(String field) =>
        (properties[field]! as Map<String, Object?>)['maximum']! as int;
    expect(maximum('warmBriefInspectStandardP95Us'), 300000);
    expect(maximum('warmBriefInspectLargeTreeP95Us'), 750000);
    expect(maximum('actionOverheadP95Us'), 250000);
    expect(maximum('payloadP95EstimatedTokens'), 1500);

    final environment = definitions['environment']! as Map<String, Object?>;
    final environmentProperties =
        environment['properties']! as Map<String, Object?>;
    expect(
      (environmentProperties['buildMode']! as Map<String, Object?>)['const'],
      'debug',
    );
  });
}

Map<String, Object?> _schema(String name) =>
    jsonDecode(File('schemas/v1/$name').readAsStringSync())
        as Map<String, Object?>;
