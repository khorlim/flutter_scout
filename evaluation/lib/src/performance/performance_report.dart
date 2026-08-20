import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import '../digests.dart';
import '../json_support.dart';
import 'performance_config.dart';
import 'performance_sample.dart';

const int performanceReportSchemaVersion = 1;

class PerformanceInputException implements Exception {
  PerformanceInputException(Iterable<String> issues)
    : issues = List<String>.unmodifiable(issues);

  final List<String> issues;

  @override
  String toString() =>
      'Performance evidence is invalid:\n- ${issues.join('\n- ')}';
}

class DistributionSummary {
  const DistributionSummary({
    required this.count,
    required this.minimum,
    required this.maximum,
    required this.mean,
    required this.p50,
    required this.p95,
    required this.p99,
  });

  final int count;
  final num minimum;
  final num maximum;
  final double mean;
  final num p50;
  final num p95;
  final num p99;

  factory DistributionSummary.fromValues(Iterable<num> input) {
    final values = input.toList();
    if (values.isEmpty) {
      throw ArgumentError('A distribution requires at least one value.');
    }
    for (final value in values) {
      if (!value.isFinite || value < 0) {
        throw ArgumentError.value(
          value,
          'input',
          'distribution values must be finite and non-negative',
        );
      }
    }
    values.sort((first, second) => first.compareTo(second));
    final sum = values.fold<double>(0, (total, value) => total + value);
    return DistributionSummary(
      count: values.length,
      minimum: values.first,
      maximum: values.last,
      mean: sum / values.length,
      p50: _nearestRank(values, 0.50),
      p95: _nearestRank(values, 0.95),
      p99: _nearestRank(values, 0.99),
    );
  }

  Map<String, Object?> toJson() => {
    'count': count,
    'minimum': minimum,
    'maximum': maximum,
    'mean': mean,
    'p50': p50,
    'p95': p95,
    'p99': p99,
  };
}

class PerformanceReport {
  PerformanceReport({
    required this.componentBlocked,
    required Map<String, Object?> json,
  }) : _json = UnmodifiableMapView(deepCopyJsonObject(json));

  final bool componentBlocked;
  final Map<String, Object?> _json;

  Map<String, Object?> toJson() => deepCopyJsonObject(_json);
}

class PerformanceReportBuilder {
  const PerformanceReportBuilder();

