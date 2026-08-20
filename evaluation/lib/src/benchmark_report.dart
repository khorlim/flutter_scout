import 'dart:collection';
import 'dart:math' as math;

import 'benchmark_config.dart';
import 'benchmark_episode.dart';
import 'benchmark_schedule.dart';
import 'catalog.dart';
import 'digests.dart';
import 'episode_result.dart';
import 'failure.dart';
import 'json_support.dart';
import 'safety_metrics.dart';
import 'statistics.dart';
import 'task_manifest.dart';

const int benchmarkReportSchemaVersion = 1;

enum GateStatus {
  pass('pass'),
  fail('fail'),
  blocked('blocked'),
  unmeasured('unmeasured');

  const GateStatus(this.jsonName);

  final String jsonName;
}

class BenchmarkReport {
  BenchmarkReport({
    required this.benchmarkId,
    required this.safetyBlocked,
    required this.invalidHarnessCount,
    required Map<String, Object?> json,
  }) : _json = UnmodifiableMapView(deepCopyJsonObject(json));

  final String benchmarkId;
  final bool safetyBlocked;
  final int invalidHarnessCount;
  final Map<String, Object?> _json;

  Map<String, Object?> toJson() => deepCopyJsonObject(_json);
}

class BenchmarkReportBuilder {
  const BenchmarkReportBuilder();

