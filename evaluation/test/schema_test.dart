import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';
import 'package:test/test.dart';

void main() {
  test('all v1 schema documents are valid JSON and pin version one', () {
    final files = [
      File('schemas/v1/task_manifest.schema.json'),
      File('schemas/v1/agent_task.schema.json'),
      File('schemas/v1/episode_result.schema.json'),
      File('schemas/v1/benchmark_config.schema.json'),
      File('schemas/v1/benchmark_schedule.schema.json'),
      File('schemas/v1/benchmark_episode.schema.json'),
      File('schemas/v1/benchmark_report.schema.json'),
      File('schemas/v1/conformance_matrix.schema.json'),
      File('schemas/v1/corpus_policy.schema.json'),
      File('schemas/v1/corpus_descriptor.schema.json'),
      File('schemas/v1/corpus_validation_report.schema.json'),
      File('schemas/v1/performance_config.schema.json'),
      File('schemas/v1/performance_sample.schema.json'),
      File('schemas/v1/performance_report.schema.json'),
      File('schemas/v1/endurance_config.schema.json'),
      File('schemas/v1/endurance_archive.schema.json'),
      File('schemas/v1/public_fixture_configuration.schema.json'),
    ];

    for (final file in files) {
      final schema =
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      expect(schema[r'$schema'], contains('2020-12'));
      expect(schema[r'$id'], contains('/v1/'));
      expect(schema['additionalProperties'], isFalse);
    }

    final task = jsonDecode(files.first.readAsStringSync()) as Map;
    final taskProperties = task['properties'] as Map;
    expect((taskProperties['schemaVersion'] as Map)['const'], 1);
    expect(taskManifestSchemaVersion, 1);
    expect(episodeResultSchemaVersion, 1);
    expect(benchmarkConfigSchemaVersion, 1);
    expect(benchmarkScheduleSchemaVersion, 1);
    expect(benchmarkEpisodeSchemaVersion, 1);
    expect(benchmarkReportSchemaVersion, 1);
    expect(corpusPolicySchemaVersion, 1);
    expect(corpusDescriptorSchemaVersion, 1);
    expect(corpusValidationReportSchemaVersion, 1);
    expect(performanceConfigSchemaVersion, 1);
    expect(performanceSampleSchemaVersion, 1);
    expect(performanceReportSchemaVersion, 1);
    expect(enduranceConfigSchemaVersion, 1);
    expect(enduranceArchiveSchemaVersion, 1);
    expect(publicFixtureConfigurationSchemaVersion, 1);
  });

  test('checked-in gold corpus policy parses and round-trips', () {
    final raw = jsonDecode(
      File('policies/gold_conformance.v1.json').readAsStringSync(),
    );
    final policy = CorpusPolicy.fromJson(raw);

    expect(policy.minimumTemplateCount, 60);
    expect(policy.minimumVariantsPerTemplate, 5);
    expect(policy.minimumRealAppIdentitiesBeyondStressLab, 2);
    expect(CorpusPolicy.fromJson(policy.toJson()).toJson(), policy.toJson());
  });

  test('episode schema contains every first-causal failure category', () {
    final text = File(
      'schemas/v1/episode_result.schema.json',
    ).readAsStringSync();

    for (final category in FailureCategory.values) {
      expect(text, contains('"${category.jsonName}"'));
    }
  });
}
