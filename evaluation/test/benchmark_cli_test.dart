import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  test('report CLI writes a complete but non-claiming JSON report', () async {
    final root = await Directory.systemTemp.createTemp('scout-benchmark-cli-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final catalogDirectory = Directory('${root.path}/catalog/private');
    final episodeDirectory = Directory('${root.path}/episodes');
    await catalogDirectory.create(recursive: true);
    await episodeDirectory.create(recursive: true);
    final manifest = testManifest(split: BenchmarkSplit.privateValidation);
    await File(
      '${catalogDirectory.path}/task.json',
    ).writeAsString(jsonEncode(manifest.toJson()));
    final catalog = testCatalog(manifests: [manifest]);
    final config = testBenchmarkConfig(catalog: catalog, repetitions: 1);
    final configFile = File('${root.path}/config.json');
    final reportFile = File('${root.path}/report.json');
    await configFile.writeAsString(jsonEncode(config.toJson()));
    final schedule = BenchmarkSchedule.generate(
      config: config,
      catalog: catalog,
    );
    for (final scheduled in schedule.episodes) {
      final loaded = loadedBenchmarkEpisode(
        config: config,
        schedule: schedule,
        scheduled: scheduled,
      );
      await File(
        '${episodeDirectory.path}/${scheduled.episodeId}.json',
      ).writeAsBytes(loaded.rawBytes);
    }

    final process = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/benchmark.dart',
      'report',
      '--config',
      configFile.path,
      '--catalog',
      Directory('${root.path}/catalog').path,
      '--episodes',
      episodeDirectory.path,
      '--output',
      reportFile.path,
    ]);

    expect(process.exitCode, 0, reason: '${process.stderr}');
    final report =
        jsonDecode(await reportFile.readAsString()) as Map<String, Object?>;
    expect(report['schemaVersion'], benchmarkReportSchemaVersion);
    expect(
      (report['releaseAssessment']! as Map<String, Object?>)['claimable'],
      isFalse,
    );
    if (!Platform.isWindows) {
      expect((await reportFile.stat()).mode & 0x1ff, 0x180);
    }

    final bytes = await reportFile.readAsBytes();
    final repeated = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/benchmark.dart',
      'report',
      '--config',
      configFile.path,
      '--catalog',
      Directory('${root.path}/catalog').path,
      '--episodes',
      episodeDirectory.path,
      '--output',
      reportFile.path,
    ]);
    expect(repeated.exitCode, 64);
    expect(repeated.stderr.toString(), contains('will not be overwritten'));
    expect(await reportFile.readAsBytes(), bytes);
  });
}