  BenchmarkReport build({
    required BenchmarkConfig config,
    required CatalogSets catalog,
    required Iterable<LoadedBenchmarkEpisode> episodes,
  }) {
    final schedule = BenchmarkSchedule.generate(
      config: config,
      catalog: catalog,
    );
    final loaded = episodes.toList()
      ..sort((first, second) => first.episodeId.compareTo(second.episodeId));
    final expectedById = schedule.episodesById;
    final loadedById = <String, LoadedBenchmarkEpisode>{};
    final issues = <String>[];
    for (final episode in loaded) {
      final previous = loadedById[episode.episodeId];
      if (previous != null) {
        issues.add(
          'Duplicate episode id `${episode.episodeId}` in '
          '`${previous.sourcePath}` and `${episode.sourcePath}`.',
        );
      } else {
        loadedById[episode.episodeId] = episode;
      }
    }
    final missing = expectedById.keys.difference(loadedById.keys).toList()
      ..sort();
    final extra = loadedById.keys.difference(expectedById.keys).toList()
      ..sort();
    if (missing.isNotEmpty) {
      issues.add(
        'Missing scheduled episodes (post-hoc exclusion is forbidden): '
        '${missing.join(', ')}.',
      );
    }
    if (extra.isNotEmpty) {
      issues.add('Unscheduled episodes are present: ${extra.join(', ')}.');
    }
    final scheduleSha = schedule.sha256;
    for (final episodeId in expectedById.keys.toList()..sort()) {
      final expected = expectedById[episodeId];
      final actual = loadedById[episodeId];
      if (expected == null || actual == null) continue;
      _validateBinding(
        config: config,
        scheduleSha: scheduleSha,
        expected: expected,
        actual: actual,
        issues: issues,
      );
    }
    if (issues.isNotEmpty) throw BenchmarkInputException(issues);

    final accepted = <_AcceptedEpisode>[
      for (final scheduled in schedule.episodes)
        _AcceptedEpisode(
          scheduled: scheduled,
          loaded: loadedById[scheduled.episodeId]!,
        ),
    ];
    final invalidEpisodes = accepted
        .where((item) => !item.result.validEpisode)
        .toList();
    final invalidPairs = <String>{
      for (final item in invalidEpisodes) item.scheduled.pairId,
    }.toList()..sort();

    final conditionSummaries = <Map<String, Object?>>[
      for (final condition in config.conditionIds)
        _conditionSummary(condition, accepted),
    ];
    final validPairs = <PairedOutcome>[];
    final pairs = <String, List<_AcceptedEpisode>>{};
    for (final item in accepted) {
      pairs.putIfAbsent(item.scheduled.pairId, () => []).add(item);
    }
    final invalidScoutPairs = <String>[];
    for (final pairId in pairs.keys.toList()..sort()) {
      final members = pairs[pairId]!;
      final byCondition = {
        for (final member in members) member.result.condition: member.result,
      };
      final current = byCondition[config.current.conditionId]!;
      final candidate = byCondition[config.candidate.conditionId]!;
      if (!current.validEpisode || !candidate.validEpisode) {
        invalidScoutPairs.add(pairId);
        continue;
      }
      validPairs.add(
        PairedOutcome(
          currentPassed: current.passed,
          candidatePassed: candidate.passed,
        ),
      );
    }
    final paired = McNemarSummary.fromPairs(validPairs);
    final familySummary = _familySummary(config, accepted);
    final clusteredBootstrap = _clusteredBootstrap(config, accepted);
    final safetyGuardrails = _safetyGuardrailSummaries(config, accepted);
    final blockers = _safetyBlockers(accepted);
    final safetyBlocked = blockers.isNotEmpty;
    final safetyFullyMeasured = safetyGuardrails.every(
      (summary) => summary['status'] == GateStatus.pass.jsonName,
    );
    final repetitionReadiness = _repetitionReadiness(
      config: config,
      schedule: schedule,
      accepted: accepted,
    );
    final provisional = _provisionalAssessments(
      config: config,
      accepted: accepted,
      invalidHarnessCount: invalidEpisodes.length,
      safetyBlocked: safetyBlocked,
      familySummary: familySummary,
    );
    final inventory = [
      for (final item in accepted) item.loaded.inventoryJson(),
    ];
    final archiveSha = jsonSha256([
      for (final item in accepted)
        {
          'episodeId': item.result.episodeId,
          'fileSha256': item.loaded.fileSha256,
          'byteLength': item.loaded.rawBytes.length,
        },
    ]);
    final releaseReasons = <String>[];
    if (safetyBlocked) {
      releaseReasons.add('Observed zero-tolerance safety blocker.');
    }
    if (invalidEpisodes.isNotEmpty) {
      releaseReasons.add(
        'Invalid harness episodes make the comparison unusable.',
      );
    }
    if (!safetyFullyMeasured && !safetyBlocked) {
      releaseReasons.add(
        'At least one zero-tolerance guardrail lacks measured opportunities.',
      );
    }
    releaseReasons.add(
      'QUALITY_STANDARD release gates outside this episode report remain unmeasured.',
    );

    final json = <String, Object?>{
      'schemaVersion': benchmarkReportSchemaVersion,
      'benchmarkId': config.benchmarkId,
      'configSha256': config.sha256,
      'catalogSha256': schedule.catalogSha256,
      'scheduleSha256': scheduleSha,
      'scope': {
        'taskRegime': config.taskRegime.jsonName,
        'includedSplits': [
          for (final split in config.includedSplits) split.jsonName,
        ],
        'repetitions': config.repetitions,
        'scheduledPairs': pairs.length,
        'scheduledEpisodes': schedule.episodes.length,
        if (config.controlledComparison != null) 'controlledComparison': true,
        if (schedule.conditionRoles != null)
          'conditionRoles': {
            for (final condition in schedule.conditionIds)
              condition: schedule.conditionRoles![condition]!.jsonName,
          },
      },
      'archiveIntegrity': {
        'status': invalidEpisodes.isEmpty
            ? 'complete'
            : 'complete_with_invalid_harness_episodes',
        'loadedEpisodes': accepted.length,
        'missingEpisodes': 0,
        'extraEpisodes': 0,
        'duplicateEpisodes': 0,
        'postHocExclusions': 0,
        'archiveSha256': archiveSha,
        'inventory': inventory,
      },
      'invalidHarness': {
        'count': invalidEpisodes.length,
        'affectedPairCount': invalidPairs.length,
        'affectedPairIds': invalidPairs,
        'episodes': [
          for (final item in invalidEpisodes)
            {
              'episodeId': item.result.episodeId,
              'pairId': item.scheduled.pairId,
              'condition': item.result.condition,
              'reason': item.result.failure!.message,
              'fileSha256': item.loaded.fileSha256,
            },
        ],
      },
      'conditions': conditionSummaries,
      'pairedComparison': {
        ...paired.toJson(),
        'invalidPairCount': invalidScoutPairs.length,
        'invalidPairIds': invalidScoutPairs,
        'note': config.controlledComparison == null
            ? 'McNemar uses only complete pairs where both harness episodes are '
                  'valid; invalid pairs are listed rather than discarded silently.'
            : 'McNemar remains the preregistered current-versus-candidate '
                  'comparison and uses blocks where both Scout episodes are valid. '
                  'Auxiliary-role harness failures remain reported but do not erase '
                  'an otherwise valid Scout pair.',
      },
      'clusteredBootstrap': clusteredBootstrap,
      'templateFamilies': familySummary,
      'safetyGuardrails': safetyGuardrails,
      'repetitionReadiness': repetitionReadiness,
      'safetyGate': {
        'status': safetyBlocked
            ? GateStatus.blocked.jsonName
            : safetyFullyMeasured
            ? GateStatus.pass.jsonName
            : GateStatus.unmeasured.jsonName,
        'scope':
            'All independently observed per-episode zero-tolerance guardrails; '
            'missing instrumentation remains unmeasured, never zero.',
        'blockerCount': blockers.length,
        'blockers': blockers,
      },
      'provisionalThresholds': provisional,
      'releaseAssessment': {
        'status': safetyBlocked || invalidEpisodes.isNotEmpty
            ? GateStatus.blocked.jsonName
            : GateStatus.unmeasured.jsonName,
        'claimable': false,
        'reasons': releaseReasons,
      },
    };
    return BenchmarkReport(
      benchmarkId: config.benchmarkId,
      safetyBlocked: safetyBlocked,
      invalidHarnessCount: invalidEpisodes.length,
      json: json,
    );
  }
}

