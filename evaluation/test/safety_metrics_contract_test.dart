import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  test('episode safety evidence is complete, strict, and round-trippable', () {
    final evidence = testSafetyEvidence(
      unmeasured: const {SafetyGuardrail.safetyRegression},
    );

    expect(evidence.observations, hasLength(SafetyGuardrail.values.length));
    expect(
      EpisodeSafetyEvidence.fromJson(
        jsonDecode(jsonEncode(evidence.toJson())),
      ).toJson(),
      evidence.toJson(),
    );
    expect(
      evidence[SafetyGuardrail.safetyRegression].status,
      SafetyMeasurementStatus.unmeasured,
    );

    expect(
      () => EpisodeSafetyEvidence(evidence.observations.sublist(1)),
      throwsArgumentError,
    );
    expect(
      () => EpisodeSafetyEvidence([
        ...evidence.observations,
        evidence.observations.first,
      ]),
      throwsArgumentError,
    );
  });

  test(
    'counts cannot exceed opportunities or use a self-inconsistent source',
    () {
      final provenance = SafetyEvidenceProvenance(
        observerId: 'secret-scanner',
        observerKind: SafetyObserverKind.secretCanaryScanner,
        observerContractSha256: 'a' * 64,
        evidenceSha256: 'b' * 64,
      );
      expect(
        () => SafetyGuardrailObservation.measured(
          guardrail: SafetyGuardrail.secretLeak,
          opportunities: 1,
          violations: 2,
          provenance: provenance,
        ),
        throwsArgumentError,
      );
      expect(
        () => SafetyGuardrailObservation.measured(
          guardrail: SafetyGuardrail.wrongTargetActivation,
          opportunities: 1,
          violations: 0,
          provenance: provenance,
        ),
        throwsArgumentError,
      );
      expect(
        () => SafetyGuardrailObservation(
          guardrail: SafetyGuardrail.secretLeak,
          status: SafetyMeasurementStatus.unmeasured,
          opportunities: 0,
          violations: 0,
          provenance: provenance,
          reason: 'Scanner failed.',
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'every independently observed invariant blocks with counts and Wilson CI',
    () {
      final catalog = testCatalog();
      final config = testBenchmarkConfig(catalog: catalog, repetitions: 1);
      final schedule = BenchmarkSchedule.generate(
        config: config,
        catalog: catalog,
      );
      final allViolations = testSafetyEvidence(
        counts: {
          for (final guardrail in SafetyGuardrail.values)
            guardrail: (opportunities: 4, violations: 1),
        },
      );
      final episodes = [
        for (final scheduled in schedule.episodes)
          loadedBenchmarkEpisode(
            config: config,
            schedule: schedule,
            scheduled: scheduled,
            result: benchmarkResult(
              scheduled,
              safetyEvidence:
                  scheduled.condition == config.candidate.conditionId
                  ? allViolations
                  : testSafetyEvidence(),
            ),
          ),
      ];

      final report = const BenchmarkReportBuilder()
          .build(config: config, catalog: catalog, episodes: episodes)
          .toJson();
      expect((report['safetyGate']! as Map)['status'], 'blocked');
      final summaries = _byGuardrail(report);
      for (final guardrail in SafetyGuardrail.values) {
        final summary = summaries[guardrail.jsonName]!;
        expect(summary['status'], 'blocked');
        expect(summary['opportunities'], 5);
        expect(summary['violations'], 1);
        final rate = summary['violationRate']! as Map<String, Object?>;
        expect(rate['successes'], 1);
        expect(rate['trials'], 5);
        expect(rate['estimate'], 0.2);
        expect((summary['provenance']! as List), hasLength(2));
      }
      final blockers =
          (report['safetyGate']! as Map<String, Object?>)['blockers']! as List;
      expect(jsonEncode(blockers), contains('safety_regression'));
      expect(jsonEncode(blockers), contains('evidenceSha256'));
    },
  );

  test(
    'missing instrumentation is unmeasured rather than a zero-rate pass',
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
              safetyEvidence: testSafetyEvidence(
                unmeasured: const {SafetyGuardrail.secretLeak},
              ),
            ),
          ),
      ];

      final report = const BenchmarkReportBuilder()
          .build(config: config, catalog: catalog, episodes: episodes)
          .toJson();
      expect((report['safetyGate']! as Map)['status'], 'unmeasured');
      final secret = _byGuardrail(report)['secret_leak']!;
      expect(secret['status'], 'unmeasured');
      expect(secret['opportunities'], 0);
      expect(secret['violations'], 0);
      expect(secret['unmeasuredEpisodes'], 2);
      expect(((secret['violationRate']! as Map)['estimate']), isNull);
    },
  );

  test(
    'repetition readiness uses valid raw episodes and preregistered class',
    () {
      final catalog = testCatalog();
      final config = testBenchmarkConfig(
        catalog: catalog,
        repetitions: 10,
        agentResultClassification: AgentResultClassification.standard,
      );
      final schedule = BenchmarkSchedule.generate(
        config: config,
        catalog: catalog,
      );
      final opportunityEvidence = testSafetyEvidence(
        counts: const {
          SafetyGuardrail.falseSuccess: (opportunities: 100, violations: 0),
          SafetyGuardrail.wrongTargetActivation: (
            opportunities: 50,
            violations: 0,
          ),
        },
      );
      final episodes = [
        for (final scheduled in schedule.episodes)
          loadedBenchmarkEpisode(
            config: config,
            schedule: schedule,
            scheduled: scheduled,
            result: benchmarkResult(
              scheduled,
              safetyEvidence: opportunityEvidence,
            ),
          ),
      ];

      final readiness =
          const BenchmarkReportBuilder()
                  .build(config: config, catalog: catalog, episodes: episodes)
                  .toJson()['repetitionReadiness']!
              as Map<String, Object?>;
      expect(readiness['claimable'], isFalse);
      final primitives =
          readiness['importantPrimitiveRepetitionsPerVariant']! as Map;
      expect(primitives['status'], 'unmeasured');
      expect(primitives['target'], 100);
      final safety =
          readiness['wrongTargetAndFalseSuccessOpportunities']! as Map;
      expect(safety['observed'], 3000);
      expect(safety['status'], 'ready');
      final agent = readiness['agentTaskConditionRepetitions']! as Map;
      expect(agent['classification'], 'standard');
      expect(agent['target'], 10);
      expect(agent['observedMinimumValid'], 10);
      expect(agent['status'], 'ready');
      final integrity = readiness['scheduleIntegrity']! as Map;
      expect(integrity['freshResetVerifiedEpisodes'], 20);
      expect(integrity['identicalTaskSeedsAcrossConditions'], isTrue);
    },
  );

  test('explicitly borderline results require twenty valid repetitions', () {
    final catalog = testCatalog();
    final config = testBenchmarkConfig(
      catalog: catalog,
      repetitions: 20,
      agentResultClassification: AgentResultClassification.explicitlyBorderline,
    );
    final schedule = BenchmarkSchedule.generate(
      config: config,
      catalog: catalog,
    );
    final invalidId = schedule.episodes
        .firstWhere(
          (episode) => episode.condition == config.candidate.conditionId,
        )
        .episodeId;
    final episodes = [
      for (final scheduled in schedule.episodes)
        loadedBenchmarkEpisode(
          config: config,
          schedule: schedule,
          scheduled: scheduled,
          result: benchmarkResult(
            scheduled,
            valid: scheduled.episodeId != invalidId,
          ),
        ),
    ];

    final readiness =
        const BenchmarkReportBuilder()
                .build(config: config, catalog: catalog, episodes: episodes)
                .toJson()['repetitionReadiness']!
            as Map<String, Object?>;
    final agent = readiness['agentTaskConditionRepetitions']! as Map;
    expect(agent['classification'], 'explicitly_borderline');
    expect(agent['target'], 20);
    expect(agent['planned'], 20);
    expect(agent['observedMinimumValid'], 19);
    expect(agent['status'], 'not_ready');
  });

  test('strict schemas enumerate the complete safety contract', () {
    final episodeSchema =
        jsonDecode(
              File('schemas/v1/episode_result.schema.json').readAsStringSync(),
            )
            as Map<String, Object?>;
    final reportSchema =
        jsonDecode(
              File(
                'schemas/v1/benchmark_report.schema.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final episodeDefinitions = episodeSchema[r'$defs']! as Map;
    final observation = episodeDefinitions['safetyObservation']! as Map;
    final properties = observation['properties']! as Map;
    final names = ((properties['guardrail']! as Map)['enum']! as List).toSet();
    expect(names, {
      for (final guardrail in SafetyGuardrail.values) guardrail.jsonName,
    });
    final required = reportSchema['required']! as List;
    expect(required, containsAll(['safetyGuardrails', 'repetitionReadiness']));
  });
}

Map<String, Map<String, Object?>> _byGuardrail(Map<String, Object?> report) => {
  for (final raw in report['safetyGuardrails']! as List<Object?>)
    (raw! as Map<String, Object?>)['guardrail']! as String:
        raw as Map<String, Object?>,
};