  PerformanceReport build({
    required PerformanceConfig config,
    required Iterable<LoadedPerformanceSample> samples,
  }) {
    final loaded = samples.toList()
      ..sort(
        (first, second) =>
            first.sample.sampleId.compareTo(second.sample.sampleId),
      );
    final issues = _validateInputs(config, loaded);
    if (issues.isNotEmpty) throw PerformanceInputException(issues);

    final byCondition = <String, List<LoadedPerformanceSample>>{
      for (final condition in config.conditions) condition.conditionId: [],
    };
    for (final item in loaded) {
      byCondition[item.sample.conditionId]!.add(item);
    }
    final baseline = byCondition[config.baseline.conditionId]!;
    final candidate = byCondition[config.candidate.conditionId]!;
    final baselineSummary = _conditionSummary(config, baseline);
    final candidateSummary = _conditionSummary(config, candidate);
    final comparison = _comparison(config, baseline, candidate);
    final regressions = (comparison['regressions']! as List<Object?>);

    final effectSamples = <Map<String, Object?>>[];
    for (final item in loaded) {
      final effects = item.sample.observationEffects.effectKinds;
      if (effects.isNotEmpty) {
        effectSamples.add({
          'sampleId': item.sample.sampleId,
          'conditionId': item.sample.conditionId,
          'effects': effects,
          'fileSha256': item.fileSha256,
        });
      }
    }
    final nonInterferenceBlocked = effectSamples.isNotEmpty;
    final gates = _quantitativeGates(
      config: config,
      candidate: candidate,
      baseline: baseline,
      blockedByObservationEffect: nonInterferenceBlocked,
    );
    final ratifiedGateFailed = gates.any(
      (gate) => gate['status'] == 'fail' || gate['status'] == 'blocked',
    );
    final componentBlocked =
        nonInterferenceBlocked ||
        (config.thresholds.status == ThresholdRatificationStatus.ratified &&
            (ratifiedGateFailed || regressions.isNotEmpty));

    final inventory = [for (final item in loaded) item.inventoryJson()];
    final archiveSha256 = jsonSha256([
      for (final item in loaded)
        {
          'sampleId': item.sample.sampleId,
          'fileSha256': item.fileSha256,
          'byteLength': item.rawBytes.length,
        },
    ]);
    final provisional =
        config.thresholds.status == ThresholdRatificationStatus.provisional;
    final releaseReasons = <String>[
      if (nonInterferenceBlocked)
        'Observation produced a forbidden application-side effect.',
      if (provisional)
        'Thresholds are provisional; no frozen, ratified environment is pinned.',
      if (!provisional && ratifiedGateFailed)
        'At least one ratified performance component gate failed.',
      if (regressions.isNotEmpty)
        'Candidate regressions exceeded the preregistered comparison tolerance.',
      'This fixture-level performance report does not cover all QUALITY_STANDARD release gates.',
    ];

    final report = <String, Object?>{
      'schemaVersion': performanceReportSchemaVersion,
      'benchmarkId': config.benchmarkId,
      'configSha256': config.sha256,
      'environmentSha256': config.environment.sha256,
      'environment': config.environment.toJson(),
      'evidenceIntegrity': {
        'status': 'complete',
        'exactInputBytesHashed': true,
        'inputMutationDetected': false,
        'missingSamples': 0,
        'extraSamples': 0,
        'duplicateSamples': 0,
        'postHocExclusions': 0,
        'archiveSha256': archiveSha256,
        'inventory': inventory,
      },
      'measurementContract': {
        'phaseOrder': performancePhaseNames,
        'phaseUnit': 'microseconds',
        'actionOverheadDefinition':
            'connect + snapshot + match + dispatch + delta + logs + serialize; settle is excluded',
        'percentileMethod': 'empirical_nearest_rank',
        'tokenEstimationMethod': config.environment.measurement.tokenEstimator,
        'estimatedUtf8BytesPerToken':
            config.environment.measurement.estimatedUtf8BytesPerToken,
        'scenario': config.environment.fixture.scenario.jsonName,
        'warmupIterations': config.warmupIterations,
        'repetitionsPerCondition': config.repetitions,
      },
      'conditions': [baselineSummary, candidateSummary],
      'comparison': comparison,
      'observationNonInterference': {
        'status': nonInterferenceBlocked ? 'blocked' : 'pass',
        'requiredEffectKinds': const [
          'focus',
          'pointer_gesture',
          'route',
          'semantics',
          'overlay_interception',
          'business_state',
          'synthetic_frames',
        ],
        'affectedSampleCount': effectSamples.length,
        'affectedSamples': effectSamples,
      },
      'quantitativeGates': {
        'ratificationStatus': config.thresholds.status.jsonName,
        'ratificationId': config.thresholds.ratificationId,
        'frozenEnvironmentSha256': config.thresholds.frozenEnvironmentSha256,
        'gates': gates,
        'note': provisional
            ? 'Provisional targets are reported as unmeasured and cannot pass.'
            : 'Component gates use the explicitly ratified frozen environment.',
      },
      'releaseAssessment': {
        'status': componentBlocked ? 'blocked' : 'unmeasured',
        'claimable': false,
        'reasons': releaseReasons,
      },
    };
    return PerformanceReport(componentBlocked: componentBlocked, json: report);
  }
}