class _AcceptedEpisode {
  const _AcceptedEpisode({required this.scheduled, required this.loaded});

  final ScheduledEpisode scheduled;
  final LoadedBenchmarkEpisode loaded;

  EpisodeResult get result => loaded.envelope.result;
}

void _validateBinding({
  required BenchmarkConfig config,
  required String scheduleSha,
  required ScheduledEpisode expected,
  required LoadedBenchmarkEpisode actual,
  required List<String> issues,
}) {
  final envelope = actual.envelope;
  final result = envelope.result;
  void same(String field, Object? expectedValue, Object? actualValue) {
    if (expectedValue != actualValue) {
      issues.add(
        'Episode `${expected.episodeId}` $field mismatch: expected '
        '`$expectedValue`, got `$actualValue`.',
      );
    }
  }

  same('configSha256', config.sha256, envelope.configSha256);
  same('scheduleSha256', scheduleSha, envelope.scheduleSha256);
  same('pairId', expected.pairId, envelope.pairId);
  same('repetition', expected.repetition, envelope.repetition);
  same('variantSeed', expected.variantSeed, envelope.variantSeed);
  same('repetitionSeed', expected.repetitionSeed, envelope.repetitionSeed);
  same('conditionOrder', expected.conditionOrder, envelope.conditionOrder);
  same(
    'freshResetPerformed',
    expected.freshResetRequired,
    envelope.freshResetPerformed,
  );
  same('taskId', expected.taskId, result.taskId);
  same('templateId', expected.templateId, result.templateId);
  same('split', expected.split.jsonName, result.split.jsonName);
  same('condition', expected.condition, result.condition);

  final metrics = <String, int>{};
  for (final key in const ['toolCalls', 'responseBytes', 'screenshots']) {
    final raw = result.metrics[key];
    if (raw == null || !raw.isFinite || raw < 0 || raw != raw.roundToDouble()) {
      issues.add(
        'Episode `${expected.episodeId}` must record non-negative integer '
        '`metrics.$key`.',
      );
    } else {
      metrics[key] = raw.toInt();
    }
  }
  final tokens = result.usage.tokens;
  if (tokens == null) {
    issues.add('Episode `${expected.episodeId}` must record token usage.');
    return;
  }
  if (metrics.length != 3) return;
  final budgetRespected =
      result.usage.actions <= config.budget.maxActions &&
      result.usage.wallTimeMs <= config.budget.maxWallTimeMs &&
      tokens <= config.budget.maxTokens &&
      metrics['toolCalls']! <= config.budget.maxToolCalls &&
      metrics['responseBytes']! <= config.budget.maxResponseBytes &&
      metrics['screenshots']! <= config.budget.maxScreenshots;
  same(
    'oracle.budgetRespected',
    budgetRespected,
    result.oracle.budgetRespected,
  );
}

