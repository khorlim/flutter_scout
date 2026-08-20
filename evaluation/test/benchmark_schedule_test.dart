import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  test('schedule is deterministic, paired, seeded, and order-balanced', () {
    final catalog = testCatalog();
    final config = testBenchmarkConfig(catalog: catalog, repetitions: 5);

    final first = BenchmarkSchedule.generate(config: config, catalog: catalog);
    final second = BenchmarkSchedule.generate(config: config, catalog: catalog);

    expect(first.toJson(), second.toJson());
    expect(first.sha256, second.sha256);
    expect(first.episodes, hasLength(10));
    final pairs = <String, List<ScheduledEpisode>>{};
    for (final episode in first.episodes) {
      pairs.putIfAbsent(episode.pairId, () => []).add(episode);
      expect(episode.freshResetRequired, isTrue);
    }
    for (final pair in pairs.values) {
      expect(pair.map((item) => item.condition).toSet(), {
        'current',
        'candidate',
      });
      expect(pair.map((item) => item.repetitionSeed).toSet(), hasLength(1));
      expect(pair.map((item) => item.variantSeed).toSet(), hasLength(1));
      expect(pair.map((item) => item.repetition).toSet(), hasLength(1));
      expect(pair.map((item) => item.conditionOrder).toSet(), {1, 2});
    }
    final currentFirst = pairs.values
        .where((pair) => pair.first.condition == 'current')
        .length;
    expect(currentFirst, anyOf(2, 3));
  });

  test('changing the preregistered seed changes deterministic order', () {
    final catalog = testCatalog();
    final first = BenchmarkSchedule.generate(
      config: testBenchmarkConfig(
        catalog: catalog,
        repetitions: 6,
        randomizationSeed: 1,
      ),
      catalog: catalog,
    );
    final second = BenchmarkSchedule.generate(
      config: testBenchmarkConfig(
        catalog: catalog,
        repetitions: 6,
        randomizationSeed: 2,
      ),
      catalog: catalog,
    );

    expect(first.sha256, isNot(second.sha256));
    expect(
      first.episodes.map((item) => item.episodeId).toList(),
      isNot(second.episodes.map((item) => item.episodeId).toList()),
    );
  });

  test('a single pair still randomizes which condition executes first', () {
    final catalog = testCatalog();
    final first = BenchmarkSchedule.generate(
      config: testBenchmarkConfig(
        catalog: catalog,
        repetitions: 1,
        randomizationSeed: 1,
      ),
      catalog: catalog,
    );
    final second = BenchmarkSchedule.generate(
      config: testBenchmarkConfig(
        catalog: catalog,
        repetitions: 1,
        randomizationSeed: 2,
      ),
      catalog: catalog,
    );

    expect(
      first.episodes.first.condition,
      isNot(second.episodes.first.condition),
    );
  });

  test('schedule rejects catalog drift and incomplete family mapping', () {
    final catalog = testCatalog();
    final configJson = testBenchmarkConfig(catalog: catalog).toJson();
    configJson['catalogSha256'] = 'f' * 64;
    final drifted = BenchmarkConfig.fromJson(configJson);
    expect(
      () => BenchmarkSchedule.generate(config: drifted, catalog: catalog),
      throwsA(isA<BenchmarkConfigurationException>()),
    );

    final missingFamily = testBenchmarkConfig(
      catalog: catalog,
      templateFamilies: [
        TemplateFamily(familyId: 'other', templateIds: const ['not-selected']),
      ],
    );
    expect(
      () => BenchmarkSchedule.generate(config: missingFamily, catalog: catalog),
      throwsA(isA<BenchmarkConfigurationException>()),
    );
  });

  test('schedule JSON round-trips with the exact generated order', () {
    final catalog = testCatalog();
    final schedule = BenchmarkSchedule.generate(
      config: testBenchmarkConfig(catalog: catalog),
      catalog: catalog,
    );

    expect(
      BenchmarkSchedule.fromJson(schedule.toJson()).toJson(),
      schedule.toJson(),
    );
  });
}