List<String> _validateInputs(
  PerformanceConfig config,
  List<LoadedPerformanceSample> loaded,
) {
  final issues = <String>[];
  final byId = <String, LoadedPerformanceSample>{};
  final expectedConditionIds = {
    config.baseline.conditionId,
    config.candidate.conditionId,
  };
  for (final item in loaded) {
    final sample = item.sample;
    if (item.rawBytes.isEmpty ||
        sha256Bytes(item.rawBytes) != item.fileSha256) {
      issues.add(
        'Sample `${sample.sampleId}` exact-byte digest does not match its '
        'declared fileSha256.',
      );
    } else {
      try {
        final decoded = jsonDecode(
          utf8.decode(item.rawBytes, allowMalformed: false),
        );
        final rawSample = PerformanceRawSample.fromJson(decoded);
        if (canonicalJsonEncode(rawSample.toJson()) !=
            canonicalJsonEncode(sample.toJson())) {
          issues.add(
            'Sample `${sample.sampleId}` typed value differs from its exact '
            'raw bytes.',
          );
        }
      } on Object catch (error) {
        issues.add(
          'Sample `${sample.sampleId}` exact raw bytes are not a valid sample: '
          '$error',
        );
      }
    }
    final previous = byId[sample.sampleId];
    if (previous != null) {
      issues.add(
        'Duplicate sample id `${sample.sampleId}` in `${previous.sourcePath}` '
        'and `${item.sourcePath}`.',
      );
    } else {
      byId[sample.sampleId] = item;
    }
    if (sample.configSha256 != config.sha256) {
      issues.add(
        'Sample `${sample.sampleId}` config/environment mismatch: expected '
        '`${config.sha256}`, got `${sample.configSha256}`.',
      );
    }
    if (!expectedConditionIds.contains(sample.conditionId)) {
      issues.add(
        'Sample `${sample.sampleId}` has unknown condition '
        '`${sample.conditionId}`.',
      );
    }
    if (sample.repetition > config.repetitions) {
      issues.add(
        'Sample `${sample.sampleId}` is a post-hoc repetition outside the '
        'preregistered range 1..${config.repetitions}.',
      );
    }
    if (sample.warmupIterationsCompleted != config.warmupIterations) {
      issues.add(
        'Sample `${sample.sampleId}` completed '
        '${sample.warmupIterationsCompleted} warmups; expected exactly '
        '${config.warmupIterations}.',
      );
    }
  }
  final actualIds = byId.keys.toSet();
  final missing = config.expectedSampleIds.difference(actualIds).toList()
    ..sort();
  final extra = actualIds.difference(config.expectedSampleIds).toList()..sort();
  if (missing.isNotEmpty) {
    issues.add(
      'Missing preregistered samples (post-hoc exclusion is forbidden): '
      '${missing.join(', ')}.',
    );
  }
  if (extra.isNotEmpty) {
    issues.add('Extra/post-hoc samples are forbidden: ${extra.join(', ')}.');
  }
  return issues;
}