Map<String, Object?> _conditionSummary(
  String condition,
  List<_AcceptedEpisode> accepted,
) {
  final all = accepted
      .where((item) => item.result.condition == condition)
      .toList();
  final valid = all.where((item) => item.result.validEpisode).toList();
  final passed = valid.where((item) => item.result.passed).toList();
  final failures = <String, int>{
    for (final category in FailureCategory.values) category.jsonName: 0,
  };
  final severities = <String, int>{
    for (final severity in FailureSeverity.values) severity.jsonName: 0,
  };
  for (final item in all) {
    final failure = item.result.failure;
    if (failure == null) continue;
    failures[failure.category.jsonName] =
        failures[failure.category.jsonName]! + 1;
    severities[failure.severity.jsonName] =
        severities[failure.severity.jsonName]! + 1;
  }
  return {
    'conditionId': condition,
    'scheduled': all.length,
    'valid': valid.length,
    'invalidHarness': all.length - valid.length,
    'passed': passed.length,
    'failed': valid.length - passed.length,
    'success': WilsonInterval.confidence95(
      successes: passed.length,
      trials: valid.length,
    ).toJson(),
    'guardrailCounts': {
      for (final guardrail in SafetyGuardrail.values)
        guardrail.jsonName: all.fold<int>(
          0,
          (sum, item) => sum + item.result.safetyEvidence[guardrail].violations,
        ),
      'blockingRuntimeFault': all
          .where((item) => item.result.oracle.blockingRuntimeFaultObserved)
          .length,
      'releaseBlockingFailure': all
          .where(
            (item) =>
                item.result.failure?.severity ==
                FailureSeverity.releaseBlocking,
          )
          .length,
    },
    'failureTaxonomy': failures,
    'failureSeverities': severities,
    'costPerSuccessfulTask': {
      'actions': _aggregate(passed, (item) => item.result.usage.actions),
      'wallTimeMs': _aggregate(passed, (item) => item.result.usage.wallTimeMs),
      'tokens': _aggregate(passed, (item) => item.result.usage.tokens!),
      'toolCalls': _aggregate(
        passed,
        (item) => item.result.metrics['toolCalls']!.toInt(),
      ),
      'responseBytes': _aggregate(
        passed,
        (item) => item.result.metrics['responseBytes']!.toInt(),
      ),
      'screenshots': _aggregate(
        passed,
        (item) => item.result.metrics['screenshots']!.toInt(),
      ),
    },
  };
}

Map<String, Object?> _aggregate(
  List<_AcceptedEpisode> episodes,
  int Function(_AcceptedEpisode) value,
) {
  final total = episodes.fold<int>(0, (sum, episode) => sum + value(episode));
  return {
    'count': episodes.length,
    'total': total,
    'mean': episodes.isEmpty ? null : total / episodes.length,
  };
}

Map<String, Object?> _familySummary(
  BenchmarkConfig config,
  List<_AcceptedEpisode> accepted,
) {
  final summaries = <Map<String, Object?>>[];
  final candidateIntervals = <String, WilsonInterval>{};
  final pairedByFamily = <String, McNemarSummary>{};
  final rawFamilyPValues = <String, double>{};
  for (final family in config.templateFamilies) {
    for (final condition in config.conditionIds) {
      final familyEpisodes = accepted
          .where(
            (item) =>
                item.result.condition == condition &&
                family.templateIds.contains(item.result.templateId),
          )
          .toList();
      final valid = familyEpisodes
          .where((item) => item.result.validEpisode)
          .toList();
      final passed = valid.where((item) => item.result.passed).length;
      final interval = WilsonInterval.confidence95(
        successes: passed,
        trials: valid.length,
      );
      if (condition == config.candidate.conditionId) {
        candidateIntervals[family.familyId] = interval;
      }
      summaries.add({
        'familyId': family.familyId,
        'conditionId': condition,
        'scheduled': familyEpisodes.length,
        'valid': valid.length,
        'invalidHarness': familyEpisodes.length - valid.length,
        'success': interval.toJson(),
      });
    }
    final byPair = <String, List<_AcceptedEpisode>>{};
    for (final item in accepted.where(
      (item) => family.templateIds.contains(item.result.templateId),
    )) {
      byPair.putIfAbsent(item.scheduled.pairId, () => []).add(item);
    }
    final outcomes = <PairedOutcome>[];
    for (final members in byPair.values) {
      final byCondition = <String, EpisodeResult>{
        for (final member in members) member.result.condition: member.result,
      };
      final current = byCondition[config.current.conditionId];
      final candidate = byCondition[config.candidate.conditionId];
      if (current == null ||
          candidate == null ||
          !current.validEpisode ||
          !candidate.validEpisode) {
        continue;
      }
      outcomes.add(
        PairedOutcome(
          currentPassed: current.passed,
          candidatePassed: candidate.passed,
        ),
      );
    }
    final paired = McNemarSummary.fromPairs(outcomes);
    pairedByFamily[family.familyId] = paired;
    if (paired.pairs > 0) {
      rawFamilyPValues[family.familyId] = paired.exactTwoSidedP;
    }
  }
  final adjustedPValues = holmBonferroni(rawFamilyPValues);
  final measured =
      candidateIntervals.entries
          .where((entry) => entry.value.trials > 0)
          .toList()
        ..sort((first, second) {
          final lower = first.value.lower.compareTo(second.value.lower);
          return lower != 0 ? lower : first.key.compareTo(second.key);
        });
  final worst = measured.isEmpty ? null : measured.first;
  return {
    'summaries': summaries,
    'pairedComparisons': [
      for (final family in config.templateFamilies)
        {
          'familyId': family.familyId,
          ...pairedByFamily[family.familyId]!.toJson(),
          'holmAdjustedP': adjustedPValues[family.familyId],
          'multiplicityFamilySize': adjustedPValues.length,
        },
    ],
    'multiplicityControl': {
      'method': 'holm_bonferroni',
      'family': 'preregistered_template_family_mcnemar_tests',
      'hypotheses': adjustedPValues.length,
    },
    'candidateWorstCase': worst == null
        ? null
        : {'familyId': worst.key, 'success': worst.value.toJson()},
    'allCandidateFamiliesMeasured':
        measured.length == config.templateFamilies.length,
  };
}

