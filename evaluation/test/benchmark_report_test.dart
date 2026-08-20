import 'dart:convert';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  test(
    'report computes paired counts, Wilson intervals, KPIs, and taxonomy',
    () {
      final catalog = testCatalog();
      final config = testBenchmarkConfig(catalog: catalog, repetitions: 2);
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
              passed:
                  (scheduled.repetition == 1 &&
                      scheduled.condition == 'current') ||
                  (scheduled.repetition == 2 &&
                      scheduled.condition == 'candidate'),
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
      expect(paired['pairs'], 2);
      expect(paired['currentOnlyPassed'], 1);
      expect(paired['candidateOnlyPassed'], 1);
      expect(paired['exactTwoSidedP'], 1.0);
      final bootstrap = json['clusteredBootstrap']! as Map<String, Object?>;
      expect(
        bootstrap['method'],
        'task_template_clustered_percentile_bootstrap',
      );
      expect(bootstrap['clusterCount'], 1);
      final comparisons = bootstrap['comparisons']! as List<Object?>;
      expect(comparisons, hasLength(7));
      expect(
        (comparisons.first! as Map<String, Object?>)['metric'],
        'taskSuccessRate',
      );
      final conditions = json['conditions']! as List<Object?>;
      for (final raw in conditions) {
        final condition = raw! as Map<String, Object?>;
        expect(condition['scheduled'], 2);
        expect(condition['valid'], 2);
        expect(condition['passed'], 1);
        final success = condition['success']! as Map<String, Object?>;
        expect(success['estimate'], 0.5);
        final costs =
            condition['costPerSuccessfulTask']! as Map<String, Object?>;
        final calls = costs['toolCalls']! as Map<String, Object?>;
        expect(calls, {'count': 1, 'total': 2, 'mean': 2.0});
      }
      final safety = json['safetyGate']! as Map<String, Object?>;
      expect(safety['status'], 'pass');
      final release = json['releaseAssessment']! as Map<String, Object?>;
      expect(release['status'], 'unmeasured');
      expect(release['claimable'], isFalse);
    },
  );

  test(
    'invalid harness episodes are separate and never silently discarded',
    () {
      final catalog = testCatalog();
      final config = testBenchmarkConfig(catalog: catalog, repetitions: 1);
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
              valid: scheduled.condition != 'current',
              passed: true,
            ),
          ),
      ];

      final report = const BenchmarkReportBuilder().build(
        config: config,
        catalog: catalog,
        episodes: episodes,
      );
      final json = report.toJson();
      final invalid = json['invalidHarness']! as Map<String, Object?>;
      final paired = json['pairedComparison']! as Map<String, Object?>;
      final safety = json['safetyGate']! as Map<String, Object?>;
      expect(report.invalidHarnessCount, 1);
      expect(invalid['count'], 1);
      expect(invalid['affectedPairCount'], 1);
      expect(paired['pairs'], 0);
      expect(paired['invalidPairCount'], 1);
      expect(safety['status'], 'pass');
      expect(
        (json['releaseAssessment']! as Map<String, Object?>)['status'],
        'blocked',
      );
    },
  );

  test(
    'missing, duplicate, and mismatched episodes invalidate the archive',
    () {
      final catalog = testCatalog();
      final config = testBenchmarkConfig(catalog: catalog, repetitions: 1);
      final schedule = BenchmarkSchedule.generate(
        config: config,
        catalog: catalog,
      );
      final complete = [
        for (final scheduled in schedule.episodes)
          loadedBenchmarkEpisode(
            config: config,
            schedule: schedule,
            scheduled: scheduled,
          ),
      ];

      expect(
        () => const BenchmarkReportBuilder().build(
          config: config,
          catalog: catalog,
          episodes: complete.sublist(1),
        ),
        throwsA(
          isA<BenchmarkInputException>().having(
            (error) => error.toString(),
            'message',
            contains('post-hoc exclusion is forbidden'),
          ),
        ),
      );
      expect(
        () => const BenchmarkReportBuilder().build(
          config: config,
          catalog: catalog,
          episodes: [...complete, complete.first],
        ),
        throwsA(
          isA<BenchmarkInputException>().having(
            (error) => error.toString(),
            'message',
            contains('Duplicate episode id'),
          ),
        ),
      );

      final original = complete.first;
      final envelope = original.envelope;
      final mismatch = BenchmarkEpisodeEnvelope(
        configSha256: envelope.configSha256,
        scheduleSha256: envelope.scheduleSha256,
        pairId: 'wrong-pair',
        repetition: envelope.repetition,
        variantSeed: envelope.variantSeed,
        repetitionSeed: envelope.repetitionSeed,
        conditionOrder: envelope.conditionOrder,
        freshResetPerformed: envelope.freshResetPerformed,
        result: envelope.result,
      );
      final bytes = utf8.encode(canonicalJsonEncode(mismatch.toJson()));
      final mismatchedLoaded = LoadedBenchmarkEpisode(
        sourcePath: original.sourcePath,
        fileSha256: sha256Bytes(bytes),
        rawBytes: bytes,
        envelope: mismatch,
      );
      expect(
        () => const BenchmarkReportBuilder().build(
          config: config,
          catalog: catalog,
          episodes: [mismatchedLoaded, ...complete.skip(1)],
        ),
        throwsA(
          isA<BenchmarkInputException>().having(
            (error) => error.toString(),
            'message',
            contains('pairId mismatch'),
          ),
        ),
      );
    },
  );

  test('false success, forbidden state, and release-blocking severity block', () {
    final catalog = testCatalog();
    final config = testBenchmarkConfig(catalog: catalog, repetitions: 1);
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
          result: scheduled.condition == 'current'
              ? benchmarkResult(
                  scheduled,
                  passed: false,
                  claimedSuccess: true,
                  failure: EpisodeFailure(
                    category: FailureCategory.agent,
                    severity: FailureSeverity.productFailure,
                    message:
                        'Scout claimed success but the hidden oracle disagreed.',
                  ),
                )
              : benchmarkResult(
                  scheduled,
                  forbiddenState: true,
                  failure: EpisodeFailure(
                    category: FailureCategory.action,
                    severity: FailureSeverity.releaseBlocking,
                    message: 'A forbidden destructive state was reached.',
                  ),
                ),
        ),
    ];

    final report = const BenchmarkReportBuilder().build(
      config: config,
      catalog: catalog,
      episodes: episodes,
    );
    final safety = report.toJson()['safetyGate']! as Map<String, Object?>;
    expect(report.safetyBlocked, isTrue);
    expect(safety['status'], 'blocked');
    expect(safety['blockerCount'], 2);
    final blockers = safety['blockers']! as List<Object?>;
    expect(jsonEncode(blockers), contains('false_success'));
    expect(jsonEncode(blockers), contains('forbidden_state'));
    expect(jsonEncode(blockers), contains('release_blocking_failure'));
  });

  test(
    'worst template family is reported and unsupported gates stay unmeasured',
    () {
      final manifests = [
        testManifest(split: BenchmarkSplit.privateValidation),
        testManifest(
          taskId: 'edit-order.variant-a',
          templateId: 'edit-order',
          split: BenchmarkSplit.privateValidation,
        ),
      ];
      final catalog = testCatalog(manifests: manifests);
      final config = testBenchmarkConfig(
        catalog: catalog,
        repetitions: 1,
        templateFamilies: [
          TemplateFamily(
            familyId: 'profiles',
            templateIds: const ['save-profile'],
          ),
          TemplateFamily(familyId: 'orders', templateIds: const ['edit-order']),
        ],
      );
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
              passed:
                  scheduled.condition == 'current' ||
                  scheduled.templateId == 'save-profile',
            ),
          ),
      ];

      final json = const BenchmarkReportBuilder()
          .build(config: config, catalog: catalog, episodes: episodes)
          .toJson();
      final families = json['templateFamilies']! as Map<String, Object?>;
      final worst = families['candidateWorstCase']! as Map<String, Object?>;
      expect(worst['familyId'], 'orders');
      expect(
        (families['multiplicityControl']! as Map<String, Object?>)['method'],
        'holm_bonferroni',
      );
      final thresholds = json['provisionalThresholds']! as List<Object?>;
      final byId = {
        for (final raw in thresholds)
          (raw! as Map<String, Object?>)['gateId']!: raw,
      };
      expect(
        (byId['deterministic_primitive_reliability']!
            as Map<String, Object?>)['status'],
        'unmeasured',
      );
      expect(
        (byId['paired_noninferiority']! as Map<String, Object?>)['status'],
        'unmeasured',
      );
    },
  );

  test('missing required cost metrics cannot produce a benchmark report', () {
    final catalog = testCatalog();
    final config = testBenchmarkConfig(catalog: catalog, repetitions: 1);
    final schedule = BenchmarkSchedule.generate(
      config: config,
      catalog: catalog,
    );
    final first = schedule.episodes.first;
    final resultJson = benchmarkResult(first).toJson();
    final metrics = resultJson['metrics']! as Map<String, Object?>;
    metrics.remove('screenshots');
    final malformed = EpisodeResult.fromJson(resultJson);
    final episodes = [
      loadedBenchmarkEpisode(
        config: config,
        schedule: schedule,
        scheduled: first,
        result: malformed,
      ),
      for (final scheduled in schedule.episodes.skip(1))
        loadedBenchmarkEpisode(
          config: config,
          schedule: schedule,
          scheduled: scheduled,
        ),
    ];

    expect(
      () => const BenchmarkReportBuilder().build(
        config: config,
        catalog: catalog,
        episodes: episodes,
      ),
      throwsA(
        isA<BenchmarkInputException>().having(
          (error) => error.toString(),
          'message',
          contains('metrics.screenshots'),
        ),
      ),
    );
  });
}
