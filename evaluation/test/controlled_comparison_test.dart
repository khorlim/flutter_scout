import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  test('legacy paired configs remain byte-shape compatible', () {
    final catalog = testCatalog();
    final legacy = testBenchmarkConfig(catalog: catalog);
    final encoded = legacy.toJson();

    expect(encoded, isNot(contains('controlledComparison')));
    expect(BenchmarkConfig.fromJson(encoded).toJson(), encoded);
    expect(
      BenchmarkSchedule.generate(config: legacy, catalog: catalog).conditionIds,
      ['current', 'candidate'],
    );
  });

  test('controlled preregistration strictly pins all comparison roles', () {
    final config = _controlledConfig(catalog: testCatalog());
    final decoded = BenchmarkConfig.fromJson(config.toJson());

    expect(decoded.toJson(), config.toJson());
    expect(decoded.conditionRoles, {
      'coordinates': ControlledComparisonRole.screenshotCoordinateOnly,
      'current': ControlledComparisonRole.currentReleasedScout,
      'candidate': ControlledComparisonRole.candidateScout,
      'perfect-handles': ControlledComparisonRole.perfectHandleCeiling,
    });
    expect(decoded.controlledComparison!.resetProtocol.sha256, '1' * 64);

    final changed =
        jsonDecode(jsonEncode(config.toJson())) as Map<String, Object?>;
    final controlled = changed['controlledComparison']! as Map<String, Object?>;
    final conditions = controlled['conditions']! as List<Object?>;
    final coordinate = conditions.first! as Map<String, Object?>;
    final implementation =
        coordinate['implementation']! as Map<String, Object?>;
    implementation['sha256'] = '9' * 64;
    expect(BenchmarkConfig.fromJson(changed).sha256, isNot(config.sha256));
  });

  test('controlled preregistration rejects fairness-policy drift', () {
    Map<String, Object?> raw() =>
        jsonDecode(
              jsonEncode(_controlledConfig(catalog: testCatalog()).toJson()),
            )
            as Map<String, Object?>;

    final noFreshReset = raw();
    (noFreshReset['controlledComparison']!
            as Map<String, Object?>)['freshResetPerEpisode'] =
        false;
    expect(
      () => BenchmarkConfig.fromJson(noFreshReset),
      throwsA(isA<FormatException>()),
    );

    final wrongCurrent = raw();
    final conditions =
        ((wrongCurrent['controlledComparison']!
                as Map<String, Object?>)['conditions']!
            as List<Object?>);
    final current = conditions.cast<Map<String, Object?>>().singleWhere(
      (item) => item['role'] == 'current_released_scout',
    );
    current['conditionId'] = 'not-current';
    expect(
      () => BenchmarkConfig.fromJson(wrongCurrent),
      throwsA(isA<ArgumentError>()),
    );

    final duplicateRole = raw();
    final duplicateConditions =
        ((duplicateRole['controlledComparison']!
                as Map<String, Object?>)['conditions']!
            as List<Object?>);
    (duplicateConditions.last! as Map<String, Object?>)['role'] =
        'candidate_scout';
    expect(
      () => BenchmarkConfig.fromJson(duplicateRole),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('four roles are deterministically randomized and position-balanced', () {
    final catalog = testCatalog();
    final config = _controlledConfig(catalog: catalog, repetitions: 8);
    final first = BenchmarkSchedule.generate(config: config, catalog: catalog);
    final second = BenchmarkSchedule.generate(config: config, catalog: catalog);

    expect(first.toJson(), second.toJson());
    expect(first.sha256, second.sha256);
    expect(first.episodes, hasLength(32));
    expect(first.conditionRoles, config.conditionRoles);

    final blocks = <String, List<ScheduledEpisode>>{};
    for (final episode in first.episodes) {
      blocks.putIfAbsent(episode.pairId, () => []).add(episode);
      expect(episode.freshResetRequired, isTrue);
    }
    for (final block in blocks.values) {
      expect(block.map((episode) => episode.condition).toSet(), {
        'coordinates',
        'current',
        'candidate',
        'perfect-handles',
      });
      expect(block.map((episode) => episode.variantSeed).toSet(), hasLength(1));
      expect(
        block.map((episode) => episode.repetitionSeed).toSet(),
        hasLength(1),
      );
      expect(block.map((episode) => episode.conditionOrder).toSet(), {
        1,
        2,
        3,
        4,
      });
    }

    for (final condition in first.conditionIds) {
      final positions = <int, int>{};
      for (final episode in first.episodes.where(
        (episode) => episode.condition == condition,
      )) {
        positions.update(
          episode.conditionOrder,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
      expect(positions, {1: 2, 2: 2, 3: 2, 4: 2});
    }
    expect(BenchmarkSchedule.fromJson(first.toJson()).toJson(), first.toJson());

    final changedSeed = BenchmarkSchedule.generate(
      config: BenchmarkConfig.fromJson({
        ...config.toJson(),
        'randomizationSeed': config.randomizationSeed + 1,
      }),
      catalog: catalog,
    );
    expect(changedSeed.sha256, isNot(first.sha256));

    final mismatched =
        jsonDecode(jsonEncode(first.toJson())) as Map<String, Object?>;
    final serializedEpisodes = mismatched['episodes']! as List<Object?>;
    (serializedEpisodes[1]! as Map<String, Object?>)['repetitionSeed'] =
        ((serializedEpisodes[1]! as Map<String, Object?>)['repetitionSeed']!
            as int) +
        1;
    expect(
      () => BenchmarkSchedule.fromJson(mismatched),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('perfect-handle role is optional while the three core roles remain', () {
    final catalog = testCatalog();
    final config = _controlledConfig(
      catalog: catalog,
      repetitions: 2,
      includePerfectHandle: false,
    );
    final schedule = BenchmarkSchedule.generate(
      config: config,
      catalog: catalog,
    );

    expect(schedule.conditionIds, ['coordinates', 'current', 'candidate']);
    expect(schedule.episodes, hasLength(6));
    expect(schedule.episodes.map((episode) => episode.conditionOrder).toSet(), {
      1,
      2,
      3,
    });
  });

  test('report keeps current-candidate pairing with auxiliary conditions', () {
    final catalog = testCatalog();
    final config = _controlledConfig(catalog: catalog, repetitions: 2);
    final schedule = BenchmarkSchedule.generate(
      config: config,
      catalog: catalog,
    );
    final episodes = [
      for (final scheduled in schedule.episodes)
        loadedBenchmarkEpisode(
          config: config,
          schedule: schedule,
          scheduled: scheduled,
          result: benchmarkResult(
            scheduled,
            valid:
                !(scheduled.condition == 'coordinates' &&
                    scheduled.repetition == 1),
            passed: scheduled.condition == 'current'
                ? scheduled.repetition == 1
                : scheduled.condition == 'candidate'
                ? scheduled.repetition == 2
                : true,
          ),
        ),
    ];

    final report = const BenchmarkReportBuilder().build(
      config: config,
      catalog: catalog,
      episodes: episodes,
    );
    final json = report.toJson();
    final paired = json['pairedComparison']! as Map<String, Object?>;

    expect((json['conditions']! as List<Object?>), hasLength(4));
    expect(report.invalidHarnessCount, 1);
    expect(paired['pairs'], 2);
    expect(paired['currentOnlyPassed'], 1);
    expect(paired['candidateOnlyPassed'], 1);
    expect(paired['invalidPairCount'], 0);
    expect(
      (json['releaseAssessment']! as Map<String, Object?>)['claimable'],
      isFalse,
    );
  });

  test('schemas expose the additive controlled-comparison bounds', () {
    final configSchema =
        jsonDecode(
              File(
                'schemas/v1/benchmark_config.schema.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final scheduleSchema =
        jsonDecode(
              File(
                'schemas/v1/benchmark_schedule.schema.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final episodeSchema =
        jsonDecode(
              File(
                'schemas/v1/benchmark_episode.schema.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;

    expect(
      (configSchema['properties']! as Map<String, Object?>),
      contains('controlledComparison'),
    );
    final scheduleProperties =
        scheduleSchema['properties']! as Map<String, Object?>;
    expect(scheduleProperties, contains('conditionRoles'));
    expect(
      (scheduleProperties['conditionIds']! as Map<String, Object?>)['maxItems'],
      4,
    );
    final episodeProperties =
        episodeSchema['properties']! as Map<String, Object?>;
    expect(
      (episodeProperties['conditionOrder']! as Map<String, Object?>)['maximum'],
      4,
    );
  });
}

BenchmarkConfig _controlledConfig({
  required CatalogSets catalog,
  int repetitions = 2,
  bool includePerfectHandle = true,
}) {
  final legacy = testBenchmarkConfig(
    catalog: catalog,
    repetitions: repetitions,
  );
  final conditions = <ControlledComparisonCondition>[
    ControlledComparisonCondition(
      role: ControlledComparisonRole.screenshotCoordinateOnly,
      conditionId: 'coordinates',
      toolSchema: DigestPin(id: 'coordinate-tools-v1', sha256: '2' * 64),
      implementation: DigestPin(id: 'coordinate-runner-v1', sha256: '3' * 64),
    ),
    ControlledComparisonCondition(
      role: ControlledComparisonRole.currentReleasedScout,
      conditionId: legacy.current.conditionId,
      toolSchema: DigestPin(id: 'current-tools-v1', sha256: '4' * 64),
      implementation: DigestPin(id: 'current-adapter-v1', sha256: '5' * 64),
    ),
    ControlledComparisonCondition(
      role: ControlledComparisonRole.candidateScout,
      conditionId: legacy.candidate.conditionId,
      toolSchema: legacy.agent.toolSchema,
      implementation: DigestPin(id: 'candidate-adapter-v1', sha256: '6' * 64),
    ),
    if (includePerfectHandle)
      ControlledComparisonCondition(
        role: ControlledComparisonRole.perfectHandleCeiling,
        conditionId: 'perfect-handles',
        toolSchema: DigestPin(id: 'perfect-tools-v1', sha256: '7' * 64),
        implementation: DigestPin(id: 'perfect-runner-v1', sha256: '8' * 64),
      ),
  ];
  return BenchmarkConfig(
    benchmarkId: legacy.benchmarkId,
    catalogSha256: legacy.catalogSha256,
    current: legacy.current,
    candidate: legacy.candidate,
    agent: legacy.agent,
    app: legacy.app,
    environment: legacy.environment,
    budget: legacy.budget,
    repetitions: legacy.repetitions,
    agentResultClassification: legacy.agentResultClassification,
    randomizationSeed: legacy.randomizationSeed,
    taskRegime: legacy.taskRegime,
    includedSplits: legacy.includedSplits,
    templateFamilies: legacy.templateFamilies,
    controlledComparison: ControlledComparison(
      resetProtocol: DigestPin(id: 'reset-protocol-v1', sha256: '1' * 64),
      conditions: conditions,
    ),
  );
}