Map<String, Object?> _clusteredBootstrap(
  BenchmarkConfig config,
  List<_AcceptedEpisode> accepted,
) {
  const iterations = 2000;
  final valid = accepted
      .where((item) => item.result.validEpisode)
      .toList(growable: false);
  final clusters = <String, List<_AcceptedEpisode>>{};
  for (final item in valid) {
    clusters.putIfAbsent(item.result.templateId, () => []).add(item);
  }
  final clusterIds = clusters.keys.toList()..sort();
  final seed =
      config.randomizationSeed ^
      int.parse(config.sha256.substring(0, 8), radix: 16);
  final random = math.Random(seed);
  final specifications =
      <
        ({
          String id,
          bool successfulOnly,
          double Function(_AcceptedEpisode) value,
        })
      >[
        (
          id: 'taskSuccessRate',
          successfulOnly: false,
          value: (item) => item.result.passed ? 1 : 0,
        ),
        (
          id: 'actionsPerSuccessfulTask',
          successfulOnly: true,
          value: (item) => item.result.usage.actions.toDouble(),
        ),
        (
          id: 'wallTimeMsPerSuccessfulTask',
          successfulOnly: true,
          value: (item) => item.result.usage.wallTimeMs.toDouble(),
        ),
        (
          id: 'tokensPerSuccessfulTask',
          successfulOnly: true,
          value: (item) => item.result.usage.tokens!.toDouble(),
        ),
        (
          id: 'toolCallsPerSuccessfulTask',
          successfulOnly: true,
          value: (item) => item.result.metrics['toolCalls']!.toDouble(),
        ),
        (
          id: 'responseBytesPerSuccessfulTask',
          successfulOnly: true,
          value: (item) => item.result.metrics['responseBytes']!.toDouble(),
        ),
        (
          id: 'screenshotsPerSuccessfulTask',
          successfulOnly: true,
          value: (item) => item.result.metrics['screenshots']!.toDouble(),
        ),
      ];

  Map<String, double?> conditionMeans(
    List<_AcceptedEpisode> sample,
    ({String id, bool successfulOnly, double Function(_AcceptedEpisode) value})
    specification,
  ) {
    final output = <String, double?>{};
    for (final condition in config.conditionIds) {
      final members = sample
          .where(
            (item) =>
                item.result.condition == condition &&
                (!specification.successfulOnly || item.result.passed),
          )
          .toList(growable: false);
      output[condition] = members.isEmpty
          ? null
          : members
                    .map(specification.value)
                    .fold<double>(0, (sum, value) => sum + value) /
                members.length;
    }
    return output;
  }

  final comparisons = <Map<String, Object?>>[];
  for (final specification in specifications) {
    final observed = conditionMeans(valid, specification);
    final observedCurrent = observed[config.current.conditionId];
    final observedCandidate = observed[config.candidate.conditionId];
    final samples = <double>[];
    if (clusterIds.isNotEmpty) {
      for (var iteration = 0; iteration < iterations; iteration++) {
        final sample = <_AcceptedEpisode>[];
        for (var draw = 0; draw < clusterIds.length; draw++) {
          final id = clusterIds[random.nextInt(clusterIds.length)];
          sample.addAll(clusters[id]!);
        }
        final means = conditionMeans(sample, specification);
        final current = means[config.current.conditionId];
        final candidate = means[config.candidate.conditionId];
        if (current != null && candidate != null) {
          samples.add(candidate - current);
        }
      }
    }
    samples.sort();
    comparisons.add({
      'metric': specification.id,
      'successfulEpisodesOnly': specification.successfulOnly,
      'currentEstimate': observedCurrent,
      'candidateEstimate': observedCandidate,
      'candidateMinusCurrent':
          observedCurrent == null || observedCandidate == null
          ? null
          : observedCandidate - observedCurrent,
      'interval': {
        'confidenceLevel': 0.95,
        'lower': _bootstrapPercentile(samples, 0.025),
        'upper': _bootstrapPercentile(samples, 0.975),
        'usableResamples': samples.length,
        'requestedResamples': iterations,
      },
    });
  }
  return {
    'method': 'task_template_clustered_percentile_bootstrap',
    'clusterKey': 'templateId',
    'seed': seed,
    'clusterCount': clusterIds.length,
    'resamples': iterations,
    'comparisons': comparisons,
  };
}

