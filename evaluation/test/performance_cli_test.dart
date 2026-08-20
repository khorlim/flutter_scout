import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'checked-in CLI fixture matches the deterministic golden summary',
    () async {
      final root = await Directory.systemTemp.createTemp('scout-perf-cli-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final output = File('${root.path}/report.json');
      final process = await Process.run(Platform.resolvedExecutable, [
        'bin/performance.dart',
        'report',
        '--config',
        'performance/fixtures/performance_config.provisional.v1.json',
        '--samples',
        'performance/fixtures/samples',
        '--output',
        output.path,
      ]);

      expect(process.exitCode, 0, reason: process.stderr.toString());
      final report =
          jsonDecode(await output.readAsString()) as Map<String, Object?>;
      if (!Platform.isWindows) {
        expect((await output.stat()).mode & 0x1ff, 0x180);
      }
      final expected =
          jsonDecode(
                await File(
                  'performance/goldens/provisional_report_summary.v1.json',
                ).readAsString(),
              )
              as Map<String, Object?>;

      expect(_summary(report), expected);
    },
  );

  test('report output is create-only evidence', () async {
    final root = await Directory.systemTemp.createTemp('scout-perf-cli-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final output = File('${root.path}/report.json');
    await output.writeAsString('existing evidence');
    final process = await Process.run(Platform.resolvedExecutable, [
      'bin/performance.dart',
      'report',
      '--config',
      'performance/fixtures/performance_config.provisional.v1.json',
      '--samples',
      'performance/fixtures/samples',
      '--output',
      output.path,
    ]);

    expect(process.exitCode, 64);
    expect(process.stderr.toString(), contains('will not be overwritten'));
    expect(await output.readAsString(), 'existing evidence');
  });
}

Map<String, Object?> _summary(Map<String, Object?> report) {
  final integrity = report['evidenceIntegrity']! as Map<String, Object?>;
  final conditions = report['conditions']! as List<Object?>;
  final baseline = conditions[0]! as Map<String, Object?>;
  final candidate = conditions[1]! as Map<String, Object?>;
  final comparison = report['comparison']! as Map<String, Object?>;
  final nonInterference =
      report['observationNonInterference']! as Map<String, Object?>;
  final quantitative = report['quantitativeGates']! as Map<String, Object?>;
  final gates = quantitative['gates']! as List<Object?>;
  final release = report['releaseAssessment']! as Map<String, Object?>;

  Map<String, Object?> conditionSummary(Map<String, Object?> condition) {
    final overhead =
        condition['actionOverheadExcludingSettleUs']! as Map<String, Object?>;
    final phases = condition['phaseTimingsUs']! as Map<String, Object?>;
    final settle = phases['settle']! as Map<String, Object?>;
    final payload = condition['payload']! as Map<String, Object?>;
    final tokens = payload['estimatedTokens']! as Map<String, Object?>;
    return {
      'actionOverheadP95Us': overhead['p95'],
      'settleP95Us': settle['p95'],
      'payloadP95EstimatedTokens': tokens['p95'],
    };
  }

  return {
    'schemaVersion': report['schemaVersion'],
    'configSha256': report['configSha256'],
    'environmentSha256': report['environmentSha256'],
    'archiveSha256': integrity['archiveSha256'],
    'baseline': conditionSummary(baseline),
    'candidate': conditionSummary(candidate),
    'regressionStatus': comparison['regressionStatus'],
    'observationNonInterferenceStatus': nonInterference['status'],
    'quantitativeGateStatuses': [
      for (final gate in gates) (gate as Map<String, Object?>)['status'],
    ],
    'releaseAssessment': {
      'status': release['status'],
      'claimable': release['claimable'],
    },
  };
}