Map<String, Object?> _conditionSummary(
  PerformanceConfig config,
  List<LoadedPerformanceSample> samples,
) {
  final raw = [for (final item in samples) item.sample];
  final effectSamples = raw.where(
    (sample) => sample.observationEffects.hasEffect,
  );
  return {
    'conditionId': raw.first.conditionId,
    'sampleCount': raw.length,
    'phaseTimingsUs': {
      for (final phase in performancePhaseNames)
        phase: DistributionSummary.fromValues(
          raw.map((sample) => sample.phaseTimings.valueFor(phase)),
        ).toJson(),
    },
    'actionOverheadExcludingSettleUs': DistributionSummary.fromValues(
      raw.map((sample) => sample.phaseTimings.actionOverheadExcludingSettleUs),
    ).toJson(),
    'totalUs': DistributionSummary.fromValues(
      raw.map((sample) => sample.phaseTimings.totalUs),
    ).toJson(),
    'payload': {
      'bytes': DistributionSummary.fromValues(
        raw.map((sample) => sample.responsePayloadBytes),
      ).toJson(),
      'estimatedTokens': DistributionSummary.fromValues(
        raw.map((sample) => _estimatedTokens(config, sample)),
      ).toJson(),
    },
    'resources': {
      'idleCpuPercent': DistributionSummary.fromValues(
        raw.map((sample) => sample.resources.cpu.idlePercent),
      ).toJson(),
      'activeCpuPercent': DistributionSummary.fromValues(
        raw.map((sample) => sample.resources.cpu.activePercent),
      ).toJson(),
      'processRssBytes': DistributionSummary.fromValues(
        raw.map((sample) => sample.resources.memory.processRssBytes),
      ).toJson(),
      'incrementalRssBytes': DistributionSummary.fromValues(
        raw.map((sample) => sample.resources.memory.incrementalRssBytes),
      ).toJson(),
      'peakRssBytes': DistributionSummary.fromValues(
        raw.map((sample) => sample.resources.memory.peakRssBytes),
      ).toJson(),
      'frameMedianUs': DistributionSummary.fromValues(
        raw.map((sample) => sample.resources.frameTime.medianUs),
      ).toJson(),
      'frameP95Us': DistributionSummary.fromValues(
        raw.map((sample) => sample.resources.frameTime.p95Us),
      ).toJson(),
      'enduranceDurationMs': DistributionSummary.fromValues(
        raw.map((sample) => sample.resources.endurance.durationMs),
      ).toJson(),
      'enduranceActionCount': DistributionSummary.fromValues(
        raw.map((sample) => sample.resources.endurance.actionCount),
      ).toJson(),
      'enduranceGrowthBytes': _signedDistribution(
        raw.map((sample) => sample.resources.endurance.growthBytes),
      ),
      'enduranceFailures': {
        'crashes': raw.fold<int>(
          0,
          (total, sample) => total + sample.resources.endurance.crashCount,
        ),
        'crossovers': raw.fold<int>(
          0,
          (total, sample) => total + sample.resources.endurance.crossoverCount,
        ),
        'deadlocks': raw.fold<int>(
          0,
          (total, sample) => total + sample.resources.endurance.deadlockCount,
        ),
        'unboundedGrowthSamples': raw
            .where(
              (sample) => sample.resources.endurance.unboundedGrowthObserved,
            )
            .length,
      },
    },
    'provenance': {
      'cpu': _provenanceSummary(
        raw,
        (sample) => sample.resources.cpu.provenance,
      ),
      'memory': _provenanceSummary(
        raw,
        (sample) => sample.resources.memory.provenance,
      ),
      'frameTime': _provenanceSummary(
        raw,
        (sample) => sample.resources.frameTime.provenance,
      ),
      'endurance': _provenanceSummary(
        raw,
        (sample) => sample.resources.endurance.provenance,
      ),
      'observationEffects': _provenanceSummary(
        raw,
        (sample) => sample.observationEffects.provenance,
      ),
    },
    'observationEffectSampleCount': effectSamples.length,
  };
}