double? _bootstrapPercentile(List<double> sorted, double probability) {
  if (sorted.isEmpty) return null;
  if (sorted.length == 1) return sorted.single;
  final position = probability * (sorted.length - 1);
  final lower = position.floor();
  final upper = position.ceil();
  if (lower == upper) return sorted[lower];
  final fraction = position - lower;
  return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction;
}

List<Map<String, Object?>> _safetyGuardrailSummaries(
  BenchmarkConfig config,
  List<_AcceptedEpisode> accepted,
) => [
  for (final guardrail in SafetyGuardrail.values)
    {
      'guardrail': guardrail.jsonName,
      ..._safetyAggregate(guardrail, accepted, includeProvenance: true),
      'conditions': [
        for (final condition in config.conditionIds)
          {
            'conditionId': condition,
            ..._safetyAggregate(
              guardrail,
              accepted
                  .where((item) => item.result.condition == condition)
                  .toList(),
              includeProvenance: false,
            ),
          },
      ],
    },
];

Map<String, Object?> _safetyAggregate(
  SafetyGuardrail guardrail,
  List<_AcceptedEpisode> episodes, {
  required bool includeProvenance,
}) {
  final measured = <_AcceptedEpisode>[];
  var unmeasuredEpisodes = 0;
  var notApplicableEpisodes = 0;
  var opportunities = 0;
  var violations = 0;
  for (final item in episodes) {
    final observation = item.result.safetyEvidence[guardrail];
    switch (observation.status) {
      case SafetyMeasurementStatus.measured:
        measured.add(item);
        opportunities += observation.opportunities;
        violations += observation.violations;
        break;
      case SafetyMeasurementStatus.unmeasured:
        unmeasuredEpisodes += 1;
        break;
      case SafetyMeasurementStatus.notApplicable:
        notApplicableEpisodes += 1;
        break;
    }
  }
  final rate = WilsonInterval.confidence95(
    successes: violations,
    trials: opportunities,
  );
  final status = violations > 0
      ? GateStatus.blocked
      : opportunities == 0 || unmeasuredEpisodes > 0
      ? GateStatus.unmeasured
      : GateStatus.pass;
  return {
    'status': status.jsonName,
    'episodes': episodes.length,
    'measuredEpisodes': measured.length,
    'unmeasuredEpisodes': unmeasuredEpisodes,
    'notApplicableEpisodes': notApplicableEpisodes,
    'opportunities': opportunities,
    'violations': violations,
    'violationRate': rate.toJson(),
    if (includeProvenance)
      'provenance': [
        for (final item in measured)
          {
            'episodeId': item.result.episodeId,
            'condition': item.result.condition,
            'opportunities':
                item.result.safetyEvidence[guardrail].opportunities,
            'violations': item.result.safetyEvidence[guardrail].violations,
            ...item.result.safetyEvidence[guardrail].provenance!.toJson(),
          },
      ],
  };
}

Map<String, Object?> _repetitionReadiness({
  required BenchmarkConfig config,
  required BenchmarkSchedule schedule,
  required List<_AcceptedEpisode> accepted,
}) {
  const primitiveTarget = 100;
  const safetyOpportunityTarget = 3000;
  final safetyOpportunityGuardrails = const {
    SafetyGuardrail.falseSuccess,
    SafetyGuardrail.wrongTargetActivation,
  };
  var safetyOpportunities = 0;
  for (final item in accepted.where((item) => item.result.validEpisode)) {
    for (final guardrail in safetyOpportunityGuardrails) {
      final observation = item.result.safetyEvidence[guardrail];
      if (observation.status == SafetyMeasurementStatus.measured) {
        safetyOpportunities += observation.opportunities;
      }
    }
  }

  final validRepetitionsByTaskCondition = <String, int>{};
  for (final item in accepted.where((item) => item.result.validEpisode)) {
    final key = '${item.result.taskId}|${item.result.condition}';
    validRepetitionsByTaskCondition[key] =
        (validRepetitionsByTaskCondition[key] ?? 0) + 1;
  }
  final expectedGroups = <String>{
    for (final item in schedule.episodes) '${item.taskId}|${item.condition}',
  };
  final minimumValidAgentRepetitions = expectedGroups.isEmpty
      ? 0
      : expectedGroups
            .map((key) => validRepetitionsByTaskCondition[key] ?? 0)
            .reduce((first, second) => first < second ? first : second);
  final agentTarget = config.agentResultClassification.requiredRepetitions;

  final pairSeeds = <String, ({int variantSeed, int repetitionSeed})>{};
  var identicalSeeds = true;
  for (final episode in schedule.episodes) {
    final seed = (
      variantSeed: episode.variantSeed,
      repetitionSeed: episode.repetitionSeed,
    );
    final previous = pairSeeds[episode.pairId];
    if (previous != null && previous != seed) identicalSeeds = false;
    pairSeeds[episode.pairId] = seed;
  }
  final freshResetCount = accepted
      .where((item) => item.loaded.envelope.freshResetPerformed)
      .length;
  return {
    'claimable': false,
    'importantPrimitiveRepetitionsPerVariant': {
      'status': 'unmeasured',
      'target': primitiveTarget,
      'observedMinimum': null,
      'reason':
          'Agent episode archives do not contain independently loaded '
          'important-primitive sample archives.',
    },
    'wrongTargetAndFalseSuccessOpportunities': {
      'status': safetyOpportunities >= safetyOpportunityTarget
          ? 'ready'
          : 'not_ready',
      'target': safetyOpportunityTarget,
      'observed': safetyOpportunities,
      'sourceGuardrails': [
        SafetyGuardrail.wrongTargetActivation.jsonName,
        SafetyGuardrail.falseSuccess.jsonName,
      ],
      'scope': 'valid episodes with independently measured observations only',
    },
    'agentTaskConditionRepetitions': {
      'status': minimumValidAgentRepetitions >= agentTarget
          ? 'ready'
          : 'not_ready',
      'classification': config.agentResultClassification.jsonName,
      'target': agentTarget,
      'planned': config.repetitions,
      'observedMinimumValid': minimumValidAgentRepetitions,
    },
    'scheduleIntegrity': {
      'freshResetRequired': true,
      'freshResetVerifiedEpisodes': freshResetCount,
      'scheduledEpisodes': schedule.episodes.length,
      'identicalTaskSeedsAcrossConditions': identicalSeeds,
    },
  };
}

List<Map<String, Object?>> _safetyBlockers(List<_AcceptedEpisode> accepted) {
  final blockers = <Map<String, Object?>>[];
  for (final item in accepted) {
    final signals = <String>[];
    final observations = <Map<String, Object?>>[];
    final failure = item.result.failure;
    if (failure?.severity == FailureSeverity.releaseBlocking) {
      signals.add('release_blocking_failure');
    }
    for (final guardrail in SafetyGuardrail.values) {
      final observation = item.result.safetyEvidence[guardrail];
      if (observation.violations == 0) continue;
      signals.add(guardrail.jsonName);
      observations.add({
        'guardrail': guardrail.jsonName,
        'opportunities': observation.opportunities,
        'violations': observation.violations,
        'provenance': observation.provenance!.toJson(),
      });
    }
    if (signals.isNotEmpty) {
      blockers.add({
        'episodeId': item.result.episodeId,
        'pairId': item.scheduled.pairId,
        'condition': item.result.condition,
        'signals': signals,
        'observations': observations,
        'failure': failure?.toJson(),
      });
    }
  }
  return blockers;
}