Map<String, Object?> _comparison(
  PerformanceConfig config,
  List<LoadedPerformanceSample> baseline,
  List<LoadedPerformanceSample> candidate,
) {
  final baselineSamples = [for (final item in baseline) item.sample];
  final candidateSamples = [for (final item in candidate) item.sample];
  final metrics = <String, Map<String, Object?>>{};
  void compare(String metricId, num baselineValue, num candidateValue) {
    metrics[metricId] = _metricComparison(
      metricId: metricId,
      baseline: baselineValue,
      candidate: candidateValue,
      tolerancePercent: config.thresholds.comparisonTolerancePercent,
    );
  }

  void compareHigher(String metricId, num baselineValue, num candidateValue) {
    metrics[metricId] = _metricComparison(
      metricId: metricId,
      baseline: baselineValue,
      candidate: candidateValue,
      tolerancePercent: config.thresholds.comparisonTolerancePercent,
      lowerIsBetter: false,
    );
  }

  for (final phase in performancePhaseNames) {
    compare(
      'phase.$phase.p95_us',
      DistributionSummary.fromValues(
        baselineSamples.map((sample) => sample.phaseTimings.valueFor(phase)),
      ).p95,
      DistributionSummary.fromValues(
        candidateSamples.map((sample) => sample.phaseTimings.valueFor(phase)),
      ).p95,
    );
  }
  compare(
    'action_overhead_excluding_settle.p95_us',
    DistributionSummary.fromValues(
      baselineSamples.map(
        (sample) => sample.phaseTimings.actionOverheadExcludingSettleUs,
      ),
    ).p95,
    DistributionSummary.fromValues(
      candidateSamples.map(
        (sample) => sample.phaseTimings.actionOverheadExcludingSettleUs,
      ),
    ).p95,
  );
  compare(
    'payload.p95_bytes',
    DistributionSummary.fromValues(
      baselineSamples.map((sample) => sample.responsePayloadBytes),
    ).p95,
    DistributionSummary.fromValues(
      candidateSamples.map((sample) => sample.responsePayloadBytes),
    ).p95,
  );
  compare(
    'payload.p95_estimated_tokens',
    DistributionSummary.fromValues(
      baselineSamples.map((sample) => _estimatedTokens(config, sample)),
    ).p95,
    DistributionSummary.fromValues(
      candidateSamples.map((sample) => _estimatedTokens(config, sample)),
    ).p95,
  );
  compare(
    'cpu.idle.p95_percent',
    DistributionSummary.fromValues(
      baselineSamples.map((sample) => sample.resources.cpu.idlePercent),
    ).p95,
    DistributionSummary.fromValues(
      candidateSamples.map((sample) => sample.resources.cpu.idlePercent),
    ).p95,
  );
  compare(
    'cpu.active.p95_percent',
    DistributionSummary.fromValues(
      baselineSamples.map((sample) => sample.resources.cpu.activePercent),
    ).p95,
    DistributionSummary.fromValues(
      candidateSamples.map((sample) => sample.resources.cpu.activePercent),
    ).p95,
  );
  compare(
    'memory.incremental_rss.p95_bytes',
    DistributionSummary.fromValues(
      baselineSamples.map(
        (sample) => sample.resources.memory.incrementalRssBytes,
      ),
    ).p95,
    DistributionSummary.fromValues(
      candidateSamples.map(
        (sample) => sample.resources.memory.incrementalRssBytes,
      ),
    ).p95,
  );
  compare(
    'memory.process_rss.p95_bytes',
    DistributionSummary.fromValues(
      baselineSamples.map((sample) => sample.resources.memory.processRssBytes),
    ).p95,
    DistributionSummary.fromValues(
      candidateSamples.map((sample) => sample.resources.memory.processRssBytes),
    ).p95,
  );
  compare(
    'memory.peak_rss.p95_bytes',
    DistributionSummary.fromValues(
      baselineSamples.map((sample) => sample.resources.memory.peakRssBytes),
    ).p95,
    DistributionSummary.fromValues(
      candidateSamples.map((sample) => sample.resources.memory.peakRssBytes),
    ).p95,
  );
  compare(
    'frame_time.median_of_medians_us',
    DistributionSummary.fromValues(
      baselineSamples.map((sample) => sample.resources.frameTime.medianUs),
    ).p50,
    DistributionSummary.fromValues(
      candidateSamples.map((sample) => sample.resources.frameTime.medianUs),
    ).p50,
  );
  compare(
    'frame_time.p95_of_p95_us',
    DistributionSummary.fromValues(
      baselineSamples.map((sample) => sample.resources.frameTime.p95Us),
    ).p95,
    DistributionSummary.fromValues(
      candidateSamples.map((sample) => sample.resources.frameTime.p95Us),
    ).p95,
  );
  compareHigher(
    'endurance.minimum_duration_ms',
    baselineSamples
        .map((sample) => sample.resources.endurance.durationMs)
        .reduce(math.min),
    candidateSamples
        .map((sample) => sample.resources.endurance.durationMs)
        .reduce(math.min),
  );
  compareHigher(
    'endurance.minimum_action_count',
    baselineSamples
        .map((sample) => sample.resources.endurance.actionCount)
        .reduce(math.min),
    candidateSamples
        .map((sample) => sample.resources.endurance.actionCount)
        .reduce(math.min),
  );
  compare(
    'endurance.maximum_positive_growth_bytes',
    baselineSamples
        .map((sample) => math.max(0, sample.resources.endurance.growthBytes))
        .reduce(math.max),
    candidateSamples
        .map((sample) => math.max(0, sample.resources.endurance.growthBytes))
        .reduce(math.max),
  );
  compare(
    'endurance.failure_count',
    _enduranceFailureCount(baselineSamples),
    _enduranceFailureCount(candidateSamples),
  );
  final regressions = [
    for (final entry in metrics.entries)
      if (entry.value['regressed'] == true)
        {
          'metricId': entry.key,
          'baseline': entry.value['baseline'],
          'candidate': entry.value['candidate'],
          'relativeChangePercent': entry.value['relativeChangePercent'],
          'reason': entry.value['reason'],
        },
  ];
  return {
    'baselineConditionId': config.baseline.conditionId,
    'candidateConditionId': config.candidate.conditionId,
    'comparisonTolerancePercent': config.thresholds.comparisonTolerancePercent,
    'metrics': metrics,
    'regressionStatus': regressions.isEmpty ? 'pass' : 'fail',
    'regressions': regressions,
  };
}