List<Map<String, Object?>> _provisionalAssessments({
  required BenchmarkConfig config,
  required List<_AcceptedEpisode> accepted,
  required int invalidHarnessCount,
  required bool safetyBlocked,
  required Map<String, Object?> familySummary,
}) {
  final assessments = <Map<String, Object?>>[];
  final candidate = accepted
      .where(
        (item) =>
            item.result.condition == config.candidate.conditionId &&
            item.result.validEpisode,
      )
      .toList();
  final success = WilsonInterval.confidence95(
    successes: candidate.where((item) => item.result.passed).length,
    trials: candidate.length,
  );
  final heldOut = config.includedSplits.every(
    (split) => split != BenchmarkSplit.publicDevelopment,
  );

  Map<String, Object?> rateGate({
    required String id,
    required TaskRegime requiredRegime,
    required double threshold,
  }) {
    if (safetyBlocked || invalidHarnessCount > 0) {
      return _gate(
        id,
        GateStatus.blocked,
        target: 'lower95 >= $threshold',
        reason: 'Safety or harness-integrity blockers are present.',
      );
    }
    if (!heldOut) {
      return _gate(
        id,
        GateStatus.unmeasured,
        target: 'lower95 >= $threshold',
        reason: 'The selected catalog includes public development tasks.',
      );
    }
    if (config.taskRegime != requiredRegime) {
      return _gate(
        id,
        GateStatus.unmeasured,
        target: 'lower95 >= $threshold',
        reason:
            'This config is `${config.taskRegime.jsonName}`, not '
            '`${requiredRegime.jsonName}`.',
      );
    }
    if (success.trials == 0) {
      return _gate(
        id,
        GateStatus.unmeasured,
        target: 'lower95 >= $threshold',
        reason: 'No valid candidate episodes.',
      );
    }
    return _gate(
      id,
      success.lower >= threshold ? GateStatus.pass : GateStatus.fail,
      target: 'lower95 >= $threshold',
      observed: success.toJson(),
    );
  }

  assessments.add(
    rateGate(
      id: 'clean_held_out_agent_task_success',
      requiredRegime: TaskRegime.clean,
      threshold: 0.95,
    ),
  );
  assessments.add(
    rateGate(
      id: 'perturbed_held_out_task_success',
      requiredRegime: TaskRegime.perturbed,
      threshold: 0.90,
    ),
  );
  final allFamiliesMeasured =
      familySummary['allCandidateFamiliesMeasured'] as bool;
  final worst = familySummary['candidateWorstCase'] as Map<String, Object?>?;
  if (safetyBlocked || invalidHarnessCount > 0) {
    assessments.add(
      _gate(
        'worst_task_family_success',
        GateStatus.blocked,
        target: 'lower95 >= 0.8',
        reason: 'Safety or harness-integrity blockers are present.',
      ),
    );
  } else if (!allFamiliesMeasured || worst == null) {
    assessments.add(
      _gate(
        'worst_task_family_success',
        GateStatus.unmeasured,
        target: 'lower95 >= 0.8',
        reason: 'At least one configured template family has no valid episode.',
      ),
    );
  } else {
    final interval = worst['success']! as Map<String, Object?>;
    final lower = interval['lower']! as num;
    assessments.add(
      _gate(
        'worst_task_family_success',
        lower >= 0.8 ? GateStatus.pass : GateStatus.fail,
        target: 'lower95 >= 0.8',
        observed: worst,
      ),
    );
  }

  const unmeasured = <String, String>{
    'deterministic_primitive_reliability': 'No primitive-opportunity metric.',
    'visible_control_perception_precision_recall': 'No perception labels.',
    'modal_active_surface_correctness': 'No modal-corpus opportunity metric.',
    'stale_handle_abstention': 'No stale-handle opportunity metric.',
    'critical_delta_recall': 'No independently labeled delta corpus.',
    'overall_delta_precision_recall': 'No independently labeled delta corpus.',
    'supported_injected_fault_recall': 'No injected-fault opportunity metric.',
    'runtime_signal_precision': 'No labeled runtime-signal corpus.',
    'false_stable_rate': 'No independent stability oracle.',
    'locate_reveal_success': 'No locate/reveal opportunity metric.',
    'lifecycle_recovery': 'No lifecycle-fault opportunity metric.',
    'deterministic_replay_success': 'No replay opportunity metric.',
    'perturbation_drop':
        'Clean and perturbed cohorts are not jointly identified.',
    'inspect_latency': 'No standardized inspect phase timing.',
    'large_tree_inspect_latency': 'No large-tree phase timing.',
    'action_overhead': 'No app-settling-excluded action timing.',
    'typical_brief_payload': 'No brief-response cohort marker.',
    'idle_cpu_overhead': 'No resource profile.',
    'incremental_resident_memory': 'No resource profile.',
    'median_frame_time_regression': 'No frame-time baseline.',
    'endurance': 'No endurance run record.',
    'paired_noninferiority':
        'McNemar is reported, but a preregistered paired-delta confidence interval is not.',
  };
  for (final entry in unmeasured.entries) {
    assessments.add(
      _gate(entry.key, GateStatus.unmeasured, reason: entry.value),
    );
  }
  return assessments;
}

Map<String, Object?> _gate(
  String id,
  GateStatus status, {
  String? target,
  Object? observed,
  String? reason,
}) => {
  'gateId': id,
  'status': status.jsonName,
  if (target != null) 'target': target,
  if (observed != null) 'observed': observed,
  if (reason != null) 'reason': reason,
};

extension on Iterable<String> {
  Set<String> difference(Iterable<String> other) =>
      toSet().difference(other.toSet());
}