Map<String, Object?> _metricComparison({
  required String metricId,
  required num baseline,
  required num candidate,
  required double tolerancePercent,
  bool lowerIsBetter = true,
}) {
  final absoluteChange = candidate - baseline;
  final double? relativeChange = baseline == 0
      ? (candidate == 0 ? 0 : null)
      : absoluteChange / baseline * 100;
  final regressed = relativeChange == null
      ? lowerIsBetter && candidate > 0
      : lowerIsBetter
      ? relativeChange > tolerancePercent
      : relativeChange < -tolerancePercent;
  return {
    'metricId': metricId,
    'baseline': baseline,
    'candidate': candidate,
    'absoluteChange': absoluteChange,
    'relativeChangePercent': relativeChange,
    'lowerIsBetter': lowerIsBetter,
    'regressed': regressed,
    'reason': regressed
        ? (relativeChange == null
              ? 'Candidate is non-zero while the baseline is zero.'
              : lowerIsBetter
              ? 'Relative increase exceeds the preregistered tolerance.'
              : 'Relative decrease exceeds the preregistered tolerance.')
        : null,
  };
}

List<Map<String, Object?>> _quantitativeGates({
  required PerformanceConfig config,
  required List<LoadedPerformanceSample> baseline,
  required List<LoadedPerformanceSample> candidate,
  required bool blockedByObservationEffect,
}) {
  final target = config.thresholds;
  final candidateSamples = [for (final item in candidate) item.sample];
  final baselineSamples = [for (final item in baseline) item.sample];
  final actionP95 = DistributionSummary.fromValues(
    candidateSamples.map(
      (sample) => sample.phaseTimings.actionOverheadExcludingSettleUs,
    ),
  ).p95;
  final totalP95 = DistributionSummary.fromValues(
    candidateSamples.map((sample) => sample.phaseTimings.totalUs),
  ).p95;
  final tokenP95 = DistributionSummary.fromValues(
    candidateSamples.map((sample) => _estimatedTokens(config, sample)),
  ).p95;
  final idleCpuP95 = DistributionSummary.fromValues(
    candidateSamples.map((sample) => sample.resources.cpu.idlePercent),
  ).p95;
  final rssP95 = DistributionSummary.fromValues(
    candidateSamples.map(
      (sample) => sample.resources.memory.incrementalRssBytes,
    ),
  ).p95;
  final baselineFrameMedian = DistributionSummary.fromValues(
    baselineSamples.map((sample) => sample.resources.frameTime.medianUs),
  ).p50;
  final candidateFrameMedian = DistributionSummary.fromValues(
    candidateSamples.map((sample) => sample.resources.frameTime.medianUs),
  ).p50;
  final frameRegression = baselineFrameMedian == 0
      ? (candidateFrameMedian == 0 ? 0.0 : null)
      : (candidateFrameMedian - baselineFrameMedian) /
            baselineFrameMedian *
            100;
  final endurancePass = candidateSamples.every((sample) {
    final endurance = sample.resources.endurance;
    final requiredExtent =
        endurance.durationMs >= target.enduranceMinDurationMs ||
        endurance.actionCount >= target.enduranceMinActions;
    return requiredExtent &&
        endurance.clean &&
        endurance.growthBytes <= target.enduranceMaxGrowthBytes;
  });

  Map<String, Object?> gate({
    required String gateId,
    required Object threshold,
    required Object? observed,
    required bool passes,
    String? comparison,
    bool applicable = true,
  }) {
    if (blockedByObservationEffect) {
      return {
        'gateId': gateId,
        'status': 'blocked',
        'threshold': threshold,
        'observed': observed,
        'reason': 'Observation non-interference failed.',
      };
    }
    if (target.status == ThresholdRatificationStatus.provisional) {
      return {
        'gateId': gateId,
        'status': 'unmeasured',
        'threshold': threshold,
        'observed': observed,
        'reason':
            'The environment and threshold have not been explicitly ratified.',
      };
    }
    if (!applicable) {
      return {
        'gateId': gateId,
        'status': 'unmeasured',
        'threshold': threshold,
        'observed': null,
        'reason':
            'This config pins `${config.environment.fixture.scenario.jsonName}`; '
            'the gate requires its own preregistered scenario.',
      };
    }
    return {
      'gateId': gateId,
      'status': passes ? 'pass' : 'fail',
      'threshold': threshold,
      'observed': observed,
      if (comparison != null) 'comparison': comparison,
      if (!passes) 'reason': 'Observed value did not meet the ratified gate.',
    };
  }

  return [
    gate(
      gateId: 'warm_brief_inspect_standard_p95_us',
      threshold: target.warmBriefInspectStandardP95Us,
      observed: totalP95,
      passes: totalP95 <= target.warmBriefInspectStandardP95Us,
      comparison: 'less_than_or_equal',
      applicable:
          config.environment.fixture.scenario ==
          PerformanceScenario.warmBriefInspectStandard,
    ),
    gate(
      gateId: 'warm_brief_inspect_large_tree_p95_us',
      threshold: target.warmBriefInspectLargeTreeP95Us,
      observed: totalP95,
      passes: totalP95 <= target.warmBriefInspectLargeTreeP95Us,
      comparison: 'less_than_or_equal',
      applicable:
          config.environment.fixture.scenario ==
          PerformanceScenario.warmBriefInspectLargeTree,
    ),
    gate(
      gateId: 'action_overhead_p95_us',
      threshold: target.actionOverheadP95Us,
      observed: actionP95,
      passes: actionP95 <= target.actionOverheadP95Us,
      comparison: 'less_than_or_equal',
      applicable:
          config.environment.fixture.scenario ==
          PerformanceScenario.actionOverhead,
    ),
    gate(
      gateId: 'payload_p95_estimated_tokens',
      threshold: target.payloadP95EstimatedTokens,
      observed: tokenP95,
      passes: tokenP95 <= target.payloadP95EstimatedTokens,
      comparison: 'less_than_or_equal',
    ),
    gate(
      gateId: 'idle_cpu_p95_percent',
      threshold: target.idleCpuMaxPercent,
      observed: idleCpuP95,
      passes: idleCpuP95 < target.idleCpuMaxPercent,
      comparison: 'strictly_less_than',
    ),
    gate(
      gateId: 'incremental_rss_p95_bytes',
      threshold: target.incrementalRssMaxBytes,
      observed: rssP95,
      passes: rssP95 < target.incrementalRssMaxBytes,
      comparison: 'strictly_less_than',
    ),
    gate(
      gateId: 'frame_time_median_regression_percent',
      threshold: target.frameTimeMedianRegressionMaxPercent,
      observed: frameRegression,
      passes:
          frameRegression != null &&
          frameRegression < target.frameTimeMedianRegressionMaxPercent,
      comparison: 'strictly_less_than',
    ),
    gate(
      gateId: 'endurance',
      threshold: {
        'minimumDurationMsOrActions': {
          'durationMs': target.enduranceMinDurationMs,
          'actions': target.enduranceMinActions,
        },
        'maximumGrowthBytes': target.enduranceMaxGrowthBytes,
        'crashes': 0,
        'crossovers': 0,
        'deadlocks': 0,
        'unboundedGrowth': false,
      },
      observed: {
        'allSamplesPass': endurancePass,
        'sampleCount': candidateSamples.length,
      },
      passes: endurancePass,
    ),
  ];
}

int _estimatedTokens(PerformanceConfig config, PerformanceRawSample sample) =>
    (sample.responsePayloadBytes /
            config.environment.measurement.estimatedUtf8BytesPerToken)
        .ceil();

int _enduranceFailureCount(List<PerformanceRawSample> samples) =>
    samples.fold<int>(0, (total, sample) {
      final endurance = sample.resources.endurance;
      return total +
          endurance.crashCount +
          endurance.crossoverCount +
          endurance.deadlockCount +
          (endurance.unboundedGrowthObserved ? 1 : 0);
    });

Map<String, Object?> _provenanceSummary(
  List<PerformanceRawSample> samples,
  MeasurementProvenance Function(PerformanceRawSample sample) select,
) {
  final counts = <String, ({MeasurementProvenance value, int count})>{};
  final timestamps = <DateTime>[];
  for (final sample in samples) {
    final value = select(sample);
    timestamps.add(value.capturedAtUtc);
    final identity = canonicalJsonEncode({
      'source': value.source,
      'method': value.method,
      'collectorVersion': value.collectorVersion,
      'target': value.target,
    });
    final existing = counts[identity];
    counts[identity] = (value: value, count: (existing?.count ?? 0) + 1);
  }
  timestamps.sort();
  final identities = counts.keys.toList()..sort();
  return {
    'observationCount': samples.length,
    'earliestCapturedAtUtc': timestamps.first.toIso8601String(),
    'latestCapturedAtUtc': timestamps.last.toIso8601String(),
    'collectors': [
      for (final identity in identities)
        {
          'source': counts[identity]!.value.source,
          'method': counts[identity]!.value.method,
          'collectorVersion': counts[identity]!.value.collectorVersion,
          'target': counts[identity]!.value.target,
          'observationCount': counts[identity]!.count,
        },
    ],
  };
}

num _nearestRank(List<num> sorted, double percentile) {
  final rank = (percentile * sorted.length).ceil();
  return sorted[math.max(0, rank - 1)];
}

Map<String, Object?> _signedDistribution(Iterable<int> input) {
  final values = input.toList()..sort();
  if (values.isEmpty) throw ArgumentError('A distribution cannot be empty.');
  final sum = values.fold<int>(0, (total, value) => total + value);
  return {
    'count': values.length,
    'minimum': values.first,
    'maximum': values.last,
    'mean': sum / values.length,
    'p50': _nearestRank(values, 0.50),
    'p95': _nearestRank(values, 0.95),
    'p99': _nearestRank(values, 0.99),
  };
}
